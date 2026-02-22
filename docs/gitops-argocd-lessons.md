# GitOps / ArgoCD Lessons Learned

Hard-won lessons from standing up Rook/Ceph on k3s with Cilium Gateway API and ArgoCD.
Each section describes the symptom, root cause, and fix so future bringups are faster.

---

## 1. Rook Toolbox: `ceph.conf` empty and malformed keyring

### Symptom

```
mon host =                 # empty
[client.admin]AQ...==      # keyring key and section header concatenated
```

`ceph status` fails with auth errors from inside the toolbox pod.

### Root Cause

The toolbox startup script used `grep ^data` to parse the mon-endpoints ConfigMap, but the
ConfigMap value has no `data=` prefix — it's a raw CSV like `a=1.2.3.4:6789,b=1.2.3.5:6789`.

The keyring-writing step did:

```bash
cat /var/lib/rook/client.admin.keyring > /etc/ceph/keyring
echo "[client.admin]" >> /etc/ceph/keyring
cat /var/lib/rook/client.admin.keyring >> /etc/ceph/keyring
```

…which wrote the raw base64 blob directly, then appended the section header *after* it.

### Fix (`applications/rook/cluster/toolbox.yaml`)

```bash
# Parse mon endpoints correctly (file has no "data=" prefix)
MON_ENDPOINTS=$(cat /etc/rook/mon-endpoints | tr ',' '\n' | awk -F= '{print $2}' | paste -sd,)

# Write a properly-formatted INI keyring
printf '[client.admin]\n\tkey = %s\n' "${CEPH_SECRET}" > /etc/ceph/keyring
```

---

## 2. Ceph `HEALTH_WARN mon clock skew`

### Symptom

```
HEALTH_WARN: clock skew detected on mon.c
mon.c clock skew 56ms > max 50ms
```

(Can climb to 100ms+ on VirtualBox hosts under load.)

### Root Cause

VirtualBox VM clocks drift more than Ceph's default 50ms `mon_clock_drift_allowed` threshold.
Restarting `systemd-timesyncd` on the affected VM helps temporarily but drift returns.

### Fix: raise the threshold in `CephCluster`

Use the `cephConfig` field (Rook ≥ v1.15):

```yaml
# applications/rook/cluster/cephcluster.yaml
spec:
  cephConfig:
    mon:
      mon_clock_drift_allowed: "0.5"   # 500ms — comfortable for VirtualBox
```

**Do NOT use `configOverride`** — that field was removed from the CRD schema in Rook v1.17.
ArgoCD will report a `ComparisonError` with:

```
ValidationError(CephCluster.spec): unknown field "configOverride"
```

The correct field is `spec.cephConfig.<section>.<key>: "value"`.

---

## 3. Gateway API manifests permanently OutOfSync in ArgoCD

### Symptom

Apps containing `HTTPRoute`, `GRPCRoute`, or `Gateway` resources are always `OutOfSync`
even though the resources are `Healthy` and functioning correctly.
ArgoCD self-heal keeps running (`autoHealAttemptsCount` climbing) and always reports "Synced"
— then immediately flips back to OutOfSync.

### Root Cause

The Gateway API admission webhook **normalises resources on write** by injecting default
field values that are not present in the source manifests:

| Resource | Field injected |
|---|---|
| `HTTPRoute` / `GRPCRoute` `backendRefs[]` | `group: ""`, `kind: Service`, `weight: 1` |
| `HTTPRoute` rules | `matches: [{path: {type: PathPrefix, value: /}}]` |
| `Gateway` `tls.certificateRefs[]` | `group: ""`, `kind: Secret` |

ArgoCD's client-side diff compares the un-defaulted manifest from git against the
normalised live object, so it always sees a diff. Self-heal applies the manifest, the
webhook re-injects the defaults, and the cycle repeats forever.

### What does NOT work

- `ServerSideDiff=true` — ArgoCD then uses `kubectl apply --server-side --dry-run` for the
  diff, which also causes the tracking-id annotation (`argocd.argoproj.io/tracking-id`) to
  appear in the diff.
- `ignoreDifferences` on the tracking-id annotation — the annotation diff disappears but the
  field-injection diff remains.
- `RespectIgnoreDifferences=true` — only affects sync, not comparison.

### Fix: explicitly declare all API-defaulted fields in every manifest

Add the injected defaults to the source YAML so git matches what the API server stores.

**HTTPRoute / GRPCRoute backendRefs:**

```yaml
rules:
  - matches:                          # required on every rule
      - path:
          type: PathPrefix
          value: /
    backendRefs:
      - group: ""                     # required
        kind: Service                 # required
        name: my-service
        port: 80
        weight: 1                     # required
```

**GRPCRoute** (does not default `matches`, only backendRefs fields):

```yaml
rules:
  - backendRefs:
      - group: ""
        kind: Service
        name: my-service
        port: 80
        weight: 1
```

