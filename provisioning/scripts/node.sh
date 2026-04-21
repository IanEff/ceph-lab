#!/bin/bash
# ceph-lab — node.sh
# Joins a worker node to the k3s cluster.
set -euo pipefail

CONTROL_PLANE_IP="${SANDBOX_CONTROL_PLANE_IP:-192.168.56.50}"
K3S_CHANNEL="${SANDBOX_K3S_CHANNEL:-v1.32}"

# Detect this node's private network IP
NODE_IP=$(ip -4 addr show | grep '192\.168\.56\.' | awk '{print $2}' | cut -d/ -f1 | head -n1)

echo "[ceph-lab worker] Node IP = ${NODE_IP}"
echo "[ceph-lab worker] Waiting for join token from ceph-control..."

until [ -f /vagrant/node-token ]; do
    echo "  /vagrant/node-token not found yet — retrying in 5s..."
    sleep 5
done

K3S_TOKEN=$(cat /vagrant/node-token)

echo "[ceph-lab worker] Joining cluster at ${CONTROL_PLANE_IP}..."
# INSTALL_K3S_SKIP_START=true prevents the installer from blocking on
# `systemctl start k3s-agent` (a Type=notify unit that takes 1-2 min to reach
# READY). We kick it off with --no-block so Vagrant doesn't stall per node.
# The service is still enabled; it will join the cluster in the background.
curl -sfL https://get.k3s.io | \
    INSTALL_K3S_CHANNEL="${K3S_CHANNEL}" \
    K3S_URL="https://${CONTROL_PLANE_IP}:6443" \
    K3S_TOKEN="${K3S_TOKEN}" \
    INSTALL_K3S_EXEC="agent --node-ip=${NODE_IP}" \
    INSTALL_K3S_SKIP_START=true \
    sh -

systemctl --no-block start k3s-agent

echo "✓ node.sh complete — k3s-agent starting in background"
