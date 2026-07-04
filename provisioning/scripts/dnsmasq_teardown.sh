#!/bin/bash
# ceph-lab — dnsmasq_teardown.sh
# Removes the ceph-lab dnsmasq config and resolver file.
set -euo pipefail

DOMAIN="${SANDBOX_DNS_DOMAIN:-ceph.lab}"

if [ -d /opt/homebrew/etc/dnsmasq.d ]; then
    DNSMASQ_DIR="/opt/homebrew/etc/dnsmasq.d"
elif [ -d /usr/local/etc/dnsmasq.d ]; then
    DNSMASQ_DIR="/usr/local/etc/dnsmasq.d"
else
    DNSMASQ_DIR=""
fi

if [ -n "$DNSMASQ_DIR" ]; then
    CONF_FILE="${DNSMASQ_DIR}/ceph-lab.conf"
    if [ -f "$CONF_FILE" ]; then
        sudo rm -f "$CONF_FILE"
        echo "[dnsmasq] Removed ${CONF_FILE}"
    fi
fi

RESOLVER_FILE="/etc/resolver/${DOMAIN}"
if [ -f "$RESOLVER_FILE" ]; then
    sudo rm -f "$RESOLVER_FILE"
    echo "[dnsmasq] Removed resolver: ${RESOLVER_FILE}"
fi

# Restart dnsmasq and flush DNS cache
sudo brew services restart dnsmasq 2>/dev/null || \
    sudo launchctl kickstart -k system/homebrew.mxcl.dnsmasq 2>/dev/null || true

sudo dscacheutil -flushcache 2>/dev/null || true
sudo killall -HUP mDNSResponder 2>/dev/null || true
