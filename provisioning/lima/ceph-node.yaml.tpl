# Lima VM definition — ceph-node-__NODE_NUM__ (k3s agent + Ceph OSD node)
#
# Template placeholders replaced by lima-up.sh:
#   __CEPH_LAB_ROOT__  → absolute path to project root
#   __NODE_NAME__      → e.g. ceph-node-1
#   __NODE_NUM__       → e.g. 1
#   __NODE_IP__        → e.g. 192.168.56.61

vmType: "vz"
os: "Linux"
# arch omitted — Lima defaults to the host architecture

cpus: 3
memory: "8GiB"
disk: "40GiB"

# k3s ships its own containerd — Lima's nerdctl install wastes ~10 min on first boot.
containerd:
  system: false
  user: false

images:
  - location: "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-arm64.img"
    arch: "aarch64"
  - location: "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
    arch: "x86_64"

# Three additional block devices per worker:
#   /dev/vdb — k3s rancher data dir (20 GiB, formatted ext4 by common.sh)
#   /dev/vdc — Ceph OSD disk 1 (10 GiB, raw — Rook auto-claims)
#   /dev/vdd — Ceph OSD disk 2 (10 GiB, raw — Rook auto-claims)
#
# All must be pre-created with `limactl disk create` before starting this instance.
additionalDisks:
  - name: "__NODE_NAME__-rancher"
    size: "20GiB"
  - name: "__NODE_NAME__-osd-1"
    size: "10GiB"
  - name: "__NODE_NAME__-osd-2"
    size: "10GiB"

mounts:
  - location: "__CEPH_LAB_ROOT__"
    mountPoint: "/ceph-lab"
    writable: true

networks:
  - vzNAT: true
  - lima: "ceph-lab"
    interface: "eth1"

provision:
  # Netplan only — heavy provisioning (common.sh + node.sh) runs from the Mac
  # via `limactl shell` in lima-up.sh AFTER `limactl start` returns.
  # Keeping this step tiny lets Lima detect "boot done" in ~5 s instead of
  # falling back to a 9-min timeout waiting for cloud-init.
  - mode: system
    script: |
      #!/bin/bash
      set -e
      cat > /etc/netplan/99-ceph-lab-static.yaml << 'NETPLAN'
      network:
        version: 2
        ethernets:
          eth1:
            dhcp4: false
            addresses:
              - __NODE_IP__/24
          lima0:
            dhcp4: true
            dhcp4-overrides:
              use-routes: false
      NETPLAN
      chmod 600 /etc/netplan/99-ceph-lab-static.yaml
      netplan apply || true
      echo "[Lima] Static IP __NODE_IP__ on eth1; lima0 routes suppressed"
