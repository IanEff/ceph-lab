#!/bin/bash
# ceph-lab — open_urls.sh
# Service directory: shows live URLs, credentials, and cluster health.
# Run from your Mac after 'vagrant up'.
set -euo pipefail

NAMESPACE="rook-ceph"
GATEWAY_IP="192.168.56.200"
DOMAIN="ceph.lab"

NC='\033[0m'
BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'

header() { echo -e "\n${BOLD}${CYAN}── $* ──${NC}"; }
ok()     { echo -e "  ${GREEN}✓${NC}  $*"; }
warn()   { echo -e "  ${YELLOW}⚠${NC}  $*"; }
info()   { echo -e "  ${BLUE}ℹ${NC}  $*"; }
err()    { echo -e "  ${RED}✗${NC}  $*"; }

echo ""
echo -e "${BOLD}${CYAN}"
echo "   ██████╗███████╗██████╗ ██╗  ██╗      ██╗      █████╗ ██████╗ "
echo "  ██╔════╝██╔════╝██╔══██╗██║  ██║      ██║     ██╔══██╗██╔══██╗"
echo "  ██║     █████╗  ██████╔╝███████║█████╗██║     ███████║██████╔╝"
echo "  ██║     ██╔══╝  ██╔═══╝ ██╔══██║╚════╝██║     ██╔══██║██╔══██╗"
echo "  ╚██████╗███████╗██║     ██║  ██║      ███████╗██║  ██║██████╔╝"
echo "   ╚═════╝╚══════╝╚═╝     ╚═╝  ╚═╝      ╚══════╝╚═╝  ╚═╝╚═════╝ "
echo -e "${NC}"
echo -e "${BOLD}  k3s + Rook Ceph + ArgoCD GitOps — ceph.lab${NC}"
echo ""

# ── Cluster nodes ─────────────────────────────────────────────────────────────
header "Cluster Nodes"
kubectl get nodes -o wide --context ceph-lab 2>/dev/null \
    | awk 'NR==1{print "  "$0; next} {print "  "$0}' || warn "Cannot reach cluster"

# ── CephCluster health ────────────────────────────────────────────────────────
header "Ceph Cluster"
PHASE=$(kubectl get cephcluster rook-ceph -n "$NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
HEALTH=$(kubectl get cephcluster rook-ceph -n "$NAMESPACE" \
    -o jsonpath='{.status.ceph.health}' 2>/dev/null || echo "unknown")

case "$HEALTH" in
    HEALTH_OK)   ok  "CephCluster: ${PHASE} / ${HEALTH}" ;;
    HEALTH_WARN) warn "CephCluster: ${PHASE} / ${HEALTH}" ;;
    HEALTH_ERR)  err  "CephCluster: ${PHASE} / ${HEALTH}" ;;
    *)           info "CephCluster: ${PHASE} / ${HEALTH}" ;;
esac

OSD_UP=$(kubectl exec -n "$NAMESPACE" deploy/rook-ceph-tools -- \
    ceph osd stat 2>/dev/null | grep -o '[0-9]* up' | head -1 || echo "?")
info "OSDs: ${OSD_UP}"

# ── ArgoCD ────────────────────────────────────────────────────────────────────
header "ArgoCD Applications"
kubectl get applications -n argocd \
    -o custom-columns='APP:.metadata.name,WAVE:.metadata.annotations.argocd\.argoproj\.io/sync-wave,HEALTH:.status.health.status,SYNC:.status.sync.status' \
    2>/dev/null | awk 'NR==1{print "  "$0; next} {print "  "$0}' \
    || info "ArgoCD not yet installed (run install_argocd.sh)"

# ── Gateway / DNS detection ───────────────────────────────────────────────────
header "Service URLs"
DNS_OK=false
if host "dashboard.${DOMAIN}" 127.0.0.1 >/dev/null 2>&1 || \
   host "dashboard.${DOMAIN}"            >/dev/null 2>&1; then
    DNS_OK=true
fi

if $DNS_OK; then
    ok "DNS resolves — direct access via hostname:"
    echo ""
    printf "  %-12s  https://argocd.%s\n"        "ArgoCD"       "$DOMAIN"
    printf "  %-12s  https://dashboard.%s\n"      "Ceph"         "$DOMAIN"
    printf "  %-12s  https://grafana.%s\n"        "Grafana"      "$DOMAIN"
    printf "  %-12s  https://prometheus.%s\n"     "Prometheus"   "$DOMAIN"
    printf "  %-12s  https://alertmanager.%s\n"   "Alertmanager" "$DOMAIN"
    printf "  %-12s  https://hubble.%s\n"         "Hubble"       "$DOMAIN"
else
    warn "DNS not yet configured — use port-forwards or IP:"
    echo ""
    printf "  %-12s  http://%s  (port-forward: bash provisioning/scripts/argocd_access.sh)\n" \
        "ArgoCD" "${GATEWAY_IP}"
    printf "  %-12s  http://%s  (port-forward: bash provisioning/scripts/ceph_dashboard_access.sh)\n" \
        "Ceph" "${GATEWAY_IP}"
    printf "  %-12s  http://%s  (port-forward: bash provisioning/scripts/grafana_access.sh)\n" \
        "Grafana" "${GATEWAY_IP}"
    printf "  %-12s  http://%s  (port-forward: bash provisioning/scripts/hubble_ui.sh)\n" \
        "Hubble" "${GATEWAY_IP}"
    echo ""
    info "To enable *.${DOMAIN} DNS on this Mac:"
    echo "    brew install dnsmasq"
    echo "    SANDBOX_CONFIGURE_DNSMASQ=1 vagrant up  (or re-trigger the dnsmasq trigger)"
fi

echo ""
header "Credentials"
CEPH_PASS=$(kubectl -n "$NAMESPACE" get secret rook-ceph-dashboard-password \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "(not yet available)")
ARGO_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "password")

printf "  %-18s  admin / %s\n" "Ceph Dashboard"  "$CEPH_PASS"
printf "  %-18s  admin / %s\n" "ArgoCD"           "$ARGO_PASS"
printf "  %-18s  admin / password\n" "Grafana"
echo ""
