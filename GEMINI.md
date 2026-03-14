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
| CNI + LB | Cilium | 1.18.2 |
| Storage | Rook + Ceph Tentacle | v1.19.1 / v20.2.x |
| GitOps | ArgoCD | stable |
| TLS | cert-manager | v1.14.5 |
| Ingress | Gateway API (Cilium) | v1.4.1 |
| Observability | kube-prometheus-stack + Loki + Tempo + Alloy | |
| Secrets | Sealed Secrets | |

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
ArgoCD uses `--enable-helm` in `kustomize.buildOptions`. Use `helmCharts:` in `kustomization.yaml` or a wrapper chart.

---

## Critical gotchas

1. **`/dev/sdb` is NOT an OSD** — it's the k3s data disk. `deviceFilter: "^sd[cd]"` in `cephcluster.yaml` targets only `sdc`/`sdd`. Never include `sdb`.
2. **OSD disks must stay raw** — pre-formatting any block device breaks Rook auto-discovery.
3. **Gateway API manifests must include API-defaulted fields** — See `docs/gitops-argocd-lessons.md` §3. Omitting them causes permanent ArgoCD OutOfSync loops.
4. **`CephFilesystemSubVolumeGroup` is required** (Rook ≥ v1.17) — without it, CephFS dynamic provisioning silently fails.
5. **ArgoCD runs insecure** — TLS terminates at Cilium Gateway using cert-manager self-signed `*.ceph.lab` wildcard.

---

## Directory map

```
applications/
  config/           # gitops.env (single source of truth) + Kustomize Component
  infrastructure/   # One dir per infra component (config.json + kustomization.yaml + manifests)
  clusters/ceph-lab/ # ApplicationSet (infra-set.yaml) + per-wave Rook Applications
  rook/             # Kustomize bases for rook-operator, rook-cluster, rook-storage, rook-gateway
cluster-bootstrap/
  argocd/           # ArgoCD install patches (insecure, --enable-helm, limits)
  bootstrap/        # root-app.yaml — the seed Application applied by install_argocd.sh
provisioning/scripts/ # VM provisioning + host-side helpers
docs/               # ceph-cheatsheet.md, gitops-argocd-lessons.md, observability-tour.md
```

---

## Common commands

```bash
vagrant up                                                          # boot cluster
python3 provisioning/scripts/manage_k8s_config.py add             # merge kubeconfig
bash provisioning/scripts/install_argocd.sh                       # bootstrap ArgoCD
kubectl get applications -n argocd -w --context ceph-lab          # watch sync
kubectl exec -it -n rook-ceph deploy/rook-ceph-tools -- ceph status
bash provisioning/scripts/wipe_ceph_disks.sh                      # wipe OSDs
```
