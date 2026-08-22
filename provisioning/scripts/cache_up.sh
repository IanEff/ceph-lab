#!/usr/bin/env bash
# ceph-lab — cache_up.sh
# Start the local apt-cacher-ng + OCI registry mirror containers on the Mac.
# Best-effort: common.sh's guest-side probe falls through silently to public
# registries if this isn't running, so failures here are non-fatal.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/../cache/docker-compose.yaml"

if ! command -v docker >/dev/null 2>&1; then
    echo "[cache] docker not found on PATH; skipping pull-through cache." >&2
    exit 0
fi

if ! docker info >/dev/null 2>&1; then
    echo "[cache] docker daemon not reachable; skipping pull-through cache." >&2
    exit 0
fi

echo "[cache] Starting apt-cacher-ng + registry mirrors..."
if docker compose -f "$COMPOSE_FILE" up -d; then
    echo "[cache] Pull-through cache is up (3142 apt, 5001-5004 registry mirrors)."
else
    echo "[cache] Failed to start pull-through cache; continuing without it." >&2
fi