**Filter-only HTTPRoute rules** (no backendRefs, but `matches` is still injected):

```yaml
rules:
  - matches:
      - path:
          type: PathPrefix
          value: /
    filters:
      - type: RequestRedirect
        requestRedirect:
          scheme: https
          statusCode: 301
```

**Gateway `tls.certificateRefs`:**

```yaml
tls:
  mode: Terminate
  certificateRefs:
    - group: ""        # required
      kind: Secret     # required
      name: gateway-tls
```

Once all source manifests match the normalised form, ArgoCD client-side diff produces no
false positives and `ServerSideDiff` / `ignoreDifferences` hacks are unnecessary — keep
`syncOptions` lean:

```yaml
syncOptions:
  - CreateNamespace=true
  - ServerSideApply=true
```

### How to find the injected fields quickly

```bash
# Apply the manifest once, then diff to see exactly what was injected:
kubectl --context=<ctx> diff -f my-route.yaml
# or for what's already live:
kubectl --context=<ctx> -n <ns> get httproute <name> -o yaml | grep -A5 backendRefs
```

---

## 4. Rook CRD field names change between versions

| Rook version | Field for raw ceph.conf overrides |
|---|---|
| ≤ v1.14 | `spec.configOverride` (string) |
| ≥ v1.15 | `spec.cephConfig` (structured map) |

Always check the CRD schema for your installed version before writing `CephCluster` overrides.
ArgoCD's `ComparisonError` ("unknown field") is a reliable signal that you're using a
removed/renamed field.

---

## 5. VirtualBox SSH key gotcha

When `vagrant ssh-config` gives you `IdentityFile ~/.vagrant.d/insecure_private_key` but
connections get rejected, use the per-machine key instead:

```bash
ssh -o IdentitiesOnly=yes \
    -i .vagrant/machines/<name>/virtualbox/private_key \
    vagrant@127.0.0.1 -p <port>
```

The `deploy_ceph-lab` key is for k8s access, not SSH into the VMs (triggers "too many
authentication failures" when multiple keys are offered).

---

## General methodology for debugging persistent OutOfSync

This section is a step-by-step playbook. Work through the steps in order — each one
narrows down what kind of problem you're actually dealing with before you start changing
things.

---

### Step 0: Understand what "OutOfSync" actually means

ArgoCD continuously compares two things:

- **Desired state**: the YAML files in git (after Kustomize/Helm rendering)
- **Live state**: what `kubectl get <resource> -o yaml` returns from the cluster

If they don't match, the app is `OutOfSync`. The app can be `Healthy` (workloads running
fine) and `OutOfSync` simultaneously — health and sync are independent axes.

ArgoCD's automated self-heal responds to OutOfSync by reapplying the manifests. If the
cluster immediately goes OutOfSync again despite a successful apply, the diff is being
*produced by the cluster itself*, not by a missing change.

---

### Step 1: Confirm the self-heal loop

```bash
kubectl --context=<ctx> -n argocd get app <name> -o jsonpath='{.status.operationState}' \
  | python3 -m json.tool
```

Look for two things:

