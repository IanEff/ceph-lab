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
