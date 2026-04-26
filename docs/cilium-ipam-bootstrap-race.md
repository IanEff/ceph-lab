# Cilium Cluster-Pool IPAM Bootstrap Race — Diagnosis & Fix

## Symptom

After `make up`, ArgoCD `ceph-lab-root` is permanently `Unknown`.
The app-controller logs:

```
Failed to cache app resources: dial tcp <redis-svc>:6379: i/o timeout
```

No wave applications ever sync. The cluster is useless until rebuilt.

---

## Root Cause

**Cilium cluster-pool IPAM race condition — affects both the DaemonSet agent and the operator Deployment.**

The Helm chart default for `cluster-pool-ipv4-cidr` is `10.0.0.0/8`.
Our desired value is `10.244.0.0/16` (matching k3s `--cluster-cidr` and
Cilium's `ipv4NativeRoutingCIDR`).

Both the Cilium agent (DaemonSet) and the operator (Deployment) read
`cluster-pool-ipv4-cidr` from a mounted ConfigMap volume at startup.
The kubelet's ConfigMap volume mount is eventually consistent — if the
process reads its config-dir before the mount is fully populated, it
falls back to the compiled-in default: **`10.0.0.0/8`**.

### Why the agent race is the critical one

The agent starts **before** the operator (observed delta: ~5 seconds). At startup it:

1. Reads config-dir → gets `10.0.0.0/8` (default; race lost)
2. Computes a `/24` for this node from that pool: `10.0.x.0/24`
3. Creates the CiliumNode object with `spec.ipam.podCIDRs: ["10.0.x.0/24"]`
4. Even logs a drift warning it can't act on:
   `Mismatch found key=cluster-pool-ipv4-cidr actual=10.0.0.0/8 expectedValue=10.244.0.0/16`

The operator starts ~5 seconds later. Even if the operator has the
correct CIDR (`10.244.0.0/16`), it rejects the pre-written CiliumNode spec:

```
operator-status: error: "allocator not configured for the requested CIDR 10.0.x.0/24"
```

The agent never gets a valid CIDR allocation from the operator, but it
already configured the node with `10.0.x.x` addresses. Pods land on
`10.0.x.x` IPs — outside `ipv4NativeRoutingCIDR: 10.244.0.0/16` —
so Cilium's BPF masquerades every cross-node pod packet (source IP →
node eth1 address). Return packets route to the node, not the pod.
Cross-node connections fail permanently.

### Evidence trail

| Observation | Value | Where |
|---|---|---|
| Agent config-dir at startup | `--cluster-pool-ipv4-cidr='10.0.0.0/8'` | agent log |
| Agent IPAM init | `v4Prefix=10.0.1.0/24` | agent log `Initializing IPAM` |
| CiliumNode spec | `podCIDRs: ["10.0.x.0/24"]` | `kubectl get ciliumnode -o yaml` |
| Operator rejection | `allocator not configured for requested CIDR 10.0.x.0/24` | CiliumNode `.status.ipam` |
| Operator own log | `ipv4CIDRs=[10.244.0.0/16]` | operator started correctly — too late |
| ArgoCD | `dial tcp ...:6379: i/o timeout` | app-controller log |
| ConfigMap (after mount settles) | `cluster-pool-ipv4-cidr: 10.244.0.0/16` | correct — read too late |

---

## Fix

Pin `--cluster-pool-ipv4-cidr=10.244.0.0/16` as an explicit CLI arg on
**both** the DaemonSet (agent) and the Deployment (operator) via kustomize
patches. CLI args win over config-dir; no race possible.

**File: `applications/infrastructure/cilium/kustomization.yaml`**

```yaml
patches:
  # Operator: pin cluster-pool CIDR as CLI arg to avoid ConfigMap mount race
  - target:
      kind: Deployment
      name: cilium-operator
    patch: |-
      - op: add
        path: /spec/template/spec/containers/0/args/-
        value: --cluster-pool-ipv4-cidr=10.244.0.0/16

  # Agent: same fix — agent pre-computes node pod CIDR before operator starts
  - target:
      kind: DaemonSet
      name: cilium
    patch: |-
      - op: add
        path: /spec/template/spec/containers/0/args/-
        value: --cluster-pool-ipv4-cidr=10.244.0.0/16
```

The operator patch was committed in `30d3127`. The DaemonSet patch is
the remaining fix.

Also required (committed in `443af47`):

- `applications/infrastructure/cilium/values.yaml`: set
  `ipam.operator.clusterPoolIPv4PodCIDRList: ["10.244.0.0/16"]` so the
  ConfigMap also carries the right value (eventual consistency catch-up).
- `cluster-bootstrap/argocd/kustomization.yaml`: delete-patch all ArgoCD
  `NetworkPolicy` objects (this cluster is wide-open; L4/L7 control lives
  at the Cilium Gateway).

---

## What Does NOT Need Changing

- `ipv4NativeRoutingCIDR: 10.244.0.0/16` in `valuesInline` — correct, keep.
- `devices: [enp+]` — Lima VMs use `eth0/eth1`; no `enp+` match means
  Cilium auto-detects all devices. Fine.
- `autoDirectNodeRoutes: true` — correct, drives cross-node route installation.
- k3s `cluster-cidr: 10.244.0.0/16` — already correct.
- Do NOT set `ipv4NativeRoutingCIDR: 10.0.0.0/8` — this breaks Cilium's
  direct-routing device auto-detection (routes for `10.0.x.x` exist on
  both `cilium_host` and `eth1`, causing ambiguity).

---

## Verification After `make destroy-force && make up`

```bash
# Pod IPs must be 10.244.x.x
kubectl get pods -n argocd -o wide

# Operator must have accepted the CiliumNode allocations (no error)
kubectl get ciliumnodes -o yaml | grep -A5 'operator-status'

# ArgoCD must transition Unknown → Synced
kubectl get applications -n argocd -w
```
