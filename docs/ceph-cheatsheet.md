# Ceph Cheatsheet — ceph-lab

> Quick reference for Ceph, Rook, and ArgoCD commands in this lab.
> All `ceph` commands run inside the toolbox pod unless noted otherwise.

## Toolbox access

```bash
# From VM (alias)
rook-tools

# From Mac
kubectl exec -it -n rook-ceph deploy/rook-ceph-tools -- bash
```

---

## Cluster status

```bash
ceph status               # overall health + pools + pgs
ceph health detail        # verbose health warnings
ceph -w                   # watch live events
ceph df                   # cluster usage
ceph df detail            # pool-level usage
ceph osd df               # per-OSD usage
ceph osd stat             # OSD count + up/in
ceph mon stat             # monitor quorum
ceph pg stat              # placement group summary
ceph pg dump brief        # brief pg dump
```

---

## OSDs

```bash
ceph osd tree             # visual OSD hierarchy (hosts, weights)
ceph osd crush tree       # CRUSH map tree
ceph osd perf             # per-OSD latency + throughput
ceph osd pool ls detail   # all pools with replication/pg counts
ceph osd dump             # full OSD map dump
ceph osd find <id>        # which host holds OSD <id>

# Mark an OSD down/out (for maintenance)
ceph osd out <id>
ceph osd down <id>

# Bring an OSD back
ceph osd in <id>

# Remove an OSD entirely
ceph osd rm <id>
ceph osd crush remove osd.<id>
ceph auth del osd.<id>
```

---

## Pools

```bash
ceph osd pool ls detail
ceph osd pool stats <pool>
ceph osd pool get <pool> all           # pool parameters
ceph osd pool set <pool> size 3        # change replication size

# Placement group tuning
ceph osd pool get <pool> pg_num
ceph osd pool set <pool> pg_num 64
ceph osd pool set <pool> pgp_num 64

# Show pool quotas
ceph osd pool get-quota <pool>
```

---

## RBD (block storage)

```bash
rbd ls <pool>                          # list images
rbd info <pool>/<image>                # image details
rbd du <pool>                          # disk usage per image
rbd snap ls <pool>/<image>             # list snapshots
rbd snap create <pool>/<image>@<snap>  # create snapshot
rbd snap rm <pool>/<image>@<snap>      # remove snapshot
rbd snap purge <pool>/<image>          # remove all snapshots
rbd bench --io-type write <pool>/<image> --io-size 4M --io-total 1G
```

---

## CephFS (filesystem)

```bash
ceph fs ls                             # list filesystems
ceph fs status <fs-name>               # health, MDSes, pools
ceph mds stat                          # MDS daemons

# Check CephFS mounts (inside ceph-tools)
ceph fs top                            # live client/file stats
```

---

## RGW (object store / S3)

```bash
radosgw-admin user list
radosgw-admin user info --uid=<uid>
radosgw-admin user create --uid=test --display-name="Test User"
radosgw-admin bucket list
radosgw-admin bucket stats --bucket=<name>
radosgw-admin quota set --quota-scope=user --uid=<uid> --max-size=10G
```

---

## CRUSH map

```bash
ceph osd crush tree
ceph osd getcrushmap -o crush.bin
crushtool -d crush.bin -o crush.txt    # decompile
# Edit crush.txt, then:
crushtool -c crush.txt -o crush-new.bin
ceph osd setcrushmap -i crush-new.bin
```

---

## Authentication

```bash
ceph auth list
ceph auth get client.admin
ceph auth get-or-create client.<name> mon 'allow r' osd 'allow rw pool=<pool>'
ceph auth del client.<name>
```

---

## Monitoring + alerts

```bash
ceph log last 50          # last 50 cluster log entries
ceph log last 50 debug    # verbose
ceph crash ls             # crash dumps
ceph crash info <id>      # crash detail
ceph crash archive <id>   # dismiss crash
ceph crash archive-all    # dismiss all crashes

ceph balancer status      # pg balancer
ceph balancer on          # enable automatic balancer
ceph progress             # ongoing operations (backfill, recovery)
```

---

## Rook / kubectl

```bash
# Cluster CRD status
kubectl get cephcluster -n rook-ceph
kubectl describe cephcluster -n rook-ceph rook-ceph

# All Rook CRDs
kubectl get cephblockpool,cephfilesystem,cephobjectstore -n rook-ceph

# OSD pods
kubectl get pods -n rook-ceph -l app=rook-ceph-osd

# Restart toolbox
kubectl rollout restart deploy/rook-ceph-tools -n rook-ceph

# Force-delete a stuck pod
kubectl delete pod -n rook-ceph <pod> --force --grace-period=0

# Watch Rook operator logs
kubectl logs -n rook-ceph deploy/rook-ceph-operator -f

# Scrub a specific pool manually
kubectl exec -n rook-ceph deploy/rook-ceph-tools -- \
    ceph osd pool application enable replicapool rbd
```

---

## StorageClass quick test

```bash
# Create a PVC
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: rbd-test
spec:
  storageClassName: rook-ceph-block
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
EOF

# Verify bound
kubectl get pvc rbd-test

# Clean up
kubectl delete pvc rbd-test
```

---

## ArgoCD

```bash
# App overview
argo-apps                    # alias: kubectl get applications -n argocd

# Sync specific app
argocd app sync <name>

# Sync ALL apps
argocd app sync --all

# Watch sync status
argocd app wait <name> --sync --health

# Force hard refresh (ignore cache)
argocd app diff <name> --hard-refresh

# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' | base64 -d
```

---

## Cilium / Hubble

```bash
# Network policy flows
hubble-rook                  # hubble observe --namespace rook-ceph
hubble-drops                 # hubble observe --verdict DROPPED

# All L7 flows
hubble observe --protocol http

# Service map
hubble observe --output=json | jq .

# Cilium node status
cilium status
cilium connectivity test
```

---

## Common troubleshooting

| Symptom | Command |
|---|---|
| PGs stuck | `ceph pg repair <pgid>` |
| OSD down | `kubectl logs -n rook-ceph pod/rook-ceph-osd-<N>-...` |
| Full cluster | `ceph osd set nofull && ceph df` |
| MDS crash loop | `ceph mds fail <name>` then restart pod |
| CephFS mount fails | check `CephFilesystemSubVolumeGroup` exists |
| ArgoCD stuck OutOfSync | `argocd app diff <name> --hard-refresh` |
| Sealed secret not decrypting | check `kubeseal --controller-name` matches |
| Certificate not issued | `kubectl describe certificaterequest -n <ns>` |

---

## Useful links

- [Ceph Tentacle Release Notes](https://docs.ceph.com/en/tentacle/releases/tentacle/)
- [Rook Ceph Troubleshooting](https://rook.io/docs/rook/latest/Troubleshooting/ceph-common-issues/)
- [Ceph PG Calculator](https://old.ceph.com/pgcalc/)
- [Red Hat Ceph Storage 9 — Troubleshooting](https://access.redhat.com/documentation/en-us/red_hat_ceph_storage/9/html/troubleshooting_guide/)
