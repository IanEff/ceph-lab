#!/usr/bin/env bash
# ceph-lab — lima-down.sh
# Gracefully stop all cluster VMs, preserving their state on disk.
#
# Equivalent to `vagrant halt`. Use `make up` to resume without re-provisioning.
#
# Usage:
#   make down
#   bash provisioning/lima-down.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${GREEN}[lima-down]${NC} $*"; }
step() { echo -e "${CYAN}[lima-down]${NC} $*"; }

ENV_FILE="${SCRIPT_DIR}/provision.env"
# shellcheck disable=SC1090,SC1091
[ -f "${ENV_FILE}" ] && { set -a; source "${ENV_FILE}"; set +a; }

NUM_NODES="${SANDBOX_NUM_CEPH_NODES:-3}"

# Stop workers first, then control plane
for i in $(seq "${NUM_NODES}" -1 1); do
    NODE_NAME="ceph-node-${i}"
    step "Stopping ${NODE_NAME}..."
    limactl stop "${NODE_NAME}" 2>/dev/null || true
done

step "Stopping ceph-control..."
limactl stop ceph-control 2>/dev/null || true

info "All VMs stopped. Run 'make up' to resume."
