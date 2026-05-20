#!/bin/bash
# ceph-lab — common.sh
# Runs on every node (control plane + workers) during cluster provisioning.
# Sets up kernel modules, sysctl, swap, base packages, and shell ergonomics.
set -e

# Idempotency guard — Lima re-runs provision scripts on every boot.
# Skip if already provisioned (destroy + recreate resets this).
if [ -f /etc/ceph-lab-common.done ]; then
    echo "[common.sh] Already provisioned, skipping."
    exit 0
fi

echo "══════════════════════════════════════════"
echo "  ceph-lab provisioning — common baseline  "
echo "══════════════════════════════════════════"

# Lima provision steps run as root directly; SUDO_USER is never set.
# Source Lima's cidata env — LIMA_CIDATA_USER and LIMA_CIDATA_HOME are always
# set and authoritative (the Mac user's UID maps to Lima, not necessarily 1000).
# shellcheck disable=SC1091
[ -f /mnt/lima-cidata/lima.env ] && source /mnt/lima-cidata/lima.env
LAB_USER="${LIMA_CIDATA_USER:-}"
USER_HOME="${LIMA_CIDATA_HOME:-}"

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

echo "[4b] k3s containerd registry mirrors — failover for flaky quay.io/docker.io"
# k3s reads this at start; configures containerd to try each endpoint in order.
# Cilium images live primarily on quay.io but are mirrored to docker.io;
# k3s's pause image lives on docker.io. Listing both as endpoints for each
# means a TLS handshake timeout on one provider falls through to the other
# instead of failing the whole install.
mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/registries.yaml <<'EOF'
mirrors:
  quay.io:
    endpoint:
      - "https://quay.io"
      - "https://registry-1.docker.io"
  docker.io:
    endpoint:
      - "https://registry-1.docker.io"
      - "https://quay.io"
EOF

echo "[5] /etc/hosts — cluster node entries"
CONTROL_PLANE_IP="${SANDBOX_CONTROL_PLANE_IP:-192.168.56.50}"
NODE_IP_BASE="${SANDBOX_CEPH_NODE_IP_BASE:-60}"
NUM_NODES="${SANDBOX_NUM_CEPH_NODES:-3}"
cat >> /etc/hosts <<EOF
${CONTROL_PLANE_IP} ceph-control
EOF
for i in $(seq 1 "${NUM_NODES}"); do
    NODE_IP="192.168.56.$((NODE_IP_BASE + i))"
    echo "${NODE_IP} ceph-node-${i}" >> /etc/hosts
done

echo "[6] Mount secondary disk → /var/lib/rancher (k3s data dir)"
# Lima virtio-blk: /dev/vdb is the pre-created secondary disk for k3s data.
# /dev/vdc and /dev/vdd are raw OSD disks — leave them unformatted for Rook.
TARGET_DISK="/dev/vdb"
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
echo "  OSD disks (vdc+) left raw — Rook claims them automatically."

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

echo "[9] Shell ergonomics — fish, bash, vim, tmux"

# ── fish config ────────────────────────────────────────────────────────────────
mkdir -p "${USER_HOME}/.config/fish/conf.d"
cat > "${USER_HOME}/.config/fish/conf.d/ceph-lab.fish" <<'FISH'
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
abbr -a open-urls      'bash /ceph-lab/provisioning/scripts/open_urls.sh'
abbr -a get-pass       'kubectl -n rook-ceph get secret rook-ceph-dashboard-password -o jsonpath="{.data.password}" | base64 -d; echo'
FISH

chown -R "${LAB_USER}:${LAB_USER}" "${USER_HOME}/.config"

# ── bash aliases ──────────────────────────────────────────────────────────────
cat >> "${USER_HOME}/.bashrc" <<'BASH'

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
alias open-urls='bash /ceph-lab/provisioning/scripts/open_urls.sh'
alias get-pass='kubectl -n rook-ceph get secret rook-ceph-dashboard-password -o jsonpath="{.data.password}" | base64 -d; echo'

# git branch + k8s context in prompt
__ps1_k8s() { kubectl config current-context 2>/dev/null || echo '—'; }
__ps1_git() { git -C "$PWD" rev-parse --abbrev-ref HEAD 2>/dev/null | sed 's/^/ (/;s/$/)/' || true; }
export PROMPT_COMMAND='PS1="\[\e[1;36m\]k8s:\[\e[0m\]$(__ps1_k8s)\[\e[1;33m\]$(__ps1_git)\[\e[0m\] \w \$ "'
BASH

# ── vim defaults ──────────────────────────────────────────────────────────────
cat > "${USER_HOME}/.vimrc" <<'VIM'
syntax on
set number relativenumber
set tabstop=2 shiftwidth=2 expandtab
set incsearch hlsearch
set encoding=utf-8
set backspace=indent,eol,start
colorscheme desert
VIM

# ── tmux config ───────────────────────────────────────────────────────────────
cat > "${USER_HOME}/.tmux.conf" <<'TMUX'
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

chown "${LAB_USER}:${LAB_USER}" \
    "${USER_HOME}/.vimrc" \
    "${USER_HOME}/.tmux.conf" \
    "${USER_HOME}/.bashrc"

touch /etc/ceph-lab-common.done
echo "✓ common.sh complete"
