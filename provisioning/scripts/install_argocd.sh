#!/bin/bash
# ceph-lab — install_argocd.sh
# Bootstraps ArgoCD and seeds the root Application that drives GitOps.
#
# Requires (from .env / provision.env):
#   GITOPS_REPO_URL       — full URL of this repo (SSH or HTTPS)
#   GITOPS_REPO_TOKEN     — GitHub token for HTTPS access  (leave empty for SSH)
#   GITOPS_SSH_KEY_PATH   — relative path to SSH private key (leave empty for HTTPS)
#   ARGOCD_VERSION        — "stable" or "v2.14.0" etc.
#
# Run from inside ceph-control VM:
#   bash /ceph-lab/provisioning/scripts/install_argocd.sh
set -euo pipefail

export KUBECONFIG=/root/.kube/config

# Load cluster config (secrets from .env, topology from provision.env)
set -a
# shellcheck disable=SC1091
source /ceph-lab/provisioning/provision.env
# shellcheck disable=SC1091
[ -f /ceph-lab/.env ] && source /ceph-lab/.env
set +a

GITOPS_REPO_URL="${GITOPS_REPO_URL:-}"
GITOPS_REPO_TOKEN="${GITOPS_REPO_TOKEN:-}"
GITOPS_SSH_KEY_PATH="${GITOPS_SSH_KEY_PATH:-}"
ARGOCD_VERSION="${ARGOCD_VERSION:-stable}"

# Auto-detect the deploy key when it exists at the conventional location
# and no SSH key path was explicitly configured.
if [ -z "$GITOPS_SSH_KEY_PATH" ] && [ -f "/ceph-lab/deploy_ceph-lab" ]; then
    GITOPS_SSH_KEY_PATH="deploy_ceph-lab"
    echo "  Auto-detected deploy key at /ceph-lab/deploy_ceph-lab"
fi

if [ -z "$GITOPS_REPO_URL" ]; then
    echo "ERROR: GITOPS_REPO_URL is not set. Set it in .env before running."
    echo "  Example: GITOPS_REPO_URL=https://github.com/YOUR_USERNAME/ceph-lab.git"
    exit 1
fi

echo "══════════════════════════════════════════"
echo "  ceph-lab — ArgoCD bootstrap              "
echo "  Repo: ${GITOPS_REPO_URL}                 "
echo "══════════════════════════════════════════"

echo "[0] Pre-bootstrap Cilium Gateway resources (LBIPPool, L2Policy, Gateway, HTTPRoutes)"
echo "    This makes 192.168.56.200 reachable before ArgoCD reconciles wave -10."
CILIUM_APP=/ceph-lab/applications/infrastructure/cilium
bootstrap_ok=0
for attempt in $(seq 1 8); do
    echo "[0] Building and applying Cilium kustomization (attempt ${attempt}/8)..."
    output=$(kubectl kustomize "${CILIUM_APP}" --enable-helm \
        | kubectl apply --server-side --force-conflicts -f - 2>&1) || true
    echo "$output"
    if echo "$output" | grep -qE ' configured$| created$| unchanged$'; then
        bootstrap_ok=1
        break
    fi
    echo "[0] Attempt ${attempt}/8 incomplete; retrying in 10s..."
    sleep 10
done
if [ "$bootstrap_ok" -eq 1 ]; then
    echo "[0] Cilium resources applied.  Waiting for daemonset to settle..."
    kubectl rollout status daemonset/cilium -n kube-system --timeout=3m || true
else
    echo "[WARN] Pre-bootstrap may be incomplete; ArgoCD will reconcile."
fi

