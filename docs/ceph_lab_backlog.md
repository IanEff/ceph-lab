# 🔬 Ceph Lab Backlog — GitOps & Automation Ideas
*Started Mar 14, 2026. Pursue in a dedicated context window. This is the parking lot.* 🅿️

---

## 🌟 The Big Idea: ArgoCD-Managed Maintenance Windows

**The concept:** Use ArgoCD sync windows + resource hooks + ConfigMaps to drive Ceph operational state changes — specifically opening up recovery and backfill throttles during maintenance windows, then snapping them back when the window closes. The cluster's operational posture lives in git. A merge to `main` is the maintenance ticket.

### Why this is interesting
- Ceph's recovery/backfill ops are tunable but the tuning is ephemeral (`ceph config set` at runtime, lost on restart unless persisted in the mon config store)
- If those tuning values live in a ConfigMap in git and ArgoCD syncs them via a Job/hook, you get: auditable maintenance windows, automatic revert, no "who ran that ceph command at 2am" mysteries
- This is exactly the kind of "GitOps-ifying the runbook" work that Dan Prince's team needs to build and doesn't have yet

### Rough implementation shape
```
maintenance-window/
  ├── argocd-sync-window.yaml        # SyncWindow: allow sync only during window
  ├── pre-sync-hook-job.yaml         # PreSync Job: opens recovery throttles
  │     ceph config set osd osd_max_backfills 4
  │     ceph config set osd osd_recovery_op_priority 63
  │     ceph config set osd osd_recovery_max_active 4
  ├── post-sync-hook-job.yaml        # PostSync Job: restores conservative values
  │     ceph config set osd osd_max_backfills 1
  │     ceph config set osd osd_recovery_op_priority 3
  │     ceph config set osd osd_recovery_max_active 1
  └── sync-wave-annotations.yaml    # wave ordering if needed
```

**Questions to work through:**
- Does the hook Job need a ServiceAccount with `ceph` CLI access? (Yes — need to think about the toolbox pod or a custom image with `ceph` + admin keyring)
- Should this be a separate ArgoCD Application targeting a `maintenance/` directory in the repo, or hooks on the main cluster app?
- How do you handle the "window ends but the hook Job hasn't finished" case? SyncFail hook?
- Is `ceph config set` to the mon config store durable enough, or do you need to write to a CephCluster CR field?

---

## 📋 Other Lab Ideas (parking lot)

### GitOps-ify the runbooks
- OSD replacement workflow as an ArgoCD Application + sync waves + hooks
  - Wave 1: mark OSD out (`ceph osd out <id>`)
  - Wave 2: wait for PG clean (liveness check hook?)
  - Wave 3: remove from CRUSH, decommission
  - Limitation: ArgoCD isn't great at "wait for external condition" — might need an Argo Workflow instead
- Scrub scheduling: push `osd_scrub_begin_hour` / `osd_scrub_end_hour` via ConfigMap + Job, ArgoCD-managed

### Argo Workflows for the stuff ArgoCD can't do
- ArgoCD = desired state reconciler. Doesn't do "wait for `ceph -s` to be clean" well.
- Argo Workflows = DAG pipeline. Perfect for: OSD replacement sequence, PG rebalance gate, capacity expansion procedure.
- Lab experiment: model the OSD replacement runbook as a Workflow DAG. Each step is a container that runs one `ceph` command and checks the result before proceeding.
- The Workflow definition lives in git. ArgoCD manages the Workflow controller deployment. Clean composition.

### Per-tenant OBC provisioning at scale
- ApplicationSet + `git` generator: `tenants/tenant-a/obc.yaml`, `tenants/tenant-b/obc.yaml`
- New tenant = new directory = ArgoCD auto-creates the OBC + ConfigMap + Secret
- Extend to: default quota annotations on the OBC, Hubble network policy for the namespace, RGW bucket lifecycle policy
- This is the storage onboarding automation story

### Lifecycle policies on RGW buckets via GitOps
- Checkpoint retention: expire objects under `checkpoints/` prefix after 7 days
- Dataset archival: transition objects under `datasets/cold/` to EC pool after 30 days
- The lifecycle XML can be stored in git and applied via an init Job or custom controller
- Stretch: write a tiny controller that watches a CRD (`BucketLifecyclePolicy`) and applies the XML to RGW via boto3 — your `bucket_brigade` project is exactly this territory

### CiliumNetworkPolicy automation
- Current state: hand-crafted policies for Ceph OSD ↔ MON ↔ RGW traffic
- Lab experiment: template the policies per-namespace via Helm/Kustomize, ArgoCD-managed
- Verify in Hubble: before and after, with a clear before/after comparison in the lab notes
- Story value: "I implemented CiliumNetworkPolicy for internal Ceph traffic and verified enforcement via Hubble" is a strong interview answer

### Observability stack as code
- Prometheus scrape configs, alerting rules, and Grafana dashboards all in git
- ArgoCD manages the Prometheus Operator CRs (`ServiceMonitor`, `PrometheusRule`)
- Dashboards as ConfigMaps (Grafana sidecar loads them automatically)
- Alert routing in git: who gets paged for `ceph_health_status` > 0 vs. `ceph_pool_percent_used` > 0.8
- This is the "operationalizing ArgoCD" chapter made real in your own cluster

### Chaos / degradation exercises (light touch)
- NOT breaking things for breaking's sake
- Scripted, documented, reversible exercises:
  - Mark one OSD out, observe PG state in Grafana, mark it back in, watch recovery
  - Tighten a CiliumNetworkPolicy too far, observe in Hubble, revert
  - Each exercise as a documented runbook in git — input to the degradation scenarios doc

---

## 🗺️ Rough Priority Order (for when you come back to this)

1. **ArgoCD maintenance window + recovery throttle hooks** — most novel, most interview-relevant, builds on what you already have
2. **Argo Workflows OSD replacement DAG** — teaches the ArgoCD/Workflows composition pattern
3. **Per-tenant OBC provisioning via ApplicationSet** — scale story, directly connects to Voltage Park use case
4. **RGW lifecycle policies in git** — connects to cost management vocabulary
5. **Observability stack as code** — useful but probably already partially done

---

*🌸 Pursue in a dedicated context window. Don't let this eat interview prep week.*
