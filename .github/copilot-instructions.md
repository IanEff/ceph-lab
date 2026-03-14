# ceph-lab — Copilot Instructions

A Rook/Ceph playground on k3s, fully managed by ArgoCD GitOps. One `vagrant up` boots 4 VMs; one `install_argocd.sh` bootstraps the entire stack.

---

## Cluster topology

| Node | IP | Role |
|---|---|---|
| `ceph-control` | `192.168.56.50` | k3s server, 2vCPU/3GB |
| `ceph-node-{1,2,3}` | `192.168.56.{61,62,63}` | k3s agents + Ceph OSDs, 3vCPU/6GB + 2x 10GB OSDs |
| Cilium Gateway | `192.168.56.200` | L2 LB (pool `192.168.56.192/27`) |

DNS: `*.ceph.lab → 192.168.56.200` via macOS dnsmasq.

---

## Key commands

```bash
# Boot cluster (~10–20 min)
vagrant up

# Merge kubeconfig + SSH config onto Mac
python3 provisioning/scripts/manage_k8s_config.py add

# Bootstrap ArgoCD (if SANDBOX_INSTALL_ARGOCD=0)
vagrant ssh ceph-control
bash /vagrant/provisioning/scripts/install_argocd.sh

# Watch all ArgoCD apps
kubectl get applications -n argocd -w --context ceph-lab

# Check Ceph health
kubectl exec -it -n rook-ceph deploy/rook-ceph-tools -- ceph status

# Wipe OSDs for clean Rook reinstall (no VM rebuild)
bash provisioning/scripts/wipe_ceph_disks.sh

# Full teardown
python3 provisioning/scripts/manage_k8s_config.py remove && vagrant destroy -f
```

---

## Core patterns

### ApplicationSet via `config.json`
Every component under `applications/infrastructure/*/` has a `config.json`:
```json
{ "appName": "cilium", "syncWave": "-10", "namespace": "kube-system", "localPath": "applications/infrastructure/cilium" }
```
`infra-set.yaml` uses a Git generator scanning for these files. **To add a new infra component, just create a folder with `config.json` — no changes to `infra-set.yaml` needed.**

### Cluster-wide config injection (single source of truth)
`applications/config/gitops.env` holds all IPs, CIDRs, versions, and hostnames.  
`applications/config/kustomization.yaml` is a Kustomize `Component` (not `Kustomization`) that generates a `cluster-config` ConfigMap and uses `replacements:` to patch specific fields in specific resources.  
Every infra app that needs cluster values includes it:
```yaml
components:
  - ../../config
```
**Never hardcode IPs or hostnames in component manifests — always reference via replacements.**

### Helm via Kustomize `helmCharts:`
ArgoCD is configured with `--enable-helm` in `kustomize.buildOptions`. Two sub-patterns:
- **Inline Helm** (Cilium, cert-manager): `helmCharts:` stanza directly in `kustomization.yaml`
- **Wrapper Chart** (kube-prometheus-stack, Alloy, Sealed Secrets): thin `Chart.yaml` + `values.yaml`; a single `dependencies:` entry points to the upstream chart

### `GITOPS_REPO_URL` placeholder
All `Application`/`ApplicationSet` YAMLs contain the literal string `GITOPS_REPO_URL`. `install_argocd.sh` performs a `sed` in-place substitution inside the VM before applying. **Never commit substituted URLs; keep the literal placeholder in source files.**

---

## ArgoCD sync waves

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

Rook operator (`prune: false`) and rook-cluster (`prune: false`, `selfHeal: false`) are intentionally protected.  
`rook-cluster` has `ignoreDifferences` on `/status` and `/spec/mon/count` because the operator mutates those fields.

---

## CiliumNetworkPolicies (L7 visibility)

All policies live in `applications/infrastructure/l7-policies/`. Pattern:
- One policy per namespace, named `l7-visibility`
- `endpointSelector: {}` — applies to entire namespace
- Ingress: `fromEntities: [cluster]` with `toPorts[].rules.http: [{}]` for L7 visibility; L4-only for raw Ceph ports
- Egress: always includes DNS (`kube-system/kube-dns`, matchPattern `"*"`), then kube-apiserver + world for HTTPS

---

## Critical gotchas

1. **`/dev/sdb` is NOT an OSD** — it's the k3s data disk. `deviceFilter: "^sd[cd]"` in `cephcluster.yaml` targets only `sdc`/`sdd`. Never include `sdb`.
2. **OSD disks must stay raw** — pre-formatting any block device breaks Rook auto-discovery.
3. **Gateway API CRDs must precede Cilium** — `install_cilium.sh` applies them first with `kubectl wait`; ArgoCD wave `-15` mirrors this ordering.
4. **`CephFilesystemSubVolumeGroup` is required** (Rook ≥ v1.17) — without it, CephFS dynamic provisioning silently fails. See `applications/rook/storage/filesystem.yaml`.
5. **`preserve*OnDelete: true`** on `CephFilesystem` and `CephObjectStore` — ArgoCD can delete their CRs without destroying Ceph data.
6. **ArgoCD runs insecure** — TLS terminates at Cilium Gateway using cert-manager self-signed `*.ceph.lab` wildcard. Trust `ceph-lab-ca` on Mac to avoid browser warnings.
7. **Hubble metrics are disabled at bootstrap** — kube-prometheus-stack CRDs don't exist yet. Enable after wave `-5` settles.
8. **k3s uses SQLite, not etcd** — `kubeEtcd` scraper is disabled in kube-prometheus-stack values.
9. **`--enable-helm` is required** — patched into `argocd-cm` via `cluster-bootstrap/argocd/kustomization.yaml`. Without it, `helmCharts:` stanzas do nothing.

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

## Adding a new infrastructure component

1. Create `applications/infrastructure/<name>/config.json` with `appName`, `syncWave`, `namespace`, `localPath`
2. Create `kustomization.yaml` (add `components: [../../config]` if cluster values are needed)
3. Add manifests or a `helmCharts:` stanza
4. If the component needs a CiliumNetworkPolicy, add it to `applications/infrastructure/l7-policies/`
5. Commit and push — ArgoCD picks it up automatically on next sync
