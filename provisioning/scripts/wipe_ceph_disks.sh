#!/bin/bash
# ceph-lab — wipe_ceph_disks.sh
# DESTRUCTIVE: deletes all Rook Ceph resources and zeroes OSD disks.
# Use this to reinstall Rook without rebuilding VMs.
# Run from the REPO ROOT on your Mac.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

NAMESPACE="rook-ceph"
NUM_NODES="${SANDBOX_NUM_CEPH_NODES:-3}"
# OSD disks on Lima virtio-blk: vdc (osd-1) and vdd (osd-2)
OSD_DISKS=("vdc" "vdd")

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
kubectl patch cephcluster rook-ceph -n "$NAMESPACE" \
    -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
kubectl delete cephcluster rook-ceph -n "$NAMESPACE" \
    --ignore-not-found=true --timeout=60s || true

echo "─── Step 4: Uninstall Rook operator Helm release ────────────────────────"
helm uninstall rook-ceph -n "$NAMESPACE" 2>/dev/null || true
helm uninstall rook-ceph-cluster -n "$NAMESPACE" 2>/dev/null || true

echo "─── Step 5: Force-delete rook-ceph namespace ────────────────────────────"
kubectl get namespace "$NAMESPACE" -o json 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" \
    | kubectl replace --raw "/api/v1/namespaces/${NAMESPACE}/finalize" -f - 2>/dev/null || true
kubectl delete namespace "$NAMESPACE" --ignore-not-found=true --timeout=30s || true

echo "─── Step 6: Zero OSD disks on each worker node ──────────────────────────"
# Lima virtio-blk: vdc = osd-1, vdd = osd-2
# Unmount Lima auto-mounts, wipe partition tables, clean up fstab entries.
for ((n=1; n<=NUM_NODES; n++)); do
    NODE="ceph-node-${n}"
    echo "  Wiping ${NODE}..."
    limactl shell "${NODE}" -- sudo bash -s << 'WIPE'
set -e
for dev in vdc vdd; do
    # Unmount any partitions Lima auto-mounted
    for part in /dev/${dev}?*; do
        [ -b "$part" ] && umount "$part" 2>/dev/null || true
    done
    dd if=/dev/zero of=/dev/${dev} bs=4096 count=2048 2>/dev/null || true
    wipefs -a /dev/${dev} 2>/dev/null || true
    sgdisk --zap-all /dev/${dev} 2>/dev/null || true
    echo "  /dev/${dev} wiped"
done
# Remove Lima auto-mount fstab entries for OSD disks
sed -i '/lima-.*-osd-/d' /etc/fstab || true
rm -rf /var/lib/rook
WIPE
done

echo ""
echo "✓ Wipe complete. Push updated manifests and let ArgoCD sync rook-* apps,"
echo "  or run: kubectl rollout restart deployment/rook-ceph-operator -n rook-ceph"
