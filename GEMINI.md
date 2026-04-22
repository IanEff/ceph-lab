# GEMINI.md — Instructions for Gemini CLI

This file provides context and specialized instructions for the Gemini CLI agent working in the `ceph-lab` repository.

---

## What this repo is

A fully-gitopsed **Rook/Ceph playground on k3s**, managed end-to-end by ArgoCD.
`vagrant up` provisions 4 VMs; `install_argocd.sh` bootstraps the entire software stack
from git — no manual kubectl applies.

---

## Technology stack

| Layer | Technology | Version |
|---|---|---|
| VMs | Vagrant + VirtualBox | Ubuntu 24.04, 4 nodes |
| Kubernetes | k3s | 1.32 |
| CNI, LB & L7 Policies | Cilium | 1.18.2 |
| Storage | Rook + Ceph Squid | v1.19.1 / v19.2.2 |
| GitOps | ArgoCD | stable |
| Ingress | Gateway API (Cilium) | v1.4.1 (HTTP only) |
| Observability | Prometheus, Grafana | |

---

## Key conventions — read before changing anything

### 1. Never hardcode IPs or hostnames
All network values live in `applications/config/gitops.env`. The Kustomize Component at
`applications/config/kustomization.yaml` injects them via `replacements:` into every
component that includes `components: [../../config]`.

### 2. GITOPS_REPO_URL is a literal placeholder
Every `Application`/`ApplicationSet` YAML should contain the string `GITOPS_REPO_URL`.
`install_argocd.sh` substitutes the real URL with `sed` at bootstrap time.
**Note**: Some files in the repository may have already been committed with the
substituted URL (`git@github.com:ianeff/ceph-lab.git`). Prefer the placeholder for new files.

### 3. Adding a new infrastructure component
Create `applications/infrastructure/<name>/config.json`:
```json
{ "appName": "my-app", "syncWave": "0", "namespace": "my-ns", "localPath": "applications/infrastructure/my-app" }
```
The `infrastructure-set` ApplicationSet auto-discovers it. No other file needs editing.

### 4. ArgoCD Sync Waves

| Wave | Component | Prune | SelfHeal |
|---|---|---|---|
| -15 | gateway-api CRDs | true | true |
| -10 | cilium | true | true |
| -6 | prometheus-operator-crds | true | true |
| -5 | prometheus, grafana | true | true |
| 1 | l7-policies (CiliumNetworkPolicies) | true | true |
| 10 | argocd-ingress | true | true |
| 20 | rook-operator | **false** | true |
| 25 | rook-cluster + PostSync gate | **false** | **false** |
| 30 | rook-storage (pools, fs, object) | true | true |
| 30 | ceph-latency-bridge (SLO metrics) | true | true |
| 31 | rook-dashboards (Grafana CMs) | true | true |
| 32 | elk-slo-dashboard (Ceph OSD SLO) | true | true |
| 35 | rook-gateway (routes) | true | true |

### 5. Helm is always via Kustomize
ArgoCD uses `--enable-helm` in `kustomize.buildOptions`. Use `helmCharts:` in `kustomization.yaml` or a wrapper chart.

### 6. Custom Agent Skills
This project contains custom Gemini CLI skills in `.github/skills/`. For GitOps operations (like creating infra components or syncing waves), run the `activate_skill` tool with `ceph-gitops` to load the project's specialized workflows and component templates.

---

## Critical gotchas

1. **`/dev/sdb` is NOT an OSD** — it's the k3s data disk. `deviceFilter: "^sd[cd]"` in `cephcluster.yaml` targets only `sdc`/`sdd`. Never include `sdb`.
2. **OSD disks must stay raw** — pre-formatting any block device breaks Rook auto-discovery.
3. **Gateway API manifests must include API-defaulted fields** — See `docs/gitops-argocd-lessons.md` §3. Omitting them causes permanent ArgoCD OutOfSync loops.
4. **`CephFilesystemSubVolumeGroup` is required** (Rook ≥ v1.17) — without it, CephFS dynamic provisioning silently fails.
5. **ArgoCD runs insecure** — TLS is disabled. Cilium Gateway runs HTTP-only (port 80). Service URLs work at http://*.ceph.lab.
6. **L7 Policies (CNP) are in effect** — Cilium Network Policies in `applications/infrastructure/l7-policies/` enforce strict network isolation. If a new component needs to communicate externally or across namespaces, ensure appropriate policies exist. **Crucial**: Egress to the Kubernetes API server (port 443) must be explicitly allowed for components that need to query the API (like `kube-state-metrics`).
7. **OSD Performance Histograms are coarse** — Ceph Squid OSD histograms have a minimum granularity of 100ms. SLOs requiring higher resolution (e.g., 50ms) cannot be tracked via the `ceph-latency-bridge` and should use CSI metrics instead.
8. **Resource Limits in Monitoring** — Prometheus-related components (especially `kube-state-metrics` and `prometheus-server`) are resource-heavy in this lab environment. If they enter `CrashLoopBackOff`, check memory limits first; `kube-state-metrics` needs at least 256Mi and `prometheus-server` needs 1Gi to handle substantial dashboards.
9. **ArgoCD Sync Loops during Debugging** — When performing emergency manual fixes via `kubectl patch/apply`, ArgoCD's `selfHeal` will often immediately revert them. To stop this loop, disable sync on the **root app** (`ceph-lab-root`) first, then the specific Application, then perform your fix. Don't forget to re-enable them after pushing to Git.
10. **Histogram Bucket Ordering** — Custom Prometheus exporters (like `ceph-latency-bridge`) MUST export histogram buckets in strictly ascending `le` order with `+Inf` at the end. Out-of-order buckets will cause Prometheus to discard the metrics.


---

## Directory map

```
.github/skills/     # Custom Gemini CLI skills (e.g., ceph-gitops)
applications/
  config/           # gitops.env (single source of truth) + Kustomize Component
  infrastructure/   # One dir per infra component:
    prometheus/     # Time-series database
    grafana/        # Dashboards & Visualization
    prometheus-operator-crds/ # Foundation for monitoring CRDs
    cilium/         # CNI & Gateway
    l7-policies/    # Network security policies
    elk-slo-dashboard/ # Ceph OSD SLO alerts and dashboard
    ceph-latency-bridge/ # Native OSD histogram reconstruction
  clusters/ceph-lab/ # ApplicationSet (infra-set.yaml) + per-wave Rook Applications
  rook/             # Kustomize bases for rook-operator, cluster, storage, gateway, and dashboards
cluster-bootstrap/
  argocd/           # ArgoCD install patches (insecure, --enable-helm, limits)
  bootstrap/        # root-app.yaml — the seed Application applied by install_argocd.sh
provisioning/scripts/ # VM provisioning + host-side helpers (dnsmasq, trust_ca, UI access scripts)
docs/               # runbooks, operational posture, observability tour, gitops lessons
```

---

## Common commands

```bash
vagrant up                                                          # boot cluster
uv run provisioning/scripts/manage_k8s_config.py add             # merge kubeconfig
bash provisioning/scripts/install_argocd.sh                       # bootstrap ArgoCD
kubectl get applications -n argocd -w --context ceph-lab          # watch sync
kubectl exec -it -n rook-ceph deploy/rook-ceph-tools -- ceph status
bash provisioning/scripts/wipe_ceph_disks.sh                      # wipe OSDs
bash provisioning/scripts/open_urls.sh                            # quickly open all UIs
```
