#!/bin/bash
# ceph-lab — common.sh
# Runs on every node (control plane + workers) during vagrant up.
# Sets up kernel modules, sysctl, swap, OSD disks, base packages, and shell ergonomics.
set -e

SANDBOX_CACHE_ENABLED="${SANDBOX_CACHE_ENABLED:-0}"
SANDBOX_CACHE_HOST="${SANDBOX_CACHE_HOST:-}"
SANDBOX_CACHE_APT_PORT="${SANDBOX_CACHE_APT_PORT:-3142}"
SANDBOX_CACHE_REGISTRY_DOCKERHUB_PORT="${SANDBOX_CACHE_REGISTRY_DOCKERHUB_PORT:-5001}"
SANDBOX_CACHE_REGISTRY_K8S_PORT="${SANDBOX_CACHE_REGISTRY_K8S_PORT:-5002}"
SANDBOX_CACHE_REGISTRY_GHCR_PORT="${SANDBOX_CACHE_REGISTRY_GHCR_PORT:-5003}"
SANDBOX_CACHE_REGISTRY_QUAY_PORT="${SANDBOX_CACHE_REGISTRY_QUAY_PORT:-5004}"

cache_tcp_check() {
    local host="$1" port="$2"
    [ -z "$host" ] && return 1
    timeout 1 bash -c "</dev/tcp/${host}/${port}" >/dev/null 2>&1
}

maybe_configure_apt_cache() {
    [ "$SANDBOX_CACHE_ENABLED" != "1" ] && return 0
    local h; h=$(echo "$SANDBOX_CACHE_HOST" | tr -d ' \\')
    [ -z "$h" ] && { echo "[CACHE] SANDBOX_CACHE_HOST empty; skipping APT cache."; return 0; }
    if ! cache_tcp_check "$h" "$SANDBOX_CACHE_APT_PORT"; then
        echo "[CACHE] APT cache not reachable at ${h}:${SANDBOX_CACHE_APT_PORT}; continuing without it."
        return 0
    fi
    echo "[CACHE] Using APT proxy at ${h}:${SANDBOX_CACHE_APT_PORT}"
    printf 'Acquire::http::Proxy "http://%s:%s";\n' "$h" "$SANDBOX_CACHE_APT_PORT" \
        > /etc/apt/apt.conf.d/01sandbox-cache
    printf 'Acquire::http::Proxy::%s "DIRECT";\n' "$h" \
        >> /etc/apt/apt.conf.d/01sandbox-cache
    printf 'Acquire::https::Proxy "DIRECT";\n' \
        >> /etc/apt/apt.conf.d/01sandbox-cache
}

maybe_configure_k3s_registry_mirrors() {
    [ "$SANDBOX_CACHE_ENABLED" != "1" ] && return 0
    local h; h=$(echo "$SANDBOX_CACHE_HOST" | tr -d ' \\')
    [ -z "$h" ] && return 0
    if ! cache_tcp_check "$h" "$SANDBOX_CACHE_REGISTRY_K8S_PORT"; then
        echo "[CACHE] Registry cache not reachable; continuing without it."
        return 0
    fi
    echo "[CACHE] Configuring k3s registry mirrors via ${h}"
    mkdir -p /etc/rancher/k3s
    cat > /etc/rancher/k3s/registries.yaml <<EOF
mirrors:
  docker.io:
    endpoint:
      - "http://${h}:${SANDBOX_CACHE_REGISTRY_DOCKERHUB_PORT}"
  registry-1.docker.io:
    endpoint:
      - "http://${h}:${SANDBOX_CACHE_REGISTRY_DOCKERHUB_PORT}"
  registry.k8s.io:
    endpoint:
      - "http://${h}:${SANDBOX_CACHE_REGISTRY_K8S_PORT}"
  ghcr.io:
    endpoint:
      - "http://${h}:${SANDBOX_CACHE_REGISTRY_GHCR_PORT}"
  quay.io:
    endpoint:
      - "http://${h}:${SANDBOX_CACHE_REGISTRY_QUAY_PORT}"
EOF
}

echo "══════════════════════════════════════════"
echo "  ceph-lab provisioning — common baseline  "
echo "══════════════════════════════════════════"

echo "[1] Disable swap"
swapoff -a
sed -i '/swap/d' /etc/fstab

echo "[2] Override DNS with reliable resolvers"
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/dns.conf <<EOF
[Resolve]
DNS=8.8.8.8
FallbackDNS=1.1.1.1
EOF
systemctl restart systemd-resolved

maybe_configure_apt_cache

echo "[3] Kernel modules for Kubernetes + Rook Ceph"
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
cat > /etc/modules-load.d/rook-ceph.conf <<EOF
rbd
EOF
modprobe overlay
modprobe br_netfilter
modprobe rbd 2>/dev/null || echo "[WARN] rbd module unavailable now; will load after reboot."

