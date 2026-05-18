#!/usr/bin/env bash
# ceph-lab — lima-up.sh
# Provision the Ceph lab cluster using Lima VMs, end-to-end.
#
# Sequence:
#   1. Preflight  — check prereqs and .env before touching any VMs
#   2. Disks      — pre-create all Lima disks (idempotent)
#   3. VMs        — all four VMs started in parallel; Lima runs provision
#                   scripts internally and blocks until probes pass
#   4. Post-up    — merge kubeconfig + SSH, configure dnsmasq
#   5. ArgoCD     — bootstrap from the Mac host once the full cluster is Ready
#
# Usage:
#   make up
#   bash provisioning/lima-up.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[lima-up]${NC} $*"; }
step()  { echo -e "${CYAN}[lima-up]${NC} $*"; }
warn()  { echo -e "${YELLOW}[lima-up]${NC} $*"; }
error() { echo -e "${RED}[lima-up]${NC} $*" >&2; exit 1; }

# ── Load cluster config ───────────────────────────────────────────────────────
ENV_FILE="${SCRIPT_DIR}/provision.env"
[ -f "${ENV_FILE}" ] || error "provision.env not found at ${ENV_FILE}"
set -a
# shellcheck disable=SC1090,SC1091
source "${ENV_FILE}"
# User secrets (GITOPS_REPO_URL, etc.) override provision.env defaults
# shellcheck disable=SC1090,SC1091
[ -f "${PROJECT_ROOT}/.env" ] && source "${PROJECT_ROOT}/.env"
set +a

NUM_NODES="${SANDBOX_NUM_CEPH_NODES:-3}"
NODE_IP_BASE="${SANDBOX_CEPH_NODE_IP_BASE:-60}"
CONFIGURE_DNSMASQ="${SANDBOX_CONFIGURE_DNSMASQ:-1}"
DNS_DOMAIN="${SANDBOX_DNS_DOMAIN:-ceph.lab}"
GATEWAY_LB_IP="${SANDBOX_GATEWAY_LB_IP:-192.168.56.200}"
INSTALL_ARGOCD="${SANDBOX_INSTALL_ARGOCD:-1}"

# ── Preflight ─────────────────────────────────────────────────────────────────
command -v limactl >/dev/null 2>&1 || error "limactl not found. Run: make setup"

if [ "${INSTALL_ARGOCD}" = "1" ] && [ -z "${GITOPS_REPO_URL:-}" ]; then
    error "GITOPS_REPO_URL is not set.
  Copy .env.example to .env, set GITOPS_REPO_URL, and add your deploy key before
  running make up.  To skip ArgoCD bootstrap, set SANDBOX_INSTALL_ARGOCD=0 in .env."
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

vm_status() {
    local name="$1"
    limactl list --json 2>/dev/null | python3 -c "
import sys, json
name = sys.argv[1]
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        inst = json.loads(line)
        if inst.get('name') == name:
            print(inst.get('status', ''))
            break
    except Exception:
        pass
" "${name}" 2>/dev/null
}

ensure_disk() {
    local name="$1" size="$2"
    if limactl disk list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "${name}"; then
        info "Disk ${name} already exists."
    else
        step "Creating Lima disk ${name} (${size})..."
        limactl disk create "${name}" --size "${size}"
    fi
}

# ── Start control plane ───────────────────────────────────────────────────────
step "Ensuring ceph-control disks exist..."
ensure_disk "ceph-control-rancher" "20GiB"

# Remove stale node-token — workers poll for this file and an old one would
# cause them to try to join a dead cluster.
rm -f "${SCRIPT_DIR}/node-token"

CP_STATUS="$(vm_status ceph-control)"
case "${CP_STATUS}" in
    "")
        step "Creating ceph-control (baking in params)..."
        limactl create -y --name=ceph-control \
            --set ".param.ProjectRoot = \"${PROJECT_ROOT}\"" \
            "${SCRIPT_DIR}/lima/ceph-control.yaml"
        step "Starting ceph-control in background (provision runs inside Lima)..."
        limactl start -y --timeout 35m ceph-control &
        CP_PID=$!
        ;;
    "Running")
        warn "ceph-control is already running — skipping."
        CP_PID=""
        ;;
    *)
        warn "ceph-control exists (${CP_STATUS}) — starting."
        limactl start -y --timeout 35m ceph-control &
        CP_PID=$!
        ;;
