# ceph-lab — Makefile
# Wrapper around Lima cluster lifecycle scripts.
#
# Quick reference:
#   make setup         — one-time host prereqs (Lima, socket_vmnet, network config)
#   make up            — provision and start all VMs (~10–20 min first run)
#   make down          — stop VMs, preserve state
#   make destroy       — permanently delete VMs + disks (prompts for confirmation)
#   make destroy-force — destroy without confirmation
#   make ssh           — open a shell on ceph-control
#   make kubeconfig    — re-merge kubeconfig + SSH aliases after a restart

.PHONY: setup up down destroy destroy-force ssh kubeconfig

setup:
	bash provisioning/lima-setup.sh

up:
	bash provisioning/lima-up.sh

down:
	bash provisioning/lima-down.sh

destroy:
	bash provisioning/lima-destroy.sh

destroy-force:
	bash provisioning/lima-destroy.sh -f

ssh:
	limactl shell ceph-control

kubeconfig:
	python3 provisioning/scripts/manage_k8s_config.py add
