#!/bin/bash
# ceph-lab — install_cilium.sh
# Installs Gateway API CRDs (must precede Cilium) then Cilium via Helm.
# Called by control-plane.sh; can also be re-run idempotently.
set -euo pipefail

CILIUM_VERSION="${CILIUM_VERSION:-1.19.3}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.5.1}"
CONTROL_PLANE_IP="${SANDBOX_CONTROL_PLANE_IP:-192.168.56.50}"

export KUBECONFIG=/root/.kube/config

echo "[cilium] Gateway API CRDs (${GATEWAY_API_VERSION}) — must precede Cilium install"
kubectl apply --server-side -f \
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/experimental-install.yaml"

echo "[cilium] Waiting for Gateway API CRDs to be established..."
kubectl wait --for=condition=Established \
    crd/gateways.gateway.networking.k8s.io \
    crd/httproutes.gateway.networking.k8s.io \
    crd/gatewayclasses.gateway.networking.k8s.io \
    crd/grpcroutes.gateway.networking.k8s.io \
    --timeout=60s

echo "[cilium] Installing Cilium ${CILIUM_VERSION} via Helm (local vendored chart)"
# Use the chart vendored in the repo rather than `helm repo add ... helm.cilium.io`.
# Removes a network dep at boot and locks the install to exactly the chart
# ArgoCD will reconcile against later.
CHART_DIR="/ceph-lab/applications/infrastructure/cilium/charts/cilium-${CILIUM_VERSION}/cilium"
[ -d "${CHART_DIR}" ] || { echo "[ERROR] Vendored Cilium chart not found at ${CHART_DIR}"; exit 1; }

helm upgrade --install cilium "${CHART_DIR}" \
    --namespace kube-system \
    --set kubeProxyReplacement=true \
    --set k8sServiceHost="${CONTROL_PLANE_IP}" \
    --set k8sServicePort="6443" \
    --set routingMode=native \
    --set autoDirectNodeRoutes=true \
    --set ipv4NativeRoutingCIDR="10.244.0.0/16" \
    --set "ipam.operator.clusterPoolIPv4PodCIDRList={10.244.0.0/16}" \
    --set bpf.masquerade=true \
    --set datapathMode=netkit \
    --set "devices=eth+" \
    --set operator.replicas=1 \
    --set gatewayAPI.enabled=true \
    --set l2announcements.enabled=true \
    --set hubble.enabled=true \
    --set hubble.relay.enabled=true \
    --set hubble.ui.enabled=true \
    --set "hubble.metrics.enabled={dns,drop,tcp,flow,icmp,httpV2:exemplars=true;labelsContext=source_ip\,source_namespace\,source_workload\,destination_ip\,destination_namespace\,destination_workload\,traffic_direction}" \
    --wait --timeout 10m

# Trust helm --wait. The previous `kubectl rollout status` was a redundant
# second check that just doubled our exposure to flaky image pulls. Workers
# can already join (token published earlier); if Cilium is slow, they'll come
# up NotReady and recover when the DaemonSet spreads.

echo "[cilium] Installing Hubble CLI"
ARCH=$(dpkg --print-architecture)
HUBBLE_VERSION="v1.19.3"
curl --fail --show-error --silent --location \
     --connect-timeout 15 --max-time 180 --retry 3 --retry-delay 5 \
     -o /tmp/hubble.tar.gz \
     "https://github.com/cilium/hubble/releases/download/${HUBBLE_VERSION}/hubble-linux-${ARCH}.tar.gz"
tar -xzf /tmp/hubble.tar.gz -C /tmp hubble
install -m 755 /tmp/hubble /usr/local/bin/hubble
rm -f /tmp/hubble.tar.gz /tmp/hubble

echo "✓ Cilium ${CILIUM_VERSION} installed with Hubble + Gateway API support"
