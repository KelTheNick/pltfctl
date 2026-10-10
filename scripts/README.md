# scripts/

This directory holds the two entrypoints, `pltfctl` and `projctl`. `pltfctl`
sources eight function-only libraries from `scripts/lib/pltfctl/` (`common.sh`,
`flux.sh`, `cilium.sh`, `cmds.sh`, `sbom.sh`, `images.sh`, `verify_local.sh`,
`kafka.sh`) after `scripts/lib/core/log.sh`; `projctl` sources
`scripts/lib/projctl/`. The comments inside those files state
constraints — one flag, one wait, one retry shape — without the reasoning
behind them. This file is that reasoning: the symptom that shows up when the
constraint is dropped, the cause behind it, and the rule to keep. For how to
run pltfctl, see the repo [README.md](../README.md); for script conventions
(shell dialect, where a subcommand lives, which `deploy/` tree a manifest
belongs in), see [CONTRIBUTING.md](../CONTRIBUTING.md).

## Cilium flag pairs

You are looking at a `cilium install` that failed partway — a Helm error
about adopting or creating the `kube-system` namespace, before anything else
in the release got created. Or: the fleet-wide `clusterset.local` name for a
service load-balances across clusters fine, but a specific remote pod's
per-pod name (`podinfo-0.op-2...clusterset.local`) never resolves.

`tls.secretsNamespace.name=kube-system` keeps Cilium's policy-secret sync
inside the platform's one namespace instead of spawning a separate
`cilium-secrets` namespace (the chart's default, since `tls.secretSync`
defaults to enabled from upgradeCompatibility >= 1.17). But `name` and
`create` are a pair in the chart — `create` defaults to `true` — so setting
`name` alone leaves Helm trying to create or adopt the `kube-system`
namespace object as part of the Cilium release. That adoption fails: k3s
creates `kube-system` natively, and it carries none of the Helm ownership
labels/annotations Helm requires before it will touch a pre-existing
resource. `tls.secretsNamespace.create=false` must go alongside it — the
chart itself ships this same `name`+`create=false` pairing by default for
`bgpControlPlane.secretsNamespace`, so it is a supported combination, not a
guess.

Separately, `clustermesh.enableEndpointSliceSynchronization=true` is Beta
upstream. Without it, MCS-API only merges global-service backends into the
eBPF service map — it never mirrors a remote cluster's per-pod EndpointSlice
data into the local cluster's Kubernetes/CoreDNS view, so per-pod
`clusterset.local` records for a remote cluster's members never resolve even
though the Service-level names work.

Keep both pairs together: `tls.secretsNamespace.name` with
`tls.secretsNamespace.create=false`, and
`clustermesh.enableEndpointSliceSynchronization=true`.

## cgroup and the datapath

`cilium status` reports healthy. The DaemonSet reports healthy. Every node
is `Ready`. And every ClusterIP route is dead — CoreDNS cannot reach the
apiserver Service, and neither can anything else.

k3d nodes are themselves Docker containers, and on this host they run with
`CgroupnsMode` `private` (checked with `docker inspect --format
'{{.HostConfig.CgroupnsMode}}'`). Cilium's default cgroup2 auto-mount
nsenters into the node container's own PID 1 cgroup and mount namespaces and
mounts a fresh cgroup2 instance there — which lands on PID 1's own
leaf-scoped cgroup, with no other pods underneath it as descendants. Cilium's
cgroup-attached socket-LB BPF programs, which is how kube-proxy replacement
actually redirects ClusterIP traffic, never fire for anything. The node
container's own `/sys/fs/cgroup` is already the correctly-scoped cgroup2
mount (verified with `docker exec <node> find /sys/fs/cgroup -maxdepth 2`,
which lists `kubepods` and `k3s` as siblings there); pointing Cilium at it
directly, instead of letting it auto-mount, is what fixes routing.

