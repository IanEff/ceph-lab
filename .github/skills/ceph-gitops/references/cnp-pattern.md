# CiliumNetworkPolicy Pattern — ceph-lab

All policies live in `applications/infrastructure/l7-policies/`. Applied at sync wave `1`.

## Annotated Template

```yaml
# L7 visibility for the <namespace> namespace.
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: l7-visibility        # Always named l7-visibility — one policy per namespace
  namespace: <namespace>
spec:
  endpointSelector: {}       # Applies to all pods in the namespace

  ingress:
    # --- HTTP ports (L7 visibility) ---
    - fromEntities: [cluster]
      toPorts:
        - ports:
            - { port: "8080", protocol: TCP }   # your HTTP port
          rules:
            http: [{}]                          # empty rule = capture all HTTP flows

    # --- Non-HTTP ports (L4 only — no rules: block) ---
    - fromEntities: [cluster]
      toPorts:
        - ports:
            - { port: "9000", protocol: TCP }   # e.g. gRPC, raw TCP
            # no rules: key means L4 only

    # --- kubelet health probes (always include if pods have liveness probes) ---
    - fromEntities: [host, remote-node]

  egress:
    # --- DNS (required for all namespaces) ---
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - { port: "53", protocol: UDP }
            - { port: "53", protocol: TCP }
          rules:
            dns:
              - matchPattern: "*"

    # --- kube-apiserver + outbound HTTPS ---
    - toEntities: [cluster, kube-apiserver, world]
      toPorts:
        - ports:
            - { port: "443",  protocol: TCP }
            - { port: "6443", protocol: TCP }   # kube-apiserver

    # --- Intra-namespace (if pods talk to each other) ---
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: <namespace>
```

## Decision Guide

| Situation | What to do |
|---|---|
| App exposes HTTP/REST | Add port to `fromEntities: [cluster]` block with `rules: http: [{}]` |
| App exposes gRPC or raw TCP | Add port to a **separate** `fromEntities: [cluster]` block with **no** `rules:` |
| App needs to talk to other pods in same namespace | Add intra-namespace egress `toEndpoints` block |
| App makes outbound HTTP calls | Add `port: "80"` to the world/cluster egress block |
| App receives traffic from kubelet | Add `fromEntities: [host, remote-node]` ingress rule |
| App is a webhook called by kube-apiserver | Add `fromEntities: [kube-apiserver]` ingress rule (see `cnp-rook-ceph.yaml`) |
| App needs git over SSH (e.g. ArgoCD) | Add `port: "22"` to world egress (see `cnp-argocd.yaml`) |

## Adding to the Kustomization

After creating `cnp-<namespace>.yaml`, add it to `applications/infrastructure/l7-policies/kustomization.yaml`:

```yaml
resources:
  - cnp-argocd.yaml
  - cnp-monitoring.yaml
  - cnp-rook-ceph.yaml
  - cnp-<namespace>.yaml   # ← add here
```

## Existing Policies for Reference

| File | Namespace | Notable patterns |
|---|---|---|
| `cnp-argocd.yaml` | `argocd` | SSH egress (port 22) for git operations |
| `cnp-monitoring.yaml` | `monitoring` | Multiple HTTP ports, pushgateway |
| `cnp-rook-ceph.yaml` | `rook-ceph` | L4-only Ceph MON/OSD/MDS ports, webhook ingress from kube-apiserver |
| `cnp-ceph-clients.yaml` | `ceph-clients` | Client-side Ceph traffic patterns |

## Why L7 Rules Matter

Without `rules: http: [{}]`, Cilium tracks the flow at L4 only — you see source/dest IP and port in Hubble but no HTTP method, path, or status code. Adding the empty HTTP rule enables full L7 visibility without restricting any traffic.
