# What the meshed platform affords a multi-cluster Strimzi Kafka

This page is prose, not a how-to: nothing here is YAML, so nothing here can
rot untested. It explains why `pltfctl` is shaped the way it is, what its
Cilium ClusterMesh substrate does and does not give a stretched Strimzi
Kafka deployment, and how to check the substrate's claims for yourself
without deploying Kafka at all.

## Why this platform is shaped this way

`pltfctl` does not deploy a multi-cluster Kafka, and it never will. Its
Strimzi manifests (`event-bus`) are single-cluster. The motivating workload behind the
`fleet` distro (one cluster, `ops`, ClusterMesh enabled; a second cluster no longer fits on a Mac, so the two-cluster statements below describe the mesh as it was measured), the Cilium ClusterMesh, and the disjoint
CIDR allocation is a multi-cluster Strimzi Kafka deployment: brokers and
KRaft controllers spread across two (or more) Kubernetes clusters, addressed
by name from any of them. `pltfctl` provides the substrate that shape of
workload needs — mutually routable clusters, fleet-wide DNS, and global
service failover — and stops there. Everything below is either something
the substrate demonstrably provides (verified by `podinfo`, the one
StatefulSet this platform ships, in the `kube-public` namespace) or
something it deliberately does not, stated
plainly so a reader deciding whether to build a stretched Kafka on top of
it knows exactly what they are and are not getting.

## What the mesh affords

### Per-pod fleet-wide FQDNs

Every pod in a StatefulSet gets a name of the shape
`<pod>.<cluster>.<svc>.<ns>.svc.clusterset.local` that resolves identically
from any cluster in the mesh — for example
`podinfo-0.ops.podinfo.kube-public.svc.clusterset.local`, resolved from
`op-2`, for this platform's own sample workload. This maps directly onto two
of Kafka's most cluster-topology-sensitive settings:

- **`advertised.listeners`** — each broker needs an address that every
  producer, consumer, and peer broker can dial regardless of which cluster
  it is running in. A per-pod clusterset.local name is exactly that address.
- **`controller.quorum.voters`** (KRaft) — the controller quorum needs
  stable, fleet-wide-resolvable addresses for every voter, independent of
  which cluster currently hosts which controller.

Upstream Strimzi already has the hook for this: `advertisedHostTemplate`,
with the substitution variables `{nodeId}` and `{nodePodName}`, is the
supported mechanism for pointing a broker's advertised address at a
non-default hostname. Wiring that template to a clusterset.local pattern is
the natural way a stretched Strimzi deployment would consume what this
platform's mesh provides — `pltfctl` does not do this wiring itself, since
it does not deploy Kafka.

### Global services for bootstrap survival

`service.cilium.io/global: "true"` on a Service turns it into a Cilium
global service: one name whose backends span every cluster that publishes
it. For a Kafka bootstrap address, that is the difference between "the
client can reach the cluster if and only if the specific cluster it first
contacted is still up" and "the client can reach the cluster as long as one
member of the mesh is". The failover-policy lever is the
`service.cilium.io/affinity: local | remote` annotation: `local` prefers
same-cluster backends and only spills over to the other cluster when local
ones are unavailable; `remote` inverts that preference. Either way, losing
one cluster does not take the bootstrap address down with it.

### Disjoint pod/service CIDRs as a routing precondition

Cluster `ops` runs pod range `10.42.0.0/16` / service range `10.43.0.0/16`; cluster `op-2`
runs `10.44.0.0/16` / `10.45.0.0/16`. This is not incidental — Cilium
ClusterMesh hard-requires non-overlapping pod and service CIDRs across every
member cluster, because cross-cluster routing has no way to disambiguate two
clusters both claiming `10.42.x.x`. For a stretched Kafka, that
non-overlap is the precondition that makes broker-to-broker routing across
clusters possible at all: a broker on cluster `op-2` connecting to a
peer on cluster `ops` needs the peer's pod IP to be unambiguous fleet-wide.

## What it deliberately does not provide

