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

1. **Check `autoHealAttemptsCount`** — if it's climbing with phase "Succeeded", the diff is
   caused by something the API server changes on every apply, not a config error.

2. **Get the raw diff ArgoCD sees:**
   ```bash
   kubectl --context=<ctx> -n argocd get app <name> -o json | \
     python3 -c "import json,sys; a=json.load(sys.stdin); \
     [print(r['kind'],r['name'],r.get('status'),r.get('message','')) \
      for r in a['status']['resources'] if r.get('status')!='Synced']"
   ```

3. **Compare live vs manifest manually:**
   ```bash
   # What does the API server actually store?
   kubectl --context=<ctx> -n <ns> get <kind> <name> -o yaml
   # What would a server-side apply produce?
   kubectl --context=<ctx> diff --server-side --field-manager=argocd-controller -f manifest.yaml
   ```

4. **Fix the manifest, not ArgoCD's comparison settings** — adding `ignoreDifferences` to
   paper over normalisation drift creates invisible state divergence and makes debugging
   harder. The manifest should be the truth; make it match.
