# Operations Log

## [2026-07-03] - Deploy Tempo & OTel Collector, Enable Tracing

### Action
- Cut branch `feat/p2-otel-tempo`.
- Created Tempo deployment manifests under `applications/infrastructure/tempo/`.
- Created OpenTelemetry Collector deployment manifests under `applications/infrastructure/otel-collector/`.
- Updated `applications/rook/storage/object-store.yaml` to enable Jaeger tracing (`jaeger_tracing_enable` and `jaeger_agent_port`).
- Configured Tempo datasource in Grafana (`applications/infrastructure/grafana/values.yaml`).
- Rewrote the S3 traffic generator to use Python with OpenTelemetry auto-instrumentation (`applications/infrastructure/s3-traffic-generator/manifests.yaml`).
- Created new network policy `cnp-tracing.yaml` and updated existing client and rook-ceph network policies to allow tracing traffic and world egress.

## [2026-07-03] - Fix ceph-rgw-availability SLO rule job filter

### Action
- Identified that `ceph-rgw-availability` SLO rules were querying `job="rook-ceph-mgr"` but the metrics are exported under `job="rook-ceph-exporter"`.
- Removed the incorrect `{job="rook-ceph-mgr"}` filter in `applications/infrastructure/sloth/prometheusservicelevels.yaml`.
- Regenerated Prometheus rules via `just gen-slos`.
