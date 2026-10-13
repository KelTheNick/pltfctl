# Infrastructure

This page covers what pltfctl creates on the host: the clusters, their nodes, the Docker network, the local registry, and how versions and settings are pinned. It also covers how `up` and `down` treat existing state.

## Distros

A **distro** is a fixed posture: which clusters exist, which CNI (Container Network Interface, the pod networking plugin) they use, and whether they get a registry. All of it is declared in `infra/k3d/fleet.env` (`PLTF_DISTRO_*`).

| Distro | Clusters (contexts) | CNI | Registry | O11Y flag | Nodes per cluster |
|---|---|---|---|---|---|
| `lite` (default) | `lite` (`k3d-lite`) | Cilium | yes | true | 1 server, 3 agents |
| `fleet` | `op-1`, `op-2`, `op-3` (`k3d-op-1`..`k3d-op-3`) | Cilium | yes, on `op-1` | false | 1 server, 0 agents |

Sources: `infra/k3d/fleet.env`, `infra/k3d/lite/lite.yaml`, `infra/k3d/fleet/*.yaml`.

- **The third distro, `dev`, is not covered here.** It is a Docker Compose stack, not k3d; see the [developer reference](../developer/00-index.md).
- **`lite` was called `dev`.** The k3d shape now named `lite` was the `dev` distro in earlier pltfctl versions. No distro uses flannel, though `fleet.env` still accepts it as a CNI value.
- **Only one distro runs at a time.** Distros reuse the same host ports. `up` refuses to start a distro while a different one is running, because the second create would fail half-way with a port bind error. It also refuses while a k3d cluster named `dev` from an older pltfctl exists (`PLTF_LEGACY_CLUSTERS`); run `pltfctl down` first (`pltf_guard_one_distro` in `scripts/lib/pltfctl/cmds.sh`).
- **What "fleet" means here.** In pltfctl, a fleet is one system spread across several clusters that are meshed together and act as failure domains for it. That differs from the common industry use, where a "fleet" is many independent clusters managed together. pltfctl's fleet clusters share one ClusterMesh, one registry (on `op-1`) and one Cilium CA (from `op-1`) (`infra/k3d/fleet.env`, `scripts/lib/pltfctl/cmds.sh`).
- **Why three clusters in `fleet`.** Three is the first count where you can lose one. Software that decides by majority vote needs two of three to agree; with two places, one holds the majority and losing it stops everything. pltfctl supplies the failure domains and does not know which workload uses them (`scripts/lib/pltfctl/common.sh`).
- **`fleet` has not been live-tested.** It has not yet been run end to end on a live machine (`docs/contributing/05-verifying.md`).
- **`O11Y=true` on `lite` is declared only.** No workload-observability stack is wired yet. Hubble is separate: it comes with Cilium, and its relay and UI are opt-in (`PLTF_ENABLE=hubble`) on every Cilium distro (`infra/k3d/fleet.env`, `scripts/lib/pltfctl/common.sh`).

## Node shapes

Each node is a Docker container running k3s (a small Kubernetes distribution), created by k3d (a tool that runs k3s in Docker). The k3s image tag comes from `.env.sbom`.

- **`lite`: 1 server + 3 agents.** The server carries the taint `CriticalAddonsOnly=true:NoSchedule`, so it runs the control plane and system add-ons only. Workloads spread across the three agents. The control plane itself is not highly available (`infra/k3d/lite/lite.yaml`).
- **Each `fleet` cluster: 1 server, 0 agents.** Everything runs on the one node (`infra/k3d/fleet/*.yaml`).
- **The k3s tag has a floor.** It must ship CoreDNS >= 1.12.2, because the MCS-API `multicluster` CoreDNS plugin requires it. The default `v1.34.1-k3s1` ships CoreDNS 1.12.3 (`scripts/pltfctl`, `scripts/README.md`).

## Docker network

Every cluster joins one Docker network, `k3d-pltfctl` (`PLTF_NETWORK` in `infra/k3d/fleet.env`). ClusterMesh exposes `clustermesh-apiserver` as a NodePort, so every cluster's node IPs must be mutually routable. A shared bridge gives that. `down` removes the network at the end, because k3d can leave it behind and never cleans up a network it did not create (`scripts/lib/pltfctl/cmds.sh`).

## The registry as an artifact store

