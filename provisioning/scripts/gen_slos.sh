#!/usr/bin/env bash
# ceph-lab — gen_slos.sh
#
# Renders Sloth's PrometheusServiceLevel CRs into plain Prometheus rule
# groups and splices them into applications/infrastructure/prometheus/
# values.yaml's serverFiles block. The standalone community `prometheus`
# chart used in this lab reads NO PrometheusRule CRs (no controller watches
# monitoring.coreos.com/v1 here) — Sloth's runtime Deployment generates
# correct PrometheusRules, but Prometheus never sees them. Rendering the
# CRs to plain rule groups at commit time (this script) and embedding them
# in the same ConfigMap Prometheus already loads (`rule_files:` in
# serverFiles.prometheus.yml already points at these two paths) is the fix.
#
# Run this after editing applications/infrastructure/sloth/prometheusservicelevels.yaml,
# then commit the diff. CI (see .github/workflows/slo-drift.yml) fails the
# build if this script's output would differ from what's committed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SLO_SPEC="$REPO_ROOT/applications/infrastructure/sloth/prometheusservicelevels.yaml"
VALUES_FILE="$REPO_ROOT/applications/infrastructure/prometheus/values.yaml"

command -v sloth >/dev/null 2>&1 || { echo "gen_slos.sh: 'sloth' CLI required (brew install sloth-cli)" >&2; exit 1; }
command -v yq >/dev/null 2>&1 || { echo "gen_slos.sh: 'yq' CLI required (brew install yq)" >&2; exit 1; }

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

sloth generate -i "$SLO_SPEC" --disable-alerts --no-color -o "$tmpdir/recording.k8s.yaml"
sloth generate -i "$SLO_SPEC" --disable-recordings --no-color -o "$tmpdir/alerting.k8s.yaml"

# Sloth emits one PrometheusRule (k8s-wrapped) document per SLO. Prometheus's
# plain rule_files format wants a single top-level `groups:` list — merge
# every SLO's .spec.groups into one list, in source order.
yq eval-all '[.spec.groups[]] as $g ireduce ([]; . + $g) | {"groups": .}' \
    "$tmpdir/recording.k8s.yaml" > "$tmpdir/recording_rules.yml"
yq eval-all '[.spec.groups[]] as $g ireduce ([]; . + $g) | {"groups": .}' \
    "$tmpdir/alerting.k8s.yaml" > "$tmpdir/alerting_rules.yml"

# Re-indent to nest as serverFiles.recording_rules.yml / .alerting_rules.yml
# siblings of serverFiles.prometheus.yml (2-space indent already used there).
{
    echo "  # Source: applications/infrastructure/sloth/prometheusservicelevels.yaml"
    echo "  # DO NOT EDIT BY HAND — run \`just gen-slos\` after changing the source spec."
    echo "  recording_rules.yml:"
    sed 's/^/    /' "$tmpdir/recording_rules.yml"
} > "$tmpdir/recording_block.yml"
{
    echo "  # Source: applications/infrastructure/sloth/prometheusservicelevels.yaml"
    echo "  # DO NOT EDIT BY HAND — run \`just gen-slos\` after changing the source spec."
    echo "  alerting_rules.yml:"
    sed 's/^/    /' "$tmpdir/alerting_rules.yml"
} > "$tmpdir/alerting_block.yml"

splice_block() {
    local begin_marker="$1" end_marker="$2" block_file="$3"
    awk -v begin="$begin_marker" -v end="$end_marker" -v blockfile="$block_file" '
        $0 == begin { print; while ((getline line < blockfile) > 0) print line; skipping = 1; next }
        $0 == end   { skipping = 0; print; next }
        skipping    { next }
        { print }
    ' "$VALUES_FILE" > "$VALUES_FILE.tmp"
    mv "$VALUES_FILE.tmp" "$VALUES_FILE"
}

splice_block \
    "  # --- BEGIN sloth-generated recording rules (regenerate: just gen-slos) ---" \
    "  # --- END sloth-generated recording rules ---" \
    "$tmpdir/recording_block.yml"

splice_block \
    "  # --- BEGIN sloth-generated alerting rules (regenerate: just gen-slos) ---" \
    "  # --- END sloth-generated alerting rules ---" \
    "$tmpdir/alerting_block.yml"

echo "gen_slos.sh: regenerated recording_rules.yml / alerting_rules.yml in $VALUES_FILE"
