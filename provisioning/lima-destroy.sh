#!/usr/bin/env bash
# ceph-lab — lima-destroy.sh
# Permanently delete all cluster VMs and their disks.
#
# Equivalent to `vagrant destroy -f`. This is DESTRUCTIVE and cannot be undone.
# Ceph data on the OSD disks will be lost.
#
# Usage:
#   make destroy          — prompts for confirmation
#   make destroy-force    — skips confirmation (bash provisioning/lima-destroy.sh -f)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[lima-destroy]${NC} $*"; }
step()  { echo -e "${CYAN}[lima-destroy]${NC} $*"; }
warn()  { echo -e "${YELLOW}[lima-destroy]${NC} $*"; }
error() { echo -e "${RED}[lima-destroy]${NC} $*" >&2; exit 1; }

FORCE=0
[ "${1:-}" = "-f" ] && FORCE=1

ENV_FILE="${SCRIPT_DIR}/provision.env"
# shellcheck disable=SC1090,SC1091
[ -f "${ENV_FILE}" ] && { set -a; source "${ENV_FILE}"; set +a; }

NUM_NODES="${SANDBOX_NUM_CEPH_NODES:-3}"
OSD_DISKS="${SANDBOX_OSD_DISKS_PER_NODE:-2}"
CONFIGURE_DNSMASQ="${SANDBOX_CONFIGURE_DNSMASQ:-1}"
DNS_DOMAIN="${SANDBOX_DNS_DOMAIN:-ceph.lab}"

if [ "${FORCE}" -eq 0 ]; then
    warn "This will PERMANENTLY DELETE all ceph-lab VMs and disks."
    warn "All Ceph data will be lost. This cannot be undone."
    echo ""
    read -r -p "  Type 'yes' to confirm: " confirm
    [ "${confirm}" = "yes" ] || { info "Aborted."; exit 0; }
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
# Idempotent delete: succeed if the target is already gone, fail loudly on any
# other error.  Previous form (`|| true`) swallowed real failures and left the
# script reporting "Cluster destroyed" on a half-cleaned state — which then
# poisoned the next `make up`.
vm_exists()   { limactl list --quiet 2>/dev/null | grep -qx "$1"; }
disk_exists() { limactl disk list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$1"; }

delete_vm() {
    local name="$1"
    if ! vm_exists "${name}"; then
        info "VM ${name} already absent."
        return 0
    fi
    step "Deleting VM ${name}..."
    if ! limactl delete --force "${name}"; then
        error "Failed to delete VM ${name}.  Inspect: limactl list"
    fi
    vm_exists "${name}" && error "VM ${name} still present after delete."
    return 0
}

delete_disk() {
    local name="$1"
    if ! disk_exists "${name}"; then
        info "Disk ${name} already absent."
        return 0
    fi
    step "Deleting disk ${name}..."
    if ! limactl disk delete "${name}"; then
        error "Failed to delete disk ${name}.  Inspect: limactl disk list"
    fi
    disk_exists "${name}" && error "Disk ${name} still present after delete."
    return 0
}

# ── Delete VMs ────────────────────────────────────────────────────────────────
for i in $(seq "${NUM_NODES}" -1 1); do
    delete_vm "ceph-node-${i}"
done
delete_vm "ceph-control"

# ── Delete named disks ────────────────────────────────────────────────────────
delete_disk "ceph-control-rancher"
for i in $(seq 1 "${NUM_NODES}"); do
    NODE_NAME="ceph-node-${i}"
    delete_disk "${NODE_NAME}-rancher"
    for d in $(seq 1 "${OSD_DISKS}"); do
        delete_disk "${NODE_NAME}-osd-${d}"
    done
done

# ── Clean up host-side state ──────────────────────────────────────────────────
step "Removing node-token..."
rm -f "${SCRIPT_DIR}/node-token"

step "Removing kubeconfig context and SSH aliases..."
python3 "${PROJECT_ROOT}/provisioning/scripts/manage_k8s_config.py" remove

if [ "${CONFIGURE_DNSMASQ}" = "1" ]; then
    step "Removing dnsmasq config for *.${DNS_DOMAIN}..."
    export SANDBOX_DNS_DOMAIN="${DNS_DOMAIN}"
    if ! bash "${PROJECT_ROOT}/provisioning/scripts/dnsmasq_teardown.sh"; then
        error "dnsmasq teardown failed."
    fi
fi

info "Cluster destroyed."
