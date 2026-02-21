#!/bin/bash
# ceph-lab — hubble_ui.sh
# Port-forward Hubble UI to localhost:12000.
set -euo pipefail
echo "Hubble UI → http://localhost:12000  (Ctrl+C to stop)"
kubectl port-forward -n kube-system service/hubble-ui 12000:80