echo "[4] Sysctl: IP forwarding + bridge netfilter"
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null

echo "[5] /etc/hosts — cluster node entries"
cat >> /etc/hosts <<EOF
192.168.56.50 ceph-control
192.168.56.61 ceph-node-1
192.168.56.62 ceph-node-2
192.168.56.63 ceph-node-3
EOF

echo "[6] Mount secondary disk → /var/lib/rancher (k3s data dir)"
TARGET_DISK="/dev/sdb"
if [ -b "$TARGET_DISK" ]; then
    if grep -qs "$TARGET_DISK" /proc/mounts; then
        echo "  $TARGET_DISK already mounted."
    else
        if ! blkid "$TARGET_DISK" >/dev/null 2>&1; then
            mkfs.ext4 -F "$TARGET_DISK"
        fi
        mkdir -p /var/lib/rancher
        mount "$TARGET_DISK" /var/lib/rancher
        grep -q "$TARGET_DISK" /etc/fstab || \
            echo "$TARGET_DISK /var/lib/rancher ext4 defaults 0 0" >> /etc/fstab
    fi
fi
echo "  OSD disks (sdc+) left raw — Rook claims them automatically."

echo "[7] Robust APT settings"
apt-get update
cat > /etc/apt/apt.conf.d/99robust <<EOF
Acquire::Retries "10";
Acquire::ForceIPv4 "true";
Acquire::https::Timeout "60";
Acquire::http::Timeout "60";
Acquire::http::Pipeline-Depth "0";
EOF

echo "[8] Install base packages"
apt-get install -y \
    apt-transport-https ca-certificates curl gpg \
    lvm2 gdisk sg3-utils udev open-iscsi nfs-common \
    git vim bash-completion wget jq \
    ripgrep bat fd-find tmux fish
systemctl enable --now iscsid

echo "[9] k3s OCI registry mirrors"
maybe_configure_k3s_registry_mirrors

echo "[10] Shell ergonomics — fish, bash, vim, tmux"

# ── fish config ────────────────────────────────────────────────────────────────
mkdir -p /home/vagrant/.config/fish/conf.d
cat > /home/vagrant/.config/fish/conf.d/ceph-lab.fish <<'FISH'
# ── Ceph / Rook diagnostics ──────────────────────────────────────────────────
abbr -a ceph-status    'kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph status'
abbr -a ceph-df        'kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph df detail'
abbr -a ceph-osd-tree  'kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph osd tree'
abbr -a ceph-health    'kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph health detail'
abbr -a ceph-auth      'kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph auth list'
abbr -a ceph-osd-perf  'kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph osd perf'
abbr -a ceph-log       'kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph log last 50'
abbr -a ceph-crush     'kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph osd crush tree'
abbr -a ceph-pools     'kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph osd pool ls detail'
abbr -a ceph-pg-stat   'kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph pg stat'
abbr -a ceph-s3-test   'kubectl exec -n rook-ceph deploy/rook-ceph-tools -- radosgw-admin bucket list'

# ── Rook / k8s shortcuts ─────────────────────────────────────────────────────
abbr -a rook-status    'kubectl get cephcluster -n rook-ceph'
abbr -a rook-tools     'kubectl exec -it -n rook-ceph deploy/rook-ceph-tools -- bash'
abbr -a watch-pods     'watch kubectl get pods -n rook-ceph'
abbr -a kpn            'kubectl get pods -n rook-ceph'
abbr -a kpa            'kubectl get pods -A'

# ── ArgoCD shortcuts ─────────────────────────────────────────────────────────
abbr -a argo-apps      'kubectl get applications -n argocd'
abbr -a argo-sync      'kubectl get applications -n argocd -w'
abbr -a argo-waves     'kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,WAVE:.metadata.annotations."argocd.argoproj.io/sync-wave",HEALTH:.status.health.status,SYNC:.status.sync.status'

# ── Hubble flow inspection ────────────────────────────────────────────────────
abbr -a hubble-rook    'hubble observe --namespace rook-ceph'
abbr -a hubble-drops   'hubble observe --verdict DROPPED'
abbr -a hubble-ceph    'hubble observe --namespace rook-ceph --type l7'

# ── Lab helpers ───────────────────────────────────────────────────────────────
abbr -a open-urls      'bash /vagrant/provisioning/scripts/open_urls.sh'
abbr -a get-pass       'kubectl -n rook-ceph get secret rook-ceph-dashboard-password -o jsonpath="{.data.password}" | base64 -d; echo'
FISH

chown -R vagrant:vagrant /home/vagrant/.config

# ── bash aliases ──────────────────────────────────────────────────────────────
cat >> /home/vagrant/.bashrc <<'BASH'

