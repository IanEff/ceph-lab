#!/usr/bin/env bash
# ceph-lab — build_golden_image.sh
#
# Bakes a Lima golden disk image: boots a disposable Lima VM from the stock
# Ubuntu cloud image, runs the *real* common.sh (apt packages, kernel
# modules, sysctl — same script every real node runs, not a templated
# duplicate), pre-pulls every container image the GitOps tree declares into
# k3s's embedded containerd cache, wipes the throwaway k3s server identity,
# and converts the resulting disk into a standalone qcow2 under
# ~/.lima-images/ that ceph-control.yaml/ceph-node.yaml can boot from
# instead of downloading + installing + pulling everything cold every time.
#
# One golden image serves BOTH roles (control-plane and worker): the
# baked content (apt packages, pre-pulled images) is identical either way —
# cpus/memory/additionalDisks are separate Lima instance settings, not part
# of the disk image itself. control-plane.sh/node.sh (the actual k3s
# join/server-init logic, which needs a live join token and per-node
# identity) are deliberately NOT baked — they still run for real on every
# boot, same as today.
#
# Usage: provisioning/scripts/build_golden_image.sh [--keep-builder]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
IMAGES_DIR="${HOME}/.lima-images"
BUILDER_NAME="ceph-lab-image-builder"
KEEP_BUILDER=0

for arg in "$@"; do
    case "$arg" in
        --keep-builder) KEEP_BUILDER=1 ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

GREEN='\033[0;32m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'
info() { echo -e "${GREEN}[build-image]${NC} $*"; }
step() { echo -e "${CYAN}[build-image]${NC} $*"; }
error() { echo -e "${RED}[build-image]${NC} $*" >&2; exit 1; }

command -v limactl >/dev/null 2>&1 || error "limactl not found."
command -v qemu-img >/dev/null 2>&1 || error "qemu-img not found (brew install qemu)."

case "$(uname -m)" in
    arm64) LIMA_ARCH="aarch64" ;;
    x86_64) LIMA_ARCH="x86_64" ;;
    *) error "Unsupported host arch: $(uname -m)" ;;
esac

mkdir -p "${IMAGES_DIR}"
TIMESTAMP="$(date +%Y%m%dT%H%M%S)"
OUT_IMAGE="${IMAGES_DIR}/ceph-lab-golden-${LIMA_ARCH}.qcow2"
ARCHIVE_IMAGE="${IMAGES_DIR}/archive/ceph-lab-golden-${LIMA_ARCH}-${TIMESTAMP}.qcow2"
mkdir -p "${IMAGES_DIR}/archive"

cleanup() {
    if [ "${KEEP_BUILDER}" -eq 0 ]; then
        step "Deleting builder VM ${BUILDER_NAME}..."
        limactl stop "${BUILDER_NAME}" >/dev/null 2>&1 || true
        limactl delete "${BUILDER_NAME}" >/dev/null 2>&1 || true
    else
        info "--keep-builder set; leaving ${BUILDER_NAME} in place for inspection."
    fi
}
trap cleanup EXIT

step "[1/6] Extracting image inventory from the GitOps tree..."
MANIFEST_FILE="$(mktemp)"
python3 "${SCRIPT_DIR}/image_manifest.py" --out "${MANIFEST_FILE}"
IMAGE_COUNT="$(wc -l < "${MANIFEST_FILE}" | tr -d ' ')"
info "Found ${IMAGE_COUNT} images to pre-cache."

step "[2/6] Creating disposable builder VM (${BUILDER_NAME})..."
limactl delete "${BUILDER_NAME}" >/dev/null 2>&1 || true
cat > /tmp/ceph-lab-builder.yaml <<YAML
minimumLimaVersion: "2.0.0"
vmType: "vz"
os: "Linux"
cpus: 4
memory: "6GiB"
disk: "40GiB"
containerd:
  system: false
  user: false
images:
  - location: "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-arm64.img"
    arch: "aarch64"
  - location: "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
    arch: "x86_64"
mounts:
  - location: "${PROJECT_ROOT}"
    mountPoint: "/ceph-lab"
    writable: false
networks:
  - vzNAT: true
