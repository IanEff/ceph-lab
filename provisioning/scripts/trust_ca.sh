#!/bin/bash
# ceph-lab — trust_ca.sh
#
# Extracts the fixed ceph-lab CA cert from the cluster and trusts it in the
# macOS System Keychain. Because the CA is committed to the repo (not generated
# by cert-manager on each run), you only need to run this ONCE — it survives
# 'vagrant destroy && vagrant up'.
#
# Usage:
#   bash provisioning/scripts/trust_ca.sh [--context ceph-lab]
#
# Requires: kubectl with access to the cluster, sudo for keychain write.

set -euo pipefail

CONTEXT="${KUBE_CONTEXT:-ceph-lab}"
CERT_FILE="/tmp/ceph-lab-ca.crt"

# Allow overriding context via flag
while [[ $# -gt 0 ]]; do
    case "$1" in
        --context) CONTEXT="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

echo "[trust_ca] Using kubeconfig context: ${CONTEXT}"

# Wait for the secret to exist (cert-manager might not have applied yet)
echo "[trust_ca] Waiting for ceph-lab-ca-keypair secret..."
for i in $(seq 1 30); do
    if kubectl get secret ceph-lab-ca-keypair -n cert-manager --context "${CONTEXT}" &>/dev/null; then
        break
    fi
    echo "  Attempt ${i}/30 — secret not ready yet, retrying in 5s..."
    sleep 5
done

# Extract the CA cert
kubectl get secret ceph-lab-ca-keypair \
    -n cert-manager \
    --context "${CONTEXT}" \
    -o jsonpath='{.data.tls\.crt}' | base64 -d > "${CERT_FILE}"

echo "[trust_ca] Extracted CA cert to ${CERT_FILE}"
echo "[trust_ca] Subject: $(openssl x509 -noout -subject -in "${CERT_FILE}")"
echo "[trust_ca] Expires: $(openssl x509 -noout -enddate -in "${CERT_FILE}")"

# Check if already trusted (avoid prompting for sudo unnecessarily)
FINGERPRINT=$(openssl x509 -noout -fingerprint -sha256 -in "${CERT_FILE}" | cut -d= -f2)
if security find-certificate -Z -a /Library/Keychains/System.keychain 2>/dev/null | grep -qi "${FINGERPRINT//:/}"; then
    echo "[trust_ca] CA cert is already trusted in System Keychain — nothing to do."
    exit 0
fi

echo "[trust_ca] Adding CA cert to macOS System Keychain (requires sudo)..."
sudo security add-trusted-cert -d -r trustRoot \
    -k /Library/Keychains/System.keychain \
    "${CERT_FILE}"

echo ""
echo "[trust_ca] Done. *.ceph.lab TLS is now trusted on this Mac."
echo "  argocd login argocd.ceph.lab --username admin --password password --grpc-web"
