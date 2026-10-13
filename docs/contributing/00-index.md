# Contributing guides

Read these in order the first time. After that, jump straight to the one you need.

1. [Script conventions](01-conventions.md): POSIX sh rules and how to add a subcommand.
2. [Adding a manifest](02-adding-manifests.md): where it goes in `deploy/`, and scaffolding it with `projctl`.
3. [Changing the fleet](03-fleet.md): ports, CIDRs, clusters and the registry, all in `infra/k3d/fleet.env`.
4. [Bumping a pinned version](04-versions.md): `.env.sbom` and the drift check.
5. [Verifying a change](05-verifying.md): checks you can run offline and the live acceptance gate.
6. [Things never to change casually](06-invariants.md): read this before you touch Cilium, the mesh or `verify`.
7. [README conventions](07-readme-instructions.md): the structure and style the root README follows.

Each guide ends with links to the previous guide, this index, and the next guide.

---

Next: [Script conventions](01-conventions.md) →
