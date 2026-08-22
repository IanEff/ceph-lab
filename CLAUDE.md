# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A fully-gitopsed **Rook/Ceph playground on k3s**, managed end-to-end by ArgoCD. `task up` provisions 4 Lima VMs; `install_argocd.sh` bootstraps the entire software stack from git — no manual `kubectl apply` needed.

---

## Key commands

**⚠️ `justfile` was retired in favor of `Taskfile.yaml` (go-task) — use `task <verb>`, not `just <verb>`.** A `Makefile` also still exists as a thinner wrapper around the same lifecycle scripts (`make up/down/destroy/ssh/kubeconfig/setup/setup-sudoers`) for muscle-memory compat, but it doesn't cover the newer verbs (SLO gen, cache, golden images) — prefer `task` going forward. Run `task --list` (or bare `task`) for the live list.

```bash
# One-time host setup (Lima, socket_vmnet, network config)
task setup

# Optional: passwordless sudo for Lima/dnsmasq/resolver management
task setup-sudoers

# Boot cluster (~10–20 min first run, faster with a golden image — see gotcha #28)
task up

# Merge kubeconfig + SSH config onto Mac (re-run after restarts)
task kubeconfig

# Open a shell on ceph-control
task ssh

# Bootstrap ArgoCD manually (from inside ceph-control, or if SANDBOX_INSTALL_ARGOCD=0)
bash /ceph-lab/provisioning/scripts/install_argocd.sh

# Watch ArgoCD sync progress
kubectl get applications -n argocd -w --context ceph-lab

# Check Ceph health
kubectl exec -it -n rook-ceph deploy/rook-ceph-tools -- ceph status

# Wipe OSDs for clean Rook reinstall (no VM rebuild)
bash provisioning/scripts/wipe_ceph_disks.sh

# Regenerate Prometheus rule groups from the Sloth SLO specs
task gen-slos

# Time every ArgoCD Application reaching Healthy from a cold boot
task up & task boot-timeline

# Start/stop the local apt + OCI pull-through cache (see gotcha #27)
task cache-up
task cache-down

# Bake a Lima golden image (packages + images pre-cached; see gotcha #28)
task bake-image
task images         # list built golden images (active + archived)
task prune-images    # delete old archived images, keep newest per arch

# Stop VMs (preserve state)
task down

# Full teardown (prompts unless FORCE=1)
task destroy
FORCE=1 task destroy && time task up   # force teardown and time the rebuild
```

---

## Repository layout

