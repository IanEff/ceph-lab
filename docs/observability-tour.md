# Observability Tour — ceph-lab

> A guided walkthrough of every signal, screen, and query worth knowing
> in this cluster's observability stack.  Five UIs, three signal types,
> one very lit-up Christmas tree.

---

## The signal map

```
                     ┌─────────────────────────────────────────────────────┐
                     │                   Grafana                            │
                     │   dashboards · explore · alerts · service maps       │
                     └────┬────────────┬────────────┬───────────────────────┘
                          │            │            │
                    Prometheus       Loki         Tempo
                    (metrics)       (logs)       (traces)
                          │            │            │
                   ┌──────┴──┐   ┌────┴────┐   ┌───┴────┐
                   │ServiceM.│   │  Alloy  │   │  OTLP  │
                   │ (Rook)  │   │DaemonSet│   │receiver│
                   └──────┬──┘   └────┬────┘   └───┬────┘
                          │           │             │
              ┌───────────┴───────────┴─────────────┘
              │          Kubernetes cluster
              │   rook-ceph · kube-system · monitoring · logging · tracing
              └────────────────────────────┬────────────────────────────
                                           │
                               Hubble (Cilium)
                               L3/L4/L7 flow visibility
```

**Every URL is `https://`:// — TLS terminates at the Cilium Gateway using a cert-manager
self-signed wildcard for `*.ceph.lab`.**

| Service        | URL                                 | Credentials           |
|----------------|-------------------------------------|-----------------------|
| Grafana        | <https://grafana.ceph.lab>            | admin / password      |
| Prometheus     | <https://prometheus.ceph.lab>         | (none)                |
| Alertmanager   | <https://alertmanager.ceph.lab>       | (none)                |
| Ceph Dashboard | <https://dashboard.ceph.lab>          | admin / (see below)   |
| Hubble UI      | <https://hubble.ceph.lab>             | (none)                |
| ArgoCD         | <https://argocd.ceph.lab>             | admin / (see below)   |

```bash
# Retrieve the Ceph dashboard password
kubectl -n rook-ceph get secret rook-ceph-dashboard-password \
    -o jsonpath='{.data.password}' | base64 -d && echo

# Retrieve the ArgoCD password
kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' | base64 -d && echo
```

---

## Grafana

**<https://grafana.ceph.lab>**

The primary window into everything.  Three datasources are pre-configured and
cross-linked so you can jump from a metric spike → the logs that caused it →
a trace that explains the path.

### Datasources

| Name       | UID          | What it connects to                                 |
|------------|--------------|-----------------------------------------------------|
| Prometheus | `prometheus` | `kube-prometheus-stack-prometheus.monitoring:9090`  |
| Loki       | `loki`       | `loki.logging:3100`                                 |
| Tempo      | `tempo`      | `tempo.tracing:3100`                                |

Cross-datasource links are wired:

- **Loki → Tempo**: any log line containing `traceID=<hex>` becomes a clickable link
  to the matching Tempo trace.
- **Tempo → Prometheus**: service map node click opens the Prometheus metrics for
  that service.
- **Tempo → Loki**: trace detail panel has a "Logs for this trace" button that runs
  a Loki query filtered by `traceID`.

### Dashboard inventory

Grafana's sidecar auto-imports ConfigMaps labelled `grafana_dashboard=1` from every
namespace.  Here's what's loaded at boot:

#### Ceph / Rook (namespace: `rook-ceph`)

| Dashboard                  | What to look for                                         |
|----------------------------|----------------------------------------------------------|
| **Ceph Cluster**           | Cluster health, IOPS, throughput, capacity, PG states    |
| **Ceph OSD Single**        | Per-OSD latency (commit + apply), ops/sec, bytes/sec     |
| **Ceph Pools**             | Per-pool read/write bandwidth, object counts, PG distribution |

#### Cilium / Hubble (namespace: `monitoring`)

| Dashboard                  | What to look for                                         |
|----------------------------|----------------------------------------------------------|
| **Cilium Overview**        | Drop rates, policy verdicts, endpoint health             |
| **Hubble L4 Flows**        | Per-namespace TCP/UDP flow counts, connection rate        |
| **Hubble L7 HTTP**         | Request rate, error rate, latency p50/p95/p99 per workload |
| **Hubble DNS**             | DNS query rate, NXDOMAIN counts, per-client query volume |
| **Cilium Operator**        | Operator reconciliation latency, error rate              |

#### Kubernetes / Infrastructure (kube-prometheus-stack defaults)

