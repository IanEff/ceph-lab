---
name: Cluster stack decisions
description: Current app inventory, what was removed, gateway is HTTP-only, known ArgoCD noise
type: project
---

Stack simplified to: ceph (rook), grafana, prometheus (with kube-state-metrics + node-exporter), cilium, gateway-api, l7-policies, argocd-ingress.

**Removed apps (2026-04-21):** cert-manager, alloy, metrics-server, prometheus-operator-crds. User confirmed they don't need TLS certs or Alloy. Config.json files deleted; ArgoCD prunes the namespaces.

**Why:** Control plane OOM during vagrant up caused by all pods landing there before workers joined. Removing 4 apps freed ~600MB of swap pressure.

**Gateway is HTTP-only.** Cilium gateway.yaml has only `http` (port 80) and `hubble-relay` (port 4245) listeners — no HTTPS. All HTTPRoutes use `sectionName: http`. Service URLs work at http://*.ceph.lab via dnsmasq → 192.168.56.200. No browser cert warnings, no cert-manager needed.

**Known ArgoCD noise:** `grafana` shows OutOfSync because both grafana and prometheus apps include `components: [../../config]` generating the same `cluster-config` ConfigMap in the `monitoring` namespace. ArgoCD's `app.kubernetes.io/instance` label conflict. Grafana IS healthy and running correctly — this is a tracking artifact.

**Prometheus scrape strategy:** static configs (not ServiceMonitors). Rook MGR scraped at `rook-ceph-mgr.rook-ceph.svc.cluster.local:9283`, operator at port 2112, Hubble at `hubble-metrics.kube-system.svc.cluster.local:9965`.

**Cilium dashboard ConfigMaps disabled** in values.yaml — they exceeded the 262KB annotation limit because kustomize namespace-overrides put them in kube-system instead of monitoring, and SSA couldn't resolve the orphan.
