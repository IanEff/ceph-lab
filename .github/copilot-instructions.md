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
uv run provisioning/scripts/manage_k8s_config.py add

# Bootstrap ArgoCD (run from inside ceph-control VM)
bash /vagrant/provisioning/scripts/install_argocd.sh

# Watch all ArgoCD apps
kubectl get applications -n argocd -w --context ceph-lab

# Check Ceph health
kubectl exec -it -n rook-ceph deploy/rook-ceph-tools -- ceph status

# Wipe OSDs for clean Rook reinstall (no VM rebuild)
bash provisioning/scripts/wipe_ceph_disks.sh

# Full teardown
uv run provisioning/scripts/manage_k8s_config.py remove && vagrant destroy -f
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
- **Wrapper Chart** (kube-prometheus-stack): thin `Chart.yaml` + `values.yaml`; a single `dependencies:` entry points to the upstream chart

### `GITOPS_REPO_URL` bootstrap variable
`GITOPS_REPO_URL` is an **environment variable** consumed by `install_argocd.sh` — it is used to:
1. Create the ArgoCD repository secret (with SSH deploy key or HTTPS token)
2. `sed`-substitute the literal string `GITOPS_REPO_URL` across all YAMLs under `applications/clusters/` and `cluster-bootstrap/` at bootstrap time

After bootstrapping, the actual repo URL is in-place in those files. Set `GITOPS_REPO_URL` in `.env` before running `install_argocd.sh` on a fresh clone.

---

## ArgoCD sync waves

| Wave | Component | Prune | SelfHeal |
|---|---|---|---|
| -15 | gateway-api CRDs | true | true |
| -10 | cilium | true | true |
| -6 | prometheus-operator-crds | true | true |
| -5 | cert-manager, prometheus, grafana | true | true |
| 0 | alloy, metrics-server | true | true |
| 1 | l7-policies (CiliumNetworkPolicies) | true | true |
| 10 | argocd-ingress | true | true |
| 20 | rook-operator | **false** | true |
| 25 | rook-cluster + PostSync gate | **false** | **false** |
| 30 | rook-storage | true | true |
| 31 | rook-dashboards (Grafana ConfigMaps) | true | true |
| 35 | rook-gateway (dashboard, S3, S3-shared routes) | true | true |

Rook operator (`prune: false`) and rook-cluster (`prune: false`, `selfHeal: false`) are intentionally protected.  
`rook-cluster` has `ignoreDifferences` on `/status` and `/spec/mon/count` because the operator mutates those fields.

### PostSync gate (wave 25 → 30)
`applications/rook/cluster/postsync-ceph-health.yaml` is an ArgoCD `PostSync` hook Job that polls the `CephCluster` CR until `state=Connected` and `health=HEALTH_OK`. ArgoCD will not advance to wave 30 (rook-storage) until it exits 0. Timeout: 30 minutes (`activeDeadlineSeconds: 1800`). The companion RBAC in `postsync-ceph-health-rbac.yaml` is a regular (non-hook) sync resource that persists.

---

## CiliumNetworkPolicies (L7 visibility)

All policies live in `applications/infrastructure/l7-policies/`. Pattern:
- One policy per namespace, named `l7-visibility`
- `endpointSelector: {}` — applies to entire namespace
- Ingress: `fromEntities: [cluster]` with `toPorts[].rules.http: [{}]` for L7 visibility; L4-only for raw Ceph ports
- Egress: always includes DNS (`kube-system/kube-dns`, matchPattern `"*"`), then kube-apiserver + world for HTTPS

---

## Maintenance overlay

`applications/rook/cluster/overlays/maintenance/` is a Kustomize overlay over the base `rook/cluster/` that adds aggressive OSD recovery throttles via a strategic-merge patch on `CephCluster`. To enter maintenance posture, point the `rook-cluster` Application's `path` at this overlay and sync. Revert to the base path to restore conservative defaults.

---

## Critical gotchas