`lite` and `fleet` get a local OCI registry (OCI: the container image and artifact format; Helm charts can be stored this way). The distro's first cluster creates it via `registries.create` in its k3d template.

| Where | Address |
|---|---|
| Host | `oci://localhost:5001` |
| In-cluster | `oci-registry:5000` |

- k3d does not add a `k3d-` prefix to the registry's name, unlike node names. `k3d-oci-registry` does not resolve in-cluster (`deploy/k3d-lite/flux-system/registry.yaml`).
- Flux reads it through the `oci-registry` HelmRepository, which lives in `flux-system`, is plain HTTP and is marked `insecure: true`. See [Certificates](04-certificates.md).
- `registry.yaml` lives under `deploy/k3d-lite/`; `deploy/k3d-op-1/` symlinks to it.
- The registry normally dies with its cluster. `down` also deletes any leftover registry so the next `up` does not hit a name or port collision (`scripts/lib/pltfctl/cmds.sh`).

## fleet.env is the source of truth

`infra/k3d/fleet.env` holds every cluster name, port, CIDR, cluster ID, the network and the registry. The k3d configs under `infra/k3d/<distro>/` are templates: `up` renders them with `envsubst` from `fleet.env`, and the scripts read the same file through `pltf_fleet`. Change a value in `fleet.env`, never in a template or a script (`infra/k3d/fleet.env`, `scripts/lib/pltfctl/common.sh`, `docs/contributing/03-fleet.md`).

## Create-time-only settings

Every value in `fleet.env` is applied when a cluster is created. Changing one needs `down` + `up`. k3d host port maps in particular can only be declared at create, which is why an HTTPS port is reserved even though nothing listens on it (`infra/k3d/fleet.env`, `infra/k3d/*/*.yaml`).

## Skip-idempotency of `up`

`up` is **skip**-idempotent, not **converge**-idempotent. It skips what already exists (a cluster, a Cilium install, Flux, clustermesh) but never reconciles an existing cluster onto changed settings. Changing a `cilium install --set` value has no effect on a cluster that already has Cilium; that needs `down` + `up` (`scripts/lib/pltfctl/cilium.sh`).

`up` does heal one kind of drift: if a cluster exists but its kube context is unusable, it re-runs `k3d kubeconfig merge` (`pltf_up_k3d` in `scripts/lib/pltfctl/cmds.sh`).

If a `cilium install` was interrupted, the DaemonSet can exist without a finished Helm release. `up` then fails loudly with the recovery command (`k3d cluster delete` + `up`) rather than trying to repair it (`scripts/lib/pltfctl/cilium.sh`).

## Teardown order

`PLTF_ALL_CLUSTERS='op-3 op-2 op-1 lite'` is the teardown-safe order. A first cluster owns the registry and the Cilium CA, so it is created first and deleted after its peers. `down` walks this list, then `PLTF_LEGACY_CLUSTERS='dev'` (the old k3d `dev` cluster), deleting only clusters that exist, and tolerates partial state (`infra/k3d/fleet.env`, `scripts/lib/pltfctl/cmds.sh`).

After the clusters, `down` deletes the registry, the developer `dev` distro's Compose stack with its volumes, and the shared network. It then runs `docker system prune -f` and `docker volume prune -f`. **That prune is host-wide, not scoped to pltfctl:** it removes every stopped container, unused network, dangling image and the build cache, and every unused anonymous volume on the machine (`cmd_down` in `scripts/lib/pltfctl/cmds.sh`). `down`, including the prune, has not been run live since this change.

## SBOM and version pinning

`.env.sbom` pins every external artifact: k3s, Flux, Cilium, the Gateway API CRDs, the kube-argus and kgateway charts, and the podinfo and openssl images, plus the probe images. The entrypoint refuses to run without it, so there is no second place a version can be defined (`.env.sbom`, `scripts/pltfctl`).

- **Script-side pins** (k3s, Cilium, Flux, Gateway API, probe images) are read from `.env.sbom` at runtime, so they cannot drift. An explicit override such as `CILIUM_VERSION=...` still wins.
- **Manifest-side pins** live inside `deploy/` YAML, which cannot source a shell file. `doctor` checks that each manifest still carries the version `.env.sbom` claims, and counts occurrences, because kgateway's version appears twice in one file. A half-finished bump fails `doctor` (`scripts/lib/pltfctl/sbom.sh`, `scripts/README.md`).
- Flux was once installed from `releases/latest`, so two runs a week apart installed different controllers. It is now pinned (`scripts/lib/pltfctl/flux.sh`).

