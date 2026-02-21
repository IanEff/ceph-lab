#!/bin/bash
# ceph-lab — dnsmasq_teardown.sh
# Removes the ceph.lab dnsmasq config (called by 'vagrant destroy').
set -euo pipefail

CONF_FILE="/etc/dnsmasq.d/ceph-lab.conf"

if [ -f "$CONF_FILE" ]; then
    sudo rm -f "$CONF_FILE"
    echo "[dnsmasq] Removed ${CONF_FILE}"
    sudo brew services restart dnsmasq 2>/dev/null || true
fi
