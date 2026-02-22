#!/usr/bin/env python3
"""
ceph-lab — manage_k8s_config.py

Add or remove the ceph-lab kubeconfig context and SSH entries on the macOS host.

Usage:
    python3 provisioning/scripts/manage_k8s_config.py add
    python3 provisioning/scripts/manage_k8s_config.py remove
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

# ── Constants ─────────────────────────────────────────────────────────────────
CONTROL_PLANE_IP = "192.168.56.50"
NUM_CEPH_NODES = int(os.environ.get("SANDBOX_NUM_CEPH_NODES", "3"))
CEPH_NODE_IP_BASE = int(os.environ.get("SANDBOX_CEPH_NODE_IP_BASE", "60"))

CONTEXT_NAME = "ceph-lab"
CLUSTER_NAME = "ceph-lab-cluster"
USER_NAME = "ceph-lab-admin"
VM_NAMES = ["ceph-control"] + [f"ceph-node-{i}" for i in range(1, NUM_CEPH_NODES + 1)]

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent
VAGRANT_DIR = REPO_ROOT / ".vagrant" / "machines"
SSH_CONFIG = Path.home() / ".ssh" / "config"
KUBE_CONFIG = Path.home() / ".kube" / "config"

SSH_BLOCK_BEGIN = f"# BEGIN ceph-lab managed hosts"
SSH_BLOCK_END = f"# END ceph-lab managed hosts"


def run(cmd: list, **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw)


# ── SSH config helpers ────────────────────────────────────────────────────────


def scan_vms() -> dict[str, str]:
    """Return {vm_name: private_key_path} for all available Vagrant VMs."""
    keys = {}
    for vm in VM_NAMES:
        key = VAGRANT_DIR / vm / "virtualbox" / "private_key"
        if key.exists():
            keys[vm] = str(key)
    return keys


def build_ssh_block(keys: dict[str, str]) -> str:
    lines = [SSH_BLOCK_BEGIN]
    ip_map = {"ceph-control": CONTROL_PLANE_IP}
    for i in range(1, NUM_CEPH_NODES + 1):
        ip_map[f"ceph-node-{i}"] = f"192.168.56.{CEPH_NODE_IP_BASE + i}"

    for vm, key in keys.items():
        ip = ip_map.get(vm, "")
        if not ip:
            continue
        lines += [
            f"Host {vm}",
            f"  HostName {ip}",
            f"  User vagrant",
            f"  IdentityFile {key}",
            f"  StrictHostKeyChecking no",
            f"  UserKnownHostsFile /dev/null",
            f"  LogLevel ERROR",
            "",
        ]
    lines.append(SSH_BLOCK_END)
    return "\n".join(lines) + "\n"


def update_ssh_config(keys: dict[str, str]) -> None:
    SSH_CONFIG.parent.mkdir(parents=True, exist_ok=True)
    existing = SSH_CONFIG.read_text() if SSH_CONFIG.exists() else ""
    # Strip any previous ceph-lab block
    stripped = re.sub(
        rf"{re.escape(SSH_BLOCK_BEGIN)}.*?{re.escape(SSH_BLOCK_END)}\n?",
        "",
        existing,
        flags=re.DOTALL,
    )
    new_block = build_ssh_block(keys)
    SSH_CONFIG.write_text(stripped + new_block)
    SSH_CONFIG.chmod(0o600)
    print(f"  SSH config updated: {SSH_CONFIG}")


def remove_ssh_config() -> None:
    if not SSH_CONFIG.exists():
        return
    existing = SSH_CONFIG.read_text()
    stripped = re.sub(
        rf"{re.escape(SSH_BLOCK_BEGIN)}.*?{re.escape(SSH_BLOCK_END)}\n?",
        "",
        existing,
        flags=re.DOTALL,
    )
    SSH_CONFIG.write_text(stripped)
    print(f"  SSH entries removed from {SSH_CONFIG}")


# ── kubeconfig helpers ────────────────────────────────────────────────────────


def fetch_kubeconfig(retries: int = 6, delay: float = 10.0) -> str:
    """SSH to the control plane and retrieve its kubeconfig, with retries."""
    for attempt in range(1, retries + 1):
        try:
            result = subprocess.run(
                [
                    "ssh",
                    "-F",
                    str(SSH_CONFIG),
                    "-o",
                    "ConnectTimeout=15",
                    "-o",
                    "BatchMode=yes",
                    "-o",
                    "IdentitiesOnly=yes",
                    "ceph-control",
                    "cat /home/vagrant/.kube/config",
                ],
                capture_output=True,
                text=True,
                check=True,
            )
            return result.stdout
        except subprocess.CalledProcessError as e:
            if attempt < retries:
                print(
                    f"  SSH attempt {attempt}/{retries} failed (exit {e.returncode})"
                    f"{': ' + e.stderr.strip() if e.stderr.strip() else ''}; "
                    f"retrying in {delay:.0f}s…"
                )
                time.sleep(delay)
                delay = min(delay * 1.5, 60.0)
            else:
                print(f"  SSH failed after {retries} attempts: {e.stderr.strip()}")
                raise


def rewrite_names(raw: str) -> str:
    """Rename the default context/cluster/user to ceph-lab-* names."""
    raw = re.sub(r"\bcluster: default\b", f"cluster: {CLUSTER_NAME}", raw)
    raw = re.sub(r"\buser: default\b", f"user: {USER_NAME}", raw)
    raw = re.sub(r"\bname: default\b", f"name: {CONTEXT_NAME}", raw)
    raw = re.sub(r"\bcurrent-context: default\b", f"current-context: {CONTEXT_NAME}", raw)
    return raw


def add_kube_config() -> None:
    KUBE_CONFIG.parent.mkdir(parents=True, exist_ok=True)
    new_config = rewrite_names(fetch_kubeconfig())

    with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as f:
        f.write(new_config)
        tmp_path = f.name

    try:
        env = os.environ.copy()
        env["KUBECONFIG"] = f"{KUBE_CONFIG}:{tmp_path}"
        result = subprocess.run(
            ["kubectl", "config", "view", "--flatten"],
            capture_output=True,
            text=True,
            check=True,
            env=env,
        )
        KUBE_CONFIG.write_text(result.stdout)
        KUBE_CONFIG.chmod(0o600)
    finally:
        os.unlink(tmp_path)

    subprocess.run(
        ["kubectl", "config", "use-context", CONTEXT_NAME],
        check=True,
    )
    print(f"  kubeconfig updated — context: {CONTEXT_NAME}")


def remove_kube_config() -> None:
    for cmd in [
        ["kubectl", "config", "delete-context", CONTEXT_NAME],
        ["kubectl", "config", "delete-cluster", CLUSTER_NAME],
        ["kubectl", "config", "delete-user", USER_NAME],
    ]:
        try:
            subprocess.run(cmd, check=True, capture_output=True)
        except subprocess.CalledProcessError:
            pass  # already absent
    print(f"  Removed kubeconfig context/cluster/user for {CONTEXT_NAME}")


# ── Entrypoint ────────────────────────────────────────────────────────────────


def main() -> None:
    if len(sys.argv) < 2 or sys.argv[1] not in ("add", "remove"):
        print(f"Usage: {sys.argv[0]} add|remove")
        sys.exit(1)

    action = sys.argv[1]

    if action == "add":
        print("Adding ceph-lab kubeconfig + SSH entries...")
        keys = scan_vms()
        if not keys:
            print("  WARNING: No Vagrant private keys found. Run 'vagrant up' first.")
        update_ssh_config(keys)
        if keys.get("ceph-control"):
            add_kube_config()
        else:
            print("  WARNING: ceph-control not found; skipping kubeconfig merge.")
        print("Done.")

    elif action == "remove":
        print("Removing ceph-lab kubeconfig + SSH entries...")
        remove_ssh_config()
        remove_kube_config()
        print("Done.")


if __name__ == "__main__":
    main()