Keep `cgroup.autoMount.enabled=false` and `cgroup.hostRoot=/sys/fs/cgroup`
together, always. "Cilium started" is not evidence the datapath works —
only actual ClusterIP traffic is.

## The shared CA

Either ClusterMesh's mTLS handshakes between clusters fail with nothing
obviously pointing at a CA problem, or `cilium-agent`'s init container
crashloops on cluster bring-up in a way that looks like an eBPF failure.

ClusterMesh mTLS requires every cluster to trust the same CA, so the first
cluster's `cilium-ca` secret (`op-1` on fleet) is copied to `op-2` and `op-3` before Cilium installs there —
`cilium_propagate_ca`, called ahead of `cilium_install` for any joining
cluster. The copy is stamped with Helm's ownership labels and annotations
(`app.kubernetes.io/managed-by: Helm`, plus the `meta.helm.sh/release-name`
and `meta.helm.sh/release-namespace` annotations) so cilium-cli's own Helm
release adopts the secret on install instead of rejecting it with "invalid
ownership metadata". The propagation is idempotent — a CA already present
and matching the first cluster's is left alone — but a CA present and *differing* from
the first cluster's must fail loudly rather than skip silently: that mismatch (most
often `op-2` recreated with a fresh self-signed CA while `op-1` kept its old
one) is the single most common ClusterMesh failure mode, and the alternative
is a permanently broken mesh with mTLS failures that never point back here.

The crashloop is a different bug with a similar shape: `k8sServiceHost` must
be the control-plane node's InternalIP specifically, selected with
`node-role.kubernetes.io/control-plane`. Reading `{.items[0]...}` without
that role selector can return an agent node — node list order is not
guaranteed — and pointing `k8sServiceHost` at an agent leaves the
`cilium-agent` config init container unable to reach the apiserver at all,
crashlooping in a way that reads like a broken eBPF program rather than a
wrong IP. (The k3d serverlb is not an alternative: its IP is not in the
apiserver certificate's SANs, and its name cannot resolve before cluster DNS
exists.)

## DNS and PLTF_RESOLV_CONF

CoreDNS forwarding fails with `SERVFAIL`, and Flux's external chart pulls
(the kgateway HelmRepository, the kube-argus HelmRepository) fail to
resolve their sources.

The gateway address of this host's k3d bridge network — where k3s points a
node's `resolv.conf`, and therefore where CoreDNS forwards by default — runs
no DNS listener at all. This was confirmed with a plain Docker container on
the same bridge, no Kubernetes and no Cilium involved: both a UDP `nslookup`
and a TCP `nc -zv <gateway> 53` fail against it. It is a host fact, not a
Cilium one — a plain pod's `ping` to that same gateway address succeeds once
Cilium owns the datapath, so Cilium was never what stood between a pod and
that address. The gateway simply was never a DNS server, for any caller.

The fix is a bind-mounted, working resolver file: `infra/network/resolv.conf`,
mounted into every node and pointed at by k3s's `--resolv-conf` extraArg (see
every template under `infra/k3d/<distro>/`). `PLTF_RESOLV_CONF` overrides which file gets
mounted, for an internal/corporate resolver behind a VPN or on an air-gapped
host. Its default is resolved once in the entrypoint, `pltfctl`, and
exported from there — not left to `envsubst` inside the rendered k3d config
— because `pltf_render_k3d_config`'s plain `envsubst` cannot expand
`${VAR:-default}` syntax inside YAML; the default has to already be a plain
value by the time envsubst sees it.

Separately: `K3D_TAG` must pin a k3s release shipping CoreDNS >= 1.12.2,
because the MCS-API `multicluster` CoreDNS plugin that serves the
`.clusterset.local` zone requires it. The default, `v1.34.1-k3s1`, ships
CoreDNS 1.12.3.

## Mesh convergence

`up` reports "ClusterMesh established between k3d-op-1 and k3d-op-2" — and
`verify`'s very first assertion still sees a hard 0/N. Not a skewed
split, not a coin flip: zero responses from either cluster.

