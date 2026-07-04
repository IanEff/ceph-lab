set shell := ["bash", "-euo", "pipefail", "-c"]

# list available recipes
default:
    @just --list

# one-time host prerequisites (Lima, socket_vmnet, network config)
setup:
    provisioning/lima-setup.sh

# configure passwordless sudo for Lima, dnsmasq, resolver, and mDNSResponder on the host
setup-sudoers:
    sudo provisioning/scripts/setup_host_sudoers.sh

# provision and start all VMs (~10–20 min first run)
up:
    provisioning/lima-up.sh

# stop VMs and preserve state
down:
    provisioning/lima-down.sh

# permanently delete all VMs and disks
[confirm("Permanently delete all VMs and disks?")]
destroy:
    provisioning/lima-destroy.sh -f

# open a shell on ceph-control
ssh:
    limactl shell ceph-control

# merge kubeconfig + SSH aliases after a restart
kubeconfig:
    python3 provisioning/scripts/manage_k8s_config.py add

# regenerate Prometheus rule groups from the Sloth SLO specs (requires sloth-cli, yq)
gen-slos:
    provisioning/scripts/gen_slos.sh
