#!/usr/bin/env python3
"""Manage Kubernetes configuration for the Lima-based ceph-lab cluster.

Equivalent to the old Vagrant trigger helpers:
  add    — merge kubeconfig + write SSH host aliases
  remove — strip kubeconfig context + SSH host aliases

Requires Python 3.8+.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Dict, List, Optional


def _load_cluster_env() -> None:
    """Load provisioning/provision.env defaults into os.environ.

    Real environment variables always win (setdefault semantics), so this is
    safe to call unconditionally.  provision.env lives one level above this
    script (provisioning/scripts/ → provisioning/).
    """
    env_file = Path(__file__).parent.parent / "provision.env"
    if not env_file.exists():
        return
    for line in env_file.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, _, value = line.partition("=")
        # Strip inline comments
        value = value.split("#")[0].strip()
        os.environ.setdefault(key.strip(), value)


_load_cluster_env()

# Configuration — resolved from provision.env (or real env vars / hard-coded fallbacks)
CONTROL_PLANE_IP = os.environ.get("SANDBOX_CONTROL_PLANE_IP", "192.168.56.50")
NODE_IP_BASE = int(os.environ.get("SANDBOX_CEPH_NODE_IP_BASE", "60"))

KUBE_CONFIG_PATH = Path.home() / ".kube" / "config"
SSH_CONFIG_PATH = Path.home() / ".ssh" / "config"

# Lima uses a single shared SSH identity key for all VMs.
LIMA_SSH_KEY = Path.home() / ".lima" / "_config" / "user"

# Context names used in the merged kubeconfig
NEW_CONTEXT_NAME = "ceph-lab"
NEW_USER_NAME = "ceph-lab-admin"
NEW_CLUSTER_NAME = "ceph-lab-cluster"


def get_vm_ip(name: str) -> Optional[str]:
    """Calculate static VM IP from the naming convention in provision.env."""
    if name == "ceph-control":
        return CONTROL_PLANE_IP

    match = re.match(r"ceph-node-(\d+)", name)
    if match:
        n = int(match.group(1))
        return f"192.168.56.{NODE_IP_BASE + n}"

    return None


def scan_vms() -> List[Dict[str, str]]:
    """Enumerate running ceph-* Lima instances via `limactl list --json`."""
    try:
        result = subprocess.run(
            ["limactl", "list", "--json"],
            capture_output=True,
            text=True,
            check=True,
        )
    except FileNotFoundError:
        print("limactl not found. Install Lima: brew install lima")
        return []
    except subprocess.CalledProcessError as e:
        print(f"limactl list failed: {e.stderr.strip()}")
        return []

    # limactl outputs one JSON object per line
    vms = []
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            instance = json.loads(line)
        except json.JSONDecodeError:
            continue

        name = instance.get("name", "")
        if not name.startswith("ceph-"):
            continue

        status = instance.get("status", "")
        if status not in ("Running", "Stopped"):
            continue

        ip = get_vm_ip(name)
        if not ip:
            print(f"Warning: could not determine IP for {name}")
            continue

        key_path = (
            str(LIMA_SSH_KEY) if LIMA_SSH_KEY.exists() else str(Path.home() / ".ssh" / "id_rsa")
        )

        vms.append({"name": name, "ip": ip, "key_path": key_path})

    return sorted(vms, key=lambda x: x["name"])


def backup_file(path: Path) -> None:
    """Create a timestamped backup of a file."""
    if path.exists():
        timestamp = int(time.time())
        backup_path = path.with_suffix(f".bak.{timestamp}")
        shutil.copy2(path, backup_path)
        print(f"Backed up {path.name} to {backup_path.name}")


def update_ssh_config(vms: List[Dict[str, str]]) -> None:
    """Add or update SSH config entries for all ceph-* VMs."""
    if not vms:
        print("No VMs found to configure.")
        return

    print(f"Updating SSH config for {len(vms)} nodes...")

    if not SSH_CONFIG_PATH.exists():
        SSH_CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
        SSH_CONFIG_PATH.touch(mode=0o600)

    backup_file(SSH_CONFIG_PATH)
    content = SSH_CONFIG_PATH.read_text(encoding="utf-8")

    # Remove existing ceph-* blocks to avoid duplication
    lines = content.splitlines()
    new_lines: List[str] = []
    skip = False

    for line in lines:
        if line.strip().startswith("Host ceph-"):
            skip = True

        if skip:
            if line.strip() == "":
                skip = False
                continue
            elif line.strip().startswith("Host ") and not line.strip().startswith("Host ceph-"):
                skip = False
            else:
                continue

        new_lines.append(line)

    # Generate new blocks
    new_blocks = []
    for vm in vms:
        block = f"""
