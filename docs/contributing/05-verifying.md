# Verifying a change

## Offline (no cluster)

    ./scripts/projctl lint      # sh -n on each script + shellcheck -x
    ./scripts/projctl check     # infra/fleet.env vs infra/k3d/ and deploy/; unique ports/CIDRs/IDs
    ./scripts/pltfctl doctor    # tools on PATH + SBOM drift

`projctl lint` runs `sh -n` on **each** file separately. `sh -n a.sh b.sh` looks equivalent but
is not: `sh -n` parses only its first operand and treats the rest as positional parameters, so
they are never checked.

## Live

There is no offline chart-render suite. Check behaviour against a running cluster:

    ./scripts/pltfctl up && ./scripts/pltfctl status            # dev, the default distro
    curl -fsS http://gateway.k3d.workbench.local.gd:8080/readyz
    ./scripts/pltfctl up fleet && ./scripts/pltfctl verify      # acceptance gate for mesh changes

`fleet` has not yet been run end to end on a live machine. A `verify` pass on it is the first
evidence that a mesh change works, so report the output rather than assuming it.

`status` always exits 0. Gate on `verify`, not `status`.

---

← Previous: [Bumping a pinned version](04-versions.md) · [Index](00-index.md) · Next: [Things never to change casually](06-invariants.md) →
