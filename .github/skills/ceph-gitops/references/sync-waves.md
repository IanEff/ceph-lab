# ArgoCD Sync Waves — ceph-lab

## Wave Ordering

| Wave | Component | Prune | SelfHeal | Reason |
|---|---|---|---|---|
| -15 | `gateway-api` | true | true | Gateway API CRDs must exist before Cilium starts |
| -10 | `cilium` | true | true | Needs Gateway CRDs; creates `cilium` GatewayClass |
| -5 | `cert-manager`, `kube-prometheus-stack`, `loki`, `tempo` | true | true | Observability backbone; cert-manager issues certs for everything |
| 0 | `alloy`, `sealed-secrets`, `metrics-server` | true | true | Depend on CRDs from wave -5 |
| 1 | `l7-policies` | true | true | CiliumNetworkPolicies — Cilium must already be running |
| 10 | `argocd-ingress` | true | true | HTTPRoutes for ArgoCD UI — needs gateway + cert-manager |
| 20 | `rook-operator` | **false** | true | Never auto-delete operator; CRDs must precede cluster CR |
| 25 | `rook-cluster` | **false** | **false** | Operator mutates CephCluster; `ignoreDifferences` on `/status` and `/spec/mon/count` |
| 30 | `rook-storage` | true | true | Block/CephFS/RGW pools — safe to recreate |
| 35 | `rook-gateway` | true | true | HTTPRoutes for Ceph Dashboard — needs rook-cluster + gateway |

## Choosing a Wave for a New Component

1. **Does it provide CRDs others depend on?** → Use a low negative wave (e.g., `-15`).
2. **Does it depend on Cilium's GatewayClass?** → Must be ≥ `-9`.
3. **Does it depend on cert-manager?** → Must be ≥ `-4`.
4. **Does it depend on CiliumNetworkPolicies?** → Must be ≥ `2`.
5. **Does it depend on ArgoCD HTTPRoutes?** → Must be ≥ `11`.
6. **Is it Rook-related?** → Follow the existing 20/25/30/35 pattern; don't insert between them.
7. **General-purpose infra with no special deps?** → `0` or `5`.

## Prune / SelfHeal Defaults

For new infra components, use:
```json
"prune": true,
"selfHeal": true
```

Only set `prune: false` for operators whose deletion would orphan CRDs or custom resources in the cluster (e.g., Rook). Only set `selfHeal: false` when an operator mutates the CR and ArgoCD would fight it in a loop.

## How Waves Are Applied

The `infra-set.yaml` `ApplicationSet` injects the `syncWave` annotation from `config.json` into each generated `Application`:
```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "{{syncWave}}"
```

For standalone Rook `Application` CRs (`rook-*.yaml`), the wave annotation is set directly in the file.