```
applications/
  config/             # gitops.env — single source of truth for all IPs, versions, hostnames
  infrastructure/     # one dir per infra component; each has config.json + kustomization.yaml
    ceph-latency-bridge/  # native OSD histogram reconstruction (wave 30)
    sloth/            # PrometheusServiceLevel specs — NOT a deployed app; build-time input to
                      # `task gen-slos` (renders into infrastructure/prometheus/values.yaml). See gotcha #24.
    topology-catalog/ # static catalog-info.yaml topology map, ConfigMap (wave 5)
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
  cache/              # docker-compose.yaml for the local apt + OCI pull-through cache (gotcha #27)
  scripts/            # VM provisioning scripts + macOS host helpers
    build_golden_image.sh    # bakes a Lima golden qcow2 (task bake-image, gotcha #28)
    manage_golden_images.sh  # list/prune golden images (task images / prune-images)
    image_manifest.py        # discovers every image the GitOps tree declares (task list-images)
    boot_timeline.py         # times each ArgoCD Application reaching Healthy (task boot-timeline)
    cache_up.sh / cache_down.sh  # start/stop the pull-through cache containers
  provision.env       # Cluster topology defaults (committed; no secrets)
  lima-up.sh          # Start/provision all VMs
  lima-down.sh        # Stop VMs (preserve state)
  lima-destroy.sh     # Delete VMs and disks
  lima-setup.sh       # One-time host prereqs
docs/                 # ceph-cheatsheet.md, gitops-argocd-lessons.md, observability-tour.md, operational-posture.md, rgw-s3-runbook.md
Taskfile.yaml         # go-task lifecycle wrapper (task --list) — replaces the retired justfile
Makefile              # Thinner wrapper, core verbs only: make up/down/destroy/ssh/kubeconfig/setup
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
| 5 | topology-catalog (static `catalog-info.yaml` ConfigMap) | true | true |
| 10 | argocd-ingress | true | true |
| 20 | rook-operator | **false** | true |
| 25 | rook-cluster | **false** | **false** |
| 30 | rook-storage | true | true |
| 30 | ceph-latency-bridge (SLO metrics) | true | true |
| 31 | rook-dashboards (Grafana ConfigMaps) | true | true |
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
11. **OSD histogram `le` labels use high floating-point precision** — `ceph-latency-bridge` exports bucket boundaries with millisecond units because the exporter divides raw nanosecond values by `1e6` (e.g. `le="102.399999"` represents ~102.4ms). PromQL queries in dashboards and recording rules must match these exact labels, or they will return no data.
12. **Histogram buckets must be in strictly ascending order** — custom exporters (like `ceph-latency-bridge`) must emit `le` values ascending with `+Inf` last. Out-of-order buckets cause Prometheus to silently discard the metric.
13. **`ceph-observability-mach-2.json` is the definitive SLO dashboard** — 3-row narrative: Health → SLI → SLO. Uses per-OSD P99 lines and burn-rate alerting. Located in `applications/rook/dashboards/`. Row 3 is Sloth-backed (`sloth_id="ceph-osd-latency"`, **write** latency 99%/100ms — it was read latency 99.9%/100ms before the Sloth cutover, a real semantic change) — see gotcha #21/#22 before editing its queries. The write-latency threshold was originally spec'd as <50ms (`le="0.049999"`) but that bucket doesn't exist; verified live 2026-07-03 against `ceph_osd_op_w_latency_bucket` and corrected to <100ms (`le="0.099999"`) — see gotcha #24.
14. **Disabling ArgoCD selfHeal during manual fixes** — `selfHeal: true` will immediately revert `kubectl patch/apply` changes. Disable sync on `ceph-lab-root` first, then the specific Application, apply the fix, then push to git and re-enable.
15. **virtiofs mounts are async** — Lima YAML provision steps poll for `/ceph-lab/provisioning/provision.env` (up to 60s) before running scripts. Scripts must not assume `/ceph-lab` is immediately available at VM boot.
16. **`socket_vmnet` must be at `/opt/socket_vmnet`** — required for the `ceph-lab` host-only network (192.168.56.0/24) that gives VMs static IPs. Run `make setup` once after installing Lima.
17. **Lima disks must be pre-created** — `limactl disk create` must run before `limactl start`. `lima-up.sh` handles this automatically; manual starts require running `ensure_disk` first.
18. **`lima0` default route breaks pod egress** — Lima always adds a `lima0` management interface (192.168.105.0/24) whose DHCP installs a default route at metric 100, beating vzNAT's `eth0` at metric 200. Cilium BPF masquerade SNATs via `eth0`, so outbound pod packets leave on `lima0` with the wrong source IP and replies (e.g. from GitHub) never match the BPF conntrack table — ArgoCD can't clone repos. Fix: `dhcp4-overrides: {use-routes: false}` on `lima0` in netplan (already in both Lima templates).
19. **Cilium IPAM CIDR must match at both install phases** — `install_cilium.sh` (Helm, runs at VM boot) and the GitOps kustomization (applied later by `install_argocd.sh`) are two separate Cilium installs. If `install_cilium.sh` omits `--set "ipam.operator.clusterPoolIPv4PodCIDRList={10.244.0.0/16}"`, the initial ConfigMap gets Helm's default `cluster-pool-ipv4-cidr: 10.0.0.0/8`. Agents initialize IPAM from that value, write `10.0.x.0/24` into CiliumNode specs, and stay stuck there — the later kustomize apply fixes the ConfigMap but doesn't trigger a DaemonSet rollout. Result: all cross-node pod traffic BPF-masquerades and breaks. Fix is already in `install_cilium.sh`. **`--cluster-pool-ipv4-cidr` is NOT a valid `cilium-agent` flag** (only valid for `cilium-operator`) — do not add it to the DaemonSet args.
20. **Lima auto port-forwarding is pure noise here — disable it wholesale.** Lima's hostagent forwards every guest-bound port to host loopback by default, and since the v1.1 GRPC-forwarder default it forwards UDP too. On a busy k3s+Ceph guest that's hundreds of ephemeral `0.0.0.0:NNNNN → 127.0.0.1:NNNNN` lines, plus a dual-stack `0.0.0.0:111` / `[::]:111` rpcbind collision (`bind: address already in use`), drowning `ha.stdout.log`. **None of it is load-bearing**: all access is via the `ceph-lab` socket_vmnet net (192.168.56.0/24) + Cilium Gateway, and the kubeconfig targets `192.168.56.50:6443` directly — nothing routes over Lima loopback. Disable it in both `ceph-control.yaml` and `ceph-node.yaml` (SSH:22 is forwarded regardless):
    ```yaml
    portForwards:
      - ignore: true
        proto: any
        guestIP: "0.0.0.0"
    ```
    `proto: any` + `guestIP: "0.0.0.0"` is the canonical disable-all incantation; the bare `ignore: true` form silently regressed in Lima 1.0.1 (#2901). If you ever need a loopback shortcut, list it *above* the ignore — first match wins. Grammar is undocumented except in `templates/default.yaml` comments and `pkg/limayaml/defaults.go`.
21. **Sloth's `sloth_id` label is NOT the CR's `metadata.name`** — it's computed as `"{spec.service}-{slo.name}"` (confirmed against Sloth's own source, `internal/storage/io/k8s_sloth.go`). To land on a specific `sloth_id` (rattle's `SLO.ID` contract requires this — see `applications/infrastructure/sloth/prometheusservicelevels.yaml`), split `service`/`name` accordingly (e.g. `service: ceph-osd` + `name: latency` → `sloth_id: ceph-osd-latency`), not by renaming the CR.
22. **Sloth's `slo:current_burn_rate:ratio` is a single un-windowed series**, computed off the page-alert's short window — there is no separate metadata metric per window (1h vs 6h). Anything wanting an explicit windowed burn rate (like `ceph-observability-mach-2.json`'s Row 3) must use `slo:sli_error:ratio_rate{1h,6h}{sloth_id=...} / (1 - objective)` instead — Sloth does generate per-window SLI error-ratio series, just not per-window burn-rate ones. Also: Sloth's metadata recording rules have no on/off flag — they're always generated, there's nothing to "enable."
23. **Loki/Tempo/Alloy were already deployed here once and removed for OOM'ing `ceph-control`** (see `docs/trim-observability-stack.md`) — but that was on the old Vagrant/VMware topology at 3 GB. The Lima rewrite already doubled `ceph-control` to 6 GiB, and Lima's `vz` backend has substantially less virtualization overhead than Vagrant/VMware on top of that — real headroom exists now. Still: size any reintroduction (Loki/Promtail, Tempo/OTel Collector) with explicit resource requests/limits (the original incident's root cause was *unbounded* usage, not merely "too much") and a post-deploy OOM-watch verification gate, not by assuming the extra headroom makes limits unnecessary.
24. **The standalone `prometheus` chart reads NO `monitoring.coreos.com` CRs** — no ServiceMonitor/PrometheusRule controller is deployed (`prometheus-operator-crds` ships CRD schemas only, no controller), so a live Sloth Deployment generating `PrometheusRule` CRs was pure overhead nothing consumed. Fix: `applications/infrastructure/sloth/prometheusservicelevels.yaml` is now a **build-time spec only** (the Sloth runtime chart + CRDs were retired from the cluster) — `provisioning/scripts/gen_slos.sh` (`task gen-slos`) runs the pinned `sloth` CLI (`brew install sloth-cli`, version must match the spec's last-tested chart version) to render it into plain rule groups spliced into `applications/infrastructure/prometheus/values.yaml`'s `serverFiles.recording_rules.yml` / `.alerting_rules.yml` (between `# --- BEGIN/END sloth-generated ... ---` markers — do not hand-edit inside them). `.github/workflows/slo-drift.yml` fails CI if the spec and the rendered rules disagree. Also folded in here: the `ceph-osd-latency` SLO's `le="0.049999"` bucket boundary was a guess that turned out wrong — verified live 2026-07-03 against `ceph_osd_op_w_latency_bucket`, corrected to `le="102.399999"` (objective is p99 **< 100ms**, not <50ms; also requires filtering count/bucket to `{job="ceph-latency-bridge"}` to avoid count inflation from double scrapes).
25. **Any new scrape target in a CNP'd namespace needs its port added to that namespace's `l7-visibility` allowlist** — the l7-policies make selected pods default-deny for unmatched ingress (`endpointSelector: {}` + explicit `toPorts` allowlist). Diagnosed via kube-state-metrics: its scrape job existed and KSM was healthy, but `monitoring/l7-visibility` only allowlisted 9090/3000/80, so every scrape timed out (`context deadline exceeded`) despite being same-node. Symptom looks like "no ServiceMonitor" or "target down"; check the CNP allowlist before anything else.
26. **Sloth SLIs must aggregate to a singleton series** — any scrape source scraped multiple times (e.g., `mgr` pod double-scraped by the annotation-based `kubernetes-pods` job and the explicit `rook-ceph-mgr` job) will duplicate metric streams. If the SLI doesn't aggregate (e.g., wrapping raw queries in `max()` or `sum()`), multiple series are written per `sloth_id` (like `slo:current_burn_rate:ratio`). Downstream systems like rattle's `BurnSamples` take the first series (`Result[0]`), silently ignoring duplicates, which leads to flapping behavior if scrape paths go out of sync.
27. **`applications/**/charts/` is now committed, not gitignored** — this flipped in the justfile→Taskfile overhaul. Several slow-fetching Helm charts (rook-ceph, grafana, loki, promtail, prometheus-operator-crds) are deliberately vendored so ArgoCD's repo-server never needs a live `helm pull` round-trip to render them on sync; kustomize reuses the local chart dir instead. **Do not re-add a blanket `applications/**/charts/` ignore** — that silently drops them from git again and reintroduces the network dependency. `.task/` (go-task's local cache/checksum dir) is gitignored instead.
28. **Local pull-through cache is opt-in but on by default** (`SANDBOX_CACHE_ENABLED=1`) — `provisioning/cache/docker-compose.yaml` runs apt-cacher-ng (3142) + OCI registry mirrors for docker.io/registry.k8s.io/ghcr.io/quay.io (5001–5004) on the Mac, bound to the `ceph-lab` socket_vmnet gateway (192.168.56.1) so VMs can reach it. `task up` starts it automatically via `cache_up.sh` before touching any VM; every guest-side consumer (`common.sh`) probes with a plain TCP check and falls through silently to the public registries on a miss, so a cache that was never started (`docker` missing, daemon down) costs nothing beyond one probe timeout. Manage by hand with `task cache-up` / `task cache-down`, not `docker compose` directly — the ports must stay in sync with `provisioning/provision.env`.
29. **Golden Lima images are an optional boot-time accelerator, not a required step** — `task bake-image` (`provisioning/scripts/build_golden_image.sh`) boots a disposable Lima VM, runs the real `common.sh` (apt packages, kernel modules, sysctl), pre-pulls every image the GitOps tree declares (via `image_manifest.py`) into k3s's embedded containerd, and converts the result to `~/.lima-images/ceph-lab-golden-<arch>.qcow2`. `lima-up.sh` picks that file up automatically if present (per-arch, both control-plane and worker roles share one image — `control-plane.sh`/`node.sh` still run live every boot for join tokens/identity) and falls back to the stock cloud image with no config change if it's absent. Rebuild after any package/image-list change with `task bake-image`; prune stale ones with `task prune-images`.
30. **`lima-up.sh` no longer waits for all four VMs before doing anything** — it waits only on `ceph-control`, kicks off ArgoCD bootstrap against just the control plane, and `wait`s on the worker PIDs *after* that bootstrap call returns. This is safe because ArgoCD's early sync waves (gateway-api, cilium, cert-manager, prometheus, rook-operator) don't need workers — only wave 25 (`rook-cluster`) does, and workers finish well before the reconciler gets there. `install_argocd.sh` itself now backgrounds the `argocd` CLI download (nothing downstream needs the binary, only `kubectl`) and pre-applies the `prometheus-operator-crds` Kustomize output server-side before the root Application, closing a CRD-registration race the earliest waves could otherwise hit. `ARGOCD_VERSION` is now a pinned tag in `provisioning/provision.env` (was the floating `stable` tag) — bump it deliberately.

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