portForwards:
  - ignore: true
    proto: any
    guestIP: "0.0.0.0"
YAML
limactl create -y --name="${BUILDER_NAME}" /tmp/ceph-lab-builder.yaml
limactl start -y --timeout 20m "${BUILDER_NAME}"

step "[3/6] Running common.sh baseline on the builder VM..."
limactl shell "${BUILDER_NAME}" -- sudo bash -c "
set -a
source /ceph-lab/provisioning/provision.env
set +a
bash /ceph-lab/provisioning/scripts/common.sh
"

step "[4/6] Pre-pulling ${IMAGE_COUNT} images into containerd..."
limactl copy "${MANIFEST_FILE}" "${BUILDER_NAME}:/tmp/image_manifest.txt"
K3S_CHANNEL="$(grep '^SANDBOX_K3S_CHANNEL=' "${PROJECT_ROOT}/provisioning/provision.env" | cut -d= -f2)"
limactl shell "${BUILDER_NAME}" -- sudo bash -c "
set -euo pipefail
echo '>> Installing k3s (channel ${K3S_CHANNEL}), server disabled from auto-start after install...'
curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL='${K3S_CHANNEL}' INSTALL_K3S_SKIP_ENABLE=true sh -

echo '>> Starting k3s server just long enough to warm containerd...'
systemctl start k3s

echo '>> Waiting for containerd socket...'
ready=0
for attempt in \$(seq 1 30); do
    if k3s ctr images list >/dev/null 2>&1; then ready=1; break; fi
    sleep 2
done
[ \"\$ready\" -eq 1 ] || { echo 'ERROR: containerd never became ready'; exit 1; }

total=0; ok=0; failed=0
while IFS= read -r img || [ -n \"\$img\" ]; do
    img=\$(echo \"\$img\" | xargs); [ -z \"\$img\" ] && continue
    total=\$((total+1))
    for attempt in 1 2 3; do
        if k3s ctr --namespace k8s.io images pull \"\$img\" >/dev/null 2>&1; then
            ok=\$((ok+1)); break
        fi
        sleep \$((attempt*2))
        [ \"\$attempt\" -eq 3 ] && { failed=\$((failed+1)); echo \"  [WARN] failed to pull \$img\"; }
    done
done < /tmp/image_manifest.txt
echo \">> Pre-cache summary: \$ok/\$total succeeded, \$failed failed.\"

echo '>> Wiping throwaway k3s server identity (containerd image cache is kept)...'
systemctl stop k3s
/usr/local/bin/k3s-killall.sh || true
rm -rf /var/lib/rancher/k3s/server/db /var/lib/rancher/k3s/server/tls /etc/rancher/node /tmp/image_manifest.txt
"

step "[5/6] Generalizing (machine-id, cloud-init state)..."
limactl shell "${BUILDER_NAME}" -- sudo bash -c "
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
cloud-init clean --logs || true
"

step "[6/6] Stopping builder and converting disk to a standalone golden image..."
limactl stop "${BUILDER_NAME}"

INSTANCE_DIR="${HOME}/.lima/${BUILDER_NAME}"
DISK_FILE=""
for candidate in "${INSTANCE_DIR}/disk" "${INSTANCE_DIR}/diffdisk"; do
    if [ -f "${candidate}" ]; then
        DISK_FILE="${candidate}"
        break
    fi
done
[ -n "${DISK_FILE}" ] || error "Could not find the builder VM's disk file under ${INSTANCE_DIR} (expected 'disk' or 'diffdisk'). Lima's internal layout may have changed — inspect ${INSTANCE_DIR} by hand."

qemu-img convert -O qcow2 "${DISK_FILE}" "${ARCHIVE_IMAGE}"
cp "${ARCHIVE_IMAGE}" "${OUT_IMAGE}"

info ""
info "Golden image built: ${OUT_IMAGE}"
info "Archived copy:      ${ARCHIVE_IMAGE}"
info ""
info "\`task up\` will now use it automatically for ${LIMA_ARCH} (see lima-up.sh's"
info "golden-image check) — no config change needed. Run \`task list-images\` to see"
info "everything cached, \`task prune-images\` to reclaim disk space from old archives."