| Dashboard                  | What to look for                                         |
|----------------------------|----------------------------------------------------------|
| **Kubernetes / Nodes**     | CPU, memory, disk I/O — per node                         |
| **Kubernetes / Pods**      | Container restart counts, OOMKill events                 |
| **Kubernetes / Namespaces**| Resource usage by namespace                              |
| **Kubernetes / Persistent Volumes** | PVC usage, volume latency                     |
| **Kubernetes / API Server**| Request rate, error rate, etcd size (SQLite in k3s)      |
| **CoreDNS**                | Query rate, errors, cache hit ratio                      |

### Grafana Explore — the real fun starts here

**Menu → Explore** (compass icon) is where you write ad-hoc queries.  The three
datasources unlock three query languages:

#### Explore: Prometheus (PromQL)

```promql
# Ceph cluster health (0=OK, 1=WARN, 2=ERR)
ceph_health_status

# OSD IOPS over the last 5 minutes
rate(ceph_osd_op_r[5m]) + rate(ceph_osd_op_w[5m])

# OSD applied latency percentile (ms)
histogram_quantile(0.99, rate(ceph_osd_op_w_latency_seconds_bucket[5m])) * 1000

# Cluster raw capacity
ceph_cluster_total_bytes - ceph_cluster_total_used_raw_bytes

# Alert: any firing Ceph alerts right now?
ALERTS{alertname=~"Ceph.*", alertstate="firing"}

# Per-namespace network bytes via Hubble
sum by (destination_namespace) (
  rate(hubble_flows_processed_total{direction="INGRESS"}[5m])
)

# Cilium policy drop rate
rate(hubble_drop_total[5m])

# Node memory pressure
(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100
```

#### Explore: Loki (LogQL)

All pod logs land in Loki with labels: `{namespace, pod, container, cluster="ceph-lab"}`.
Logs from `rook-ceph` also get `{ceph_daemon, ceph_level}` extracted by Alloy.

```logql
# All Ceph OSD logs
{namespace="rook-ceph", container=~"osd.*"}

# Ceph OSD warnings and above
{namespace="rook-ceph"} | ceph_level =~ "WARNING|ERR|CRITICAL"

# Specific OSD daemon
{namespace="rook-ceph", ceph_daemon="osd.0"}

# MGR log (controller decisions, module output)
{namespace="rook-ceph", container="mgr"}

# Rook operator decisions (watch this when you apply CRD changes)
{namespace="rook-ceph", container="rook-ceph-operator"}

# Cluster-wide error logs across all namespaces
{cluster="ceph-lab"} |= "error" | __error__=""

# ArgoCD app-controller (sync decisions, health checks)
{namespace="argocd", container="argocd-application-controller"}

# Kubernetes events (node NotReady, OOMKilled, PV bound, etc.)
{job="loki.source.kubernetes_events"}

# cert-manager certificate issuance
{namespace="cert-manager"} |= "certificate"

# Hubble relay logs
{namespace="kube-system", container="hubble-relay"}

# Log volume over time by namespace (good for spotting noise)
sum by (namespace) (count_over_time({cluster="ceph-lab"}[1m]))
```

**Tip**: In Grafana Explore with Loki selected, enable **"Live"** mode (lightning bolt
button) for a tail -f style stream of any label selector.  Great for watching OSD logs
during a scrub or rebalance.

**Trace correlation tip**: If a log line contains `traceID=abc123def456`, clicking the
`TraceID` derived field link jumps you directly to that trace in Tempo without any
copy-pasting.

#### Explore: Tempo (TraceQL)

Tempo holds OTLP traces forwarded by Alloy.  The service map shows inter-service
dependencies derived from span parent/child relationships and is backed by the
Prometheus metrics-generator.

```traceql
# All traces from the Ceph dashboard service
{ .service.name = "rook-ceph-mgr" }

# Slow spans (> 500ms) anywhere in the cluster
{ duration > 500ms }

# Errors in any span
{ status = error }

# Traces touching the rook-ceph namespace
{ resource.k8s.namespace.name = "rook-ceph" }
```

**Service Map** (Tempo datasource → Service Graph tab): shows a live directed graph of
which services call each other, with request rate and error rate overlaid.  Click any
node to see its RED metrics (Rate, Errors, Duration) as Prometheus charts.

---

## Prometheus

**<https://prometheus.ceph.lab>**

Most useful for ad-hoc metric exploration and alert debugging outside of Grafana.

### Key pages

