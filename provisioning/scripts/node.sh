#!/bin/bash
# ceph-lab — node.sh
# Joins a worker node to the k3s cluster.
set -euo pipefail

CONTROL_PLANE_IP="${SANDBOX_CONTROL_PLANE_IP:-192.168.56.50}"
K3S_CHANNEL="${SANDBOX_K3S_CHANNEL:-v1.33}"

# Detect this node's static IP on the ceph-lab host-only interface (eth1).
NODE_IP=$(ip -4 addr show | grep '192\.168\.56\.' | awk '{print $2}' | cut -d/ -f1 | head -n1)

echo "[ceph-lab worker] Node IP = ${NODE_IP}"
echo "[ceph-lab worker] Waiting for node-token from ceph-control..."

for _i in $(seq 1 60); do
    [ -f /ceph-lab/provisioning/node-token ] && break
    echo "  waiting for node-token (${_i}/60)..."
    sleep 5
done
[ -f /ceph-lab/provisioning/node-token ] \
    || { echo "[ERROR] node-token not available after 5 min"; exit 1; }

K3S_TOKEN=$(cat /ceph-lab/provisioning/node-token)

echo "[ceph-lab worker] Joining cluster at ${CONTROL_PLANE_IP}..."
# Run synchronously — Lima waits for kubelet.conf via a probe.
curl -sfL https://get.k3s.io | \
    INSTALL_K3S_CHANNEL="${K3S_CHANNEL}" \
    K3S_URL="https://${CONTROL_PLANE_IP}:6443" \
    K3S_TOKEN="${K3S_TOKEN}" \
    INSTALL_K3S_EXEC="agent --node-ip=${NODE_IP}" \
    sh -

echo "✓ node.sh complete — k3s-agent joined cluster"
