#!/usr/bin/env bash
# ceph-lab — setup_host_sudoers.sh
# One-time host setup for passwordless sudo rules.
# Must be run as root (usually via `sudo provisioning/scripts/setup_host_sudoers.sh` or `just setup-sudoers`).

set -euo pipefail

# Ensure run as root
if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root (via sudo)." >&2
    echo "Please run: just setup-sudoers" >&2
    exit 1
fi

SUDO_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "")}"
if [ -z "$SUDO_USER" ] || [ "$SUDO_USER" = "root" ]; then
    echo "Error: Could not detect the original user (SUDO_USER is empty or root)." >&2
    exit 1
fi

echo "[sudoers] Setting up passwordless sudo rules for user: ${SUDO_USER}"

# Ensure /etc/sudoers.d exists
mkdir -p /etc/sudoers.d

TEMP_FILE=$(mktemp)
trap 'rm -f "$TEMP_FILE"' EXIT

# 1. Generate Lima rules (if limactl is installed)
if sudo -u "$SUDO_USER" command -v limactl >/dev/null 2>&1; then
    echo "[sudoers] Generating Lima VM sudoers rules..."
    sudo -u "$SUDO_USER" limactl sudoers >> "$TEMP_FILE"
else
    echo "[sudoers] Warning: limactl not found in PATH for user ${SUDO_USER}."
    echo "[sudoers] Sudoers rules for Lima VM virtualization will not be generated automatically."
fi

# 2. Append custom ceph-lab dnsmasq, resolver, mDNSResponder, and socket_vmnet rules
cat << EOF >> "$TEMP_FILE"

# ceph-lab dnsmasq, resolver, mDNSResponder and helper rules
%admin ALL=(root) NOPASSWD: /usr/local/bin/brew services start dnsmasq
%admin ALL=(root) NOPASSWD: /usr/local/bin/brew services stop dnsmasq
%admin ALL=(root) NOPASSWD: /usr/local/bin/brew services restart dnsmasq
%admin ALL=(root) NOPASSWD: /opt/homebrew/bin/brew services start dnsmasq
%admin ALL=(root) NOPASSWD: /opt/homebrew/bin/brew services stop dnsmasq
%admin ALL=(root) NOPASSWD: /opt/homebrew/bin/brew services restart dnsmasq
%admin ALL=(root) NOPASSWD: /usr/local/bin/brew services start socket_vmnet
%admin ALL=(root) NOPASSWD: /usr/local/bin/brew services stop socket_vmnet
%admin ALL=(root) NOPASSWD: /usr/local/bin/brew services restart socket_vmnet
%admin ALL=(root) NOPASSWD: /opt/homebrew/bin/brew services start socket_vmnet
%admin ALL=(root) NOPASSWD: /opt/homebrew/bin/brew services stop socket_vmnet
%admin ALL=(root) NOPASSWD: /opt/homebrew/bin/brew services restart socket_vmnet
%admin ALL=(root) NOPASSWD: /usr/bin/dscacheutil -flushcache
%admin ALL=(root) NOPASSWD: /usr/bin/killall -HUP mDNSResponder
%admin ALL=(root) NOPASSWD: /bin/mkdir -p /etc/resolver
%admin ALL=(root) NOPASSWD: /usr/bin/tee /etc/resolver/*
%admin ALL=(root) NOPASSWD: /bin/rm -f /etc/resolver/*
%admin ALL=(root) NOPASSWD: /usr/bin/security add-trusted-cert *
EOF

# 3. Validate with visudo
echo "[sudoers] Validating generated sudoers syntax..."
if ! visudo -cf "$TEMP_FILE"; then
    echo "Error: Generated sudoers file is syntactically invalid! Aborting setup." >&2
    exit 1
fi

# 4. Copy to /etc/sudoers.d/ceph-lab
DEST_FILE="/etc/sudoers.d/ceph-lab"
cp "$TEMP_FILE" "$DEST_FILE"
chmod 0440 "$DEST_FILE"
chown root:wheel "$DEST_FILE" 2>/dev/null || chown root:0 "$DEST_FILE"

echo "[sudoers] Installed passwordless rules to ${DEST_FILE}."

# 5. Try starting/restarting socket_vmnet if installed
# Homebrew on Apple Silicon uses /opt/homebrew, Intel uses /usr/local
BREW_PREFIX=""
if [ -d /opt/homebrew ]; then
    BREW_PREFIX="/opt/homebrew"
elif [ -d /usr/local ]; then
    BREW_PREFIX="/usr/local"
fi

if [ -n "$BREW_PREFIX" ] && [ -x "/opt/socket_vmnet/bin/socket_vmnet" ]; then
    echo "[sudoers] Starting socket_vmnet services..."
    if [ -x "${BREW_PREFIX}/bin/brew" ]; then
        "${BREW_PREFIX}/bin/brew" services start socket_vmnet || echo "[sudoers] socket_vmnet already running or failed to start."
    fi
fi

echo "[sudoers] Sudoers setup completed successfully!"
