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

# A user-domain LaunchAgent (from a plain `brew services start dnsmasq`
# run without sudo, e.g. pre-dating this script) fights the system-domain
# LaunchDaemon below for port 53 — both register the same launchd label.
# dnsmasq here must only ever run in the system domain, so tear out any
# stray user-domain copy before (re)starting the real one.
USER_AGENT="${HOME}/Library/LaunchAgents/homebrew.mxcl.dnsmasq.plist"
if [ -f "$USER_AGENT" ]; then
    echo "[dnsmasq] Removing stray user-domain LaunchAgent: ${USER_AGENT}"
    launchctl bootout "gui/$(id -u)" "$USER_AGENT" 2>/dev/null || true
    rm -f "$USER_AGENT"
fi

sudo brew services restart dnsmasq 2>/dev/null || \
    sudo launchctl kickstart -k system/homebrew.mxcl.dnsmasq 2>/dev/null || \
    echo "  [dnsmasq] Remember to restart dnsmasq manually."

# mDNSResponder caches lookups (including negative/SERVFAIL results) made
# during the dnsmasq restart window above and won't retry on its own —
# this is the "DNS is flaky, needs kicking" symptom. Flush it every time.
sudo dscacheutil -flushcache 2>/dev/null || true
sudo killall -HUP mDNSResponder 2>/dev/null || true

echo ""
echo "  *.${DOMAIN} → ${GATEWAY_IP}  (dnsmasq ready)"
