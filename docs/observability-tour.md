# Observability Tour — ceph-lab

> A guided walkthrough of every signal, screen, and query worth knowing
> in this cluster's observability stack.

---

## The signal map

```
                     ┌─────────────────────────────────────────────────────┐
                     │                   Grafana                            │
                     │   dashboards · explore · alerts · unified alerting   │
                     └────┬────────────┬────────────────────────────────────┘
                          │            │
                    Prometheus       Hubble
                    (metrics)        (flows)
                          │            │
                   ┌──────┴──────┐     │
                   │  Alloy      │     │
                   │(scraping)   │     │
                   └──────┬──────┘     │
                          │            │
              ┌───────────┴────────────┴─────┐
              │          Kubernetes cluster  │
              │   rook-ceph · kube-system    │
              └──────────────────────────────┘
```

**Every URL is `https://` — TLS terminates at the Cilium Gateway using a cert-manager
self-signed wildcard for `*.ceph.lab`.**

| Service        | URL                                 | Credentials           |
|----------------|-------------------------------------|-----------------------|
| Grafana        | <https://grafana.ceph.lab>            | admin / password      |
| Prometheus     | <https://prometheus.ceph.lab>         | (none)                |
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

The primary window into everything. Prometheus is the core datasource, providing
metrics for the cluster, nodes, pods, and Ceph itself.

### Datasources

| Name       | What it connects to                                 |
|------------|-----------------------------------------------------|
| Prometheus | `prometheus-server.monitoring:80`                   |

### Dashboard inventory

Grafana's sidecar auto-imports ConfigMaps labelled `grafana_dashboard=1` from every
namespace. Here's what's loaded at boot:

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

---

## Prometheus

**<https://prometheus.ceph.lab>**

Most useful for ad-hoc metric exploration and alert debugging outside of Grafana.

### Key pages

| Page | URL path | What it's for |
|---|---|---|
| Graph | `/graph` | PromQL scratchpad with instant/range toggle |
| Targets | `/targets` | Every scrape target + last scrape duration and status |
| Rules | `/rules` | Every recording and alerting rule currently loaded |

### Scrape targets to verify

After cluster boot, the `/targets` page should show all of these as **UP**:

| Job | What it scrapes |
|---|---|
| `rook-ceph-mgr` | Ceph MGR Prometheus module (port 9283) |
| `rook-ceph-operator` | Rook operator performance metrics |
| `hubble` | Hubble L3/L4/L7 flow metrics (scraped via Alloy) |
| `kubernetes-service-endpoints` | Any service with `prometheus.io/scrape: "true"` |

---

## Ceph Dashboard

**<https://dashboard.ceph.lab>**

Native Ceph UI served by the MGR's dashboard module. It talks directly to Ceph
daemons for real-time state.

### Sections worth visiting

- **Home**: Live health, capacity, and active alerts.
- **OSDs**: Performance details and individual OSD health.
- **Pools**: Read/write bandwidth and PG distribution.
- **Logs**: Real-time MGR log stream.

---

## Hubble UI

**<https://hubble.ceph.lab>**

Real-time network flow visibility into every connection in the cluster.

### The basics

The UI opens on a **service map** showing live connections between services.
Green edges = forwarded, red = dropped.

### Hubble CLI (from inside the VMs)

```bash
# Follow all flows in rook-ceph namespace
hubble observe --namespace rook-ceph --follow

# Only dropped flows (debug network policy issues)
hubble observe --verdict DROPPED --follow
```