`cilium clustermesh connect` plus `cilium clustermesh status --wait
--wait-duration 5m` (`clustermesh_connect`) only confirm cluster-to-cluster
connectivity. Neither says anything about whether per-service EndpointSlice
mirroring has actually populated the peer's `kube-public` namespace yet.
That gap was measured, not assumed: reproduced live on a clean two-cluster mesh,
the destination cluster had zero EndpointSlices mirrored from the source for
several seconds after "established" was reported — one direction's mirror
took roughly 7s to appear, polled at 3s resolution.

`pltf_wait_mesh_mirrors` closes it, called right after `clustermesh_connect`
for every ORDERED pair — mirroring is directional, so three clusters need six
waits, not three. The connect loop above it runs over every UNORDERED pair
instead (three for `fleet`), because `cilium clustermesh connect` is itself
bidirectional AND ClusterMesh is not transitive: op-1<->op-2 plus op-1<->op-3
does NOT give you op-2<->op-3. Miss that and a member on `op-2` silently
cannot reach its peer on `op-3` while `clustermesh status` still looks
healthy from `op-1`. It counts the source cluster's own `ServiceExport`s
in `kube-public` and waits for the destination to carry at least that many
EndpointSlices labeled with that source's
`multicluster.kubernetes.io/source-cluster`. That count is read fresh each
time rather than hardcoded, so it never silently under-waits the moment a
second sample workload's `ServiceExport` is added.

Neither count is taken with `$(kubectl … | wc -l)`. A pipeline's exit status
comes from its last command, so `wc` succeeding against empty input from a
*failed* kubectl call hands back a perfectly plausible `0` — indistinguishable
from a real zero. That ambiguity bit in two different ways during
development: for the `ServiceExport` count, a failed query looked like "this
cluster exports nothing" and skipped the wait entirely, silently; for the
mirror count, a failed query looked like "nothing mirrored yet" and turned
an API/access failure into a "mirroring never caught up" timeout that sent
the reader chasing ClusterMesh instead of kubectl. Each query's own exit
status is captured before any counting happens, as a separate step.

## The assertion asymmetry

`pltf_assert_all_clusters` retries, up to three rounds of samples.
`pltf_assert_all_from` does not, ever — and it looks like something to "fix"
by making the two consistent.

`pltf_assert_all_clusters` asserts a monotone property: "the fleet-wide name
reaches every cluster in the fleet." The fleet is derived from
`pltf_existing_clusters`, not named — testing two named clusters would
have quietly kept passing when a third cluster joined and never answered.
Once a response from a cluster is seen, no
later sample can un-see it, so drawing more samples can only add evidence
*for* that having happened — the common case (both clusters already present
in the first batch) pays no extra cost, and extension can only turn a false
failure into a pass. Extension exists at all because Cilium's per-connection
hash load-balancing can produce a genuinely skewed split on an otherwise
healthy mesh — splits like 8/2 and 2/8 were observed in roughly 13% of
samples at n=10 — so a single fixed batch of 10 can land a healthy mesh at
10/0 and fail the gate outright. The skew gets HARDER as the fleet grows:
spreading the same 10 samples over three backends makes an all-clusters-seen
batch less likely, so extension carries more weight at three than at two.

`pltf_assert_all_from` asserts the opposite kind of property: every response
must name the target cluster, a non-monotone requirement where more samples
only create more chances to fail. That is deliberate. The regression it
guards against — an annotation landing on the Service instead of the
ServiceExport — produced one derived hostname backed by both clusters' pod
IPs, so DNS/eBPF picks an A record at random per lookup and a single,
unrepeated response passes roughly half the time even while broken. Only a
required clean sweep across repeated attempts turns that coin flip into a
deterministic gate. Retries must never be added to `pltf_assert_all_from` —
doing so would silently paper over the exact failure mode it exists to
catch.

