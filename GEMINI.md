# GEMINI.md — Instructions for Gemini CLI

This file provides context and specialized instructions for the Gemini CLI agent working in the `ceph-lab` repository.

---

## What this repo is

A fully-gitopsed **Rook/Ceph playground on k3s**, managed end-to-end by ArgoCD.
`make up` provisions 4 Lima VMs; `install_argocd.sh` bootstraps the entire software stack
from git — no manual kubectl applies.

---

## Technology stack

| Layer | Technology | Version |
|---|---|---|
| VMs | Lima + vz (Apple Virtualization) | Ubuntu 24.04, 4 nodes |
| Kubernetes | k3s | 1.32 |
| CNI, LB & L7 Policies | Cilium | 1.18.2 |
| Storage | Rook + Ceph Squid | v1.19.1 / v19.2.2 |
| GitOps | ArgoCD | stable |
| Ingress | Gateway API (Cilium) | v1.4.1 |
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
| -5 | grafana, prometheus | true | true |
| 1 | l7-policies (CiliumNetworkPolicies) | true | true |
| 10 | argocd-ingress | true | true |
| 20 | rook-operator | **false** | true |
| 25 | rook-cluster | **false** | **false** |
| 30 | rook-storage | true | true |
| 30 | ceph-latency-bridge (SLO metrics) | true | true |
| 31 | rook-dashboards (Grafana CMs) | true | true |
| 32 | elk-slo-dashboard (Ceph OSD SLO) | true | true |
| 35 | rook-gateway | true | true |

### 5. Helm is always via Kustomize
ArgoCD uses `--enable-helm` in `kustomize.buildOptions`. Use `helmCharts:` in `kustomization.yaml`.

### 6. Custom Agent Skills
This project contains custom Gemini CLI skills in `.github/skills/`. For GitOps operations (like creating infra components or syncing waves), run the `activate_skill` tool with `ceph-gitops` to load the project's specialized workflows and component templates.

---

## Critical gotchas

1. **`/dev/vdb` is NOT an OSD** — it's the k3s data disk (Lima virtio-blk). `deviceFilter: "^vd[cd]"` in `cephcluster.yaml` targets only `vdc`/`vdd`. Never include `vdb`.
2. **OSD disks must stay raw** — pre-formatting any block device breaks Rook auto-discovery. OSD disks appear as `/dev/vdc` and `/dev/vdd`.
3. **Gateway API manifests must include API-defaulted fields** — See `docs/gitops-argocd-lessons.md` §3. Omitting them causes permanent ArgoCD OutOfSync loops.
4. **`CephFilesystemSubVolumeGroup` is required** (Rook ≥ v1.17) — without it, CephFS dynamic provisioning silently fails.
5. **ArgoCD runs insecure** — TLS terminates at the Cilium Gateway. Service URLs work at https://*.ceph.lab.
6. **L7 Policies (CNP) are in effect** — Cilium Network Policies in `applications/infrastructure/l7-policies/` enforce strict network isolation.
7. **OSD Performance Histograms precision** — Ceph OSD histograms (via `ceph-latency-bridge`) export bucket boundaries with high floating-point precision (e.g., `le="0.099999"`). PromQL queries MUST match these exact labels.
8. **`virtiofs` mounts are async** — Lima YAML provision steps poll for `/ceph-lab/provisioning/provision.env` (up to 60s) before running scripts.
9. **`socket_vmnet` requirement** — Must be at `/opt/socket_vmnet` for the 192.168.56.0/24 host-only network. Run `make setup` once.
10. **`lima0` default route break** — DHCP on `lima0` must have `use-routes: false` to prevent pod egress breakage (already in templates).
11. **Definitive Observability Dashboard** — `ceph-observability-mach-2.json` is the definitive reference for Health → SLI → SLO.

---

## Cluster topology

| Node | IP | Role |
|---|---|---|
| `ceph-control` | `192.168.56.50` | k3s server, 2 vCPU / 6 GiB (Lima/vz) |
| `ceph-node-{1,2,3}` | `192.168.56.{61,62,63}` | k3s agents + Ceph OSDs, 3 vCPU / 8 GiB + 2×10 GiB raw OSDs (Lima/vz) |
| Cilium Gateway | `192.168.56.200` | L2 LB (pool `192.168.56.192/27`) |

DNS: `*.ceph.lab → 192.168.56.200` via macOS dnsmasq.

---

## Service URLs

| Service | URL |
|---|---|
| ArgoCD | https://argocd.ceph.lab |
| Grafana | https://grafana.ceph.lab |
| Ceph Dashboard | https://dashboard.ceph.lab |
| Hubble UI | https://hubble.ceph.lab |
| Prometheus | https://prometheus.ceph.lab |
| S3 (objectstore) | https://s3.ceph.lab |

---

## Directory map

```
.github/skills/     # Custom Gemini CLI skills (e.g., ceph-gitops)
applications/
  config/           # gitops.env (single source of truth) + Kustomize Component
  infrastructure/   # One dir per infra component:
    argocd-ingress/ # Ingress for ArgoCD UI
    gateway-api/    # Infrastructure for Gateway API (CRDs)
    prometheus/     # Time-series database
    grafana/        # Dashboards & Visualization
    cilium/         # CNI & Gateway
    l7-policies/    # Network security policies
  clusters/ceph-lab/ # ApplicationSet (infra-set.yaml) + per-wave Rook Applications
  rook/             # Kustomize bases: operator, cluster, storage, gateway, dashboards
cluster-bootstrap/
  argocd/           # ArgoCD install patches (insecure, --enable-helm, limits)
  bootstrap/        # root-app.yaml — the seed Application applied by install_argocd.sh
provisioning/
  lima/             # Lima VM templates
  scripts/          # VM provisioning scripts + macOS host helpers
```

---

## Common commands

```bash
make up                                                             # boot cluster
make kubeconfig                                                     # merge kubeconfig + SSH config
make ssh                                                            # shell on ceph-control
kubectl get applications -n argocd -w --context ceph-lab            # watch sync
kubectl exec -it -n rook-ceph deploy/rook-ceph-tools -- ceph status
bash provisioning/scripts/wipe_ceph_disks.sh                        # wipe OSDs
bash provisioning/scripts/open_urls.sh                              # quickly open all UIs
```