1. **`/dev/sdb` is NOT an OSD** — it's the k3s data disk. `deviceFilter: "^sd[cd]"` in `cephcluster.yaml` targets only `sdc`/`sdd`. Never include `sdb`.
2. **OSD disks must stay raw** — pre-formatting any block device breaks Rook auto-discovery.
3. **Gateway API CRDs must precede Cilium** — `install_cilium.sh` applies them first with `kubectl wait`; ArgoCD wave `-15` mirrors this ordering.
4. **`CephFilesystemSubVolumeGroup` is required** (Rook ≥ v1.17) — without it, CephFS dynamic provisioning silently fails. See `applications/rook/storage/filesystem.yaml`.
5. **`preserve*OnDelete: true`** on `CephFilesystem` and `CephObjectStore` — ArgoCD can delete their CRs without destroying Ceph data.
6. **ArgoCD runs insecure** — TLS terminates at Cilium Gateway using cert-manager self-signed `*.ceph.lab` wildcard. Trust `ceph-lab-ca` on Mac to avoid browser warnings.
7. **Hubble metrics are collected via Alloy** — Prometheus scrapes Alloy, which in turn scrapes Hubble. Ensure `l7-visibility` policies allow this path.
8. **k3s uses SQLite, not etcd** — `kubeEtcd` scraper is disabled in prometheus values.
9. **`--enable-helm` is required** — patched into `argocd-cm` via `cluster-bootstrap/argocd/kustomization.yaml`. Without it, `helmCharts:` stanzas do nothing.
10. **Gateway API manifests must include API-defaulted fields** — The admission webhook injects `group: ""`, `kind: Service`, `weight: 1` into `backendRefs` and `matches` into HTTPRoute rules. Omitting them causes permanent ArgoCD OutOfSync loops. See `docs/gitops-argocd-lessons.md`.
11. **Cilium IPAM CIDR must match at both install phases** — `install_cilium.sh` (Helm, runs at VM boot) and the GitOps kustomization (applied later by `install_argocd.sh`) are two separate Cilium installs. If `install_cilium.sh` omits `--set "ipam.operator.clusterPoolIPv4PodCIDRList={10.244.0.0/16}"`, the initial ConfigMap gets Helm's default `cluster-pool-ipv4-cidr: 10.0.0.0/8`. Agents initialize IPAM from that value, write `10.0.x.0/24` into CiliumNode specs, and stay stuck there — the later kustomize apply fixes the ConfigMap but doesn't trigger a DaemonSet rollout. Result: all cross-node pod traffic BPF-masquerades and breaks. **`--cluster-pool-ipv4-cidr` is NOT a valid `cilium-agent` flag** (only valid for `cilium-operator`) — do not add it to the DaemonSet args.

---

## Service URLs

| Service | URL |
|---|---|
| ArgoCD | https://argocd.ceph.lab |
| Grafana | https://grafana.ceph.lab |
| Ceph Dashboard | https://dashboard.ceph.lab |
| Hubble UI | https://hubble.ceph.lab |
| Prometheus | https://prometheus.ceph.lab |
| Alertmanager | https://alertmanager.ceph.lab |
| S3 (objectstore) | https://s3.ceph.lab |
| S3 (shared objectstore) | https://s3-shared.ceph.lab |

---

## Directory map

```
applications/
  config/             # gitops.env (single source of truth) + Kustomize Component
  infrastructure/     # One dir per infra component (config.json + kustomization.yaml + manifests)
  clusters/ceph-lab/  # ApplicationSet (infra-set.yaml) + per-wave Rook Applications
  rook/
    cluster/          # CephCluster CR, PostSync health gate, prometheus-rules
      overlays/
        maintenance/  # Kustomize overlay: aggressive OSD recovery throttles
    dashboards/       # Grafana ConfigMaps (ceph-cluster, ceph-osd, ceph-pools)
    gateway/          # HTTPRoutes: dashboard, S3, S3-shared
    operator/         # Rook operator Helm chart + CRDs
    storage/          # CephBlockPool, CephFilesystem, CephObjectStore(s), StorageClasses, toolbox
cluster-bootstrap/
  argocd/             # ArgoCD install patches (insecure, --enable-helm, limits)
  bootstrap/          # root-app.yaml — the seed Application applied by install_argocd.sh
provisioning/scripts/ # VM provisioning + host-side helpers
docs/
  ceph-cheatsheet.md
  gitops-argocd-lessons.md   # OutOfSync debugging playbook
  observability-tour.md
  operational-posture.md     # Maintenance vs normal posture guide
  rgw-s3-runbook.md          # RGW / S3 objectstore operations
  trim-observability-stack.md
```

---

## Adding a new infrastructure component

1. Create `applications/infrastructure/<name>/config.json` with `appName`, `syncWave`, `namespace`, `localPath`
2. Create `kustomization.yaml` (add `components: [../../config]` if cluster values are needed)
3. Add manifests or a `helmCharts:` stanza
4. If the component needs a CiliumNetworkPolicy, add it to `applications/infrastructure/l7-policies/`
5. Commit and push — ArgoCD picks it up automatically on next sync