## The probe pod

Someone wants to add a dedicated client image to the probe pod or the verify
Jobs, or a per-pod cross-cluster lookup returns a bare pod IP on a port that
doesn't match the Service, or an edit to the TCP probe's `\r\n` "looks wrong"
and gets "fixed."

Every client, the mesh probe pod and the `default` verify Jobs alike, runs
on the podinfo image, which is the same image as the server. It ships `curl`
(HTTP, and TLS with `-k` against the self-signed cert), `nc` (raw TCP) and
`podcli`. `podcli check grpc <addr> --service=<name>` exits 0 only when the
health service for that name is SERVING. podinfo registers health under its
own cluster name (`--grpc-service-name`), so a SERVING answer proves both the
gRPC path and which cluster answered. That is why there is no `grpcurl`. To
attribute a mesh-wide (aggregate) gRPC sample, the probe asks for each fleet
cluster's name in turn and prints whichever answers. Adding a client image
means one more pin in `.env.sbom` and one more pull on every node, for
nothing these three tools do not already cover.

TLS needs a certificate. `pltfctl up` generates a self-signed one on the
host with `openssl` (`pltf_apply_podinfo_tls`) into the `podinfo-tls` Secret,
so no openssl image runs in-cluster.

Per-pod FQDNs (`<svc>-0.<cluster>.<svc>.kube-public.svc.clusterset.local`)
resolve straight to the bare pod IP, with no Service-level port translation
in between — so per-pod probes must address the container's own port
directly, not any Service port, and the two lookups (aggregate vs. per-pod)
only happen to share port numbers here because the Services publish the
container ports unchanged.

The TCP snippet's `\r\n` escapes are resolved by the *outer* host `printf`
that assembles the in-pod command string — `pltf_probe_snippet`, evaluated
on the host by `pltfctl` — so the `printf` that ends up running inside
the pod already receives literal CR/LF bytes, not the two-character
backslash sequence. That in-pod `printf` must not itself be made to
interpret `\r\n`; it has nothing left to resolve, and making it "look
consistent" with a normal printf call would double-escape the sequence and
break the request line.

## The apply loop

`flux_apply_tree` applies `deploy/k3d-base/` first, then the context's tree, and
before the rounds it makes one pass over each namespace's `namespace.yaml`,
`repositories.yaml` and `registry.yaml`, so the namespace exists and its Flux
sources exist before anything references them. Those files are then in the
pending list too, which is harmless because a re-apply is idempotent.
`flux_apply_tree` re-attempts every still-pending manifest each round,
instead of retrying one file to exhaustion before moving to the next — that
looks wasteful. Separately, an empty or renamed `deploy/` tree does not
produce an obvious failure at apply time; it shows up later as a confusing
DNS or connection error deep inside `verify`.

A manifest can depend on a CRD that a *different* manifest's HelmRelease is
still installing — for example, `gateway.yaml` needs the
`GatewayParameters` CRD that only `kgateway.yaml`'s HelmRelease installs —
and which manifest is blocked on which CRD varies. A per-file retry budget
that exhausts itself on one file before advancing to the next would starve
the very file that would have unblocked it. Applying in rounds, where every
pending manifest gets one attempt per round for up to 24 rounds (5s apart,
then one final attempt that fails loudly on any manifest still stuck),
guarantees a blocked file is never starved by the one ahead of it in the
list.

The emptiness assert — refusing to proceed if the pending list built from
`deploy/k3d-base/*/*.yaml` and `deploy/<context>/*/*.yaml` comes back empty —
exists so a renamed or emptied tree fails loudly right there, instead of `up`
reporting success having applied nothing.

## Per-cluster route hosts

