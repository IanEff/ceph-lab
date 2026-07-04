#!/usr/bin/env bash
# ceph-lab — lima-setup.sh
# One-time host setup for Lima-based cluster provisioning.
#
# Run once before the first `make up`:
#   make setup   (or: bash provisioning/lima-setup.sh)
#
# Installs:
#   - lima        (limactl — the VM manager)
#   - socket_vmnet (host-only L2 networking required for static IPs + Cilium L2)
# Copies:
#   - provisioning/lima/networks.yaml → ~/.lima/_config/networks.yaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[setup]${NC} $*"; }
step()  { echo -e "${CYAN}[setup]${NC} $*"; }
warn()  { echo -e "${YELLOW}[setup]${NC} $*"; }
error() { echo -e "${RED}[setup]${NC} $*" >&2; exit 1; }

# ── Lima ──────────────────────────────────────────────────────────────────────
if command -v limactl >/dev/null 2>&1; then
    LIMA_VER=$(limactl --version 2>/dev/null | awk '{print $3}' || echo "unknown")
    info "Lima already installed: ${LIMA_VER}"
else
    step "Installing Lima via Homebrew..."
    brew install lima
fi

# ── socket_vmnet ──────────────────────────────────────────────────────────────
# socket_vmnet provides the host-only L2 network (192.168.56.0/24).
# It must be installed at /opt/socket_vmnet (Lima's expected path).
SOCKET_VMNET="/opt/socket_vmnet/bin/socket_vmnet"
if [ -x "${SOCKET_VMNET}" ]; then
    info "socket_vmnet already installed at ${SOCKET_VMNET}"
else
    warn "socket_vmnet not found at ${SOCKET_VMNET}"
    echo ""
    echo "  socket_vmnet requires building from source and a privileged install."
    echo "  Run the following (requires Xcode command-line tools):"
    echo ""
    echo "    brew install socket_vmnet"
    echo "    sudo brew services start socket_vmnet"
    echo "    sudo limactl sudoers | sudo tee /etc/sudoers.d/lima"
    echo ""
    echo "  See: https://lima-vm.io/docs/config/network/vmnet/"
    echo ""
    read -r -p "  Continue anyway? [y/N] " confirm
    [[ "${confirm}" =~ ^[Yy]$ ]] || exit 1
fi

# ── Lima _config directory ────────────────────────────────────────────────────
LIMA_CONFIG_DIR="${HOME}/.lima/_config"
mkdir -p "${LIMA_CONFIG_DIR}"

# ── Install ceph-lab network definition ───────────────────────────────────────
NETWORKS_SRC="${PROJECT_ROOT}/provisioning/lima/networks.yaml"
NETWORKS_DST="${LIMA_CONFIG_DIR}/networks.yaml"

if [ -f "${NETWORKS_DST}" ]; then
    if grep -q "ceph-lab" "${NETWORKS_DST}" 2>/dev/null; then
        info "ceph-lab network already in ${NETWORKS_DST}"
    else
        # Append just the ceph-lab stanza — other clusters (e.g. sandbox) keep their entries.
        step "Merging ceph-lab network into ${NETWORKS_DST}..."
        cp "${NETWORKS_DST}" "${NETWORKS_DST}.bak.$(date +%s)"
        cat >> "${NETWORKS_DST}" << 'STANZA'

  # ceph-lab — host-only network for the Rook/Ceph cluster
  ceph-lab:
    mode: host
    gateway: 192.168.56.1
    dhcpEnd: 192.168.56.190
    netmask: 255.255.255.0
    interface: lima-ceph-lab
STANZA
        info "ceph-lab network merged into ${NETWORKS_DST} (backup saved)."
    fi
else
    step "Installing Lima network config → ${NETWORKS_DST}"
    cp "${NETWORKS_SRC}" "${NETWORKS_DST}"
    info "Installed ${NETWORKS_DST}"
fi

echo ""
info "Setup complete!"
echo ""
echo "  Next steps:"
echo "    1. Copy .env.example to .env and set GITOPS_REPO_URL (+ key/token)"
echo "    2. Configure passwordless sudo for local DNS and Lima networking (optional but recommended):"
echo "       just setup-sudoers   (or: make setup-sudoers)"
echo "    3. just up            (or: make up) — provision the cluster (~10–20 min)"
echo "    4. kubectl get nodes --context ceph-lab"
echo ""
