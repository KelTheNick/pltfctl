# Adding a manifest

`deploy/` follows `<kube-context>/<namespace>/<manifest>.yaml`, with one extra
context: `k3d-base`, for what every distro gets. `pltfctl up <distro>` applies
`deploy/k3d-base/*/*.yaml` to each cluster of the distro, then
`deploy/k3d-<cluster>/*/*.yaml` where that directory exists. Within each
namespace, in this order:

1. the `namespace.yaml`
2. the Flux sources (`repositories.yaml`, `registry.yaml`)
3. everything else, retried in rounds until the CRDs it needs are ready

## Shared vs per-context

Anything every distro should get goes in `deploy/k3d-base/`: the Flux sources, the
kgateway and kube-argus HelmReleases, the shared Gateway, and the `podinfo` sample
(StatefulSet, Service and smoke route). The per-context directories hold only what differs:

- `deploy/k3d-dev/` holds the real files for what only dev has: the Hubble route, the OCI
  registry source, the podinfo ServiceExport (MCS-API, so it needs Cilium), and the event
  bus in `kafka-system`.
- `deploy/k3d-lite/` holds lite's single-node event bus; its operator and namespace files link to
  dev's. fleet does not link `kafka-system`, so it has no bus.
- `kafka-system` is a toggle, not part of `up`: `flux_apply_tree` skips it, and
  `pltfctl event-bus up [bus]` applies `namespace.yaml`, `strimzi-operator.yaml` and `<bus>.yaml`
  (`scripts/lib/pltfctl/kafka.sh`). A new bus kind is a new `<bus>.yaml` plus its name in
  `PLTF_EVENT_BUSES` (`infra/fleet.env`).
- `deploy/k3d-op-1/` symlinks each namespace directory to dev's.
- `deploy/k3d-op-2/` and `deploy/k3d-op-3/` symlink each namespace directory to `deploy/k3d-op-1/`.
- `lite` has no directory of its own. It gets `k3d-base` and nothing else.

Editing a linked namespace therefore changes every context that links it, which is what you want
for the platform. Links are per namespace directory, so a **new** file in a linked namespace
reaches every linked context at once. Check with `./scripts/projctl check`, which catches
dangling links.

To deploy something to one context only, give it its own namespace under that context. The
new namespace is a real directory inside that context's directory:

    ./scripts/projctl new-ns  k3d-op-1 demo
    ./scripts/projctl new-app k3d-op-1 demo hello   # OCIRepository (flux-system) + HelmRelease, from the local registry

Only replace a shared symlink with a real directory if the namespace truly has to differ
between clusters. Once you do, that copy can drift from the others.

## Which namespace?

- `kube-system`: platform components, i.e. anything that is part of the fabric itself
  (the gateway and its `/readyz` route, dashboards, controllers, HelmReleases).
- `kube-public`: sample and test workloads that exercise the platform (`podinfo`). Never put a
  platform component here. `kube-public` is world-readable by default.
- `flux-system`: every Flux source (`HelmRepository`, `OCIRepository`), whatever namespace its
  HelmRelease lands in. A HelmRelease references its source with `sourceRef.namespace: flux-system`
  (or `chartRef.namespace: flux-system`). New `HelmRepository` sources go in
  `deploy/k3d-base/flux-system/repositories.yaml`.
- Your own namespace (`projctl new-ns`): POCs and anything else.

## Steps

1. Add the manifest. Use a Flux `HelmRelease` for a platform component (plus a values
   ConfigMap if the values are large), or a plain Kubernetes manifest for a sample workload.
   A new chart source goes in `flux-system`.
2. Expose it through the shared Gateway with an `HTTPRoute` on a new
   `${PLTF_HOST_PREFIX}<name>.k3d.workbench.local.gd` hostname. Never add a new host port.
3. Re-run `./scripts/pltfctl up <distro>`. The apply loop is idempotent.
4. If the manifest pins a chart or image version, follow [Bumping a pinned version](04-versions.md).

Nothing under `deploy/` may hold a per-cluster value. Two mechanisms carry them in, and no others:

- Workloads read their own cluster name from the `pltf-cluster-info` ConfigMap.
- Route hostnames use `${PLTF_HOST_PREFIX}`. `flux_apply_file` fills it with `op-1-`, `op-2-` or `op-3-`
  on the fleet clusters (`op-1`, `op-2`, `op-3`), and with nothing on a cluster without a prefix.

---

← Previous: [Script conventions](01-conventions.md) · [Index](00-index.md) · Next: [Changing the fleet](03-fleet.md) →
