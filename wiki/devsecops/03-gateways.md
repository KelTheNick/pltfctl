# Gateways

This page covers how traffic gets from the workstation into a cluster. There is exactly one way in: a shared Gateway API gateway, served by kgateway, on each cluster's LB port.

## kgateway and Gateway API

Gateway API is the Kubernetes standard for routing external traffic (`Gateway`, `HTTPRoute` and related resources). kgateway is an Envoy-based implementation of it.

- The Gateway API standard-channel CRDs are applied by `up`, outside Flux, at the version pinned in `.env.sbom`. The `kgateway-crds` chart ships only kgateway's own CRDs (`gateway.kgateway.dev`), not the standard ones (`scripts/lib/pltfctl/flux.sh`, `deploy/k3d-base/kube-system/kgateway.yaml`).
- Flux installs two HelmReleases in `kube-system`: `kgateway-crds`, then `kgateway`, which `dependsOn` the first. Both come from the `kgateway` OCI HelmRepository at `oci://cr.kgateway.dev/kgateway-dev/charts`, which lives in `flux-system` (`deploy/k3d-base/kube-system/kgateway.yaml`, `deploy/k3d-base/flux-system/repositories.yaml`).
- Every distro gets the same gateway manifests from `deploy/k3d-base/`, which `up` applies to every cluster. Nothing is symlinked for them.

## Traefik is disabled

k3s ships Traefik as its default ingress. Every template passes `--disable=traefik`, so the Gateway is the only way in from the host network (`infra/k3d/*/*.yaml`).

## The single shared Gateway

There is one Gateway, `gw-api-kgateway` in `kube-system`, with one listener (`deploy/k3d-base/kube-system/gateway.yaml`):

| Listener | Protocol | Port | Allowed routes |
|---|---|---|---|
| `http` | HTTP | 80 | from all namespaces |

A `GatewayParameters` resource forces the proxy Service to type `LoadBalancer` on port 80. k3d's servicelb binds port 80 on the nodes, and the k3d serverlb publishes it on the host LB port.

There is no HTTPS listener. The HTTPS host port is reserved in the k3d port maps only; adding a 443 listener later needs no cluster rebuild, because the host port map already exists (`deploy/k3d-base/kube-system/gateway.yaml`).

## LB port per cluster

| Cluster | Host LB HTTP | Host LB HTTPS (reserved, nothing listens) |
|---|---|---|
| `lite`, `dev`, `op-1` | 8080 | 8443 |
| `op-2` | 9080 | 9443 |
| `op-3` | 7080 | 7443 |

Source: `infra/fleet.env`. Every code path takes the port from `pltf_lb_http_port`, which reads `fleet.env`, the same file the k3d configs are rendered from, so the two cannot drift (`scripts/lib/pltfctl/cmds.sh`).

## Rule: never a new host port

Expose a new service as an `HTTPRoute` on the shared Gateway, not as a new host port. Host port maps can only be declared when a cluster is created, so a new one forces `down` + `up` of the whole distro. Ports also follow a fixed 4-digit convention and must be unique within a distro (`infra/fleet.env`, `infra/k3d/*/*.yaml`, `docs/contributing/03-fleet.md`).

## Hostname scheme

Route hostnames follow `[<prefix>-]<ui>.k3d.workbench.local.gd` (`PLTF_DOMAIN` in `infra/fleet.env`). `local.gd` is a public wildcard domain that resolves to `127.0.0.1`.

| Cluster | Prefix | Example |
|---|---|---|
| `lite`, `dev` | none | `argus.k3d.workbench.local.gd` |
| `op-1`, `op-2`, `op-3` | `op-1`, `op-2`, `op-3` (the cluster name) | `op-2-argus.k3d.workbench.local.gd` |

The prefix makes a URL name the cluster that serves it, even when the port was copied from another cluster's URL (`scripts/README.md`).

## The PLTF_HOST_PREFIX allow-list

The `deploy/` tree is one set of files for every cluster, but the `fleet` clusters must not all claim the same hostnames. Route hosts are written as `${PLTF_HOST_PREFIX}<ui>.k3d.workbench.local.gd`. `flux_apply_file` fills the placeholder with the cluster's `<prefix>-` or with nothing (`scripts/lib/pltfctl/flux.sh`).

`envsubst` is given this one variable by name: `envsubst '${PLTF_HOST_PREFIX}'`. A bare `envsubst` would rewrite every other `$` in the YAML. A second variable on the allow-list would be a second route for per-cluster values into the shared tree, which must stay cluster-agnostic (`scripts/README.md`).

## Gateway proxy readiness wait

The proxy Deployment, `gw-api-kgateway`, is created by the kgateway controller only after its HelmRelease is Ready and the Gateway is reconciled. So "every HelmRelease Ready" still leaves a window where nothing listens on the LB port; on `lite` the proxy appeared about 50s after `up` had returned. `up` now waits up to 5 minutes for the proxy to exist and roll out. The wait is non-fatal; `status` reports the outcome (`pltf_wait_gateway` in `scripts/lib/pltfctl/cmds.sh`).

## Smoke routes

Flux has no `helm test`, so permanent smoke-test routes stand in for it:

| Host | Backend | Purpose | Source |
|---|---|---|---|
| `[<prefix>-]podinfo.k3d.workbench.local.gd` | `podinfo` Service, port 9898, in `kube-public` | proves an end-to-end data-plane request | `deploy/k3d-base/kube-public/podinfo.yaml` |
| `[<prefix>-]gateway.k3d.workbench.local.gd/readyz` | `kgateway` Service, port 9093, in `kube-system` | a known-good URL for bootstrap probes | `deploy/k3d-base/kube-system/gateway.yaml` |

The `podinfo` route lives in `kube-public` and attaches across namespaces to the shared Gateway in `kube-system`, which accepts routes from all namespaces. It runs on every distro, because the `podinfo` StatefulSet is in `k3d-base`. The `/readyz` route stays in `kube-system` because its backend, the kgateway controller, is there.

kgateway serves `/readyz` on its `health` port (9093), not on `grpc-xds` (9977).

## UIs

| UI | Host | Backend | Present on |
|---|---|---|---|
| kube-argus | `[<prefix>-]argus.k3d.workbench.local.gd` | `kube-argus` Service, port 8080 | all distros |
| Hubble | `[<prefix>-]hubble.k3d.workbench.local.gd` | `hubble-ui` Service, port 80 | Cilium distros, with `PLTF_ENABLE=hubble` |
| podinfo | `[<prefix>-]podinfo.k3d.workbench.local.gd` | `podinfo` Service, port 9898 | all distros |

Sources: `deploy/k3d-base/kube-system/kube-argus.yaml`, `deploy/k3d-dev/kube-system/hubble.yaml`, `scripts/lib/pltfctl/cmds.sh`.

Hubble's relay and UI are installed by cilium-cli as part of the Cilium release, and only when `PLTF_ENABLE` names `hubble` at install time. Flux owns only the route, which is always applied and has no backend while Hubble is off. On a running cluster, `cilium hubble enable --ui --context k3d-<cluster>` turns Hubble on without another `up`. `lite` has no `hubble.yaml` because it has no Cilium. `pltfctl open` lists the URLs without a cluster and launches one only when the cluster is running (`scripts/lib/pltfctl/cmds.sh`).

All UI traffic is plain HTTP. See [Certificates](04-certificates.md).

---

← Previous: [Networking](02-networking.md) · [Index](00-index.md) · Next: [Certificates](04-certificates.md) →
