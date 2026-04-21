---
name: Control plane OOM on vagrant up
description: How the control plane OOMs during fresh vagrant up and how to recover
type: feedback
---

The control plane (3GB RAM, no swap) OOMs during `vagrant up` when ArgoCD bootstraps before workers join — all pods land on the control plane, API server hangs goroutines, workers can't register.

**Why:** No `NoSchedule` taint on ceph-control, and ArgoCD is installed (wave 0 of control-plane.sh) before workers provision. The full observability stack + ArgoCD stack = 2.5–3GB, which fills 3GB RAM with no swap.

**Code fix committed (2026-04-21):** `control-plane.sh` now creates a 2GB `/swapfile` before k3s install and sets `kubelet-arg: fail-swap-on=false`. This gives headroom during the window when workers haven't joined.

**Emergency recovery:** If it happens again:
1. SSH in: `vagrant ssh ceph-control`
2. Add swap: `sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile`
3. Restart k3s: `sudo systemctl restart k3s`
4. Workers will re-register within ~30s
5. Taint control plane to stop pod re-accumulation: `kubectl taint nodes ceph-control node-role.kubernetes.io/control-plane=:NoSchedule --overwrite`

**How to apply:** Check swap status at the start of any `vagrant up` debugging session.
