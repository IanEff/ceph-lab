# Handoff: PR3 (P2) — Tracing & OTel Collector

Welcome to the `ceph-lab` workspace! Your predecessor just completed P0 (Sloth live verification) and P1 (Promtail + monolithic Loki on `rook-ceph-block` with 24h retention and strict resource limits) and raised PR #9. The cluster is currently running and healthy.

Your objective for this session is to implement **PR3 (P2)** from `ceph-lab-todo.md`.

## The Objective
1. **Deploy OTel Collector + Monolithic Tempo:**
   - Use a local PVC on `rook-ceph-block`.
   - Configure Tempo for an **in-memory ring** and **4h retention**.
   - Deploy as GitOps components in `applications/infrastructure/` (e.g., `tempo/` and `otel-collector/`). Include `config.json` and `kustomization.yaml` using Helm bases where possible.
2. **Enable RGW Tracing:**
   - Enable `rgw_tracing_enabled: true` on the `CephObjectStore` custom resource located in `applications/rook/storage/object-store.yaml`.
3. **Instrument the S3 Traffic Generator:**
   - Modify the `s3-traffic-generator` (located in `applications/infrastructure/s3-traffic-generator/manifests.yaml`).
   - Replace the existing `s5cmd` shell loop with a script (Python or Go) that generates S3 traffic *and* emits OTLP spans to the OTel collector.
   - **Important Constraint:** Extend the existing setup but *do not* replace the ObjectBucketClaim (OBC) or its wave slot, as ArgoCD depends on that sequence to provision the credentials correctly.

## Step-by-Step Instructions

1. **Verify State & Cut Branch**
   - Ensure you are on an up-to-date `main` branch.
   - Cut a new branch: `git checkout -b feat/p2-otel-tempo`

2. **Deploy Tempo**
   - Create `applications/infrastructure/tempo/config.json`.
   - Create `applications/infrastructure/tempo/kustomization.yaml`.
   - Use the `tempo` Helm chart in single-binary mode. 
   - Ensure the `persistence` block uses `storageClass: rook-ceph-block`.
   - Configure retention for 4h and an in-memory ring.

3. **Deploy OpenTelemetry Collector**
   - Create `applications/infrastructure/otel-collector/config.json`.
   - Create `applications/infrastructure/otel-collector/kustomization.yaml`.
   - Configure the OTel pipeline to receive traces (OTLP gRPC/HTTP) and export them to Tempo.

4. **Modify CephObjectStore**
   - Update `applications/rook/storage/object-store.yaml` to set `rgw_tracing_enabled: true` (or the equivalent spec block for your Rook version). Ensure you check the Rook CRD/documentation if you are unsure of the exact syntax.

5. **Update the Traffic Generator**
   - Review `applications/infrastructure/s3-traffic-generator/manifests.yaml`.
   - Replace the embedded shell script with an instrumented script. You might need to change the base image if you swap to a Python script that requires `boto3` and `opentelemetry-api`.

6. **Validate (Optional but Recommended)**
   - Sync the cluster (`make up` or ArgoCD manual sync) to test your additions locally. Verify that the OTel collector and Tempo pods enter the `Running` state without OOMing the nodes.

7. **Commit & Pull Request**
   - Stage and commit your changes with a descriptive message (e.g., `feat(observability): deploy Tempo and instrument S3 traffic`).
   - Push your branch: `git push -u origin feat/p2-otel-tempo`
   - Raise a Pull Request via GitHub CLI: `gh pr create --title "..." --body "..."`

Good luck, and remember to keep the footprint small!