| Page | URL path | What it's for |
|---|---|---|
| Graph | `/graph` | PromQL scratchpad with instant/range toggle |
| Alerts | `/alerts` | All `PrometheusRule` groups — firing, pending, inactive |
| Targets | `/targets` | Every scrape target + last scrape duration and status |
| Service Discovery | `/service-discovery` | Which ServiceMonitors are discovered |
| TSDB Status | `/tsdb-status` | Most-used metric names and label cardinality |
| Rules | `/rules` | Every recording and alerting rule currently loaded |

### Scrape targets to verify

After cluster boot, the `/targets` page should show all of these as **UP**:

| Job | What it scrapes |
|---|---|
| `rook-ceph-mgr` | Ceph MGR Prometheus module (port 9283) |
| `rook-ceph-exporter` | Ceph daemon performance counters (bluestore, OSD) |
| `hubble` | Hubble L3/L4/L7 flow metrics (via Alloy scrape) |
| `monitoring/kube-prometheus-stack-*` | kube-state-metrics, node-exporter, apiserver, kubelet |
| `kube-system/coredns` | DNS query metrics |

```bash
# Check all targets from CLI
kubectl exec -n monitoring deploy/kube-prometheus-stack-prometheus \
    -- wget -qO- http://localhost:9090/api/v1/targets \
    | python3 -c "
import json,sys
for t in json.load(sys.stdin)['data']['activeTargets']:
    print(t['health'], t['labels'].get('job','?'), t['lastError'] or '')
"
```

### Useful one-liners

```promql
# How many Ceph alerts are currently firing?
count(ALERTS{alertname=~"Ceph.*", alertstate="firing"}) or vector(0)

# Top 5 OSD latency offenders
topk(5, histogram_quantile(0.99,
  rate(ceph_osd_op_w_latency_seconds_bucket[5m])
) * 1000)

# Percentage of OSD capacity used
sum(ceph_osd_stat_bytes_used) / sum(ceph_osd_stat_bytes) * 100

# Oldest pending PG recovery
ceph_pg_recover_bytes_per_sec

# Hubble drops by reason
sort_desc(sum by (reason) (rate(hubble_drop_total[5m])))

# k3s node disk usage
(node_filesystem_size_bytes{mountpoint="/"} -
 node_filesystem_avail_bytes{mountpoint="/"})
/ node_filesystem_size_bytes{mountpoint="/"}
```

---

## Alertmanager

**<https://alertmanager.ceph.lab>**

Alertmanager shows every firing `PrometheusRule` alert grouped by its labels.

### What fires when things go wrong

The cluster has ~40 Ceph alerting rules loaded from the official Rook PrometheusRules.
The most important ones:

| Alert | Condition | Severity |
|---|---|---|
| `CephHealthError` | `ceph health == HEALTH_ERR` for 5m | critical |
| `CephHealthWarning` | `ceph health == HEALTH_WARN` for 15m | warning |
| `CephOSDDown` | Any OSD is down | critical |
| `CephOSDNearFull` | Any OSD > 75% used | warning |
| `CephOSDFull` | Any OSD > 85% used | critical |
| `CephMonQuorumAtRisk` | < 3 MONs in quorum | critical |
| `CephPGsDegraded` | Any PGs are degraded for > 5m | warning |
| `CephPGsInactive` | Any PGs inactive for > 5m | critical |
| `CephPoolNearFull` | Pool > 70% of quota | warning |
| `CephMDSInactiveForTooLong` | MDS has no active daemon | critical |
| `CephRGWHighRequestLatency` | RGW p99 > 1s for 10m | warning |

```bash
# Check alerts from CLI
kubectl exec -n monitoring deploy/kube-prometheus-stack-alertmanager \
    -- wget -qO- http://localhost:9093/api/v2/alerts | python3 -m json.tool
```

> **Tip**: Alertmanager is deployed but receivers are not configured — alerts fire into
> the void.  To route them somewhere useful, add an `AlertmanagerConfig` CRD pointing to
> Slack, PagerDuty, or a webhook.  See the kube-prometheus-stack docs for the manifest.

---

## Ceph Dashboard

**<https://dashboard.ceph.lab>**

Native Ceph UI served by the MGR's dashboard module.  Different from Grafana — this talks
directly to the Ceph daemons (not Prometheus) so it shows real-time state that Prometheus
may lag on.

### Sections worth visiting

#### Home

