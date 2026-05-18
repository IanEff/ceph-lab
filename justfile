# one-time host prerequesites (lima, socket_vmnet, network config
setup:
    bash provisioning/lima-setup.sh

# start the VMs and provision kubernetes
up:
	bash provisioning/lima-up.sh

# stop the VMs and preserve state
down:
	bash provisioning/lima-down.sh

# permanently delete VMs and disks
destroy:
	bash provisioning/lima-destroy.sh

# permanently delete VMs and disks, forcefully
destroy-force:
	bash provisioning/lima-destroy.sh -f

# open a shell on ceph-control
ssh:
	limactl shell ceph-control

$ merge kubeconfig and SSH aliases after a restart
kubeconfig:
	python3 provisioning/scripts/manage_k8s_config.py add