## Flux install

Flux is the GitOps controller set that reconciles the `deploy/` tree. `up` downloads Flux's pinned `install.yaml`, applies it, waits for `source-controller` and `helm-controller`, then applies the Gateway API standard CRDs (`flux_bootstrap` in `scripts/lib/pltfctl/flux.sh`).

- **Only `source-controller` and `helm-controller` run.** Every `install.yaml` document labelled for `kustomize-controller`, `notification-controller`, `source-watcher`, `image-reflector-controller` or `image-automation-controller` (their CRDs, ServiceAccounts and Deployments) is dropped before apply, along with the `--events-addr` flag that points at the notification-controller. pltfctl pins versions in `.env.sbom` and applies `deploy/` from the checkout itself, so there are no Kustomizations, image policies, alerts or artifact generators to reconcile. Dropping the three idle controllers saves memory on a 16GB laptop (`flux_drop_unused_controllers` in `scripts/lib/pltfctl/flux.sh`).
- **Cilium is not Flux-managed.** cilium-cli installs it, because the CNI must exist before Flux's own pods can schedule, and two controllers reconciling one Helm release would fight (`deploy/k3d-lite/kube-system/hubble.yaml`).
- **Apply order.** `deploy/k3d-base/` goes to every cluster first, then the cluster's own directory if it has one. Each namespace's `namespace.yaml` and Flux sources go first. Everything else is applied in rounds (up to 24, 5s apart) because a manifest can depend on a CRD that a different manifest's HelmRelease is still installing. An empty tree fails loudly instead of `up` reporting success (`scripts/lib/pltfctl/flux.sh`, `scripts/README.md`).

## Image preloading

Every k3d node keeps its own image cache, and `down` throws it away. Without help, every `up` downloads every image again on every node. Instead, right after `k3d cluster create`, `up` pulls each image once into the host's Docker cache (skipping any already cached) and copies the set into the new cluster's nodes with one `k3d image import` call (`pltf_preload_images` in `scripts/lib/pltfctl/images.sh`).

| Distro | Images per cluster | What |
|---|---|---|
| `lite` | 9 | podinfo, the two Flux controllers, kgateway and its proxy (`envoy-wrapper`), kube-argus, plus Cilium: agent, operator, envoy. With `PLTF_ENABLE=hubble`, also hubble-relay and hubble-ui (2) |
| `fleet` | 10 | as `lite`, plus `clustermesh-apiserver` |

`pltfctl event-bus up` preloads its own two images (the Strimzi operator and Kafka) when it runs.

These counts are worked out from the pins, not measured on a run.

- **Every image comes from a pin.** podinfo, kgateway and kube-argus from `.env.sbom`; the Flux controllers from the pinned `install.yaml` (after the controller filter); Cilium from `cilium install --dry-run` at `CILIUM_VERSION`. Nothing is listed twice (`scripts/lib/pltfctl/images.sh`).
- **The Flux manifest is cached.** It is downloaded once per Flux version to `$TMPDIR` and reused by preloading and by `flux_bootstrap` (`flux_install_manifest` in `scripts/lib/pltfctl/flux.sh`).
- **Cilium images are referenced by tag, not digest.** `k3d image import` keeps an image's tag but not its registry digest, so a `tag@digest` reference would miss the imported copy and download anyway. Cilium is therefore installed with `useDigest=false` on every image; the tags stay pinned by `CILIUM_VERSION` (`cilium_image_flags` in `scripts/lib/pltfctl/cilium.sh`). Switching digests back on silently disables preloading for Cilium (`docs/contributing/06-invariants.md`).
- **Best-effort.** If a host pull or the import fails, `up` warns and the nodes pull as they did before.
- **Tradeoff.** The first `up` on a fresh machine is not faster: the host still has to download everything once. Every later `up` copies locally instead.
- **Not live-tested yet.** Preloading has only been checked offline (each distro's image list resolves, lint passes); the gateway proxy image name is inferred from the kgateway version rather than read from the chart.

---

[Index](00-index.md) · Next: [Networking](02-networking.md) →
