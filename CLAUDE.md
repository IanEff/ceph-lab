# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A fully-gitopsed **Rook/Ceph playground on k3s**, managed end-to-end by ArgoCD. `make up` provisions 4 Lima VMs; `install_argocd.sh` bootstraps the entire software stack from git — no manual `kubectl apply` needed.

---

## Key commands

```bash
# One-time host setup (Lima, socket_vmnet, network config)
make setup

# Boot cluster (~10–20 min first run)
make up

# Merge kubeconfig + SSH config onto Mac (re-run after restarts)
make kubeconfig

# Open a shell on ceph-control
make ssh

# Bootstrap ArgoCD manually (from inside ceph-control, or if SANDBOX_INSTALL_ARGOCD=0)
bash /ceph-lab/provisioning/scripts/install_argocd.sh

# Watch ArgoCD sync progress
kubectl get applications -n argocd -w --context ceph-lab

# Check Ceph health
kubectl exec -it -n rook-ceph deploy/rook-ceph-tools -- ceph status

# Wipe OSDs for clean Rook reinstall (no VM rebuild)
bash provisioning/scripts/wipe_ceph_disks.sh

# Stop VMs (preserve state)
make down

# Full teardown (prompts for confirmation)
make destroy
```

---

## Repository layout

```
applications/
  config/             # gitops.env — single source of truth for all IPs, versions, hostnames
  infrastructure/     # one dir per infra component; each has config.json + kustomization.yaml
    ceph-latency-bridge/  # native OSD histogram reconstruction (wave 30)
    elk-slo-dashboard/    # Ceph OSD SLO alerts and dashboard (wave 32)
    l7-policies/      # CiliumNetworkPolicies, organized by namespace subdirectory
      argocd/         # cnp-argocd.yaml
      ceph-clients/   # cnp-ceph-clients.yaml
      monitoring/     # cnp-monitoring.yaml, cnp-monitoring-debug.yaml, cnp-monitoring-debug-cidr.yaml
      rook-ceph/      # cnp-rook-ceph.yaml
  clusters/ceph-lab/  # ApplicationSets + individual Rook Applications
    infra-set.yaml    # discovers applications/infrastructure/**/config.json
    rook-set.yaml     # discovers applications/rook/**/config.json (storage, gateway, dashboards, operator)
    rook-operator.yaml  # individual Application — prune=false, selfHeal=true
    rook-cluster.yaml   # individual Application — prune=false, selfHeal=false
  rook/               # Kustomize bases; each has config.json for rook-set.yaml discovery
    operator/         # wave 20
    cluster/          # wave 25 (no config.json — managed by rook-cluster.yaml directly)
    storage/          # wave 30
    dashboards/       # wave 31 — Grafana dashboard JSONs loaded as ConfigMaps
    gateway/          # wave 35
cluster-bootstrap/
  argocd/             # ArgoCD install patches (insecure mode, --enable-helm, resource limits)
  bootstrap/          # root-app.yaml — the seed Application that ArgoCD self-manages
provisioning/
  lima/               # Lima VM definitions (ceph-control.yaml, ceph-node.yaml, networks.yaml)
  scripts/            # VM provisioning scripts + macOS host helpers
  provision.env       # Cluster topology defaults (committed; no secrets)
  lima-up.sh          # Start/provision all VMs
  lima-down.sh        # Stop VMs (preserve state)
  lima-destroy.sh     # Delete VMs and disks
  lima-setup.sh       # One-time host prereqs
docs/                 # ceph-cheatsheet.md, gitops-argocd-lessons.md, observability-tour.md, operational-posture.md, rgw-s3-runbook.md
Makefile              # Wrapper targets: make up/down/destroy/ssh/kubeconfig
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

- **Inline**: `helmCharts:` stanza in `kustomization.yaml` (e.g. Cilium, Grafana)
- **Wrapper chart**: thin `Chart.yaml` + `values.yaml` with one upstream `dependencies:` entry (legacy pattern — no longer used)

### CiliumNetworkPolicies

All policies live in `applications/infrastructure/l7-policies/`, organized into namespace subdirectories (`argocd/`, `ceph-clients/`, `monitoring/`, `rook-ceph/`). One policy per namespace named `l7-visibility`, with `endpointSelector: {}`. Egress must always include DNS (`kube-system/kube-dns`).

---

## ArgoCD sync wave order

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
| 31 | rook-dashboards (Grafana ConfigMaps) | true | true |
| 32 | elk-slo-dashboard (Ceph OSD SLO) | true | true |
| 35 | rook-gateway | true | true |

Rook operator and rook-cluster prune/selfHeal settings are intentional — they protect Ceph data from accidental ArgoCD deletes.

---

## Critical gotchas

1. **`/dev/vdb` is NOT an OSD** — it's the k3s data disk (Lima virtio-blk). `deviceFilter: "^vd[cd]"` in `cephcluster.yaml` targets only `vdc`/`vdd`. Never include `vdb`.
2. **OSD disks must stay raw** — pre-formatting any block device breaks Rook auto-discovery. OSD disks appear as `/dev/vdc` and `/dev/vdd` (Lima virtio-blk), pre-created with `limactl disk create`. **Lima auto-formats named disks by default** — `format: false` must be set on every OSD disk entry in `ceph-node.yaml`, otherwise Lima ext4-formats and mounts them at boot, causing Rook to skip them with `skipping device "vdcX" with mountpoint`.
3. **Gateway API manifests must include API-defaulted fields** — The admission webhook injects `group: ""`, `kind: Service`, `weight: 1` into `backendRefs` and `matches` into HTTPRoute rules. Omitting them causes permanent ArgoCD OutOfSync loops. See `docs/gitops-argocd-lessons.md` §3.
4. **`CephFilesystemSubVolumeGroup` is required** (Rook ≥ v1.17) — without it, CephFS dynamic provisioning silently fails. See `applications/rook/storage/filesystem.yaml`.
5. **`preserve*OnDelete: true`** on `CephFilesystem` and `CephObjectStore` — protects data from accidental ArgoCD sync prunes.
6. **ArgoCD runs insecure** — TLS terminates at the Cilium Gateway. Trust `ceph-lab-ca` on Mac to avoid browser warnings.
7. **Hubble metrics are disabled at bootstrap** — prometheus-operator CRDs don't exist yet when Cilium deploys. Enable after wave `-5` settles.
8. **k3s uses SQLite, not etcd** — `kubeEtcd` scraper is disabled in Prometheus values.
9. **Gateway API CRDs must precede Cilium** — wave `-15` mirrors `install_cilium.sh` which applies CRDs first with `kubectl wait`.
10. **`--enable-helm` is required** — patched into `argocd-cm` via `cluster-bootstrap/argocd/kustomization.yaml`. Without it, `helmCharts:` stanzas are silently ignored.
11. **OSD histogram `le` labels use high floating-point precision** — `ceph-latency-bridge` exports bucket boundaries like `le="0.099999"` not `le="0.1"`. PromQL queries in dashboards and recording rules must match these exact labels or return no data.
12. **Histogram buckets must be in strictly ascending order** — custom exporters (like `ceph-latency-bridge`) must emit `le` values ascending with `+Inf` last. Out-of-order buckets cause Prometheus to silently discard the metric.
13. **`ceph-observability-mach-2.json` is the definitive SLO dashboard** — 3-row narrative: Health → SLI → SLO. Uses per-OSD P99 lines and burn-rate alerting. Located in `applications/rook/dashboards/`.
14. **Disabling ArgoCD selfHeal during manual fixes** — `selfHeal: true` will immediately revert `kubectl patch/apply` changes. Disable sync on `ceph-lab-root` first, then the specific Application, apply the fix, then push to git and re-enable.
15. **virtiofs mounts are async** — Lima YAML provision steps poll for `/ceph-lab/provisioning/provision.env` (up to 60s) before running scripts. Scripts must not assume `/ceph-lab` is immediately available at VM boot.
16. **`socket_vmnet` must be at `/opt/socket_vmnet`** — required for the `ceph-lab` host-only network (192.168.56.0/24) that gives VMs static IPs. Run `make setup` once after installing Lima.
17. **Lima disks must be pre-created** — `limactl disk create` must run before `limactl start`. `lima-up.sh` handles this automatically; manual starts require running `ensure_disk` first.
18. **`lima0` default route breaks pod egress** — Lima always adds a `lima0` management interface (192.168.105.0/24) whose DHCP installs a default route at metric 100, beating vzNAT's `eth0` at metric 200. Cilium BPF masquerade SNATs via `eth0`, so outbound pod packets leave on `lima0` with the wrong source IP and replies (e.g. from GitHub) never match the BPF conntrack table — ArgoCD can't clone repos. Fix: `dhcp4-overrides: {use-routes: false}` on `lima0` in netplan (already in both Lima templates).
19. **Cilium IPAM CIDR must match at both install phases** — `install_cilium.sh` (Helm, runs at VM boot) and the GitOps kustomization (applied later by `install_argocd.sh`) are two separate Cilium installs. If `install_cilium.sh` omits `--set "ipam.operator.clusterPoolIPv4PodCIDRList={10.244.0.0/16}"`, the initial ConfigMap gets Helm's default `cluster-pool-ipv4-cidr: 10.0.0.0/8`. Agents initialize IPAM from that value, write `10.0.x.0/24` into CiliumNode specs, and stay stuck there — the later kustomize apply fixes the ConfigMap but doesn't trigger a DaemonSet rollout. Result: all cross-node pod traffic BPF-masquerades and breaks. Fix is already in `install_cilium.sh`. **`--cluster-pool-ipv4-cidr` is NOT a valid `cilium-agent` flag** (only valid for `cilium-operator`) — do not add it to the DaemonSet args.

---

## Cluster topology

| Node | IP | Role |
|---|---|---|
| `ceph-control` | `192.168.56.50` | k3s server, 2 vCPU / 6 GiB (Lima/vz) |
| `ceph-node-{1,2,3}` | `192.168.56.{61,62,63}` | k3s agents + Ceph OSDs, 3 vCPU / 8 GiB + 2×5 GiB raw OSDs (Lima/vz) |
| Cilium Gateway | `192.168.56.200` | L2 LB (pool `192.168.56.192/27`) |

Hypervisor: **Lima** with `vmType: vz` (Apple Virtualization.framework) — native performance, no QEMU overhead.
Host network: `ceph-lab` socket_vmnet host-only segment (192.168.56.0/24, gateway .1).
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

## Further reading

- `docs/gitops-argocd-lessons.md` — hard-won GitOps/ArgoCD lessons and OutOfSync debugging playbook
- `docs/ceph-cheatsheet.md` — quick Ceph CLI reference
- `docs/observability-tour.md` — guided walkthrough of the Prometheus/Grafana + Hubble stack
- `docs/operational-posture.md` — maintenance vs normal cluster posture
- `docs/rgw-s3-runbook.md` — RGW / S3 objectstore operations and bucket management
- `.github/copilot-instructions.md` — full coding conventions (same content as this file, kept in sync)