echo "[0] Waiting for Gateway to acquire LB IP (up to 120s)..."
for _i in $(seq 1 12); do
    GW_IP=$(kubectl get gateway cilium-gateway -n kube-system \
        -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
    if [ -n "$GW_IP" ]; then
        echo "[0] Gateway LB IP: ${GW_IP}  — 192.168.56.200 is now L2-announced."
        break
    fi
    sleep 10
done

echo "[1] Install ArgoCD (${ARGOCD_VERSION})"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --server-side -n argocd -f \
    "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

echo "[2] Apply local bootstrap patches (insecure mode, kustomize-helm, bcrypt password)"
kubectl apply --server-side -k /ceph-lab/cluster-bootstrap/argocd/

echo "[3] Wait for ArgoCD server to be ready..."
kubectl rollout status deployment/argocd-server -n argocd --timeout=5m

echo "[4] Configure repository access"
if [ -n "$GITOPS_SSH_KEY_PATH" ] && [ -f "/ceph-lab/${GITOPS_SSH_KEY_PATH}" ]; then
    echo "  Using SSH deploy key: ${GITOPS_SSH_KEY_PATH}"
    # Indent each line of the key for the YAML literal block scalar
    SSH_KEY_INDENTED=$(awk '{print "    " $0}' "/ceph-lab/${GITOPS_SSH_KEY_PATH}")
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ceph-lab-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: "${GITOPS_REPO_URL}"
  insecureIgnoreHostKey: "true"
  sshPrivateKey: |
${SSH_KEY_INDENTED}
EOF
elif [ -n "$GITOPS_REPO_TOKEN" ]; then
    echo "  Using HTTPS token"
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ceph-lab-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: "${GITOPS_REPO_URL}"
  password: "${GITOPS_REPO_TOKEN}"
  username: "git"
EOF
else
    echo "  WARNING: No repo credentials configured."
    echo "  If ${GITOPS_REPO_URL} is public, ArgoCD will clone it without auth."
    echo "  For private repos, set GITOPS_REPO_TOKEN or GITOPS_SSH_KEY_PATH in .env."
fi

echo "[5] Substitute GITOPS_REPO_URL placeholder across all manifests"
# All Application / ApplicationSet YAMLs under applications/clusters/ and
# cluster-bootstrap/ contain the literal string GITOPS_REPO_URL.  Replace it
# in-place so ArgoCD can resolve the correct repository when it reads them.
find /ceph-lab/applications/clusters /ceph-lab/cluster-bootstrap \
    -type f -name "*.yaml" \
    -exec sed -i "s|GITOPS_REPO_URL|${GITOPS_REPO_URL}|g" {} +

echo "[5b] Apply root Application (seeds entire GitOps tree)"
kubectl apply -f /ceph-lab/cluster-bootstrap/bootstrap/root-app.yaml

echo "[6] Install argocd CLI"
ARGOCD_CLI_VERSION=$(curl -sL \
    https://api.github.com/repos/argoproj/argo-cd/releases/latest \
    | grep '"tag_name"' | cut -d'"' -f4)
ARCH=$(dpkg --print-architecture)
curl -fsSL -o /usr/local/bin/argocd \
    "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_CLI_VERSION}/argocd-linux-${ARCH}"
chmod +x /usr/local/bin/argocd

echo ""
echo "✓ ArgoCD is bootstrapped!"
echo ""
echo "  UI:       http://argocd.ceph.lab  (after Gateway is up)"
echo "  Login:    admin / password  (CHANGE IN PRODUCTION)"
echo ""
echo "  Watch sync progress:"
echo "    kubectl get applications -n argocd -w"
echo ""
echo "  Sync waves overview:"
echo "    -15: gateway-api CRDs"
echo "    -10: cilium (reconciled)"
echo "     -6: prometheus-operator-crds"
echo "     -5: cert-manager, prometheus, grafana"
echo "      0: alloy, metrics-server"
echo "      1: l7-policies (CiliumNetworkPolicies)"
echo "     10: argocd-ingress"
echo "     20: rook operator"
echo "     25: rook cluster (CephCluster CR)"
echo "     30: rook storage (pools, filesystem, object-store)"
echo "     35: rook gateway routes"
