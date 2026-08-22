#!/usr/bin/env bash
# ceph-lab — cache_down.sh
# Stop the local apt-cacher-ng + OCI registry mirror containers. Cached data
# is preserved in named docker volumes (removed only via `docker compose
# down -v` run manually, never automatically).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/../cache/docker-compose.yaml"

if ! command -v docker >/dev/null 2>&1; then
    echo "[cache] docker not found on PATH; nothing to stop."
    exit 0
fi

docker compose -f "$COMPOSE_FILE" down
