#!/bin/bash
# ceph-lab — wipe_ceph_disks.sh
# DESTRUCTIVE: deletes all Rook Ceph resources and zeroes OSD disks.
# Use this to reinstall Rook without rebuilding VMs.
# Run from the REPO ROOT on your Mac.
set -euo pipefail

NAMESPACE="rook-ceph"
NUM_NODES="${SANDBOX_NUM_CEPH_NODES:-3}"
NODE_IP_BASE="${SANDBOX_CEPH_NODE_IP_BASE:-60}"
OSD_DISKS="${SANDBOX_OSD_DISKS_PER_NODE:-2}"

RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${RED}"
echo "  ██╗    ██╗ █████╗ ██████╗ ███╗   ██╗██╗███╗   ██╗ ██████╗ "
echo "  ██║    ██║██╔══██╗██╔══██╗████╗  ██║██║████╗  ██║██╔════╝ "
echo "  ██║ █╗ ██║███████║██████╔╝██╔██╗ ██║██║██╔██╗ ██║██║  ███╗"
echo "  ██║███╗██║██╔══██║██╔══██╗██║╚██╗██║██║██║╚██╗██║██║   ██║"
echo "  ╚███╔███╔╝██║  ██║██║  ██║██║ ╚████║██║██║ ╚████║╚██████╔╝"
echo "   ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝╚═╝╚═╝  ╚═══╝ ╚═════╝ "
echo -e "${NC}"
echo -e "${YELLOW}This will DESTROY all Rook Ceph resources and zero all OSD disks.${NC}"
echo "VMs will NOT be destroyed — Rook can be reinstalled afterwards."
echo ""
echo "Ceph namespace: ${NAMESPACE}"
echo "OSD nodes:      ceph-node-{1..${NUM_NODES}}"
echo ""
read -rp "Type 'yes' to continue: " CONFIRM
[ "$CONFIRM" = "yes" ] || { echo "Aborted."; exit 1; }

echo ""
echo "─── Step 1: Delete Ceph StorageClasses ─────────────────────────────────"
kubectl delete storageclass rook-ceph-block rook-cephfs rook-ceph-bucket \
    --ignore-not-found=true

echo "─── Step 2: Delete Ceph CRs ─────────────────────────────────────────────"
for kind in CephFilesystem CephObjectStore CephBlockPool CephFilesystemSubVolumeGroup; do
    kubectl delete "$kind" --all -n "$NAMESPACE" --ignore-not-found=true --timeout=60s || true
done

echo "─── Step 3: Delete CephCluster ──────────────────────────────────────────"
# Patch to remove finalizer first
kubectl patch cephcluster rook-ceph -n "$NAMESPACE" \
    -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
kubectl delete cephcluster rook-ceph -n "$NAMESPACE" \
    --ignore-not-found=true --timeout=60s || true

echo "─── Step 4: Uninstall Rook operator Helm release ────────────────────────"
helm uninstall rook-ceph -n "$NAMESPACE" 2>/dev/null || true
helm uninstall rook-ceph-cluster -n "$NAMESPACE" 2>/dev/null || true

echo "─── Step 5: Force-delete rook-ceph namespace ────────────────────────────"
# Strip namespace finalizers via the raw API to avoid hangs
kubectl get namespace "$NAMESPACE" -o json 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" \
    | kubectl replace --raw "/api/v1/namespaces/${NAMESPACE}/finalize" -f - 2>/dev/null || true
kubectl delete namespace "$NAMESPACE" --ignore-not-found=true --timeout=30s || true

echo "─── Step 6: Zero OSD disks on each worker node ──────────────────────────"
# Disk letters: sdc, sdd, sde, ... based on OSD_DISKS count
OSD_DISK_LETTERS=()
for ((i=0; i<OSD_DISKS; i++)); do
    OSD_DISK_LETTERS+=("$(echo "sdc" | tr 'c' "$(printf "\\x$(printf '%x' $((99+i)))")")")
done
# Simpler: just hardcode sdc, sdd from known disk list
OSD_DISK_LIST=("sdc" "sdd" "sde" "sdf" "sdg" "sdh")

for ((n=1; n<=NUM_NODES; n++)); do
    NODE="ceph-node-${n}"
    NODE_IP="192.168.56.$((NODE_IP_BASE + n))"
    KEY=".vagrant/machines/${NODE}/virtualbox/private_key"

    if [ ! -f "$KEY" ]; then
        echo "  Skipping ${NODE} — private key not found at ${KEY}"
        continue
    fi

    echo "  Wiping ${NODE} (${NODE_IP})..."
    for ((i=0; i<OSD_DISKS; i++)); do
        DEV="/dev/${OSD_DISK_LIST[$i]}"
        ssh -i "$KEY" \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR \
            "vagrant@${NODE_IP}" \
            "sudo dd if=/dev/zero of=${DEV} bs=4096 count=2048 2>/dev/null; \
             sudo wipefs -a ${DEV} 2>/dev/null || true; \
             sudo sgdisk --zap-all ${DEV} 2>/dev/null || true; \
             echo '  ${DEV} wiped on ${NODE}'"
    done

    ssh -i "$KEY" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        "vagrant@${NODE_IP}" \
        "sudo rm -rf /var/lib/rook"
done

echo ""
echo "✓ Wipe complete."
echo ""
echo "Reinstall Rook:"
echo "  vagrant ssh ceph-control"
echo "  bash /vagrant/provisioning/scripts/install_rook_ceph.sh  # imperative"
echo ""
echo "OR push updated manifests and let ArgoCD sync the rook-* applications."
