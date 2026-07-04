# Operations Log

## [2026-07-04] - Configure Passwordless Sudo (Opt-in)

### Action
- Added `just setup-sudoers` and `make setup-sudoers` recipes to `justfile` and `Makefile`.
- Created helper script `provisioning/scripts/setup_host_sudoers.sh` to dynamically configure `/etc/sudoers.d/ceph-lab`.
- Updated `provisioning/lima-setup.sh` to display instructions about `setup-sudoers` at completion.
- Updated `README.md` to document the optional `make setup-sudoers` step in the Quick start.
- Rewrote `provisioning/scripts/dnsmasq_teardown.sh` to search for dnsmasq configuration directories dynamically and properly remove the `/etc/resolver/ceph.lab` resolver file.

## [2026-07-03] - PR1.6: SLO Integrity Fixes

### Action
- Cut branch `fix/slo-integrity-pr1.6`.
- Modified `applications/infrastructure/sloth/prometheusservicelevels.yaml`:
  - Aligned OSD write latency SLO to query `job="ceph-latency-bridge"` and use `le="102.399999"` (since the exporter divides raw nanosecond values by `1e6`, making values millisecond-based).
  - Wrapped `ceph-health` raw SLI query in `max()` to aggregate away multiple series resulting from double-scraped MGR target.
- Updated `applications/rook/dashboards/prototype-observability.json` to use `le="102.399999"` bucket and filter to `job="ceph-latency-bridge"` for OSD latency panels.
- Regenerated Prometheus rules by running `just gen-slos` which rendered rule groups inside `applications/infrastructure/prometheus/values.yaml`.
- Updated `CLAUDE.md` and `GEMINI.md` gotchas to document both the millisecond-based OSD latency bucket configuration and the requirement for Sloth SLIs to aggregate to singleton series.

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
- Amended PR1.6 to drop explicit duplicate jobs `rook-ceph-mgr` and `rook-ceph-exporter` in Prometheus values since the `kubernetes-pods` annotation path covers them.
