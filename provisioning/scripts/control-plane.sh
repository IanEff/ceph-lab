#!/bin/bash
# ceph-lab — control-plane.sh
# Installs k3s server, Helm, and Cilium CNI on the control plane node.
set -euo pipefail

CONTROL_PLANE_IP="${SANDBOX_CONTROL_PLANE_IP:-192.168.56.50}"
K3S_CHANNEL="${SANDBOX_K3S_CHANNEL:-v1.33}"
CILIUM_VERSION="${CILIUM_VERSION:-1.19.3}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.5.1}"

# Lima provision steps run as root directly; SUDO_USER is never set.
# Source Lima's cidata env for the authoritative interactive user identity.
# shellcheck disable=SC1091
[ -f /mnt/lima-cidata/lima.env ] && source /mnt/lima-cidata/lima.env
LAB_USER="${LIMA_CIDATA_USER:-}"

echo "══════════════════════════════════════════"
echo "  ceph-lab — control-plane setup           "
echo "══════════════════════════════════════════"

echo "[1] Install Helm"
curl -fsSL -o /tmp/get_helm.sh \
    https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 /tmp/get_helm.sh && /tmp/get_helm.sh && rm /tmp/get_helm.sh

echo "[2] Create swap file for control-plane memory headroom"
# common.sh disables system swap; re-enable a dedicated swap file here so the
# API server doesn't OOM while ArgoCD syncs before workers join.
if ! swapon --show | grep -q '/swapfile'; then
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

echo "[3] Write k3s server config"
mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml <<EOF
advertise-address: ${CONTROL_PLANE_IP}
node-ip: ${CONTROL_PLANE_IP}
flannel-backend: "none"
disable-network-policy: true
disable-kube-proxy: true
disable:
  - traefik
  - servicelb
cluster-cidr: "10.244.0.0/16"
service-cidr: "10.96.0.0/12"
cluster-domain: "cluster.local"
tls-san:
  - "${CONTROL_PLANE_IP}"
  - "ceph-control"
data-dir: "/var/lib/rancher/k3s"
kubelet-arg:
  - "fail-swap-on=false"
EOF

echo "[4] Install k3s server (channel: ${K3S_CHANNEL})"
curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL="${K3S_CHANNEL}" sh -

echo "[5] Wait for API server to respond"
until kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes &>/dev/null; do
    sleep 3
done

echo "[6] Set up kubeconfig for root + ${LAB_USER}"
mkdir -p /root/.kube
cp /etc/rancher/k3s/k3s.yaml /root/.kube/config
sed -i "s/127\.0\.0\.1/${CONTROL_PLANE_IP}/g" /root/.kube/config

LAB_USER_HOME="${LIMA_CIDATA_HOME:-}"
if [ -n "${LAB_USER_HOME}" ]; then
    mkdir -p "${LAB_USER_HOME}/.kube"
    cp /etc/rancher/k3s/k3s.yaml "${LAB_USER_HOME}/.kube/config"
    sed -i "s/127\.0\.0\.1/${CONTROL_PLANE_IP}/g" "${LAB_USER_HOME}/.kube/config"
    chown -R "${LAB_USER}:${LAB_USER}" "${LAB_USER_HOME}/.kube"
fi

echo "[6b] Wait for API server at ${CONTROL_PLANE_IP}:6443 (k3s may briefly restart during init)"
until kubectl --kubeconfig /root/.kube/config get nodes &>/dev/null; do
    sleep 3
done

echo "[7] Install Cilium CNI"
bash /ceph-lab/provisioning/scripts/install_cilium.sh

echo "[8] Publish join token for worker nodes"
until [ -f /var/lib/rancher/k3s/server/node-token ]; do sleep 1; done
install -m 644 /var/lib/rancher/k3s/server/node-token /ceph-lab/provisioning/node-token

echo "✓ control-plane.sh complete — workers can now join"
