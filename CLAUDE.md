# CLAUDE.md

Orientation for AI agents working in `pltfctl`. This file only points to where
things are written down. Read the source it names; do not rely on memory of an
older layout.

| You need | Read |
| --- | --- |
| What the project is and what it is for | [README.md](README.md) |
| How to change it: conventions, adding manifests, the fleet, versions, verifying, things never to change casually | [CONTRIBUTING.md](CONTRIBUTING.md) → `docs/contributing/` |
| How the platform works and why: infrastructure, networking, gateways, certificates, IAM, deep dives | [WIKI.md](WIKI.md) → `wiki/` |
| Why a script does something non-obvious | `scripts/README.md` |

## Working rules

- **Check the code before you state a fact.** `infra/.infra.env` (distros),
  `infra/k3d/fleet.env` (k3d clusters, ports, CIDRs), `infra/compose/` (Compose stacks and their
  env), `.env.sbom` (versions) and `deploy/` (manifests) are the sources of truth. Docs
  describe them; when the two disagree, the code wins and the doc needs fixing.
- **Read the guardrails before changing Cilium, the mesh, `deploy/` or `verify`:**
  `docs/contributing/06-invariants.md`.
- **Verify before you claim.** Offline: `./scripts/projctl lint`, `./scripts/projctl check`,
  `./scripts/pltfctl doctor`. Live: `./scripts/pltfctl up <distro>` then `verify`. Report what
  you actually ran. `fleet` has not been run end to end on a live machine yet; say so rather
  than claiming its `verify` passes.
- **Never run `down` (or delete clusters) without first checking what is running and getting
  the user's go-ahead.** `down` removes every pltfctl cluster and Compose stack, not just the
  one you created, then runs a host-wide `docker system prune -f` and `docker volume prune -f`.
- **Write new technical knowledge into the wiki**, following "Writing for the wiki" in
  [WIKI.md](WIKI.md). Keep docs you touch in step with the code you change.
- `docs/superpowers/` is agent scratch and is gitignored.