- `"phase": "Succeeded"` — the sync operation *succeeded* (so it's not a broken manifest)
- `"autoHealAttemptsCount": N` with N > 1 and climbing — ArgoCD keeps re-trying

If both are true, the resource is being normalised by the cluster on every apply. You are
not dealing with a misconfiguration; you are dealing with a defaulting/mutation issue.
Skip ahead to Step 4.

If `phase` is `"Failed"`, you have a genuine apply error — read `message` for details and
fix the manifest or RBAC before continuing.

---

### Step 2: Find exactly which resources are out of sync

ArgoCD tracks sync status per-resource. Get only the ones that aren't Synced:

```bash
kubectl --context=<ctx> -n argocd get app <name> -o json | python3 -c "
import json, sys
app = json.load(sys.stdin)
for r in app['status']['resources']:
    if r.get('status') != 'Synced':
        print(r.get('group','core'), r['kind'], r['namespace'], r['name'], '→', r.get('status'), r.get('message',''))
"
```

This tells you the exact resource type and name. Knowing whether it's an `HTTPRoute`, a
`Gateway`, a `Deployment`, a `CRD`, etc. tells you where to look next.

---

### Step 3: Get the raw diff

The most direct approach is to see what ArgoCD actually considers different. There are two
ways depending on your ArgoCD sync mode:

**Client-side diff (default):**

```bash
# See what kubectl would change if ArgoCD applied the manifest right now
kubectl --context=<ctx> diff -f <path-to-rendered-manifest.yaml>
```

**Server-side diff (if `ServerSideApply=true` is in syncOptions):**

```bash
# Simulate what the API server would produce, using ArgoCD's field manager
kubectl --context=<ctx> diff \
  --server-side \
  --field-manager=argocd-controller \
  -f <path-to-rendered-manifest.yaml>
```

The output is a standard unified diff. Lines prefixed `-` are in the live object but not
in your manifest; lines prefixed `+` are in your manifest but not live. Anything the API
server injects will show up as `-` lines (present live, absent in your file).

If `kubectl diff` shows nothing but ArgoCD still says OutOfSync, the diff is in metadata
ArgoCD tracks separately — check annotations (see Step 5).

---

### Step 4: Understand what the API server actually stores

Kubernetes admission webhooks can mutate resources on write — adding fields with default
values that you didn't specify. The resource stored in etcd differs from what you applied.
This is expected and correct behaviour; the problem is only that your source manifest
doesn't reflect it.

To see the canonical stored form:

```bash
kubectl --context=<ctx> -n <namespace> get <kind> <name> -o yaml
```

Compare this line-by-line against your source manifest. Fields present in the live object
but absent from your manifest are being defaulted by a webhook. Add them explicitly to your
source file — then git, your manifest, and the live object all agree, and the diff
disappears permanently.

Common examples in this repo:

| Webhook | Fields it injects |
|---|---|
| Gateway API | `backendRefs[*].group: ""`, `backendRefs[*].kind: Service`, `backendRefs[*].weight: 1` |
| Gateway API | `rules[*].matches: [{path: {type: PathPrefix, value: /}}]` on HTTPRoute |
| Gateway API | `tls.certificateRefs[*].group: ""`, `tls.certificateRefs[*].kind: Secret` on Gateway |

The fix is always the same: copy those fields into your source YAML. They are just
spelling out what the API would have assumed anyway — adding them is safe and idempotent.

---

### Step 5: Check for annotation-driven diffs

Some ArgoCD features cause it to write annotations onto live resources that are not in the
source manifest, which then appear as diffs:

- `argocd.argoproj.io/tracking-id` — added by ArgoCD to track resource ownership
- `kubectl.kubernetes.io/last-applied-configuration` — added by client-side apply

These are usually harmless in practice, but if they cause false OutOfSync signals you have
two options:

**Option A (preferred): switch to ServerSideApply** — this uses server-side apply which
doesn't write `last-applied-configuration`, and ArgoCD's tracking annotation is handled
differently. Add to `syncOptions`:

```yaml
syncOptions:
  - ServerSideApply=true
```

**Option B (last resort): `ignoreDifferences`** — suppresses the diff in ArgoCD's
comparison without fixing the underlying cause. Use only for fields you genuinely cannot
control (e.g. operator-managed status subresources):

```yaml
ignoreDifferences:
  - group: some.api.group
    kind: SomeKind
    jsonPointers:
      - /metadata/annotations/some-annotation
```

Avoid `ignoreDifferences` for anything in `spec` — it hides real divergence.

---

### Step 6: Check for operator-managed fields

Some controllers (Rook, cert-manager, the Gateway controller itself) write back into
`spec` fields after creation. For example, Rook's mon controller updates
`spec/mon/count` after initial placement. These fields will always differ from your source.

For these, `ignoreDifferences` with `jsonPointers` *is* the right tool — but scope it
tightly to the exact path. Also consider `prune: false` + `selfHeal: false` for resources
whose lifecycle is entirely owned by an operator (e.g. `CephCluster`).

Example from `rook-cluster.yaml`:

```yaml
ignoreDifferences:
  - group: ceph.rook.io
    kind: CephCluster
    jsonPointers:
      - /status
      - /spec/mon/count
```

---

### Step 7: Verify the fix holds across a resync

After updating manifests:

1. Commit and push to git.
2. Force a hard refresh so ArgoCD re-fetches from git immediately (rather than waiting for
   the poll interval):

   ```bash
   kubectl --context=<ctx> -n argocd patch app <name> \
     --type merge \
     -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
   ```

3. Wait ~30 seconds, then check:

   ```bash
   kubectl --context=<ctx> -n argocd get applications
   ```

4. If the app goes `Synced` and stays there through the next reconcile cycle (~3 minutes),
   the fix is solid. If it flips back to OutOfSync, return to Step 3 — there's another
   field being injected that you haven't captured yet.

---

### Decision tree summary

```
App is OutOfSync
│
├─ phase=Failed → fix the manifest / RBAC error shown in message
│
└─ phase=Succeeded, autoHealAttemptsCount climbing
   │
   ├─ kubectl diff shows a field diff
   │  ├─ Field is in spec → webhook is injecting defaults → add fields to manifest
   │  └─ Field is in metadata/annotations → consider ServerSideApply=true
   │
   └─ kubectl diff shows nothing
      └─ ArgoCD tracking annotation drift → ServerSideApply=true usually fixes it
         └─ If not → ignoreDifferences on that exact annotation path (last resort)
```
