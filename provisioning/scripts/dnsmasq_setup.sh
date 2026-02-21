#!/bin/bash
# ceph-lab — dnsmasq_setup.sh
# Writes a dnsmasq fragment so *.ceph.lab resolves to the Cilium gateway IP.
# Runs on the macOS host (triggered by Vagrant after 'vagrant up').
set -euo pipefail

DOMAIN="${SANDBOX_DNS_DOMAIN:-ceph.lab}"
GATEWAY_IP="${SANDBOX_GATEWAY_LB_IP:-192.168.56.200}"
CONF_FILE="/etc/dnsmasq.d/ceph-lab.conf"

CONTENT="address=/.${DOMAIN}/${GATEWAY_IP}"

if [ ! -d /etc/dnsmasq.d ]; then
    echo "[dnsmasq] /etc/dnsmasq.d does not exist."
    echo "  Install dnsmasq:  brew install dnsmasq"
    echo "  Then run:         sudo brew services start dnsmasq"
    exit 0
fi

if [ -f "$CONF_FILE" ] && grep -qF "$GATEWAY_IP" "$CONF_FILE" 2>/dev/null; then
    echo "[dnsmasq] Config already present at ${CONF_FILE}; no change."
    exit 0
fi

echo "$CONTENT" | sudo tee "$CONF_FILE" > /dev/null
echo "[dnsmasq] Wrote: ${CONF_FILE}"
echo "  ${CONTENT}"

sudo brew services restart dnsmasq 2>/dev/null || \
    sudo launchctl kickstart -k system/homebrew.mxcl.dnsmasq 2>/dev/null || \
    echo "  [dnsmasq] Remember to restart dnsmasq manually."

echo ""
echo "  *.${DOMAIN} → ${GATEWAY_IP}"
echo "  (requires macOS resolvers configured via /etc/resolver/${DOMAIN})"
if [ ! -f "/etc/resolver/${DOMAIN}" ]; then
    echo ""
    echo "  Run once to create resolver:"
    cat <<CMD
    sudo mkdir -p /etc/resolver
    echo 'nameserver 127.0.0.1' | sudo tee /etc/resolver/${DOMAIN}
CMD
fi
