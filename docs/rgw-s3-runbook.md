# RGW S3 runbook — ceph-lab

GitOps-first walkthrough for standing up object storage, wiring external S3 access, and creating buckets via OBC.

---

## Prerequisites

- ArgoCD waves 20–30 complete (`rook-ceph-operator`, `CephCluster` healthy)
- `ceph status` reports `HEALTH_OK`
- DNS: `*.ceph.lab` → `192.168.56.200` via dnsmasq
- The `rook-ceph-tools` toolbox pod is deployed at **wave 30** (alongside rook-storage, not rook-cluster) — run `kubectl exec -it -n rook-ceph deploy/rook-ceph-tools -- ceph status` to verify

---

## Wave 30 — object store

> **Ref:** [CephObjectStore CRD](https://rook.io/docs/rook/latest/CRDs/Object-Store/ceph-object-store-crd/) · [Object storage setup](https://rook.io/docs/rook/latest/Storage-Configuration/Object-Storage-RGW/object-storage/)

### `applications/rook/storage/object-store.yaml`

```yaml
apiVersion: ceph.rook.io/v1
kind: CephObjectStore
metadata:
  name: ceph-objectstore
  namespace: rook-ceph
spec:
  metadataPool:
    failureDomain: host
    replicated:
      size: 3
      requireSafeReplicaSize: true
  dataPool:
    failureDomain: host
    replicated:
      size: 3
      requireSafeReplicaSize: true
    parameters:
      bulk: "true"   # hint for large sequential I/O; not an EC directive
  preservePoolsOnDelete: true
  gateway:
    port: 80
    instances: 1
    priorityClassName: system-cluster-critical
    resources:
      requests:
        cpu: "100m"
        memory: "256Mi"
      limits:
        cpu: "1000m"
        memory: "512Mi"
  healthCheck:
    startupProbe:
      disabled: false
    readinessProbe:
      disabled: false
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: rook-ceph-bucket
provisioner: rook-ceph.ceph.rook.io/bucket
reclaimPolicy: Delete   # change to Retain if bucket data must survive OBC deletion
parameters:
  objectStoreName: ceph-objectstore
  objectStoreNamespace: rook-ceph
```

**What Rook does on reconcile:** creates the underlying RADOS pools (`.rgw.buckets.index`, `.rgw.buckets.data`, etc.), starts an RGW pod, and creates a ClusterIP Service named `rook-ceph-rgw-ceph-objectstore` on port 80.

Verify:

```bash
kubectl get svc -n rook-ceph | grep rgw
kubectl exec -it -n rook-ceph deploy/rook-ceph-tools -- ceph status
# expect osd pool stats showing .rgw.* pools
```

---

## Wave 30 — shared-pool object store (`ceph-shared-objectstore`)

> **Ref:** [Shared Pools CRD](https://rook.io/docs/rook/latest/CRDs/Object-Store/ceph-object-store-crd/#shared-pools)

This pattern separates pool lifecycle from the object store. Pools are declared as standalone `CephBlockPool` resources and referenced by name — letting you use an erasure-coded data pool without Rook creating it inline.

### `applications/rook/storage/object-shared-pools.yaml`

Three pools underpin this store:

| Pool | Type | Purpose |
|---|---|---|
| `rgw-meta-pool` | Replicated 3× | Bucket/object metadata, low-latency reads |
| `rgw-data-pool` | Erasure Coded 2+1 | Bulk object data, space-efficient |
| `rgw-nonec-pool` | Replicated 3× | Reserved for non-EC-capable objects |

### `applications/rook/storage/object-store-shared.yaml`

```yaml
apiVersion: ceph.rook.io/v1
kind: CephObjectStore
metadata:
  name: ceph-shared-objectstore
  namespace: rook-ceph
spec:
  sharedPools:
    metadataPoolName: rgw-meta-pool
    dataPoolName: rgw-data-pool
    preserveRadosNamespaceDataOnDelete: true
  gateway:
    port: 80
    instances: 1
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: rook-ceph-communal-bucket
provisioner: rook-ceph.ceph.rook.io/bucket
reclaimPolicy: Delete
parameters:
  objectStoreName: ceph-shared-objectstore
  objectStoreNamespace: rook-ceph
```

RGW service: `rook-ceph-rgw-ceph-shared-objectstore` in namespace `rook-ceph`.

> **CRD gotcha — `dataNonECPoolName` does not exist.** `spec.sharedPools` in the installed Rook version only accepts `metadataPoolName`, `dataPoolName`, `poolPlacements`, and `preserveRadosNamespaceDataOnDelete`. Specifying `dataNonECPoolName` causes ArgoCD server-side apply to fail with: `dataNonECPoolName: field not declared in schema`.

> **Cilium transient EPERM on first RGW start:** When a new `CephObjectStore`'s RGW pod first comes up, Cilium may not yet have propagated endpoint identity for it. The Rook operator's probe to the admin API (`http://rook-ceph-rgw-ceph-shared-objectstore.rook-ceph.svc:80/admin/user`) will transiently get `connect: operation not permitted`. OBC provisioning will succeed on the next retry (~2 min). No action required.

Verify both stores are Ready:

```bash
kubectl get cephobjectstore -n rook-ceph
# NAME                      PHASE
# ceph-objectstore          Ready
# ceph-shared-objectstore   Ready

kubectl get svc -n rook-ceph | grep rgw
# rook-ceph-rgw-ceph-objectstore         ClusterIP  ...  80/TCP
# rook-ceph-rgw-ceph-shared-objectstore  ClusterIP  ...  80/TCP
```

---

## Wave 35 — expose RGW externally

> **Ref:** [Expose Object Store](https://rook.io/docs/rook/latest/Storage-Configuration/Object-Storage-RGW/object-storage/#create-the-object-store)

### `applications/rook/gateway/httproute-s3.yaml`

This file already exists in the repo. Copy of canonical content for reference:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ceph-s3
  namespace: rook-ceph
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: cilium-gateway
      namespace: kube-system      # Gateway lives in kube-system, not rook-ceph
      sectionName: https          # TLS-terminating listener; backend is cleartext HTTP
  hostnames:
    - s3.ceph.lab
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - group: ""
          kind: Service
          name: rook-ceph-rgw-ceph-objectstore
          port: 80
          weight: 1
```

> **Important:** All Gateway API-defaulted fields (`group`, `kind`, `weight`, `matches`) must be present verbatim. The admission webhook injects them and ArgoCD will loop OutOfSync forever if they are omitted. See `docs/gitops-argocd-lessons.md` §3.

Verify DNS and connectivity from your Mac:

```bash
curl -v https://s3.ceph.lab/
# expect an empty ListAllMyBuckets XML response or 403 — either means RGW is reachable
# If you hit a TLS error, run: bash provisioning/scripts/trust_ca.sh
```

---

## Wave 30 — admin user for external access

> **Ref:** [CephObjectStoreUser CRD](https://rook.io/docs/rook/latest/CRDs/Object-Store/ceph-object-store-user-crd/)

OBCs create per-bucket subusers scoped to that bucket — not useful for external CLI work. Create a named user instead.

### `applications/rook/storage/objectstore-user.yaml`

> **Note:** This file does not yet exist in the repo. Create it and add it to `applications/rook/storage/kustomization.yaml`.

```yaml
apiVersion: ceph.rook.io/v1
kind: CephObjectStoreUser
metadata:
  name: s3-admin
  namespace: rook-ceph
spec:
  store: ceph-objectstore
  displayName: "s3-admin"
  capabilities:
    user: "*"
    bucket: "*"
```

Rook creates `rook-ceph-object-user-ceph-objectstore-s3-admin` in `rook-ceph`.

Extract credentials:

```bash
kubectl -n rook-ceph get secret \
  rook-ceph-object-user-ceph-objectstore-s3-admin \
  -o go-template='ACCESS: {{index .data "AccessKey" | base64decode}}
SECRET: {{index .data "SecretKey" | base64decode}}'
```

---

## s5cmd setup (Mac)

Install:

```bash
brew install s5cmd
```

Wire credentials:

```ini
# ~/.aws/credentials
[ceph-lab]
aws_access_key_id     = <AccessKey>
aws_secret_access_key = <SecretKey>
```

Shell alias (fish or bash):

```bash
# add to config.fish / .bashrc
set -x S3_ENDPOINT_URL "https://s3.ceph.lab"
alias s5="s5cmd --credentials-file ~/.aws/credentials --profile ceph-lab"
```

> TLS is terminated at the Cilium Gateway. If you haven't trusted the lab CA yet, run `bash provisioning/scripts/trust_ca.sh` first, or append `--no-verify-ssl` to s5cmd calls.

Smoke test:

```bash
s5 ls                                   # list buckets
s5 mb s3://test-busket                  # create bucket
s5 cp /etc/hosts s3://test-busket/
s5 ls s3://test-busket/
s5 cat s3://test-busket/hosts.txt
s5 rb s3://test-busket               # remove bucket (must be empty)
```

---

## GitOps bucket creation via OBC

> **Ref:** [Object Bucket Claim](https://rook.io/docs/rook/latest/Storage-Configuration/Object-Storage-RGW/object-bucket-claim/)

For buckets that belong to workloads living inside the cluster, the GitOps path is an `ObjectBucketClaim`. The provisioner creates the bucket and drops connection info into the same namespace.

### `applications/rook/storage/<appname>-obc.yaml`

Two `spec` variants — use whichever fits your workload:

```yaml
# Fixed bucket name (predictable, but fails if the name already exists)
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: my-bucket
  namespace: my-app          # must match consuming pod's namespace
spec:
  bucketName: my-bucket      # exact S3 bucket name
  storageClassName: rook-ceph-bucket
```

```yaml
# Generated bucket name (safe for re-deploy; actual name read from ConfigMap BUCKET_NAME)
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: my-bucket
  namespace: my-app
spec:
  generateBucketName: my-bucket  # prefix; Rook appends a random suffix
  storageClassName: rook-ceph-bucket
```

The existing `applications/rook/storage/warp-obc.yaml` uses `generateBucketName` against `storageClassName: rook-ceph-bucket` (the dedicated-pool store).

`applications/rook/storage/demo-buckets.yaml` defines three pipeline-stage OBCs against the shared-pool store:

```yaml
# ceph-bucket-raw       → generateBucketName: ceph-bkt-raw
# ceph-bucket-inflight  → generateBucketName: ceph-bkt-inflight
# ceph-bucket-processed → generateBucketName: ceph-bkt-processed
# all use storageClassName: rook-ceph-communal-bucket
```

Use these as templates for workloads that should share the EC data pool.

After reconcile, in `my-app` namespace:

| Resource | Key fields |
|---|---|
| ConfigMap `my-bucket` | `BUCKET_HOST`, `BUCKET_PORT`, `BUCKET_NAME` |
| Secret `my-bucket` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |

Watch reconciliation:

```bash
kubectl get objectbucketclaims -A -w
kubectl get objectbuckets -w          # cluster-scoped, one per OBC
```

**Note on `reclaimPolicy`:** `Delete` on the StorageClass means deleting the OBC deletes the bucket and all its data. If that's not what you want, create a second StorageClass with `reclaimPolicy: Retain` and reference it instead.

---

## Hubble observation

From inside `ceph-control` (or via `kubectl exec`):

```bash
# All RGW traffic
hubble observe --namespace rook-ceph --follow

# Filter to HTTP port
hubble observe --namespace rook-ceph --port 80 --follow

# Anything being dropped (CiliumNetworkPolicy hits)
hubble observe --verdict DROPPED
```

The existing `hubble-rook` and `hubble-drops` shell aliases cover the common cases.

---

## Wiring summary

```
CephObjectStore  ←─── StorageClass (provisioner + objectStoreName)
       │                      │
       │              ObjectBucketClaim (per-workload bucket)
       │                      │
       │              ConfigMap + Secret (same ns as OBC)
       │
       └── CephObjectStoreUser  →  Secret (AccessKey/SecretKey)
                                        │
                               s5cmd / aws-cli (external)
```

Two RGW endpoints, two StorageClasses, two auth paths:

```
ceph-objectstore (dedicated pools)       ceph-shared-objectstore (shared pools)
       │                                              │
StorageClass: rook-ceph-bucket          StorageClass: rook-ceph-communal-bucket
       │                                              │
   warp-bucket OBC                  ceph-bucket-raw / -inflight / -processed OBCs
       │                                              │
   ConfigMap + Secret                           ConfigMap + Secret
   (same ns as OBC)                             (same ns as OBC)

Both stores:
  └── CephObjectStoreUser → Secret (AccessKey/SecretKey) → s5cmd / aws-cli (external)
```

OBC path = per-bucket subuser, credentials live with the workload. `CephObjectStoreUser` path = named user, credentials extracted manually, used for external/admin CLI access.
