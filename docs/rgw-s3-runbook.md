# RGW S3 runbook — ceph-lab

GitOps-first walkthrough for standing up object storage, wiring external S3 access, and creating buckets via OBC.

---

## Prerequisites

- ArgoCD waves 20–30 complete (`rook-ceph-operator`, `CephCluster` healthy)
- `ceph status` reports `HEALTH_OK`
- DNS: `*.ceph.lab` → `192.168.56.200` via dnsmasq

---

## Wave 30 — object store

### `gitops/rook/storage/object-store.yaml`

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

## Wave 31 — expose RGW externally

### `gitops/rook/gateway/rgw-httproute.yaml`

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: rgw-s3
  namespace: rook-ceph
spec:
  parentRefs:
    - name: cilium-gateway        # adjust to your actual Gateway name
      namespace: rook-ceph
  hostnames:
    - s3.ceph.lab
  rules:
    - backendRefs:
        - name: rook-ceph-rgw-ceph-objectstore
          port: 80
```

Verify DNS and connectivity from your Mac:

```bash
curl -v http://s3.ceph.lab/
# expect an empty ListAllMyBuckets XML response or 403 — either means RGW is reachable
```

---

## Wave 31 — admin user for external access

OBCs create per-bucket subusers scoped to that bucket — not useful for external CLI work. Create a named user instead.

### `gitops/rook/storage/objectstore-user.yaml`

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
set -x S3_ENDPOINT_URL "http://s3.ceph.lab"
alias s5="s5cmd --credentials-file ~/.aws/credentials --profile ceph-lab"
```

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

For buckets that belong to workloads living inside the cluster, the GitOps path is an `ObjectBucketClaim`. The provisioner creates the bucket and drops connection info into the same namespace.

### `gitops/apps/<appname>/bucket.yaml`

```yaml
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: my-bucket
  namespace: my-app          # must match consuming pod's namespace
spec:
  bucketName: my-bucket      # actual S3 bucket name
  storageClassName: rook-ceph-bucket
```

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

Two auth paths, one store. OBC path = per-bucket subuser, credentials live with the workload. CephObjectStoreUser path = named user, credentials extracted manually, used for external/admin access.
