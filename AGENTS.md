# AGENTS.md — ceph-lab

> Quick orientation for AI agents and automated tools working in this repository.

---

## What this repo is

A fully-gitopsed **Rook/Ceph playground on k3s**, managed end-to-end by ArgoCD.
`vagrant up` provisions 4 VMs; `install_argocd.sh` bootstraps the entire software stack
from git — no manual kubectl applies.

**Primary use:** learning Ceph storage concepts and GitOps patterns in a local lab.

---

## Technology stack

| Layer | Technology | Version |
|---|---|---|
| VMs | Vagrant + VirtualBox | Ubuntu 24.04, 4 nodes |
| Kubernetes | k3s | 1.32 |
| CNI + LB | Cilium | 1.18.2 |
| Storage | Rook + Ceph Tentacle | v1.19.1 / v20.2.x |
| GitOps | ArgoCD | stable |
| TLS | cert-manager | v1.14.5 |
| Ingress | Gateway API (Cilium) | v1.4.1 |
| Observability | kube-prometheus-stack + Loki + Tempo + Alloy | |
| Secrets | Sealed Secrets | |

---

## Repository layout

```
applications/
  config/               # gitops.env — single source of truth for all IPs, versions, hostnames
  infrastructure/       # one dir per infra component; each has config.json + kustomization.yaml
  clusters/ceph-lab/    # ApplicationSet (infra-set.yaml) + per-wave Rook Applications
  rook/                 # Kustomize bases: operator, cluster, storage, gateway, dashboards
cluster-bootstrap/
  argocd/               # ArgoCD install patches (insecure mode, --enable-helm, resource limits)
  bootstrap/            # root-app.yaml — the seed Application that ArgoCD self-manages
provisioning/scripts/   # VM provisioning (Vagrant) + macOS host helpers
docs/
  ceph-cheatsheet.md        # Quick Ceph CLI reference
  gitops-argocd-lessons.md  # Hard-won GitOps/ArgoCD lessons + OutOfSync debugging playbook
  observability-tour.md     # Guided walkthrough of the LGTM + Hubble stack
.github/
  copilot-instructions.md   # Detailed coding instructions (read before making changes)
  skills/ceph-gitops/       # Skill file for GitOps authoring tasks
```

---

## Key conventions — read before changing anything

### 1. Never hardcode IPs or hostnames

All network values live in `applications/config/gitops.env`. The Kustomize Component at
`applications/config/kustomization.yaml` injects them via `replacements:` into every
component that includes `components: [../../config]`.

### 2. GITOPS_REPO_URL is a literal placeholder

Every `Application`/`ApplicationSet` YAML contains the string `GITOPS_REPO_URL`.
`install_argocd.sh` substitutes the real URL with `sed` at bootstrap time.
**Never commit a substituted URL.**

### 3. Adding a new infrastructure component

Create `applications/infrastructure/<name>/config.json`:

```json
{ "appName": "my-app", "syncWave": "0", "namespace": "my-ns", "localPath": "applications/infrastructure/my-app" }
```

The `infra-set.yaml` ApplicationSet auto-discovers it. No other file needs editing.

### 4. Helm is always via Kustomize

ArgoCD uses `--enable-helm` in `kustomize.buildOptions`. Two patterns:

- **Inline**: `helmCharts:` stanza in `kustomization.yaml` (e.g. Cilium, cert-manager)
- **Wrapper chart**: thin `Chart.yaml` + `values.yaml` with one upstream dependency (e.g. kube-prometheus-stack, Alloy)

### 5. OSD disk filter

`deviceFilter: "^sd[cd]"` in `cephcluster.yaml` — `/dev/sdb` is the k3s data disk and must never be included.

### 6. Gateway API manifests must include API-defaulted fields

The Gateway API admission webhook injects `group: ""`, `kind: Service`, `weight: 1` into
`backendRefs` and `matches` into HTTPRoute rules. Omitting them causes permanent ArgoCD
OutOfSync loops. See `docs/gitops-argocd-lessons.md` §3 for the full fix.

### 7. Rook prune/selfHeal policy

- `rook-operator`: `prune: false`, `selfHeal: true`
- `rook-cluster`: `prune: false`, `selfHeal: false`
These are intentional to protect Ceph data from accidental ArgoCD deletes.

---

## Cluster topology

| Node | IP | Role |
|---|---|---|
| `ceph-control` | `192.168.56.50` | k3s server, 2 vCPU / 3 GB |
| `ceph-node-{1,2,3}` | `192.168.56.{61,62,63}` | k3s agents + Ceph OSDs, 3 vCPU / 6 GB + 2x 10 GB OSDs |
| Cilium Gateway | `192.168.56.200` | L2 LB, pool `192.168.56.192/27` |

DNS: `*.ceph.lab → 192.168.56.200` via macOS dnsmasq.

---

## ArgoCD sync wave order

| Wave | Component | Prune | SelfHeal |
|---|---|---|---|
| -15 | gateway-api CRDs | true | true |
| -10 | cilium | true | true |
| -5 | cert-manager, kube-prometheus-stack, loki, tempo | true | true |
| 0 | alloy, sealed-secrets, metrics-server | true | true |
| 1 | l7-policies (CiliumNetworkPolicies) | true | true |
| 10 | argocd-ingress | true | true |
| 20 | rook-operator | **false** | true |
| 25 | rook-cluster | **false** | **false** |
| 30 | rook-storage | true | true |
| 35 | rook-gateway | true | true |

---

## Common commands

```bash
vagrant up                                                          # boot cluster (~10-20 min)
python3 provisioning/scripts/manage_k8s_config.py add             # merge kubeconfig on Mac
bash provisioning/scripts/install_argocd.sh                       # bootstrap ArgoCD (from VM)
kubectl get applications -n argocd -w --context ceph-lab          # watch sync progress
kubectl exec -it -n rook-ceph deploy/rook-ceph-tools -- ceph status
bash provisioning/scripts/wipe_ceph_disks.sh                      # wipe OSDs (no VM rebuild)
python3 provisioning/scripts/manage_k8s_config.py remove && vagrant destroy -f
```

---

## Service URLs (after cluster is up)

| Service | URL |
|---|---|
| ArgoCD | <https://argocd.ceph.lab> |
| Grafana | <https://grafana.ceph.lab> |
| Ceph Dashboard | <https://dashboard.ceph.lab> |
| Hubble UI | <https://hubble.ceph.lab> |
| Prometheus | <https://prometheus.ceph.lab> |
| Alertmanager | <https://alertmanager.ceph.lab> |

---

## Further reading

- [GEMINI.md](GEMINI.md) — specialized instructions for Gemini CLI
- [CLAUDE.md](CLAUDE.md) — specialized instructions for Claude
- [.github/copilot-instructions.md](.github/copilot-instructions.md) — full coding conventions and gotchas
- [docs/gitops-argocd-lessons.md](docs/gitops-argocd-lessons.md) — OutOfSync debugging playbook
- [docs/observability-tour.md](docs/observability-tour.md) — observability stack walkthrough
- [docs/ceph-cheatsheet.md](docs/ceph-cheatsheet.md) — Ceph CLI quick reference
