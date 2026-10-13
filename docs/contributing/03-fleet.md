# Changing the fleet

The inventory is three files, each the single source of truth for its part. Each value is in exactly one of them.

| File | Holds | Applies to |
|---|---|---|
| `infra/.infra.env` | the distros (`PLTF_DISTROS`, `PLTF_DEFAULT_DISTRO`) and each one's kind (`PLTF_DISTRO_<D>_KIND`; `k3d` unless set to `compose`) | every distro |
| `infra/k3d/fleet.env` | everything listed below | k3d distros (`lite`, `fleet`) |
| `infra/compose/compose.env` | a Compose distro's project name and host ports (`PLTF_DEV_PROJECT`, `PLTF_DEV_*_PORT`); its Kafka variant is in `infra/compose/.variant.env` | Compose distros (`dev`) |

`scripts/pltfctl` and `scripts/projctl` source them in that order and stop if any is missing.

`infra/k3d/fleet.env` holds:

- per k3d distro: `PLTF_DISTRO_<D>_{CLUSTERS,CNI,REGISTRY,O11Y}`
- the cluster names, in teardown order (`PLTF_ALL_CLUSTERS`), plus `PLTF_LEGACY_CLUSTERS`: old
  names `down` still deletes and `up` refuses to run alongside (today `dev`, the old k3d name)
- per cluster: Cilium cluster ID, API/HTTP/HTTPS host ports, pod/service CIDRs, cluster DNS IP,
  and route host prefix
- the Docker network every k3d cluster joins, and the upstream resolver file
  (`infra/k3d/network/resolv.conf`)
- the OCI registry's name and ports
- the event-bus kinds, the default kind and namespace (`PLTF_EVENT_BUSES`,
  `PLTF_EVENT_BUS_DEFAULT`, `PLTF_EVENT_BUS_NS`), used by `pltfctl event-bus`

The k3d configs in `infra/k3d/<distro>/<cluster>.yaml` are **templates**. `pltfctl up` renders each one
with `envsubst` from `fleet.env`, and the scripts read the same file through
`pltf_fleet <cluster> <KEY>`. A port or CIDR is therefore written down in exactly one place.

## Rules

- Every value is set when a cluster is created. Changing one requires `pltfctl down` + `up`.
- Only one distro runs at a time, and distros reuse host ports. So ports, CIDRs and cluster IDs
  must be unique **within** a distro. Repeating them across distros is deliberate.
- CIDRs must not overlap within a meshed distro (`fleet`): Cilium ClusterMesh requires it.
- Ports follow the 4-digit convention: `655x` for the API, `x080` for HTTP, `x443` for HTTPS.
- The first cluster of each distro owns the registry (where `REGISTRY=true`) and, on Cilium
  distros, the Cilium CA. It is created first and deleted after its peers. `fleet`'s first cluster is `op-1`.

A Compose distro (`dev`) has no clusters. It has one stack file per Kafka variant,
`infra/compose/<distro>-<variant>.yaml`; `VARIANT_KAFKA` picks one, from the environment if
exported, else `infra/compose/.variant.env` (default `strimzi-kraft`). `up` refuses while a
different variant's stack is running, and `down` removes every variant's. The stack reads
images from `.env.sbom` and ports from `fleet.env` through Compose's `${VAR}` interpolation
(`scripts/lib/pltfctl/compose.sh`).

`./scripts/projctl check` confirms, for every compose distro, that `infra/compose/.variant.env`
sets `VARIANT_KAFKA`, that `infra/compose/<d>-<default>.yaml` exists and that `PLTF_<D>_PROJECT`
is set; and for every k3d distro: each cluster has an `infra/k3d/` template,
ports, CIDRs and IDs are unique within the distro, `deploy/k3d-base/` exists, every other
`deploy/` directory names a known cluster, and no symlink is broken.

## Adding a cluster

1. Add its name to `PLTF_DISTRO_<D>_CLUSTERS` and to `PLTF_ALL_CLUSTERS`, and add a
   `PLTF_<NAME>_*` block to `infra/k3d/fleet.env`.
2. Copy a template from the same distro (for example `infra/k3d/fleet/op-3.yaml`) to
   `infra/k3d/<distro>/<name>.yaml` and change `metadata.name`.
3. Only if the cluster needs its own additions, create `deploy/k3d-<name>/`. Symlink each
   namespace directory to a sibling's, as `deploy/k3d-op-2/` does with `../k3d-op-1/`. A cluster
   with no directory still gets everything in `deploy/k3d-base/`.
4. Run `./scripts/projctl check`.

---

← Previous: [Adding a manifest](02-adding-manifests.md) · [Index](00-index.md) · Next: [Bumping a pinned version](04-versions.md) →
