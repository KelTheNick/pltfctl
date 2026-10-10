# Changing the fleet

`infra/fleet.env` is the single source of truth for everything this project creates:

- the distros (`PLTF_DISTROS`, and per distro `PLTF_DISTRO_<D>_{CLUSTERS,CNI,REGISTRY,O11Y}`)
- the cluster names, in teardown order (`PLTF_ALL_CLUSTERS`)
- per cluster: Cilium cluster ID, API/HTTP/HTTPS host ports, pod/service CIDRs, cluster DNS IP,
  and route host prefix
- the shared Docker network
- the OCI registry's name and ports

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

`./scripts/projctl check` confirms, for every distro: each cluster has an `infra/k3d/` template,
ports, CIDRs and IDs are unique within the distro, `deploy/k3d-base/` exists, every other
`deploy/` directory names a known cluster, and no symlink is broken.

## Adding a cluster

1. Add its name to `PLTF_DISTRO_<D>_CLUSTERS` and to `PLTF_ALL_CLUSTERS`, and add a
   `PLTF_<NAME>_*` block to `infra/fleet.env`.
2. Copy a template from the same distro (for example `infra/k3d/fleet/op-3.yaml`) to
   `infra/k3d/<distro>/<name>.yaml` and change `metadata.name`.
3. Only if the cluster needs its own additions, create `deploy/k3d-<name>/`. Symlink each
   namespace directory to a sibling's, as `deploy/k3d-op-2/` does with `../k3d-op-1/`. A cluster
   with no directory still gets everything in `deploy/k3d-base/`.
4. Run `./scripts/projctl check`.

---

← Previous: [Adding a manifest](02-adding-manifests.md) · [Index](00-index.md) · Next: [Bumping a pinned version](04-versions.md) →
