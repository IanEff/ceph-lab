---
name: ceph-gitops
description: 'Author, wire, and troubleshoot GitOps components in this ceph-lab repo. Use for: adding a new ArgoCD infra component, choosing the right sync wave, wiring cluster-wide config via Kustomize replacements, adding CiliumNetworkPolicies, integrating Helm via kustomize helmCharts, GITOPS_REPO_URL placeholder rules, and Rook/Ceph ArgoCD prune policies.'
argument-hint: 'What are you adding or changing? (e.g. "add Velero at wave 5", "CNP for monitoring namespace")'
---

# ceph-gitops

GitOps authoring assistant for this Rook/Ceph k3s lab. Covers the three main workflows: adding infrastructure components, wiring cluster-wide config, and writing CiliumNetworkPolicies.

## When to Use

- Adding a new infra component (Helm chart or plain manifests)
- Wiring a component to use cluster IPs / hostnames from `gitops.env`
- Writing or modifying a `CiliumNetworkPolicy` for L7 visibility
- Choosing the right ArgoCD sync wave, prune, and selfHeal settings
- Debugging why a component isn't being picked up by the `ApplicationSet`
- Understanding the `GITOPS_REPO_URL` placeholder and substitution flow

---

## Workflow 1: Add a New Infrastructure Component

### 1. Create the component directory

```
applications/infrastructure/<name>/
├── config.json          # Required: tells the ApplicationSet about this app
├── kustomization.yaml   # Kustomize entry point
└── <manifests or helm>  # Manifests, helmCharts: stanza, or wrapper Chart.yaml
```

### 2. Author `config.json`

Use [./assets/config.json.template](./assets/config.json.template). Fill in:

| Field | Example | Notes |
|---|---|---|
| `appName` | `"velero"` | Must be unique; becomes ArgoCD app name |
| `syncWave` | `"5"` | See [./references/sync-waves.md](./references/sync-waves.md) |
| `namespace` | `"velero"` | Target namespace for the app |
| `localPath` | `"applications/infrastructure/velero"` | Relative from repo root |

### 3. Author `kustomization.yaml`

**Does this component need cluster IPs, CIDRs, or hostnames?**

- **Yes** → add `components: [../../config]` and wire `replacements:`. Read [Cluster Config Wiring](#workflow-2-wire-cluster-wide-config) below.
- **No** → omit the `components:` stanza entirely.

**Helm chart?** Two options:

**Option A — Inline Helm** (no `Chart.yaml` needed):
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: velero
components:
  - ../../config          # only if cluster config is needed

helmCharts:
  - name: velero
    repo: https://vmware-tanzu.github.io/helm-charts
    version: "7.3.0"
    releaseName: velero
    namespace: velero
    valuesFile: values.yaml
```

**Option B — Wrapper Chart** (for complex overlays or when post-render patches are needed):
```yaml
# Chart.yaml
apiVersion: v2
name: velero-wrapper
version: 0.1.0
dependencies:
  - name: velero
    repository: https://vmware-tanzu.github.io/helm-charts
    version: "7.3.0"
```
```yaml
# kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: velero
helmCharts:
  - name: velero-wrapper
    releaseName: velero
    namespace: velero
    valuesFile: values.yaml
```

### 4. If the component exposes HTTP endpoints

Add an HTTPRoute in the component directory and a `CiliumNetworkPolicy` in `applications/infrastructure/l7-policies/`. See [Workflow 3](#workflow-3-write-a-ciliumnetworkpolicy).

### 5. Commit and push

ArgoCD's `infra-set.yaml` uses a Git generator — it will pick up the new `config.json` automatically on the next sync cycle. **No changes to `infra-set.yaml` are needed.**

---

## Workflow 2: Wire Cluster-Wide Config

All cluster constants live in `applications/config/gitops.env`. The Kustomize `Component` at `applications/config/kustomization.yaml` generates a `cluster-config` ConfigMap and uses `replacements:` to patch fields in specific resources.

**Never hardcode IPs, CIDRs, or hostnames in component manifests.**

### Steps

1. Add your component to `components: [../../config]` in its `kustomization.yaml`.

2. Identify which fields need cluster values. Common values from `gitops.env`:

| Variable | Typical use |
|---|---|
| `LB_CIDR` | `CiliumLoadBalancerIPPool.spec.blocks.0.cidr` |
| `GATEWAY_IP` | Gateway listener addresses |
| `ARGOCD_HOSTNAME`, `GRAFANA_HOSTNAME`, etc. | `HTTPRoute.spec.hostnames.0` |
| `ROOK_VERSION`, `CILIUM_VERSION` | `helmCharts[0].version` |

3. Add a `replacements:` entry in `applications/config/kustomization.yaml`:

```yaml
- source:
    kind: ConfigMap
    name: cluster-config
    fieldPath: data.YOUR_VARIABLE
  targets:
    - select:
        kind: YourResourceKind
        name: your-resource-name
      fieldPaths:
        - spec.path.to.field
```

4. Test locally with:
```bash
kubectl kustomize --enable-helm applications/infrastructure/<name>
```

---

## Workflow 3: Write a CiliumNetworkPolicy

All policies live in `applications/infrastructure/l7-policies/`. See [./references/cnp-pattern.md](./references/cnp-pattern.md) for the full annotated template.

### Quick checklist

- [ ] File named `cnp-<namespace>.yaml`
- [ ] Added to `kustomization.yaml` resources list in `l7-policies/`
- [ ] `endpointSelector: {}` (applies to whole namespace)
- [ ] Ingress: `fromEntities: [cluster]` + HTTP L7 rules for app ports
- [ ] Egress: DNS rule to `kube-system/kube-dns` with `matchPattern: "*"` + HTTPS world/apiserver

---

## Key Constraints

- **`/dev/sdb` is never an OSD** — k3s data disk. `deviceFilter: "^sd[cd]"` in `cephcluster.yaml`.
- **`GITOPS_REPO_URL` stays literal in source** — `install_argocd.sh` substitutes it via `sed`. Never commit the substituted URL.
- **`--enable-helm` is required** for `helmCharts:` stanzas — already patched into `argocd-cm`.
- **Rook apps are protected** — `rook-operator` (`prune: false`) and `rook-cluster` (`prune: false`, `selfHeal: false`) are intentional; do not change.
- **`CephFilesystemSubVolumeGroup` is mandatory** (Rook ≥ v1.17) — already in `rook/storage/filesystem.yaml`; don't remove it.