**No stretch-mode Strimzi operator.** Upstream Strimzi has no supported
mode for a single operator (or a coordinated pair of operators) managing
brokers and controllers split across independent Kubernetes clusters. The
most complete public account of getting this working —
`aswin6303.medium.com/we-proved-multi-cluster-kafka-works-on-kubernetes-heres-everything-we-learned-853dd5f1c03c`
— runs an **unmerged fork** of the operator,
`aswinayyolath/strimzi-kafka-operator` on branch `48-migration`, with custom
TLS SAN generation (so certificates issued for a pod in one cluster
validate when presented to a client in another) and a
central-operator/remote-operator split (one operator reconciling cluster
resources centrally, a remote counterpart per cluster) that does not exist
in upstream Strimzi. `pltfctl` gives that fork's needed substrate — mesh
networking, fleet-wide DNS, global services — but running an actual
stretched Kafka on it means adopting that fork or building equivalent
tooling yourself; it is not something `pltfctl` includes or endorses as
production-ready.

**No cross-cluster persistent storage.** Nothing here addresses how a
broker's log segments would be replicated or made available if its pod
migrated between clusters. Standard Kafka replication (replicas spread
across brokers, wherever those brokers run) is the mechanism available; k3d
gives each cluster its own local-path storage class with no cross-cluster
volume story.

**No KRaft controller-quorum latency tuning.** The reference article
measured stable KRaft quorum behavior under roughly 10 ms of inter-cluster
latency, with degradation appearing past roughly 50 ms. A single-host k3d
fleet — every "cluster" a set of Docker containers on the same machine,
connected by one Docker bridge network — has effectively zero inter-cluster
latency and so exercises none of that concern. Anyone taking this substrate
model to real geographically-separated clusters needs to redo that latency
characterization; `pltfctl`'s clean bill of health here proves nothing about
that scenario.

## The caveats that decide whether this actually works

These four points are the difference between the platform *looking* like it
supports a stretched Kafka and actually doing so. Skipping any one of them
produces a mesh that resolves Service-level names correctly while silently
failing at the per-pod addressing a Kafka broker fleet depends on.

- **EndpointSlice synchronization is Beta upstream.** Per-pod fleet-wide
  FQDNs (`podinfo-0.ops....svc.clusterset.local`) do not work from Cilium's
  MCS-API support alone — MCS-API only merges Service backends into the
  local eBPF service map, it does not mirror a remote cluster's per-pod
  EndpointSlice data into the local cluster's DNS view. That mirroring is a
  separate, **Beta** Cilium feature: Helm value
  `clustermesh.enableEndpointSliceSynchronization=true` on every cluster in
  the mesh, plus the annotation `service.cilium.io/global-sync-endpoint-slices:
  "true"` delivered via the relevant `ServiceExport` (see the next point for
  exactly where — not on the Service itself). Beta means exactly what it
  says — evaluate accordingly before depending on it for something as
  correctness-sensitive as broker identity.

- **That annotation belongs on the `ServiceExport`, never on the Service.**
  Specifically, it must be delivered via `ServiceExport.spec.exportedAnnotations`,
  not set directly on the underlying Service. MCS-API reconciles an
  auto-generated *derived* Service for the mesh-wide identity, and that
  derived Service does not inherit annotations from the Service it was
  built from. Putting the annotation in both places is not merely redundant
  — it opens a second, conflicting synchronization path, observed live as a
  single derived EndpointSlice whose per-pod hostnames each carried *both*
  clusters' pod IPs simultaneously. For a Kafka broker, a hostname resolving
  to two different clusters' addresses at once is a silent correctness
  disaster, not a cosmetic bug: whichever address a client happens to
  connect to, it may not be talking to the broker it thinks it is.

- **Per-pod records resolve to the bare pod IP, with no Service-level port
  translation.** A per-pod clusterset.local name goes straight to the pod's
  own IP — there is no VIP and no kube-proxy/eBPF port mapping in that path.
  That means the port to dial is whatever the container itself listens on,
  not whatever the Service happens to publish, even when the two numbers
  coincide. This platform's own sample workloads deliberately publish the
  same port number on both the Service and the container (`podinfo`
  9898/9899/9999) so the two never diverge here — but
  that alignment is a choice this repo made, not a Cilium guarantee. A
  Kafka broker configuration that assumes a Service's advertised port
  always applies uniformly to per-pod addresses will get this wrong the
  moment Service and container ports differ.