esac

# ── Start worker nodes (in parallel) ─────────────────────────────────────────
WORKER_PIDS=()

for i in $(seq 1 "${NUM_NODES}"); do
    NODE_NAME="ceph-node-${i}"
    NODE_IP="192.168.56.$((NODE_IP_BASE + i))"

    ensure_disk "${NODE_NAME}-rancher" "20GiB"
    ensure_disk "${NODE_NAME}-osd-1"   "5GiB"
    ensure_disk "${NODE_NAME}-osd-2"   "5GiB"

    W_STATUS="$(vm_status "${NODE_NAME}")"
    case "${W_STATUS}" in
        "")
            step "Creating ${NODE_NAME} (baking in params: NodeIP=${NODE_IP})..."
            limactl create -y --name="${NODE_NAME}" \
                --set ".param.NodeIP = \"${NODE_IP}\"" \
                --set ".param.ProjectRoot = \"${PROJECT_ROOT}\"" \
                --set ".additionalDisks[0].name = \"${NODE_NAME}-rancher\"" \
                --set ".additionalDisks[1].name = \"${NODE_NAME}-osd-1\"" \
                --set ".additionalDisks[2].name = \"${NODE_NAME}-osd-2\"" \
                "${SCRIPT_DIR}/lima/ceph-node.yaml"
            step "Starting ${NODE_NAME} in background..."
            limactl start -y --timeout 30m "${NODE_NAME}" &
            WORKER_PIDS+=($!)
            ;;
        "Running")
            warn "${NODE_NAME} is already running — skipping."
            ;;
        *)
            warn "${NODE_NAME} exists (${W_STATUS}) — starting."
            limactl start -y --timeout 30m "${NODE_NAME}" &
            WORKER_PIDS+=($!)
            ;;
    esac
done

# ── Wait for all VMs ──────────────────────────────────────────────────────────
ALL_PIDS=()
[ -n "${CP_PID:-}" ] && ALL_PIDS+=("${CP_PID}")
ALL_PIDS+=("${WORKER_PIDS[@]}")

if [ "${#ALL_PIDS[@]}" -gt 0 ]; then
    step "Waiting for ${#ALL_PIDS[@]} VM(s) to finish provisioning (probes included)..."
    for pid in "${ALL_PIDS[@]}"; do
        wait "${pid}" || error "A VM provisioning step failed (pid ${pid}). Check: limactl list"
    done
    info "All VMs are up and probes passed."
fi

# ── Post-up: kubeconfig + SSH aliases ────────────────────────────────────────
step "Merging kubeconfig and SSH config on host..."
python3 "${PROJECT_ROOT}/provisioning/scripts/manage_k8s_config.py" add

# ── dnsmasq ───────────────────────────────────────────────────────────────────
if [ "${CONFIGURE_DNSMASQ}" = "1" ]; then
    step "Configuring dnsmasq for *.${DNS_DOMAIN}..."
    export SANDBOX_DNS_DOMAIN="${DNS_DOMAIN}"
    export SANDBOX_GATEWAY_LB_IP="${GATEWAY_LB_IP}"
    bash "${PROJECT_ROOT}/provisioning/scripts/dnsmasq_setup.sh"
fi

# ── ArgoCD bootstrap ──────────────────────────────────────────────────────────
# Runs from the Mac host via limactl shell — no Lima provision timeout pressure,
# full cluster is available, errors surface directly to your terminal.
if [ "${INSTALL_ARGOCD}" = "1" ]; then
    step "Bootstrapping ArgoCD (repo: ${GITOPS_REPO_URL})..."
    limactl shell ceph-control -- \
        sudo bash /ceph-lab/provisioning/scripts/install_argocd.sh
    info "ArgoCD bootstrapped."
fi

info ""
info "Cluster is ready!"
info "  kubectl get nodes --context ceph-lab"
info "  kubectl get applications -n argocd -w --context ceph-lab"
info "  ArgoCD UI: https://argocd.${DNS_DOMAIN}"
