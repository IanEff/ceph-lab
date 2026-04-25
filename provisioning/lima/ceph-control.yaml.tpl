# Lima VM definition — ceph-control (k3s server + Cilium)
#
# Template: __CEPH_LAB_ROOT__ is replaced with the absolute project root path
# by lima-up.sh before calling `limactl start`.
#
# vmType: vz uses Apple's Virtualization.framework — no QEMU overhead, native
# performance on Apple Silicon and Intel Macs running macOS 13+.

vmType: "vz"
os: "Linux"
# arch omitted — Lima defaults to the host architecture

cpus: 2
memory: "6GiB"
disk: "40GiB"

# k3s ships its own containerd — Lima's nerdctl install wastes ~10 min on first boot.
containerd:
  system: false
  user: false

# Ubuntu 24.04 LTS — arm64 and amd64 variants; Lima picks the right one
images:
  - location: "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-arm64.img"
    arch: "aarch64"
  - location: "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
    arch: "x86_64"

# Secondary block device for /var/lib/rancher — keeps k3s data off the root disk.
# Appears as /dev/vdb inside the VM (virtio-blk via Virtualization.framework).
# common.sh detects and formats it on first boot.
# Must be pre-created with `limactl disk create` before starting this instance.
additionalDisks:
  - name: "ceph-control-rancher"
    size: "20GiB"

# Mount the project root at /ceph-lab (virtiofs — low-latency, writable).
# Provision scripts, deploy keys, and provision.env are all read from here.
# control-plane.sh writes provisioning/node-token here so workers can join.
mounts:
  - location: "__CEPH_LAB_ROOT__"
    mountPoint: "/ceph-lab"
    writable: true

# Networking:
#   vzNAT    — Apple Virtualization NAT for outbound internet (apt, helm pulls).
#              VMs are NOT directly reachable from the host via vzNAT.
#   ceph-lab — socket_vmnet host-only network (192.168.56.0/24).
#              Provides direct host↔VM and VM↔VM connectivity at a static IP.
#              The static IP is configured in Step 1 below via netplan.
networks:
  - vzNAT: true
  - lima: "ceph-lab"
    interface: "eth1"

# ---------------------------------------------------------------------------
# Provision: only set the static IP here.  All heavy provisioning (common.sh,
# control-plane.sh) runs from the Mac via `limactl shell` in lima-up.sh AFTER
# `limactl start` returns.  Keeping this step tiny lets Lima detect "boot done"
# in ~5 s instead of timing out after 9 min waiting for cloud-init.
# ---------------------------------------------------------------------------

provision:
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
              - 192.168.56.50/24
          lima0:
            dhcp4: true
            dhcp4-overrides:
              use-routes: false
      NETPLAN
      chmod 600 /etc/netplan/99-ceph-lab-static.yaml
      netplan apply || true
      echo "[Lima] Static IP 192.168.56.50 on eth1; lima0 routes suppressed"
