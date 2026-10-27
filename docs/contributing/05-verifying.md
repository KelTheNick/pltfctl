# Verifying a change

## Offline (no cluster)

    ./scripts/projctl lint      # sh -n on each script + shellcheck -x
    ./scripts/projctl check     # infra/k3d/fleet.env vs infra/k3d/ and deploy/; unique ports/CIDRs/IDs
    ./scripts/pltfctl doctor    # tools on PATH + SBOM drift

`projctl lint` runs `sh -n` on **each** file separately. `sh -n a.sh b.sh` looks equivalent but
is not: `sh -n` parses only its first operand and treats the rest as positional parameters, so
they are never checked.

## Live

There is no offline chart-render suite. Check behaviour against a running cluster:

    ./scripts/pltfctl up && ./scripts/pltfctl status            # lite, the default distro
    curl -fsS http://gateway.k3d.workbench.local.gd:8080/readyz
    ./scripts/pltfctl up dev && ./scripts/pltfctl verify        # dev: marker round trip on the running variant
    ./scripts/pltfctl up fleet && ./scripts/pltfctl verify      # acceptance gate for mesh changes
    ./scripts/pltfctl event-bus up && ./scripts/pltfctl event-bus status   # event-bus changes (lite, or fleet's ops)

`pltfctl up dev` and `down` (with its host-wide Docker prune) have
not been run live either. The `strimzi-kraft` `dev` variant was run live on 2026-10-13 through the real
`cmd_up_compose`, `cmd_verify_compose` and `pltf_down_compose` functions under a test project
name: each came up and passed `verify`, a variant switch was refused, and `down` left no
containers or volumes ([Kafka variants](../../wiki/developer/01-variants.md#tested)). Switching
variant needs `pltfctl down` first.
`fleet` is a single cluster, so `verify` there runs the single-cluster checks; the cross-cluster
probe path runs only when a second cluster is added. Report the output you actually saw.

`status` always exits 0. Gate on `verify`, not `status`. `<component> status` exits 1 when that
component is unhealthy. `event-bus status` is different: it exits
0 only when every Kafka cluster is Ready, so it can gate event-bus changes.

---

← Previous: [Bumping a pinned version](04-versions.md) · [Index](00-index.md) · Next: [Things never to change casually](06-invariants.md) →
