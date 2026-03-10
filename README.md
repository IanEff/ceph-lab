# ceph-lab

```
  ██████╗███████╗██████╗ ██╗  ██╗      ██╗      █████╗ ██████╗
 ██╔════╝██╔════╝██╔══██╗██║  ██║      ██║     ██╔══██╗██╔══██╗
 ██║     █████╗  ██████╔╝███████║      ██║     ███████║██████╔╝
 ██║     ██╔══╝  ██╔═══╝ ██╔══██║      ██║     ██╔══██║██╔══██╗
 ╚██████╗███████╗██║     ██║  ██║      ███████╗██║  ██║██████╔╝
  ╚═════╝╚══════╝╚═╝     ╚═╝  ╚═╝      ╚══════╝╚═╝  ╚═╝╚═════╝
```

A fully-gitopsed Rook/Ceph playground on k3s - a sandbox to play around with ceph, kubernetes, Cilium, et cetera.  Ceph traffic prettily lit up in Hubble.

---

## What's in the box

| Layer | Technology | Notes |
|---|---|---|
| VMs | Vagrant + VirtualBox | Ubuntu 24.04, 4 nodes |
| Kubernetes | k3s v1.32 | Single binary, SQLite, ~500 MB RAM |
| CNI + LB | Cilium 1.18.2 | eBPF, kube-proxy free, Gateway API, L2 LB, Hubble |
| Storage | Rook v1.19.1 + Ceph Tentacle v20.2.0 | RBD, CephFS, RGW (S3) |
| GitOps | ArgoCD stable | Kustomize-Helm, sync waves, insecure (TLS at gateway) |
| TLS | cert-manager v1.14.5 | Self-signed CA `ceph-lab-ca`, wildcard `*.ceph.lab` |
| Observability | kube-prometheus-stack + Loki + Tempo + Alloy | Full LGTM stack |
| Secrets | Sealed Secrets 2.16.0 | One-way encryption, GitOps-safe |

---

## Cluster topology

```
  ┌─────────────────────────────────────────────────┐
  │  Mac host  192.168.56.1                         │
  │  *.ceph.lab → 192.168.56.200 (via dnsmasq)      │
  └────────────┬────────────────────────────────────┘
               │ host-only network (192.168.56.0/24)
     ┌─────────▼──────────┐
     │  ceph-control :50  │  k3s server  2 vCPU / 3 GB
     └─────────┬──────────┘
               │
     ┌─────────▼──────────────────────────────┐
     │  ceph-node-1/2/3  :61/:62/:63          │
     │  k3s agents + Ceph OSDs                │
     │  3 vCPU / 6 GB each                    │
     │  /dev/sdc + /dev/sdd (50 GB, raw)       │
     └────────────────────────────────────────┘
               │
     ┌─────────▼──────────────────────────────┐
     │  Cilium Gateway  192.168.56.200         │
     │  LB pool 192.168.56.192/27              │
     └────────────────────────────────────────┘
```

---

## Prerequisites

- VirtualBox 7.x
- Vagrant 2.3+
- `brew install helm kubectl direnv jq` on your Mac
- Optional but recommended: local pull-through cache (see `.env.example`)

---

## Quick start

```bash
# 1. Clone this repo
git clone https://github.com/YOUR_USERNAME/ceph-lab.git
cd ceph-lab

# 2. Configure your environment
cp .env.example .env
# Edit .env — at minimum set:
#   GITOPS_REPO_URL=https://github.com/YOUR_USERNAME/ceph-lab.git
#   GITOPS_REPO_TOKEN=ghp_...  (or GITOPS_SSH_KEY_PATH for SSH deploy key)
direnv allow

# 3. Boot the cluster (~10–20 min)
vagrant up

# 4. Merge kubeconfig + SSH config onto your Mac
python3 provisioning/scripts/manage_k8s_config.py add

# 5. (Optional — if SANDBOX_INSTALL_ARGOCD=0) — bootstrap ArgoCD manually
vagrant ssh ceph-control
bash /vagrant/provisioning/scripts/install_argocd.sh

# 6. Watch ArgoCD sync the world
kubectl get applications -n argocd -w --context ceph-lab

# 7. Install Rook Ceph (once infra wave has settled, ~5–10 min)
# ArgoCD drives rook waves 20 through 35 automatically.
# To watch Ceph health:
kubectl exec -it -n rook-ceph deploy/rook-ceph-tools -- ceph status
```

---

## Service directory

| Service | URL | Credentials |
|---|---|---|
| ArgoCD | <https://argocd.ceph.lab> | admin / see `.env` (ARGOCD_BCRYPT_PASSWORD) |
| Ceph Dashboard | <https://dashboard.ceph.lab> | admin / `kubectl -n rook-ceph get secret rook-ceph-dashboard-password -o jsonpath='{.data.password}' \| base64 -d` |
| Grafana | <https://grafana.ceph.lab> | admin / prom-operator |
| Hubble UI | <https://hubble.ceph.lab> | — |
| Prometheus | <https://prometheus.ceph.lab> | — |
| Alertmanager | <https://alertmanager.ceph.lab> | — |

Run `bash provisioning/scripts/open_urls.sh` for a live summary including credentials.

---

## ArgoCD sync waves

Everything is deployed in dependency order — no manual sequencing needed:

| Wave | Component | Why |
|---|---|---|
| -15 | gateway-api CRDs | Must exist before Cilium starts |
| -10 | cilium | Gateway CRDs must precede; creates GatewayClass |
| -5 | cert-manager, prometheus, loki, tempo | Observability backbone |
| 0 | alloy, sealed-secrets, metrics-server | |
| 1 | l7-policies | CiliumNetworkPolicies (Cilium must exist) |
| 10 | argocd-ingress | HTTPRoutes for ArgoCD UI |
| 20 | rook operator | Helm chart, CRDs |
| 25 | rook cluster | CephCluster CR — waits for operator |
| 30 | rook storage | BlockPool, CephFS, ObjectStore (prune=true) |
| 35 | rook gateway | HTTPRoutes for Ceph Dashboard |

---

## Shell conveniences

These aliases are pre-configured inside every VM (`fish` and `bash`):

```bash
ceph-status     # ceph status via toolbox pod
ceph-df         # ceph df detail
ceph-osd-tree   # ceph osd tree
ceph-health     # ceph health detail
ceph-pools      # ceph osd pool ls detail
ceph-pg-stat    # ceph pg stat
ceph-log        # ceph log last 50
rook-tools      # exec into toolbox bash session
rook-status     # kubectl get cephcluster -n rook-ceph
watch-pods      # watch kubectl get pods -n rook-ceph
argo-apps       # kubectl get applications -n argocd
argo-sync       # argocd app sync --all
hubble-rook     # hubble observe --namespace rook-ceph
hubble-drops    # hubble observe --verdict DROPPED
get-pass        # extract dashboard password into clipboard
open-urls       # bash /vagrant/provisioning/scripts/open_urls.sh
```

---

## Wipe + reinstall (without rebuilding VMs)

```bash
# From Mac — destroys all Ceph data, zeros OSD disks
bash provisioning/scripts/wipe_ceph_disks.sh

# Then from inside ceph-control:
vagrant ssh ceph-control
bash /vagrant/provisioning/scripts/install_argocd.sh
# ArgoCD will re-sync and redeploy Rook from scratch
```

---

## Full teardown

```bash
python3 provisioning/scripts/manage_k8s_config.py remove
vagrant destroy -f
```

---

## Configuration knobs

All tuneable via `.env` (see `.env.example` for descriptions):

| Variable | Default | Purpose |
|---|---|---|
| `GITOPS_REPO_URL` | *(required)* | Your fork's clone URL |
| `SANDBOX_NUM_CEPH_NODES` | 3 | Worker count (min 3 for HA) |
| `SANDBOX_OSD_DISKS_PER_NODE` | 2 | Raw OSD disks per worker |
| `SANDBOX_INSTALL_ARGOCD` | 0 | Auto-run bootstrap after `vagrant up` |
| `SANDBOX_CACHE_ENABLED` | 0 | APT + OCI pull-through cache at 192.168.56.1 |
| `SANDBOX_CONFIGURE_DNSMASQ` | 1 | Write macOS dnsmasq entry for `*.ceph.lab` |
| `ROOK_VERSION` | v1.19.1 | Rook Helm chart version |
| `CILIUM_VERSION` | 1.18.2 | Cilium Helm chart version |
| `GATEWAY_API_VERSION` | v1.4.1 | Gateway API CRD version |
| `ARGOCD_VERSION` | stable | ArgoCD install channel or tag |

---

## Study resources

- [Mastering Ceph, 2nd Ed.](https://www.packtpub.com/product/mastering-ceph-second-edition/9781789610703) — Nick Fisk
- [Red Hat Ceph Storage 9 Documentation](https://access.redhat.com/documentation/en-us/red_hat_ceph_storage/9)
- [Ceph Upstream Docs (Tentacle)](https://docs.ceph.com/en/tentacle/)
- [Rook Ceph Documentation](https://rook.io/docs/rook/latest/)
- [Cilium Documentation](https://docs.cilium.io/en/stable/)
- [ArgoCD Documentation](https://argo-cd.readthedocs.io/en/stable/)

See also:

- [docs/ceph-cheatsheet.md](docs/ceph-cheatsheet.md) — quick Ceph command reference
- [docs/gitops-argocd-lessons.md](docs/gitops-argocd-lessons.md) — hard-won GitOps/ArgoCD lessons and the OutOfSync debugging playbook
- [docs/observability-tour.md](docs/observability-tour.md) — guided walkthrough of the LGTM + Hubble observability stack

---

## Architecture notes

- **k3s not kubeadm** — k3s uses SQLite instead of etcd, saving ~600 MB on the control node. This is important because `ceph-control` is only 3 GB and also runs Rook's operator + CSI pods.
- **OSD disks must stay raw** — Rook auto-discovers `/dev/sdc` and `/dev/sdd` on each worker. Pre-formatting them will break OSD creation.
- **`preserve*OnDelete: true`** is set on CephFilesystem and CephObjectStore as a safety net against accidental sync prunes.
- **Cilium replaces kube-proxy** — do not install kube-proxy; Cilium handles all service routing via eBPF.
- **Gateway API CRDs must precede Cilium** — `install_cilium.sh` installs them first so Cilium discovers the CRDs on startup and auto-creates the `cilium` GatewayClass.
- **CephFilesystemSubVolumeGroup is required** (Rook v1.17+) — included in `rook/storage/filesystem.yaml`. Without it dynamic CephFS provisioning silently fails.
- **Hubble metrics** are disabled at bootstrap (chicken-and-egg with Prometheus CRDs) and should be enabled once `kube-prometheus-stack` is synced.