- **The workload must be a StatefulSet.** Per-pod clusterset.local records
  are built from a `hostname` field on the backing EndpointSlice entry,
  which only exists for pods with stable, assigned hostnames — which in
  practice means StatefulSet pods. A Deployment's randomly-suffixed pods
  carry no such hostname and no per-pod record is ever created for them,
  regardless of any other configuration. Kafka's own broker/controller pods
  are conventionally StatefulSet-shaped already, which is fortunate — but it
  is a hard requirement, not an incidental match.

## How to check the substrate yourself

`./scripts/pltfctl verify` (fleet distro only) runs an ephemeral probe pod in
**each** cluster and checks the mesh from that cluster to **every other** one.
With two clusters that is 2 probes covering both ordered directions and 20
assertions; a three-cluster mesh would make 45. The gate is designed to fail loudly
(non-zero exit) if any assertion does not hold. The `fleet` distro has not yet
been run end to end on a live machine, so these counts describe what the check
asserts, not a recorded pass. The checks span four protocols that stand in for
different transport shapes a stretched Kafka deployment would use. All four
target the same `podinfo` pod, on the same port per protocol:

- **HTTP** (`podinfo`, port 9898) — represents plain REST services.
- **TLS** (`podinfo`, port 9899) — a self-signed certificate that `pltfctl up`
  generates on the host into the `podinfo-tls` Secret; the probe skips certificate
  verification, so this proves the handshake and encrypted transport
  survive the mesh, not certificate trust.
- **gRPC** (`podinfo`, port 9999) — `podcli check grpc --service=<cluster>`
  from the podinfo image. podinfo registers its health service only under
  its own cluster name (`--grpc-service-name`), so SERVING attributes the
  answer to a cluster; a separate explicit health assertion per target
  repeats that check.
