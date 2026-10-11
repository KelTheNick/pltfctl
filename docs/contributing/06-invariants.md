# Things never to change casually

- **Host ports and cluster CIDRs** (`infra/fleet.env`). They are set when a cluster is created,
  so changing them forces `down` + `up`. CIDRs must also never overlap within a meshed distro:
  Cilium ClusterMesh requires it.
- **The order that puts each distro's first cluster last to be deleted.** The first cluster owns
  the registry and the CA, so `up` creates it first and `down` deletes it after its peers
  (`PLTF_ALL_CLUSTERS='op-3 op-2 op-1 lite'` in `infra/fleet.env`).
- **Cilium and Hubble are installed by cilium-cli, not Flux**, on the Cilium distros (`lite`,
  `fleet`). Hubble's relay and UI are opt-in (`PLTF_ENABLE=hubble`). The CNI has to exist before Flux's controllers can schedule. Never turn them into a
  Flux HelmRelease.
- **Any `cilium install --set` value** in `scripts/lib/pltfctl/cilium.sh`. `up` skips what
  already exists but never updates it: `cilium_installed` treats "the DaemonSet exists" as
  installed. A changed or new value therefore never reaches a cluster that already has Cilium,
  and that cluster quietly keeps the old settings. The change needs `down` + `up` on every
  workstation with an older cluster.
- **Plaintext defaults are acceptable only here.** Everything in this repo assumes a throwaway
  workstation. Never carry these defaults to a shared cluster.
- **The `service.cilium.io/global-sync-endpoint-slices` annotation** belongs only on
  `ServiceExport.spec.exportedAnnotations`, never on the Service itself. The derived Service
  that MCS-API generates does not inherit Service-level annotations, so setting it in both
  places opens a second, conflicting sync path. That path merges both clusters' pod IPs under
  one hostname. Copy the pattern in `deploy/k3d-lite/kube-public/podinfo-export.yaml`.
- **Sample workloads stay StatefulSets.** Per-pod `clusterset.local` records come from a
  `hostname` field on the EndpointSlice, and only pods with stable names get one.
- **The `pltf_wait_mesh_mirrors` calls in `pltf_up_mesh`** (`scripts/lib/pltfctl/cmds.sh`).
  `clustermesh connect --wait` returns before EndpointSlice mirroring has filled either side's
  `kube-public`. Without the wait, `up fleet` reports success while cross-cluster service
  discovery is still broken. The wait counts each cluster's own `ServiceExport`s rather than a
  fixed number; keep it that way.
- **The two assertion helpers in `scripts/lib/pltfctl/cmds.sh` are deliberately asymmetric.**
  `pltf_assert_all_clusters` may take more samples, because extra samples can only add evidence
  that every cluster is reachable. `pltf_assert_all_from` must stay a strict clean sweep. Never
  add retries to it.
- **`${PLTF_HOST_PREFIX}` is the only substituted placeholder in `deploy/`.** `flux_apply_file`
  names it explicitly to `envsubst`. Adding another variable to that allow-list would be a second
  route for a per-cluster value to leak into the shared tree.
- **pltfctl stays generic.** It supplies failure domains; it must not encode which workload
  consumes them. Do not justify a platform feature by one consumer's internals. Worked
  examples belong in the consumer's repo, not here.
- **Cilium images stay tag-referenced (`useDigest=false`).** `pltf_preload_images` copies
  images into the nodes with `k3d image import`, which keeps tags but not registry digests.
  Switching back to digests makes every node download again, silently
  (`scripts/lib/pltfctl/cilium.sh`, `scripts/lib/pltfctl/images.sh`).
- **Hubble relay and UI stay off by default.** They are opt-in through `PLTF_ENABLE=hubble`
  (`scripts/lib/pltfctl/cilium.sh`); the 16GB-laptop memory budget assumes they are off.
- **One Kafka bus per cluster, in `kafka-system`.** The memory budget in
  `wiki/devsecops/08-event-bus.md` has room for one.
- **`up` never starts the event bus.** `flux_apply_tree` skips `$PLTF_EVENT_BUS_NS`
  (`kafka-system`); only `pltfctl event-bus up` applies it. Removing that skip puts Kafka on
  every `up`.
- **`verify-*.yaml` stays out of `up`.** `flux_apply_tree` skips those files by name, and
  `pltfctl verify` applies them itself. Renaming one makes its Job run on every `up`.
- **The workload-o11y stack does not exist yet.** `PLTF_DISTRO_DEV_O11Y=true` is declared
  only. Hubble is network observability that ships with Cilium; it is not that stack.

---

← Previous: [Verifying a change](05-verifying.md) · [Index](00-index.md) · Next: [README conventions](07-readme-instructions.md) →
