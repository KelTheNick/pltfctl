# Script conventions

## Layout

```
scripts/
├── pltfctl               # cluster lifecycle: up/down/status/open/verify/doctor
├── projctl               # housekeeping + scaffolding; never touches a cluster
├── README.md             # the reasoning behind non-obvious script choices
└── lib/
    ├── core/log.sh       # logging + pltf_require_cmd, shared by both entrypoints
    ├── pltfctl/*.sh      # common, flux, cilium, cmds, sbom
    └── projctl/*.sh      # qa, scaffold, housekeeping
```

Helpers go in `scripts/lib/<entrypoint>/`. Code used by more than one entrypoint goes in
`scripts/lib/core/`.

## Rules

- Entrypoints (`scripts/pltfctl`, `scripts/projctl`) start with `#!/usr/bin/env sh` and
  `set -eu`, and have the executable bit set.
- Sourced libs (`scripts/lib/**/*.sh`) define functions only. They have no `set` line and do no
  work at the top level beyond their fail-loud guard and derived constants. They are not
  executable.
- POSIX sh only.
- Never hardcode a fleet value (cluster name, port, CIDR, cluster ID, network, registry) in a
  script. Read it from `infra/fleet.env` with `pltf_fleet <cluster> <KEY>`.
- Never hardcode a version. Read it from `.env.sbom`.
- Prefer returning a new copy over changing values in place, and keep functions small.

## Adding a subcommand

- **pltfctl:** write `cmd_<name>()` in `scripts/lib/pltfctl/cmds.sh`. Then add it to the `case`
  in `main()` and to the `usage()` text in `scripts/pltfctl`. A command group with its own verbs
  (such as `event-bus up|down|status`) gets its own lib instead, for example
  `scripts/lib/pltfctl/kafka.sh`, sourced from `scripts/pltfctl`.
- **projctl:** write `proj_<name>()` in the matching `scripts/lib/projctl/*.sh` file (or add a new
  file and source it). Then add it to the `case` and `usage()` in `scripts/projctl`.

---

[Index](00-index.md) · Next: [Adding a manifest](02-adding-manifests.md) →