Live cluster health, capacity donut, active alerts, and a Prometheus-backed I/O sparkline
(now wired to the internal Prometheus instance — look for the "IOPS" and "Throughput" tiles
on the top row; they should show live data, not `N/A`).

#### OSDs

- **OSD List**: each OSD shows device class, capacity, read/write ops, latency, and
  `in`/`up` status.  Click an OSD to see its full performance history.
- **Performance Details**: individual OSD commit/apply latency histograms.

#### Pools

Per-pool read/write bandwidth, objects stored, compression ratio, and PG distribution.

#### Block Storage (RBD)

List all RBD images across all pools.  Snapshot creation/deletion, image sizes, and
current I/O stats per image.

#### Filesystem (CephFS)

MDS daemon status, active/standby roles, per-client I/O.

#### Object Storage (RGW)

Bucket list, per-user quota usage.  The S3 endpoint is active on port 80 inside the
cluster — see the `ceph-clients` namespace CiliumNetworkPolicy for access rules.

#### Logs (Live)

Streams the MGR log directly.  Much lower latency than Loki — use this during active
operations to see what decisions the MGR is making in real-time.

#### Administration → Cluster → CRUSH Map

Interactive CRUSH hierarchy viewer showing OSD weights, bucket types, and failure domains.

---

## Hubble UI

**<https://hubble.ceph.lab>**

Real-time network flow visibility into every connection in the cluster.

### The basics

The UI opens on a **service map** — a live directed graph of connections between services,
coloured by health.  Green edges = forwarded flows, red = dropped/rejected.

**Namespace selector** (top-left dropdown): filter to one namespace to reduce noise.
Particularly interesting namespaces:

| Namespace | What you'll see |
|---|---|
| `rook-ceph` | OSD peer replication, MGR → Prometheus, CSI sidecar health checks |
| `monitoring` | Prometheus scraping everything, Grafana → datasource calls |
| `logging` | Alloy → Loki pushes (should be constant purple flow lines) |
| `tracing` | Alloy → Tempo OTLP forwarding |
| `kube-system` | CoreDNS queries from all pods, Hubble relay, Cilium operator |
| `argocd` | App-controller → kube-apiserver, repo-server → git |

### Flow table

Click any edge in the service map to open the **flow table** below it.  Each row is an
individual connection with:

- Source pod / namespace
- Destination pod / namespace / port
- Protocol (TCP / UDP / ICMP / HTTP / DNS)
- Verdict (FORWARDED / DROPPED / REDIRECTED / ERROR)
- L7 details for HTTP flows (method, URL path, status code)

**Useful flow filters:**

```
# In the Hubble UI filter bar:

# Show only dropped flows
verdict:dropped

# Show all HTTP flows
protocol:http

# Flows to the Ceph MGR metrics port
to-port:9283

# Flows in the rook-ceph namespace
namespace:rook-ceph

# DNS flows (shows which pods query which names)
protocol:dns
```

### Hubble CLI (from inside the VMs)

More powerful than the UI for raw exploration:

```bash
# Follow all flows in rook-ceph namespace
hubble observe --namespace rook-ceph --follow

# Only dropped flows (debug network policy issues)
hubble observe --verdict DROPPED --follow

# HTTP flows with response codes
hubble observe --protocol http --output=json | jq '.flow.l7.http | {method, url, code}'

# All flows to port 9283 (Ceph metrics)
hubble observe --to-port 9283 --follow

# Service-to-service summary (last 100 flows)
hubble observe --last 100 --output=jsonpb \
  | jq -r '[.flow.source.namespace, .flow.source.workload, "→",
             .flow.destination.namespace, .flow.destination.workload,
             .flow.verdict] | @tsv' \
  | sort | uniq -c | sort -rn
```

---

## Putting it all together: a debugging flow

Here's the full observability chain in practice.  Scenario: **an OSD is slow**.

### 1. Ceph Dashboard (immediate triage)

Open **<https://dashboard.ceph.lab> → OSDs**.  Find the OSD with high latency in the per-OSD
table.  Note the OSD number (e.g. `osd.2`).

### 2. Grafana: Ceph OSD Single Dashboard

Open **Grafana → Dashboards → Ceph OSD Single**.  Set the OSD variable to `osd.2`.
You'll see commit latency, apply latency, and ops/sec on a timeline — this shows *when*
the slowdown started.

### 3. Prometheus: correlate with node metrics

```promql
# Is the node disk busy?
rate(node_disk_io_time_seconds_total{device="sdc"}[5m])

# OSD CPU
rate(container_cpu_usage_seconds_total{namespace="rook-ceph",
  pod=~"rook-ceph-osd-2-.*"}[5m])
```

