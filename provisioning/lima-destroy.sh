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

# ── Delete VMs ────────────────────────────────────────────────────────────────
for i in $(seq "${NUM_NODES}" -1 1); do
    NODE_NAME="ceph-node-${i}"
    step "Deleting ${NODE_NAME}..."
    limactl delete --force "${NODE_NAME}" 2>/dev/null || true
done

step "Deleting ceph-control..."
limactl delete --force ceph-control 2>/dev/null || true

# ── Delete named disks ────────────────────────────────────────────────────────
step "Deleting ceph-control-rancher disk..."
limactl disk delete ceph-control-rancher 2>/dev/null || true

for i in $(seq 1 "${NUM_NODES}"); do
    NODE_NAME="ceph-node-${i}"
    step "Deleting ${NODE_NAME} disks..."
    limactl disk delete "${NODE_NAME}-rancher" 2>/dev/null || true
    for d in $(seq 1 "${OSD_DISKS}"); do
        limactl disk delete "${NODE_NAME}-osd-${d}" 2>/dev/null || true
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
    bash "${PROJECT_ROOT}/provisioning/scripts/dnsmasq_teardown.sh" 2>/dev/null || true
fi

info "Cluster destroyed."
