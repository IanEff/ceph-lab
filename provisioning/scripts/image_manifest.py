#!/usr/bin/env python3
"""Discover every container image the ceph-lab GitOps tree declares.

Renders every `kustomization.yaml` under `applications/` and
`cluster-bootstrap/` with `kubectl kustomize --enable-helm` (the same flag
ArgoCD's repo-server uses, via cluster-bootstrap/argocd's
`kustomize.buildOptions` patch) and regex-extracts `image:` references from
the rendered manifests. Used by `build_golden_image.sh` to know what to
pre-pull into containerd, and standalone via `--list` to just show the
inventory (`task list-images`).

Bootstrap-time images that never appear in a kustomization (ArgoCD itself,
Cilium/Hubble — installed by install_cilium.sh/install_argocd.sh before
ArgoCD exists) are synthesized from provisioning/provision.env so they get
pre-cached too.
"""

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Dict, List, Set

REPO_ROOT = Path(__file__).resolve().parent.parent.parent


def load_env_file(filepath: Path) -> Dict[str, str]:
    env: Dict[str, str] = {}
    if not filepath.is_file():
        return env
    for line in filepath.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        env[key.strip()] = val.strip().strip("\"'")
    return env


def pinned_bootstrap_images(provision_env: Dict[str, str]) -> Set[str]:
    """Images installed outside ArgoCD's own reconciliation (VM-boot time)."""
    cilium_ver = provision_env.get("CILIUM_VERSION", "1.19.3")
    cilium_tag = cilium_ver if cilium_ver.startswith("v") else f"v{cilium_ver}"
    argocd_ver = provision_env.get("ARGOCD_VERSION", "stable")
    argocd_tag = argocd_ver if (argocd_ver.startswith("v") or argocd_ver in ("stable", "latest")) else f"v{argocd_ver}"

    images = {
        f"quay.io/cilium/cilium:{cilium_tag}",
        f"quay.io/cilium/operator-generic:{cilium_tag}",
    }
    if argocd_tag not in ("stable", "latest"):
        images.add(f"quay.io/argoproj/argocd:{argocd_tag}")
    return images


def find_kustomize_dirs(search_roots: List[Path]) -> List[Path]:
    dirs = []
    for root in search_roots:
        if not root.is_dir():
            continue
        for dirpath, _dirnames, filenames in os.walk(root):
            if "kustomization.yaml" in filenames or "kustomization.yml" in filenames:
                dirs.append(Path(dirpath))
    return dirs


def render_kustomization(kdir: Path) -> str | None:
    try:
        res = subprocess.run(
            ["kubectl", "kustomize", str(kdir), "--enable-helm"],
            capture_output=True,
            text=True,
            timeout=60,
        )
        if res.returncode == 0 and res.stdout.strip():
            return res.stdout
    except Exception:
        pass
    return None


IMAGE_LINE_RE = re.compile(r"^\s*image:\s*[\"']?([^\s\"']+)[\"']?")


def extract_images(text: str, found: Set[str]) -> None:
    for line in text.splitlines():
        line = line.strip()
        m = IMAGE_LINE_RE.match(line)
        if not m:
            continue
        img = m.group(1).strip()
        if "GITOPS_REPO_URL" in img or "PLACEHOLDER" in img or "${" in img or "{{" in img:
            continue
        found.add(img)


# Test fixtures pulled in by subchart helm-test hooks — never actually
# scheduled by the real GitOps tree, not worth pre-caching.
TEST_FIXTURE_IMAGES = ("bats/bats", "loki-helm-test")


def normalize(img: str) -> str | None:
    img = img.strip().strip("\"'")
    if not img or ":" not in img:
        return None
    if any(bad in img for bad in TEST_FIXTURE_IMAGES):
        return None
    if any(c in img for c in ["{{", "}}", "$", "<", ">", " ", "\\"]):
        return None
    if img.endswith((":null", ":None", ":")):
        return None
    if "@sha256:" in img:
        img = img.split("@sha256:")[0]

    parts = img.split("/", 1)
    if len(parts) == 1:
        return f"docker.io/library/{img}"
    domain = parts[0]
    if "." not in domain and ":" not in domain and domain != "localhost":
        return f"docker.io/{img}"
    return img


def scan_repo() -> List[str]:
    provision_env = load_env_file(REPO_ROOT / "provisioning" / "provision.env")
    found: Set[str] = set(pinned_bootstrap_images(provision_env))

    kdirs = find_kustomize_dirs([REPO_ROOT / "applications", REPO_ROOT / "cluster-bootstrap"])
    for kdir in kdirs:
        rendered = render_kustomization(kdir)
        if rendered:
            extract_images(rendered, found)

    normalized = {normalize(img) for img in found}
    normalized.discard(None)
    return sorted(normalized)  # type: ignore[arg-type]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true", help="print the discovered image inventory and exit")
    parser.add_argument("--out", default=None, help="write the flat image list to this file (one per line)")
    args = parser.parse_args()

    images = scan_repo()

    if args.out:
        Path(args.out).write_text("\n".join(images) + "\n")

    if args.list or not args.out:
        print(f"Discovered {len(images)} container images:\n")
        for img in images:
            print(f"  {img}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(1)
