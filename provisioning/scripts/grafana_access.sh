#!/bin/bash
# ceph-lab — grafana_access.sh
# Port-forward Grafana to localhost:3000.
set -euo pipefail
echo "Grafana → http://localhost:3000  (admin / password)  (Ctrl+C to stop)"
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
