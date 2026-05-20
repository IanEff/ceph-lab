#!/bin/bash
# ceph-lab — node.sh
# Joins a worker node to the k3s cluster.
set -euo pipefail

# Idempotency guard — Lima re-runs provision scripts on every boot.
# Skip if already joined (destroy + recreate resets this).
if [ -f /etc/ceph-lab-node.done ]; then
    echo "[node.sh] Already provisioned, skipping."
    exit 0
fi

CONTROL_PLANE_IP="${SANDBOX_CONTROL_PLANE_IP:-192.168.56.50}"
K3S_CHANNEL="${SANDBOX_K3S_CHANNEL:-v1.33}"

# Detect this node's static IP on the ceph-lab host-only interface (eth1).
NODE_IP=$(ip -4 addr show | grep '192\.168\.56\.' | awk '{print $2}' | cut -d/ -f1 | head -n1)

echo "[ceph-lab worker] Node IP = ${NODE_IP}"
echo "[ceph-lab worker] Waiting for node-token from ceph-control..."

# CP publishes the token right after the API server is up (well before
# anything slow like Cilium install). 3 min is plenty; if it's not there by
# then the CP itself is broken and there's no point waiting longer.
for _i in $(seq 1 36); do
    [ -f /ceph-lab/provisioning/node-token ] && break
    echo "  waiting for node-token (${_i}/36)..."
    sleep 5
done
[ -f /ceph-lab/provisioning/node-token ] \
    || { echo "[ERROR] node-token not available after 3 min — CP is broken"; exit 1; }

K3S_TOKEN=$(cat /ceph-lab/provisioning/node-token)

echo "[ceph-lab worker] Joining cluster at ${CONTROL_PLANE_IP}..."
curl --fail --show-error --silent --location \
     --connect-timeout 15 --max-time 30 --retry 3 --retry-delay 5 \
     -o /tmp/k3s-install.sh https://get.k3s.io
chmod +x /tmp/k3s-install.sh
timeout 300 env \
    INSTALL_K3S_CHANNEL="${K3S_CHANNEL}" \
    K3S_URL="https://${CONTROL_PLANE_IP}:6443" \
    K3S_TOKEN="${K3S_TOKEN}" \
    INSTALL_K3S_EXEC="agent --node-ip=${NODE_IP}" \
    /tmp/k3s-install.sh
rm -f /tmp/k3s-install.sh

echo "[ceph-lab worker] Waiting for k3s-agent service to become active..."
until systemctl is-active --quiet k3s-agent; do sleep 3; done

touch /etc/ceph-lab-node.done
echo "✓ node.sh complete — k3s-agent joined cluster"
