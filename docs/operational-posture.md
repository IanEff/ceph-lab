# Operational Posture: GitOps-Managed Maintenance Mode

This cluster runs in one of two postures at all times. Both live in git. Neither requires a ticket, a runbook, or anyone fumbling with `ceph config set` at an inconvenient hour.

---

## The two postures

### Normal (default)

`applications/rook/cluster/` — the base.

OSD recovery and backfill run in the background at a quiet, unhurried pace. Client I/O gets priority. The cluster hums along, conserving what it has, not in any particular rush down here.

| Setting | Value | Effect |
|---|---|---|
| `osd_max_backfills` | 1 | One backfill op per OSD at a time |
| `osd_recovery_max_active` | 1 | One active recovery op per OSD |
| `osd_recovery_op_priority` | 3 | Recovery yields to client I/O |

### Maintenance

`applications/rook/cluster/overlays/maintenance/` — the overlay.

When an OSD has been out and you need the cluster to recover as fast as it can, you shift to maintenance posture. Backfill and recovery get the throttle opened up. Client I/O will feel it. That's the trade, and it's a deliberate one.

| Setting | Value | Effect |
|---|---|---|
| `osd_max_backfills` | 4 | Four parallel backfills per OSD |
| `osd_recovery_max_active` | 4 | Four active recovery ops per OSD |
| `osd_recovery_op_priority` | 63 | Recovery competes aggressively with client I/O |

---

## How it works

Rook translates `spec.cephConfig` fields directly into `ceph config set` calls against the mon config store on every reconcile. The values are durable — they survive OSD restarts. When ArgoCD syncs the `rook-cluster` application, Rook sees the new CR and applies the config.

`rook-cluster` has `selfHeal: false`, which means ArgoCD will not revert a live change the operator makes. It _will_ apply whatever path you've told it to sync from. That's the lever.

---

## Entering maintenance posture

Edit `applications/clusters/ceph-lab/rook-cluster.yaml`, change one line:

```yaml
# Before (normal)
path: applications/rook/cluster

# After (maintenance)
path: applications/rook/cluster/overlays/maintenance
```

Commit, push, sync `rook-cluster` in ArgoCD (or wait for auto-sync — but with `selfHeal: false`, a manual sync is cleaner here). Rook applies the new throttle values within seconds.

The PR is the maintenance ticket. The diff is the approval record.

---

## Returning to normal posture

Revert the path change — `git revert` or a follow-up commit. Push, sync. Done. The conservative values come back. No cleanup job, no hook to wait on, nothing left running.

```bash
# Quick manual revert if the PR can wait
argocd app set rook-cluster --repo-path applications/rook/cluster
argocd app sync rook-cluster
```

Or just push the revert commit and let ArgoCD pick it up on the next poll.

---

## Why not hooks?

ArgoCD PreSync/PostSync hooks can also run `ceph config set`. They're the right tool when you need a config change _coupled to another deployment event_ — e.g., loosen throttles before applying an OSD replacement, tighten them after. That's a workflow with sequencing logic, and Argo Workflows (not ArgoCD hooks) is the correct tool for that.

This posture approach is for the simpler case: you want the cluster in a known configuration, you want git to say what that configuration is, and you want the revert to be a single merge. No hooks, no timers, no "did the PostSync job actually finish?" anxiety. Just state.

---

## Directory layout

```
applications/rook/cluster/
  cephcluster.yaml               # base: conservative recovery throttles
  kustomization.yaml
  toolbox.yaml
  monitoring-rbac.yaml
  prometheus-rules.yaml
  overlays/
    maintenance/
      kustomization.yaml         # extends base, patches cephConfig
      cephconfig-patch.yaml      # maintenance throttle values
```
