# -*- mode: ruby -*-
# vi: set ft=ruby :

# ============================================================================
# ceph-lab — Vagrantfile
#
# A local k3s + Rook Ceph cluster with a full GitOps stack (ArgoCD, Cilium,
# Prometheus, Grafana, Loki, Tempo, Alloy, cert-manager).
#
# Topology
# ────────
#   ceph-control   192.168.56.50   k3s server  2 vCPU / 3 GB
#   ceph-node-1    192.168.56.61   k3s agent   3 vCPU / 6 GB  + 2× 10 GB OSDs
#   ceph-node-2    192.168.56.62   k3s agent   3 vCPU / 6 GB  + 2× 10 GB OSDs
#   ceph-node-3    192.168.56.63   k3s agent   3 vCPU / 6 GB  + 2× 10 GB OSDs
#
# Key env vars (see .env.example / .envrc):
#   GITOPS_REPO_URL          — your fork of this repo (for ArgoCD)
#   GITOPS_REPO_TOKEN        — GitHub token (HTTPS) or empty for SSH
#   GITOPS_SSH_KEY_PATH      — path to SSH deploy key (SSH) or empty
#   SANDBOX_INSTALL_ARGOCD   — set 1 to auto-bootstrap ArgoCD on vagrant up
#   SANDBOX_CONFIGURE_DNSMASQ— set 1 to write *.ceph.lab → gateway into dnsmasq
# ============================================================================

CONFIG = {
  num_ceph_nodes:   Integer(ENV.fetch("SANDBOX_NUM_CEPH_NODES",   "3")),
  osd_disks:        Integer(ENV.fetch("SANDBOX_OSD_DISKS_PER_NODE","2")),

  control_plane_ip: ENV.fetch("SANDBOX_CONTROL_PLANE_IP", "192.168.56.50"),
  ceph_node_ip_base:Integer(ENV.fetch("SANDBOX_CEPH_NODE_IP_BASE", "60")),

  cache_enabled:    ENV.fetch("SANDBOX_CACHE_ENABLED", "1") == "1",
  cache_host:       ENV.fetch("SANDBOX_CACHE_HOST_VM",  "192.168.56.1"),
  cache_apt_port:   ENV.fetch("SANDBOX_CACHE_APT_PORT", "3142"),
  cache_docker_port:ENV.fetch("SANDBOX_CACHE_REGISTRY_DOCKERHUB_PORT", "5001"),
  cache_k8s_port:   ENV.fetch("SANDBOX_CACHE_REGISTRY_K8S_PORT",       "5002"),
  cache_ghcr_port:  ENV.fetch("SANDBOX_CACHE_REGISTRY_GHCR_PORT",      "5003"),
  cache_quay_port:  ENV.fetch("SANDBOX_CACHE_REGISTRY_QUAY_PORT",      "5004"),

  configure_dnsmasq:ENV.fetch("SANDBOX_CONFIGURE_DNSMASQ", "1") == "1",
  install_argocd:   ENV.fetch("SANDBOX_INSTALL_ARGOCD",    "0") == "1",

  k8s_minor:        ENV.fetch("SANDBOX_KUBERNETES_VERSION_MINOR", "1.32"),
  k3s_channel:      nil,  # resolved below
}
CONFIG[:k3s_channel] = ENV.fetch("SANDBOX_K3S_CHANNEL", "v#{CONFIG[:k8s_minor]}")

last_node = "ceph-node-#{CONFIG[:num_ceph_nodes]}"