### 4. Loki: what was the OSD logging?

In **Grafana → Explore → Loki**, set the time range to the slowdown window:

```logql
{namespace="rook-ceph", ceph_daemon="osd.2"}
| ceph_level =~ "WARNING|ERR"
```

Look for slow operations, throttling messages, or bluestore fragmentation warnings.

### 5. Hubble: network contribution?

In **Hubble UI** or CLI, check whether the OSD's replication traffic was dropping:

```bash
hubble observe --namespace rook-ceph --to-port 6800 --verdict DROPPED
```

A Cilium policy `DROPPED` during a high-traffic period would explain latency from the
network side.

### 6. Alertmanager: was an alert fired?

Open **<https://alertmanager.ceph.lab>** — if `CephOSDNearFull` or `CephPGsDegraded` fired
during the window, it'll appear here with its exact start time.  That pins the timeline.

---

## The live tail sequence

This combination of commands gives you a real-time view when actively doing cluster work
— running a wiping/recovery/upgrade operation:

```bash
# Terminal 1: Ceph cluster events
kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph -w

# Terminal 2: Rook operator decisions
kubectl logs -n rook-ceph deploy/rook-ceph-operator -f --since=0s

# Terminal 3: Hubble drops (know immediately if a policy kills something)
hubble observe --verdict DROPPED --follow

# Terminal 4: Prometheus alert state
watch -n5 "kubectl exec -n monitoring deploy/kube-prometheus-stack-prometheus \
    -- wget -qO- 'http://localhost:9090/api/v1/alerts' \
    | python3 -c \"import json,sys; \
      [print(a['labels']['alertname'], a['state']) \
       for a in json.load(sys.stdin)['data']['alerts'] \
       if a['labels'].get('alertname','').startswith('Ceph')]\""
```

Or — much prettier — pin the **Ceph Cluster** Grafana dashboard with the time range set to
**Last 15 minutes, auto-refresh every 10s** and watch all the panes update live.

---

## Signal cheatsheet

| "I want to know..." | Go here | Query / filter |
|---|---|---|
| Is Ceph healthy right now? | **Ceph Dashboard** home | Health tile |
| Which OSD is slow? | **Grafana** → Ceph OSD Single | Sort by commit latency |
| When did the slowdown start? | **Grafana** → Ceph Cluster | IOPS / latency timeline |
| What was Ceph logging during the incident? | **Grafana Explore** → Loki | `{namespace="rook-ceph", ceph_level=~"WARNING\|ERR"}` |
| Is a network policy blocking Ceph traffic? | **Hubble UI** | `namespace:rook-ceph verdict:dropped` |
| Which Prometheus alerts are firing? | **Alertmanager** | Home page |
| How much pool capacity is left? | **Grafana** → Ceph Pools | Capacity used bar |
| What HTTP errors is RGW returning? | **Hubble UI** | `protocol:http namespace:rook-ceph` |
| What's Alloy up to? | **Grafana Explore** → Loki | `{namespace="monitoring", pod=~"alloy.*"}` |
| Did ArgoCD sync anything? | **Grafana Explore** → Loki | `{namespace="argocd", container="argocd-application-controller"} \|= "sync"` |
| Node disk saturation? | **Grafana** → Kubernetes / Nodes | Disk I/O panel |
| CoreDNS problems? | **Grafana** → CoreDNS | Error rate panel |
| Why is a pod not starting? | **Grafana Explore** → Loki | `{job="loki.source.kubernetes_events"} \|= "pod-name"` |
| L7-level HTTP flows between services | **Hubble UI** | Click edge in service map |
| Trace a slow request through services | **Grafana Explore** → Tempo | `{duration > 500ms}` |

---

## Further reading

- [Ceph Cheatsheet](./ceph-cheatsheet.md) — Ceph CLI commands for the toolbox
- [GitOps / ArgoCD Lessons](./gitops-argocd-lessons.md) — OutOfSync debugging
- [Rook Monitoring Docs](https://rook.io/docs/rook/latest/Storage-Configuration/Monitoring/ceph-monitoring/)
- [Hubble Documentation](https://docs.cilium.io/en/stable/observability/hubble/)
- [Grafana LogQL Reference](https://grafana.com/docs/loki/latest/query/)
- [Grafana TraceQL Reference](https://grafana.com/docs/tempo/latest/traceql/)
- [Prometheus Alerting Rules Reference](https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/)