Host {vm["name"]}
    HostName {vm["ip"]}
    User {os.environ.get("USER", "ubuntu")}
    IdentityFile {vm["key_path"]}
    IdentitiesOnly yes
    PreferredAuthentications publickey
    PubkeyAuthentication yes
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
"""
        new_blocks.append(block)

    output = "\n".join(new_lines).rstrip() + "\n" + "".join(new_blocks)

    with open(SSH_CONFIG_PATH, "w", encoding="utf-8") as f:
        f.write(output)

    SSH_CONFIG_PATH.chmod(0o600)
    print("SSH config updated.")


def remove_ssh_config() -> None:
    """Remove all ceph-* entries from SSH config."""
    if not SSH_CONFIG_PATH.exists():
        print("SSH config not found.")
        return

    print("Removing all ceph-* entries from SSH config...")
    content = SSH_CONFIG_PATH.read_text(encoding="utf-8")

    lines = content.splitlines()
    new_lines: List[str] = []
    skip = False

    for line in lines:
        if line.strip().startswith("Host ceph-"):
            skip = True

        if skip:
            if line.strip() == "":
                skip = False
                continue
            elif line.strip().startswith("Host ") and not line.strip().startswith("Host ceph-"):
                skip = False
            else:
                continue

        new_lines.append(line)

    output = "\n".join(new_lines)

    if len(lines) != len(new_lines):
        backup_file(SSH_CONFIG_PATH)
        SSH_CONFIG_PATH.write_text(output + "\n", encoding="utf-8")
        print("Removed SSH config entries.")
    else:
        print("No ceph-* entries found.")


def add_kube_config(vms: List[Dict[str, str]]) -> None:
    """Fetch and merge kubeconfig from ceph-control via limactl shell."""
    cp_vm = next((vm for vm in vms if vm["name"] == "ceph-control"), None)

    if not cp_vm:
        print("Error: ceph-control not found in active VMs. Cannot update kubeconfig.")
        return

    print(f"Fetching kubeconfig from {cp_vm['name']} via limactl shell...")

    # k3s writes admin kubeconfig to /root/.kube/config
    cmd = ["limactl", "shell", cp_vm["name"], "sudo", "cat", "/root/.kube/config"]
    try:
        result = subprocess.run(cmd, check=True, capture_output=True, text=True)
    except subprocess.CalledProcessError as e:
        print(f"Failed to fetch kubeconfig: {e.stderr.strip()}")
        return

    tmpdir = Path(tempfile.mkdtemp(prefix="ceph_lab_k8s_"))
    temp_conf = tmpdir / "k3s.yaml"
    merged_conf = tmpdir / "kubeconfig.merged"
    try:
        temp_conf.write_text(result.stdout, encoding="utf-8")

        print("Renaming kubeconfig context to ceph-lab...")
        content = temp_conf.read_text(encoding="utf-8")
        # k3s names everything "default" — rename to ceph-lab-* for clarity.
        # Use multiline patterns for list entries (clusters: precedes contexts: in
        # k3s output, so a simple count=1 replacement would hit the cluster name first).
        content = content.replace("current-context: default", f"current-context: {NEW_CONTEXT_NAME}")
        content = re.sub(r"\bcluster: default\b", f"cluster: {NEW_CLUSTER_NAME}", content)
        content = re.sub(r"\buser: default\b", f"user: {NEW_USER_NAME}", content)
        content = re.sub(
            r"(- context:(?:.|\n)*?name:)\s+default",
            rf"\1 {NEW_CONTEXT_NAME}",
            content,
        )
        content = re.sub(
            r"(- cluster:(?:.|\n)*?name:)\s+default",
            rf"\1 {NEW_CLUSTER_NAME}",
            content,
        )
        # k3s user list entries use "- name: default\n  user:" format (no leading "- user:")
        content = re.sub(
            r"(?m)^- name:\s+default$",
            f"- name: {NEW_USER_NAME}",
            content,
        )
        temp_conf.write_text(content, encoding="utf-8")

        print("Merging kubeconfig...")
        env = os.environ.copy()
        if KUBE_CONFIG_PATH.exists():
            env["KUBECONFIG"] = f"{temp_conf}:{KUBE_CONFIG_PATH}"
        else:
            env["KUBECONFIG"] = str(temp_conf)

        try:
            with open(merged_conf, "w") as f:
                subprocess.run(
                    ["kubectl", "config", "view", "--flatten"],
                    env=env,
                    stdout=f,
                    check=True,
                )
        except subprocess.CalledProcessError:
            print("Failed to merge kubeconfig.")
            return

        backup_file(KUBE_CONFIG_PATH)
        KUBE_CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(merged_conf), KUBE_CONFIG_PATH)
        KUBE_CONFIG_PATH.chmod(0o600)
        print(f"Kubeconfig updated. Context '{NEW_CONTEXT_NAME}' is now current.")
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def remove_kube_config() -> None:
    """Remove ceph-lab context, user, and cluster from kubeconfig."""
    print("Removing ceph-lab Kubernetes configuration...")

    cmds = [
        ["kubectl", "config", "delete-context", NEW_CONTEXT_NAME],
        ["kubectl", "config", "delete-context", NEW_CLUSTER_NAME],  # rogue duplicate from buggy run
        ["kubectl", "config", "delete-cluster", NEW_CLUSTER_NAME],
        ["kubectl", "config", "delete-cluster", NEW_CONTEXT_NAME],  # legacy: older script versions named the cluster "ceph-lab"
        ["kubectl", "config", "delete-user", NEW_USER_NAME],
    ]

    for cmd in cmds:
        try:
            subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass

    print("Kubeconfig cleaned up (best effort).")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Manage kubeconfig and SSH config for the ceph-lab Lima cluster."
    )
    parser.add_argument("action", choices=["add", "remove"], help="Action to perform")
    args = parser.parse_args()

    if args.action == "add":
        vms = scan_vms()
        update_ssh_config(vms)
        add_kube_config(vms)
    elif args.action == "remove":
        remove_ssh_config()
        remove_kube_config()


if __name__ == "__main__":
    main()
