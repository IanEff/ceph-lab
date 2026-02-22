#!/bin/bash
# ceph-lab — dnsmasq_setup.sh
# Writes a dnsmasq fragment so *.ceph.lab resolves to the Cilium gateway IP.
# Runs on the macOS host (triggered by Vagrant after 'vagrant up').
set -euo pipefail

DOMAIN="${SANDBOX_DNS_DOMAIN:-ceph.lab}"
GATEWAY_IP="${SANDBOX_GATEWAY_LB_IP:-192.168.56.200}"

# Homebrew on Apple Silicon installs to /opt/homebrew; Intel uses /usr/local.
if [ -d /opt/homebrew/etc/dnsmasq.d ]; then
    DNSMASQ_DIR="/opt/homebrew/etc/dnsmasq.d"
elif [ -d /usr/local/etc/dnsmasq.d ]; then
    DNSMASQ_DIR="/usr/local/etc/dnsmasq.d"
else
    echo "[dnsmasq] dnsmasq.d directory not found."
    echo "  Install dnsmasq:  brew install dnsmasq"
    echo "  Then run:         sudo brew services start dnsmasq"
    exit 0
fi

CONF_FILE="${DNSMASQ_DIR}/ceph-lab.conf"
CONTENT="address=/.${DOMAIN}/${GATEWAY_IP}"

if [ -f "$CONF_FILE" ] && grep -qF "$GATEWAY_IP" "$CONF_FILE" 2>/dev/null; then
    echo "[dnsmasq] Config already present at ${CONF_FILE}; no change."
else
    echo "$CONTENT" > "${CONF_FILE}"
    echo "[dnsmasq] Wrote: ${CONF_FILE}"
    echo "  ${CONTENT}"
fi

# macOS resolver — routes *.ceph.lab queries to the local dnsmasq instance
RESOLVER_FILE="/etc/resolver/${DOMAIN}"
if [ ! -f "$RESOLVER_FILE" ]; then
    sudo mkdir -p /etc/resolver
    echo 'nameserver 127.0.0.1' | sudo tee "$RESOLVER_FILE" > /dev/null
    echo "[dnsmasq] Created resolver: ${RESOLVER_FILE}"
fi

sudo brew services restart dnsmasq 2>/dev/null || \
    sudo launchctl kickstart -k system/homebrew.mxcl.dnsmasq 2>/dev/null || \
    echo "  [dnsmasq] Remember to restart dnsmasq manually."

echo ""
echo "  *.${DOMAIN} → ${GATEWAY_IP}  (dnsmasq ready)"
