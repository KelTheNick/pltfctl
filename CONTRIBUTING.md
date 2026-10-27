# Contributing

Where things live:

| Folder | Holds |
| --- | --- |
| `scripts/` | Every executable. `pltfctl` drives clusters; `projctl` does housekeeping and scaffolding. Helpers in `scripts/lib/<owner>/`. |
| `infra/` | What the project creates: `fleet.env` (the distros, their clusters, ports, CIDRs, route host prefixes and the registry), k3d config templates, network files. |
| `deploy/` | Flux CRs and manifests. `k3d-base/<namespace>/` is applied to every distro; `<kube-context>/<namespace>/` holds a context's additions. `up` skips `kafka-system`; only `pltfctl event-bus up` applies it. |
| `docs/` | Contributor guides: `docs/contributing/` has the details below. |
| `wiki/` | Platform knowledge for DevOps and developers. Start at [WIKI.md](WIKI.md). |
| `assets/` | Static files referenced by docs, such as the README banner icons in `assets/icons/`. |

Guides (start at the [index](docs/contributing/00-index.md); each guide links to the next):

1. [Script conventions](docs/contributing/01-conventions.md): POSIX sh rules and how to add a subcommand.
2. [Adding a manifest](docs/contributing/02-adding-manifests.md): where it goes in `deploy/`, and scaffolding it with `projctl`.
3. [Changing the fleet](docs/contributing/03-fleet.md): ports, CIDRs, clusters and the registry, all in `infra/k3d/fleet.env`.
4. [Bumping a pinned version](docs/contributing/04-versions.md): `.env.sbom` and the drift check.
5. [Verifying a change](docs/contributing/05-verifying.md): checks you can run offline and the live acceptance gate.
6. [Things never to change casually](docs/contributing/06-invariants.md): read this before you touch Cilium, the mesh or `verify`.
7. [README conventions](docs/contributing/07-readme-instructions.md): the structure and style the root README follows.

The short version:

- Before every commit: `./scripts/projctl lint && ./scripts/projctl check && ./scripts/pltfctl doctor`.
- For any change to what runs in a cluster: `./scripts/pltfctl up <lite|dev> && ./scripts/pltfctl verify`
  on the distro it affects.
- For anything that touches the mesh: `./scripts/pltfctl up fleet && ./scripts/pltfctl verify`.
  `fleet` is a single cluster, so this does not exercise cross-cluster paths.
- Before running `down`, check what is running: it removes every pltfctl cluster and the `dev`
  stack, then runs a host-wide `docker system prune -f` and `docker volume prune -f`.
