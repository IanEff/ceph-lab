#!/bin/bash
# ceph-lab — control-plane.sh
# Installs k3s server, Helm, and Cilium CNI on the control plane node.
set -euo pipefail

CONTROL_PLANE_IP="${SANDBOX_CONTROL_PLANE_IP:-192.168.56.50}"
K3S_CHANNEL="${SANDBOX_K3S_CHANNEL:-v1.32}"
CILIUM_VERSION="${CILIUM_VERSION:-1.18.2}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.4.1}"

echo "══════════════════════════════════════════"
echo "  ceph-lab — control-plane setup           "
echo "══════════════════════════════════════════"

echo "[1] Install Helm"
curl -fsSL -o /tmp/get_helm.sh \
    https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 /tmp/get_helm.sh && /tmp/get_helm.sh && rm /tmp/get_helm.sh

echo "[2] Write k3s server config"
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
EOF

echo "[3] Install k3s server (channel: ${K3S_CHANNEL})"
curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL="${K3S_CHANNEL}" sh -

echo "[4] Wait for API server to respond"
until kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes &>/dev/null; do
    sleep 3
done

echo "[5] Set up kubeconfig for root + vagrant"
mkdir -p /root/.kube
cp /etc/rancher/k3s/k3s.yaml /root/.kube/config
sed -i "s/127\.0\.0\.1/${CONTROL_PLANE_IP}/g" /root/.kube/config

mkdir -p /home/vagrant/.kube
cp /etc/rancher/k3s/k3s.yaml /home/vagrant/.kube/config
sed -i "s/127\.0\.0\.1/${CONTROL_PLANE_IP}/g" /home/vagrant/.kube/config
chown -R vagrant:vagrant /home/vagrant/.kube

echo "[6] Install Cilium CNI"
bash /vagrant/provisioning/scripts/install_cilium.sh

echo "[7] Publish join token for worker nodes"
until [ -f /var/lib/rancher/k3s/server/node-token ]; do sleep 1; done
install -m 644 /var/lib/rancher/k3s/server/node-token /vagrant/node-token

echo "✓ control-plane.sh complete — workers can now join"
