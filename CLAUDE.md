# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A fully-gitopsed **Rook/Ceph playground on k3s**, managed end-to-end by ArgoCD. `vagrant up` provisions 4 VMs; `install_argocd.sh` bootstraps the entire software stack from git — no manual `kubectl apply` needed.

---

## Key commands

```bash
# Boot cluster (~10–20 min)
vagrant up

# Merge kubeconfig + SSH config onto Mac
uv run provisioning/scripts/manage_k8s_config.py add

# Bootstrap ArgoCD (from inside ceph-control VM, or if SANDBOX_INSTALL_ARGOCD=0)
bash /vagrant/provisioning/scripts/install_argocd.sh

# Watch ArgoCD sync progress
kubectl get applications -n argocd -w --context ceph-lab

# Check Ceph health
kubectl exec -it -n rook-ceph deploy/rook-ceph-tools -- ceph status

# Wipe OSDs for clean Rook reinstall (no VM rebuild)
bash provisioning/scripts/wipe_ceph_disks.sh

# Full teardown
uv run provisioning/scripts/manage_k8s_config.py remove && vagrant destroy -f
```

---

## Repository layout

```
applications/
  config/             # gitops.env — single source of truth for all IPs, versions, hostnames
  infrastructure/     # one dir per infra component; each has config.json + kustomization.yaml
  clusters/ceph-lab/  # ApplicationSet (infra-set.yaml) + per-wave Rook Applications
  rook/               # Kustomize bases: operator, cluster, storage, gateway
cluster-bootstrap/
  argocd/             # ArgoCD install patches (insecure mode, --enable-helm, resource limits)
  bootstrap/          # root-app.yaml — the seed Application that ArgoCD self-manages
provisioning/scripts/ # VM provisioning (Vagrant) + macOS host helpers
docs/                 # ceph-cheatsheet.md, gitops-argocd-lessons.md, observability-tour.md, operational-posture.md, rgw-s3-runbook.md
```

---

## Core conventions

### Never hardcode IPs or hostnames

All network values live in `applications/config/gitops.env`. The Kustomize Component at `applications/config/kustomization.yaml` injects them via `replacements:` into every component that includes:

```yaml
components:
  - ../../config
```

### `GITOPS_REPO_URL` is a literal placeholder

Every `Application`/`ApplicationSet` YAML contains the string `GITOPS_REPO_URL`. `install_argocd.sh` substitutes the real URL with `sed` at bootstrap time. **Never commit a substituted URL.**

### Adding a new infrastructure component

1. Create `applications/infrastructure/<name>/config.json`:
   ```json
   { "appName": "my-app", "syncWave": "0", "namespace": "my-ns", "localPath": "applications/infrastructure/my-app" }
   ```
2. Create `kustomization.yaml` (add `components: [../../config]` if cluster values are needed)
3. Add manifests or a `helmCharts:` stanza
4. If the component needs a CiliumNetworkPolicy, add it to `applications/infrastructure/l7-policies/`
5. Commit and push — `infra-set.yaml` ApplicationSet auto-discovers the new folder

### Helm is always via Kustomize

ArgoCD uses `--enable-helm` in `kustomize.buildOptions`. Two patterns:

- **Inline**: `helmCharts:` stanza in `kustomization.yaml` (e.g. Cilium, cert-manager)
- **Wrapper chart**: thin `Chart.yaml` + `values.yaml` with one upstream `dependencies:` entry (legacy pattern — no longer used)

### CiliumNetworkPolicies

All policies live in `applications/infrastructure/l7-policies/`. One policy per namespace named `l7-visibility`, with `endpointSelector: {}`. Egress must always include DNS (`kube-system/kube-dns`).

---

## ArgoCD sync wave order

| Wave | Component | Prune | SelfHeal |
|---|---|---|---|
| -15 | gateway-api CRDs | true | true |
| -10 | cilium | true | true |
| -6 | prometheus-operator-crds | true | true |
| -5 | cert-manager, grafana, prometheus | true | true |
| 0 | metrics-server, alloy | true | true |
| 1 | l7-policies (CiliumNetworkPolicies) | true | true |
| 10 | argocd-ingress | true | true |
| 20 | rook-operator | **false** | true |
| 25 | rook-cluster | **false** | **false** |
| 30 | rook-storage | true | true |
| 31 | rook-dashboards (Grafana ConfigMaps) | true | true |
| 35 | rook-gateway | true | true |

Rook operator and rook-cluster prune/selfHeal settings are intentional — they protect Ceph data from accidental ArgoCD deletes.

---

## Critical gotchas

1. **`/dev/sdb` is NOT an OSD** — it's the k3s data disk. `deviceFilter: "^sd[cd]"` in `cephcluster.yaml` targets only `sdc`/`sdd`. Never include `sdb`.
2. **OSD disks must stay raw** — pre-formatting any block device breaks Rook auto-discovery.
3. **Gateway API manifests must include API-defaulted fields** — The admission webhook injects `group: ""`, `kind: Service`, `weight: 1` into `backendRefs` and `matches` into HTTPRoute rules. Omitting them causes permanent ArgoCD OutOfSync loops. See `docs/gitops-argocd-lessons.md` §3.
4. **`CephFilesystemSubVolumeGroup` is required** (Rook ≥ v1.17) — without it, CephFS dynamic provisioning silently fails. See `applications/rook/storage/filesystem.yaml`.
5. **`preserve*OnDelete: true`** on `CephFilesystem` and `CephObjectStore` — protects data from accidental ArgoCD sync prunes.
6. **ArgoCD runs insecure** — TLS terminates at Cilium Gateway using cert-manager self-signed `*.ceph.lab` wildcard. Trust `ceph-lab-ca` on Mac to avoid browser warnings.
7. **Hubble metrics are disabled at bootstrap** — prometheus-operator CRDs don't exist yet when Cilium deploys. Enable after wave `-5` settles.
8. **k3s uses SQLite, not etcd** — `kubeEtcd` scraper is disabled in Prometheus values.
9. **Gateway API CRDs must precede Cilium** — wave `-15` mirrors `install_cilium.sh` which applies CRDs first with `kubectl wait`.
10. **`--enable-helm` is required** — patched into `argocd-cm` via `cluster-bootstrap/argocd/kustomization.yaml`. Without it, `helmCharts:` stanzas are silently ignored.

---

## Cluster topology

| Node | IP | Role |
|---|---|---|
| `ceph-control` | `192.168.56.50` | k3s server, 2 vCPU / 3 GB |
| `ceph-node-{1,2,3}` | `192.168.56.{61,62,63}` | k3s agents + Ceph OSDs, 3 vCPU / 6 GB + 2×10 GB raw OSDs |
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
| S3 (shared objectstore) | https://s3-shared.ceph.lab |

---

## Further reading

- `docs/gitops-argocd-lessons.md` — hard-won GitOps/ArgoCD lessons and OutOfSync debugging playbook
- `docs/ceph-cheatsheet.md` — quick Ceph CLI reference
- `docs/observability-tour.md` — guided walkthrough of the Prometheus/Grafana + Hubble stack
- `docs/operational-posture.md` — maintenance vs normal cluster posture
- `docs/rgw-s3-runbook.md` — RGW / S3 objectstore operations and bucket management
- `.github/copilot-instructions.md` — full coding conventions (same content as this file, kept in sync)
