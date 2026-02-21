#!/bin/bash
# ceph-lab — ceph_dashboard_access.sh
# Port-forward the Ceph Dashboard to localhost:7000.
# Use when *.ceph.lab DNS is not configured.
set -euo pipefail

NAMESPACE="rook-ceph"
LOCAL_PORT=7000

PASS=$(kubectl -n "$NAMESPACE" get secret rook-ceph-dashboard-password \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null \
    || echo "(secret not yet available)")

echo ""
echo "Ceph Dashboard — port-forward"
echo "  URL:      http://localhost:${LOCAL_PORT}"
echo "  Username: admin"
echo "  Password: ${PASS}"
echo ""
echo "Press Ctrl+C to stop."
echo ""
kubectl port-forward -n "$NAMESPACE" svc/rook-ceph-mgr-dashboard "${LOCAL_PORT}:7000"