Vagrant.configure("2") do |config|
  config.vm.box            = "cloud-image/ubuntu-24.04"
  config.vm.box_check_update = false

  # ── Environment forwarded to every provisioner ──────────────────────────────
  base_env = {
    "SANDBOX_CACHE_ENABLED"                     => (CONFIG[:cache_enabled] ? "1" : "0"),
    "SANDBOX_CACHE_HOST"                        => CONFIG[:cache_host],
    "SANDBOX_CACHE_APT_PORT"                    => CONFIG[:cache_apt_port],
    "SANDBOX_CACHE_REGISTRY_DOCKERHUB_PORT"     => CONFIG[:cache_docker_port],
    "SANDBOX_CACHE_REGISTRY_K8S_PORT"           => CONFIG[:cache_k8s_port],
    "SANDBOX_CACHE_REGISTRY_GHCR_PORT"          => CONFIG[:cache_ghcr_port],
    "SANDBOX_CACHE_REGISTRY_QUAY_PORT"          => CONFIG[:cache_quay_port],
    "SANDBOX_KUBERNETES_VERSION_MINOR"          => CONFIG[:k8s_minor],
    "SANDBOX_K3S_CHANNEL"                       => CONFIG[:k3s_channel],
    "ROOK_VERSION"                              => ENV.fetch("ROOK_VERSION",        "v1.19.1"),
    "CILIUM_VERSION"                            => ENV.fetch("CILIUM_VERSION",       "1.18.2"),
    "GATEWAY_API_VERSION"                       => ENV.fetch("GATEWAY_API_VERSION",  "v1.4.1"),
    "ARGOCD_VERSION"                            => ENV.fetch("ARGOCD_VERSION",       "stable"),
    "GITOPS_REPO_URL"                           => ENV.fetch("GITOPS_REPO_URL",      ""),
    "GITOPS_REPO_TOKEN"                         => ENV.fetch("GITOPS_REPO_TOKEN",    ""),
    "GITOPS_SSH_KEY_PATH"                       => ENV.fetch("GITOPS_SSH_KEY_PATH",  ""),
  }

  # ── Post-up triggers (run on host) ──────────────────────────────────────────
  config.trigger.after :up do |t|
    t.name    = "Merge kubeconfig (ceph-lab)"
    t.only_on = last_node
    t.run     = { inline: "uv run #{File.dirname(__FILE__)}/provisioning/scripts/manage_k8s_config.py add" }
  end

  config.trigger.before :destroy do |t|
    t.name    = "Remove kubeconfig (ceph-lab)"
    t.only_on = last_node
    t.run     = { inline: "uv run #{File.dirname(__FILE__)}/provisioning/scripts/manage_k8s_config.py remove" }
  end

  if CONFIG[:configure_dnsmasq]
    dns_env = {
      "SANDBOX_DNS_DOMAIN"    => ENV.fetch("SANDBOX_DNS_DOMAIN",    "ceph.lab"),
      "SANDBOX_GATEWAY_LB_IP" => ENV.fetch("SANDBOX_GATEWAY_LB_IP", "192.168.56.200"),
    }
    config.trigger.after :up do |t|
      t.name    = "Configure dnsmasq for *.ceph.lab"
      t.only_on = "ceph-control"
      t.run     = { path: "provisioning/scripts/dnsmasq_setup.sh", env: dns_env }
    end
    config.trigger.before :destroy do |t|
      t.name    = "Remove dnsmasq config for *.ceph.lab"
      t.only_on = "ceph-control"
      t.run     = { path: "provisioning/scripts/dnsmasq_teardown.sh", env: dns_env }
    end
  end

  # ── Helper: VirtualBox tuning + disk layout ─────────────────────────────────
  configure_vbox = lambda do |vm, name:, memory:, cpus:, osd_disks: 0|
    vm.vm.provider "virtualbox" do |vb|
      vb.memory        = memory
      vb.cpus          = cpus
      vb.name          = name
      vb.gui           = false
      vb.linked_clone  = false
      vb.customize ["modifyvm", :id, "--audio", "none"]
      vb.customize ["modifyvm", :id, "--usb",   "off"]
      vb.customize ["sharedfolder", "add", :id, "--name", "vagrant",
                    "--hostpath", File.dirname(__FILE__), "--automount"]
    end

    # Secondary system disk → mounted at /var/lib/rancher (k3s data dir)
    vm.vm.disk :disk, size: "20GB", name: "rancher_data"

    # Raw OSD disks — left UNFORMATTED; Rook claims them automatically
    osd_disks.times do |i|
      vm.vm.disk :disk, size: "10GB", name: "osd_#{i}"
    end

    vm.vm.synced_folder ".", "/vagrant", disabled: true
  end

  # ── Control plane ────────────────────────────────────────────────────────────
  config.vm.define "ceph-control" do |cp|
    cp.vm.hostname = "ceph-control"
    cp.vm.network "private_network", ip: CONFIG[:control_plane_ip]
    configure_vbox.call(cp, name: "ceph-control", memory: 3072, cpus: 2)
    cp.vm.provision "shell", path: "provisioning/scripts/common.sh",       env: base_env
    cp.vm.provision "shell", path: "provisioning/scripts/control-plane.sh", env: base_env
    if CONFIG[:install_argocd]
      cp.vm.provision "shell", path: "provisioning/scripts/install_argocd.sh", env: base_env
    end
  end

  # ── Worker / OSD nodes ───────────────────────────────────────────────────────
  (1..CONFIG[:num_ceph_nodes]).each do |i|
    config.vm.define "ceph-node-#{i}" do |node|
      node.vm.hostname = "ceph-node-#{i}"
      node.vm.network "private_network", ip: "192.168.56.#{CONFIG[:ceph_node_ip_base] + i}"
      configure_vbox.call(node, name: "ceph-node-#{i}",
                               memory: 6144, cpus: 3,
                               osd_disks: CONFIG[:osd_disks])
      node.vm.provision "shell", path: "provisioning/scripts/common.sh", env: base_env
      node.vm.provision "shell", path: "provisioning/scripts/node.sh",   env: base_env
    end
  end
end
