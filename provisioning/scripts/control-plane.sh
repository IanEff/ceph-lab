#!/bin/bash
# ceph-lab — control-plane.sh
# Installs k3s server, Helm, and Cilium CNI on the control plane node.
set -euo pipefail

# Idempotency guard — Lima re-runs provision scripts on every boot.
# Skip if already provisioned (destroy + recreate resets this).
if [ -f /etc/ceph-lab-control-plane.done ]; then
    echo "[control-plane.sh] Already provisioned, skipping."
    exit 0
fi

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
# Skip get-helm-3 entirely — its inner curl has no timeout and hangs forever
# on slow vzNAT. Download the binary ourselves with hard fail-fast timeouts.
HELM_VERSION="v3.16.3"
ARCH=$(dpkg --print-architecture)
curl --fail --show-error --silent --location \
     --connect-timeout 15 --max-time 180 --retry 3 --retry-delay 5 \
     -o /tmp/helm.tar.gz \
     "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
tar -xzf /tmp/helm.tar.gz -C /tmp
install -m 755 "/tmp/linux-${ARCH}/helm" /usr/local/bin/helm
rm -rf /tmp/helm.tar.gz "/tmp/linux-${ARCH}"

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
# Cap the whole install at 5 min so a hung download fails loudly instead of
# silently consuming the Lima boot timeout.
curl --fail --show-error --silent --location \
     --connect-timeout 15 --max-time 30 --retry 3 --retry-delay 5 \
     -o /tmp/k3s-install.sh https://get.k3s.io
chmod +x /tmp/k3s-install.sh
timeout 300 env INSTALL_K3S_CHANNEL="${K3S_CHANNEL}" /tmp/k3s-install.sh
rm -f /tmp/k3s-install.sh

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

# Publish the join token BEFORE the (slow) Cilium install so workers can begin
# joining in parallel. If Cilium install fails or pulls images slowly, workers
# still get the token and form the cluster (they'll be NotReady until Cilium
# spreads, which is fine — kubelets and k3s-agent come up regardless).
echo "[7] Publish join token for worker nodes"
until [ -f /var/lib/rancher/k3s/server/node-token ]; do sleep 1; done
install -m 644 /var/lib/rancher/k3s/server/node-token /ceph-lab/provisioning/node-token

echo "[8] Install Cilium CNI"
bash /ceph-lab/provisioning/scripts/install_cilium.sh

echo "[8b] Wait for API server after Cilium install"
until kubectl --kubeconfig /root/.kube/config get nodes &>/dev/null; do
    sleep 3
done

touch /etc/ceph-lab-control-plane.done
echo "✓ control-plane.sh complete — workers can now join"
