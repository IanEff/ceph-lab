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
            f"  IdentitiesOnly yes",
            f"  PreferredAuthentications publickey",
            f"  PubkeyAuthentication yes",
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


def fetch_kubeconfig(retries: int = 6, delay: float = 10.0) -> str:  # type: ignore
    """SCP the kubeconfig directly from the control plane using its Vagrant key."""
    keys = scan_vms()
    key_path = keys.get("ceph-control")
    if not key_path:
        raise RuntimeError("ceph-control private key not found — has vagrant up run?")

    for attempt in range(1, retries + 1):
        try:
            with tempfile.NamedTemporaryFile(mode="r", suffix=".yaml", delete=False) as f:
                tmp_path = f.name
            result = subprocess.run(
                [
                    "scp",
                    "-o",
                    "StrictHostKeyChecking=no",
                    "-o",
                    "UserKnownHostsFile=/dev/null",
                    "-o",
                    "IdentitiesOnly=yes",
                    "-o",
                    f"ConnectTimeout=15",
                    "-i",
                    key_path,
                    f"vagrant@{CONTROL_PLANE_IP}:/home/vagrant/.kube/config",
                    tmp_path,
                ],
                capture_output=True,
                text=True,
                check=True,
            )
            content = Path(tmp_path).read_text()
            Path(tmp_path).unlink(missing_ok=True)
            return content
        except subprocess.CalledProcessError as e:
            Path(tmp_path).unlink(missing_ok=True)
            if attempt < retries:
                msg = e.stderr.strip() or f"exit {e.returncode}"
                print(
                    f"  SCP attempt {attempt}/{retries} failed ({msg}); retrying in {delay:.0f}s…"
                )
                time.sleep(delay)
                delay = min(delay * 1.5, 60.0)
            else:
                print(f"  SCP failed after {retries} attempts: {e.stderr.strip()}")
                raise


def rewrite_names(raw: str) -> str:
    """Rename the default context/cluster/user to ceph-lab-* names.

    k3s uses 'default' for all three.  We use the surrounding YAML structure
    (the same technique as sandbox-rook) to distinguish cluster / context / user
    entries so each gets the right target name.
    """
    # Cluster list entry: `  name: default` immediately before `contexts:`
    raw = raw.replace(
        "  name: default\ncontexts:",
        f"  name: {CLUSTER_NAME}\ncontexts:",
    )
    # Context block references
    raw = raw.replace("    cluster: default", f"    cluster: {CLUSTER_NAME}")
    raw = raw.replace("    user: default", f"    user: {USER_NAME}")
    # Context list entry name (preceded by the user line we just rewrote)
    raw = raw.replace(
        f"    user: {USER_NAME}\n  name: default\n",
        f"    user: {USER_NAME}\n  name: {CONTEXT_NAME}\n",
    )
    raw = raw.replace("current-context: default", f"current-context: {CONTEXT_NAME}")
    # User list entry name
    raw = raw.replace(f"\n- name: default\n  user:", f"\n- name: {USER_NAME}\n  user:")
    return raw


def add_kube_config() -> None:
    KUBE_CONFIG.parent.mkdir(parents=True, exist_ok=True)
    new_config = rewrite_names(fetch_kubeconfig())

    with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as f:
        f.write(new_config)
        tmp_path = f.name

    try:
        # Remove any stale ceph-lab entries before merging so old certs don't linger
        for cmd in [
            ["kubectl", "config", "delete-context", CONTEXT_NAME],
            ["kubectl", "config", "delete-cluster", CLUSTER_NAME],
            ["kubectl", "config", "delete-user", USER_NAME],
        ]:
            subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        env = os.environ.copy()
        env["KUBECONFIG"] = f"{tmp_path}:{KUBE_CONFIG}" if KUBE_CONFIG.exists() else tmp_path
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


# ── CA trust helper ───────────────────────────────────────────────────────────


def trust_ca() -> None:
    """Extract the fixed ceph-lab CA cert and trust it in the macOS System Keychain.

    Because the CA keypair is committed to the repo and never regenerated, this
    only needs to take effect once — the fingerprint check prevents re-prompting
    for sudo on subsequent 'manage_k8s_config.py add' calls.
    """
    import tempfile as _tmpfile

    cert_file = Path(_tmpfile.gettempdir()) / "ceph-lab-ca.crt"

    print("  Extracting ceph-lab CA cert...")
    try:
        result = subprocess.run(
            [
                "kubectl",
                "get",
                "secret",
                "ceph-lab-ca-keypair",
                "-n",
                "cert-manager",
                "--context",
                CONTEXT_NAME,
                "-o",
                "jsonpath={.data.tls\\.crt}",
            ],
            capture_output=True,
            text=True,
            check=True,
        )
    except subprocess.CalledProcessError:
        print(
            "  WARNING: ceph-lab-ca-keypair secret not found — cert-manager may still be syncing."
        )
        print("  Run 'bash provisioning/scripts/trust_ca.sh' after the cluster is ready.")
        return

    import base64 as _b64

    cert_pem = _b64.b64decode(result.stdout.strip()).decode()
    cert_file.write_text(cert_pem)

    # Check if already trusted
    fp_result = subprocess.run(
        ["openssl", "x509", "-noout", "-fingerprint", "-sha256", "-in", str(cert_file)],
        capture_output=True,
        text=True,
    )
    fingerprint = fp_result.stdout.split("=", 1)[-1].strip().replace(":", "").upper()

    already_trusted = False
    try:
        certs_result = subprocess.run(
            ["security", "find-certificate", "-Z", "-a", "/Library/Keychains/System.keychain"],
            capture_output=True,
            text=True,
        )
        if fingerprint in certs_result.stdout.upper():
            already_trusted = True
    except Exception:
        pass

    if already_trusted:
        print("  CA cert already trusted in System Keychain — skipping.")
        return

    print("  Trusting CA cert in macOS System Keychain (requires sudo)...")
    try:
        subprocess.run(
            [
                "sudo",
                "security",
                "add-trusted-cert",
                "-d",
                "-r",
                "trustRoot",
                "-k",
                "/Library/Keychains/System.keychain",
                str(cert_file),
            ],
            check=True,
        )
        print("  CA cert trusted. *.ceph.lab TLS will be valid in browsers and argocd CLI.")
    except subprocess.CalledProcessError:
        print("  WARNING: Failed to trust CA cert. Run manually:")
        print(
            f"    sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain {cert_file}"
        )


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
            trust_ca()
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