- **TCP** (`podinfo`, port 9898) — a raw socket (`nc`) that sends a plain
  `GET /api/info` request to podinfo's HTTP port, with no HTTP client in
  between. **This proves L4 reachability to port 9898 across the mesh, and
  nothing more.** The platform runs no listener on a Kafka-conventional port
  (Kafka's usual broker port), and nothing in this repo speaks the Kafka wire protocol.
  The raw socket is the closest stand-in here for a Kafka-style binary
  protocol, but it is still HTTP bytes on the same port that the HTTP check
  already uses.

For each protocol, two checks run:

1. **Aggregate**: the fleet-wide name
   (`<workload>.kube-public.svc.clusterset.local`) must load-balance across
   both clusters over 10 samples — the baseline claim that a Kafka
   bootstrap address built the same way would depend on. This is the
   MCS-API fleet-wide Service name working at all.
2. **Per-pod**: a specific pod's cluster-scoped name
   (`<workload>-0.<cluster>.<workload>.kube-public.svc.clusterset.local`)
   must, across 10 repeated attempts, have *every* response attribute to
   the target cluster. `<workload>-0` exists in *both* clusters (every
   StatefulSet manifest here is applied unchanged to each cluster) — it is
   the `.<cluster>.` segment in the FQDN that picks out which cluster's pod
   is being addressed, not pod uniqueness, and the response payload naming
   that cluster is what proves the attribution actually holds. This is the
   per-pod, cross-cluster addressing claim — the exact shape
   `advertised.listeners` and `controller.quorum.voters` need — and it is
   the assertion that would fail first if the Beta EndpointSlice
   synchronization feature above were disabled, misconfigured, or
   annotated in the wrong place.

Two more checks round out the ten per direction: `podinfo`'s
`cluster.local` name (a Cilium global service, exercised once on HTTP since
it tests a Cilium mechanism rather than a protocol) load-balances
independently of MCS-API — the same annotation-driven behavior a Kafka
bootstrap Service marked `service.cilium.io/global: "true"` would rely on —
and a gRPC health check confirms the remote pod's health service reports
its own cluster name as `SERVING`.

The cross-cluster checks above need at least two running clusters. On `lite`,
`verify` instead runs single-cluster mode: one Job per protocol in
`default` hitting podinfo in `kube-public`. That proves the protocols inside one
cluster, not anything about the mesh. Passing `verify` on the fleet proves the
substrate; it does not prove a Kafka deployment on top of it, since
`pltfctl` never deploys Kafka.

### A note on cold-mesh convergence

`cilium clustermesh status --wait` (used by `clustermesh_connect` during
`up`) only confirms cluster-to-cluster connectivity — it says nothing about
whether per-service EndpointSlice mirroring has actually populated either
cluster's `kube-public` namespace yet. That gap was real, not theoretical:
reproduced live on a two-cluster mesh, `up` returning "ClusterMesh
established" could leave the destination cluster with ZERO EndpointSlices
mirrored from the source for several seconds afterward. A `verify` run
immediately after `up` returned could therefore race the mirror and see a
genuine, sustained 0/30 from one cluster on its very first checks — not
skew, no responses at all — a materially different failure mode from the
sampling artifact discussed below.

`up` on a multi-cluster distro now waits for this explicitly (`pltf_wait_mesh_mirrors` in
`scripts/lib/pltfctl/cilium.sh`, called once per direction right after
`clustermesh_connect`): it counts each cluster's own `ServiceExport` objects
in `kube-public` and polls the peer for at least that many EndpointSlices
carrying the matching `multicluster.kubernetes.io/source-cluster` label, up
to a 120s bound. In practice it blocks only a few seconds — the
`kube-public` StatefulSet rollout wait ahead of it has already absorbed most
of the propagation, so the figure it prints is the residual wait, not how
long mirroring takes from scratch. Either way it has stayed comfortably
inside the bound, and a `verify` run started immediately after `up` returned
passed cleanly on the earlier two-cluster mesh. That mesh ran a second, Kafka-port
workload and two `podinfo` replicas, so it is not evidence for the current workload
set, which runs one `podinfo` pod and no Kafka-port listener. The "re-run on a fresh
mesh" advice that follows covers only the residual sampling artifact below, not
a missing mirror.

### A note on sampling at n=10

Cilium's per-connection hash load-balancing can produce a genuinely skewed
split — splits like 8/2 and 2/8 have been observed in roughly 13% of
10-sample batches — on a mesh that is otherwise completely healthy. That is
a property of sampling ten requests, not a defect in the mesh, but at a
fixed n=10 it was occasionally enough to land a healthy mesh at a full 10/0
and fail the aggregate check outright. That specific 10/0 rate was never
separately measured, but since `verify` runs five aggregate gates per probe
cluster (fifteen per invocation on `fleet`), a per-run false-failure rate in
the low single digits percent was plausible before the fix below.

`pltf_assert_all_clusters` (the aggregate check) now self-extends: it
still samples 10 first and passes immediately if every cluster already
showed up (the common path, unchanged and free of extra cost), but if
any cluster is still at 0 it draws up to two more batches of 10 before
failing. The check is monotone — more samples can only add evidence that
both clusters answered, never take it away — so extending it costs no
signal, only time on the rare unlucky batch. This should make the
aggregate-skew false-failure mode described above largely gone.
`pltf_assert_all_from` (the per-pod, clean-sweep check) deliberately does
NOT get the same extension: more samples there only create more chances to
catch a real mis-attribution bug, which is the whole point of that check.

Separately, a per-pod check has been observed landing at 8/10 with the
other two responses simply missing (not misattributed to the wrong
cluster) on one run; two hundred subsequent attempts across both directions
came back 200/200 clean, and each per-pod FQDN involved resolved to exactly
one A record matching the target pod's real IP — so that, too, was a
transient, not a defect in per-pod addressing. The measured
well-under-1% figure (0 recurrences in 200 attempts) belongs to THIS
per-pod dropped-response artifact specifically — it is not a measurement of
the aggregate-skew behavior above, which was never run at that volume.

With the cold-mesh mirror wait above and the aggregate check's
self-extension both in place, a `verify` failure on a freshly-built mesh is
no longer expected to be a transient — investigate it directly rather than
re-running first. The one exception is the 8/10-then-200/200-clean per-pod
artifact described above, worth a single re-run before digging further; a
repeat failure there, or any failure of the per-pod clean-sweep check
(`pltf_assert_all_from`) more than once, is a real signal worth chasing.