# ── ceph-lab convenience aliases ────────────────────────────────────────────
_toolbox() { kubectl exec -n rook-ceph deploy/rook-ceph-tools -- "$@"; }
alias ceph-status='_toolbox ceph status'
alias ceph-df='_toolbox ceph df detail'
alias ceph-osd-tree='_toolbox ceph osd tree'
alias ceph-health='_toolbox ceph health detail'
alias ceph-auth='_toolbox ceph auth list'
alias ceph-osd-perf='_toolbox ceph osd perf'
alias ceph-log='_toolbox ceph log last 50'
alias ceph-crush='_toolbox ceph osd crush tree'
alias ceph-pools='_toolbox ceph osd pool ls detail'
alias ceph-pg-stat='_toolbox ceph pg stat'
alias rook-status='kubectl get cephcluster -n rook-ceph'
alias rook-tools='kubectl exec -it -n rook-ceph deploy/rook-ceph-tools -- bash'
alias watch-pods='watch kubectl get pods -n rook-ceph'
alias kpn='kubectl get pods -n rook-ceph'
alias kpa='kubectl get pods -A'
alias argo-apps='kubectl get applications -n argocd'
alias hubble-rook='hubble observe --namespace rook-ceph'
alias hubble-drops='hubble observe --verdict DROPPED'
alias open-urls='bash /vagrant/provisioning/scripts/open_urls.sh'
alias get-pass='kubectl -n rook-ceph get secret rook-ceph-dashboard-password -o jsonpath="{.data.password}" | base64 -d; echo'

# git branch + k8s context in prompt
__ps1_k8s() { kubectl config current-context 2>/dev/null || echo '—'; }
__ps1_git() { git -C "$PWD" rev-parse --abbrev-ref HEAD 2>/dev/null | sed 's/^/ (/;s/$/)/' || true; }
export PROMPT_COMMAND='PS1="\[\e[1;36m\]k8s:\[\e[0m\]$(__ps1_k8s)\[\e[1;33m\]$(__ps1_git)\[\e[0m\] \w \$ "'
BASH

# ── vim defaults ──────────────────────────────────────────────────────────────
cat > /home/vagrant/.vimrc <<'VIM'
syntax on
set number relativenumber
set tabstop=2 shiftwidth=2 expandtab
set incsearch hlsearch
set encoding=utf-8
set backspace=indent,eol,start
colorscheme desert
VIM

# ── tmux config ───────────────────────────────────────────────────────────────
cat > /home/vagrant/.tmux.conf <<'TMUX'
set -g mouse on
set -g default-terminal "screen-256color"
set -g status-style "bg=colour235,fg=colour136"
set -g status-left  "#[fg=colour166,bold]  ceph-lab  #[default]"
set -g status-right "#[fg=colour33]%H:%M  %d-%b  #[fg=colour166]#H"
set -g status-right-length 50
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
bind r source-file ~/.tmux.conf \; display "tmux.conf reloaded"
TMUX

chown vagrant:vagrant /home/vagrant/.vimrc /home/vagrant/.tmux.conf /home/vagrant/.bashrc

echo "[11] VirtualBox Guest Additions + /vagrant shared folder"
# Check for vboxsf (shared folder FS module), NOT vboxguest (kernel driver).
# cloud-image/ubuntu-24.04 ships with vboxguest pre-loaded, but vboxsf
# requires Guest Additions to be built from the ISO.
if ! lsmod | grep -q vboxsf 2>/dev/null; then
    apt-get install -y build-essential linux-headers-"$(uname -r)" dkms
    VBOX_ISO="/tmp/VBoxGuestAdditions.iso"
    wget -q "https://download.virtualbox.org/virtualbox/7.2.4/VBoxGuestAdditions_7.2.4.iso" \
        -O "$VBOX_ISO"
    mkdir -p /mnt/vbox-iso
    mount -o loop "$VBOX_ISO" /mnt/vbox-iso
    ARCH=$(uname -m)
    if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
        /mnt/vbox-iso/VBoxLinuxAdditions-arm64.run --nox11 || true
    else
        /mnt/vbox-iso/VBoxLinuxAdditions.run --nox11 || true
    fi
    umount /mnt/vbox-iso
    rm -rf /mnt/vbox-iso "$VBOX_ISO"
    modprobe vboxsf || echo "[WARN] vboxsf still not available after GA install"
fi

# Always ensure /vagrant is mounted.
if ! mountpoint -q /vagrant 2>/dev/null; then
    mkdir -p /vagrant
    modprobe vboxsf 2>/dev/null || true
    mount -t vboxsf vagrant /vagrant || echo "[WARN] /vagrant mount failed — shared folder unavailable"
fi
grep -q 'vboxsf' /etc/modules 2>/dev/null || echo "vboxsf" >> /etc/modules
grep -q 'vagrant.*vboxsf' /etc/fstab || \
    echo "vagrant /vagrant vboxsf defaults,uid=1000,gid=1000 0 0" >> /etc/fstab

echo "✓ common.sh complete"
