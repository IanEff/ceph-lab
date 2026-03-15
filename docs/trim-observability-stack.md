# Observability Stack Trim — This Is Overkill

## Context

The control node (2 vCPU / 3 GB, no swap) hit OOM during ArgoCD reconciliation when the
new shared objectstore came up — ArgoCD application-controller peaked at ~500 MB, k3s at
~1.4 GB, and Cilium at ~150 MB, leaving nothing for anything else.

The cluster's purpose is learning **Ceph/Rook**. The observability stack grew to serve
that, but ended up being the thing preventing Ceph from running cleanly.

---

## What to cut

### 1. Loki — `applications/infrastructure/loki/`

**Why it's here:** Centralized log aggregation. Point: `kubectl logs` is enough for a lab.
Ceph's own tooling (`ceph log`, `ceph crash ls`) covers daemon diagnostics.

**Why it's overkill:** Loki runs a StatefulSet with persistent storage, a compactor, and
relies on Alloy shipping every pod's logs cluster-wide. That's real infrastructure that
needs to be operated. In a 3-node lab where you already know which pod to look at, it's
pure overhead.

**Memory:** Loki StatefulSet + Alloy's log pipeline; the primary cost is worker-node
memory and ArgoCD reconciliation time for a complex Helm release.

**Files to remove:**
- `applications/infrastructure/loki/` (whole directory)
- `applications/infrastructure/l7-policies/cnp-monitoring.yaml` — check if the `logging`
  namespace ingress/egress rules are in the shared monitoring CNP; if so, strip the
  `logging` namespace selector entries

---

### 2. Tempo — `applications/infrastructure/tempo/`

**Why it's here:** Distributed tracing. The pitch was "see request flows across Ceph RGW."

**Why it's overkill:** Distributed tracing is meaningful for multi-service _applications_.
Ceph is a storage system — the interesting observability is metrics (pool utilization,
IOPS, latency) and logs (OSD crashes, slow ops). The traces being collected here are
almost entirely ArgoCD and Cilium internals. Zero Ceph learning value.

**Memory:** Tempo StatefulSet + compactor (~100 MB+ on workers).

**Files to remove:**
- `applications/infrastructure/tempo/` (whole directory)
- Strip `otelcol.*`/`tempo.*` blocks from Alloy values (moot once Alloy is gone too)

---

### 3. Alloy — `applications/infrastructure/alloy/`

**Why it's here:** The collection agent — ships metrics to Prometheus, logs to Loki,
traces to Tempo.

**Why it's overkill:** Once Loki and Tempo are gone, Alloy's job collapses to:
- Hubble metrics scrape (kube-prometheus-stack's own `ServiceMonitor` can do this)
- Pod annotation scraping (kube-prometheus-stack covers this natively too)
- Kubernetes event logs to... nowhere

kube-prometheus-stack ships with Prometheus, node-exporter, kube-state-metrics, and
Alertmanager. It already scrapes everything that matters. Alloy is redundant plumbing.

**Memory confirmed:** ~74 MB RSS on the control node (observed during OOM incident).
Also reduces ArgoCD application-controller load — one fewer wrapper-chart app.

**Files to remove:**
- `applications/infrastructure/alloy/` (whole directory)

**Note:** The Hubble metrics that Alloy was scraping — if you want those in Grafana, add
a `ServiceMonitor` for `hubble-metrics.kube-system:9965` in the kube-prometheus-stack
values or as a standalone manifest. It's a 10-line YAML.

---

### 4. Sealed Secrets — `applications/infrastructure/sealed-secrets/`

**Why it's here:** Encrypted secrets in git. Good practice.

**Why it's overkill:** The repo contains zero `SealedSecret` CRs. The controller runs
idle, consuming ~30 MB, and adds the ArgoCD reconciliation overhead of a Helm wrapper
chart for something producing no value.

If secrets management becomes a learning goal, it's trivially re-added.

**Memory:** ~30 MB on control node.

**Files to remove:**
- `applications/infrastructure/sealed-secrets/` (whole directory)

---

## What stays and why

| Component | Why |
|---|---|
| **Cilium** | CNI, L7 policy, L2 LB, Gateway API — foundational to the cluster and to Ceph's network story |
| **gateway-api CRDs** | Required by Cilium Gateway |
| **l7-policies** | Lightweight; makes Hubble flow views useful for watching Ceph traffic |
| **kube-prometheus-stack** | Prometheus + Grafana — the Ceph Dashboard delegates to Prometheus for pool/OSD metrics; Rook exports rich `ServiceMonitor` resources |
| **cert-manager** | ~50 MB; provides the `*.ceph.lab` wildcard cert for HTTPS on ArgoCD + Grafana |
| **argocd-ingress** | Access ArgoCD UI — hard to operate GitOps without it |
| **metrics-server** | ~20 MB; `kubectl top node/pod`, HPA support |

---

## How to remove a component

For any item in the cut list:

1. Delete the component's directory under `applications/infrastructure/<name>/`
2. ArgoCD's `infra-set.yaml` ApplicationSet auto-discovers via `config.json` — no other
   file needs editing
3. ArgoCD will detect the Application is gone from git and (with `prune: true`) delete
   the deployed resources
4. For the `logging` and `tracing` namespaces, ArgoCD prunes them too since `namespace.yaml`
   was part of the app

That's it. No `infra-set.yaml` edits, no kustomization changes. Just `rm -rf` + commit.

---

## Estimated recovery

| Cut | Where | Approximate saving |
|---|---|---|
| Loki | Workers + ArgoCD reconciliation | ~200 MB workers, reduced ArgoCD peak |
| Tempo | Workers + ArgoCD reconciliation | ~100 MB workers |
| Alloy | Control node | **74 MB confirmed** |
| Sealed Secrets | Control node | ~30 MB |

The biggest gain isn't raw RAM — it's that the ArgoCD application-controller stops
reconciling four complex Helm chart apps on every sync cycle. That's what was pushing it
to 500 MB and triggering the OOM loop during heavy reconciliation.