The deploy tree is one set of files for every cluster, but the clusters of
`fleet` must not all claim the same route hostnames. Route hosts are therefore
written as `${PLTF_HOST_PREFIX}<ui>.k3d.workbench.local.gd`, and
`flux_apply_file` fills the placeholder with the cluster's `<prefix>-` (`op-1-`,
`op-2-`, `op-3-`: the cluster name) or with nothing. The prefix makes a URL name the cluster that
serves it, even when the port was copied from another cluster's.

`envsubst` is given the variable by name. A bare `envsubst` would also rewrite
every other `$` in the YAML, and a second variable on that allow-list would be a
second route for a per-cluster value into the shared tree.

## The SBOM

Every external artifact this repo installs is pinned in `.env.sbom` at the
checkout root. The entrypoint sources it before anything else, so a missing
file stops the run immediately rather than letting `up` proceed on some
downstream default. That strictness is the point: after this change there is
no second place a version is defined, and a fallback default would quietly
recreate one.

The pins split into two worlds, and only one of them can read a shell file.

`scripts/` installs six of them — the k3s image tag, Cilium, Flux, the Gateway API
CRDs, and the two probe-pod images — so those are read straight from
`.env.sbom` at runtime. They cannot drift from it, because there is nothing to
drift: the value in the file *is* the value used. Overrides still win: K3D_TAG
uses a `${K3D_TAG:-$K3S_IMAGE_TAG}` default, and `CILIUM_VERSION` shares its
name with the pin, so `scripts/pltfctl` saves an exported `CILIUM_VERSION`
before sourcing `.env.sbom` and restores it after. An explicit
`CILIUM_VERSION=1.19.4` on the command line still wins; the SBOM supplies the
default, it does not seize control.

The other four live inside `deploy/` manifests, and a manifest cannot source a
shell file. Rendering the tree through `envsubst` would fix that but would cost
something worth more: `deploy/` is plain YAML you can `kubectl apply` by hand,
which matters when debugging a cluster that will not reconcile. So the YAML
stays authoritative and `doctor` asserts the two still agree, failing if they
do not. An SBOM that is only written down drifts silently; the check is what
makes it real.

The check asserts an occurrence *count*, not merely a match, because one of
those pins appears more than once — kgateway's chart version, twice in one file.
Asserting presence alone would pass a bump
that updated one and missed the other, which is the likeliest way this drifts.
A missing manifest reports as a missing manifest rather than a version
mismatch, so a renamed file does not send the reader looking for a version
that was never wrong.

Bumping anything in `deploy/` therefore means editing two files — the manifest
and `.env.sbom` — and `doctor` fails until both are done. That is deliberate
friction, and it is cheap next to discovering months later that the recorded
version was never what ran.

## L2 announcements

Someone allocates a `CiliumLoadBalancerIPPool`, sees an EXTERNAL-IP appear on
their Service, and finds the address unreachable from anywhere except that
cluster.

Allocating an IP and *announcing* it are two different jobs. Cilium's LB IPAM
does the first. Nothing does the second unless you ask: either BGP, or L2
announcement, where a node answers ARP for the address on the local segment.

This was measured, not assumed. With a pool defined but `l2announcements`
off, a Service got `172.19.200.1` and:

    from inside its own cluster   HTTP=200
    from another cluster          curl (7) Failed to connect

Both clusters were containers on the same Docker bridge, so there was no
routing problem to blame — the address simply had nobody speaking for it.

`l2announcements.enabled=true` is therefore set in `cilium_install`, alongside
a raised `k8sClientRateLimit` (qps 50, burst 100). The second is not
decoration: announcements are held as Kubernetes Leases, and Cilium's default
5 qps client throttles the agent hard enough to make leases flap, which
presents as an address that works intermittently — worse to diagnose than one
that never works.

Enabling the feature does not create pools. pltfctl deliberately ships none,
because a pool is cluster-wide and claims **existing** LoadBalancer Services,
not just new ones. Defining one on a running cluster reassigns whatever is
already there — observed live, where a test pool silently took over the
platform gateway's Service address.
