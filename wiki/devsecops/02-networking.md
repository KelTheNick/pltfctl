# Networking

This page covers how pods get addresses, how traffic is routed inside and between clusters, and how names resolve. Most of the hard rules here exist because breaking them leaves a cluster that reports healthy while traffic is dead.

## CNI per distro

| Distro | CNI | kube-proxy | NetworkPolicy controller |
|---|---|---|---|
| `lite`, `fleet` | Cilium (eBPF) | no, Cilium replaces it | disabled in k3s |

Sources: `infra/k3d/fleet.env`, `infra/k3d/lite/lite.yaml`, `infra/k3d/fleet/*.yaml`.

No distro uses flannel today; `PLTF_DISTRO_<D>_CNI=flannel` is still a valid value.

On Cilium distros the k3s server runs with `--flannel-backend=none`, `--disable-network-policy` and `--disable-kube-proxy`. Nodes stay `NotReady` until `cilium install` runs. Cilium is installed with `kubeProxyReplacement=true` (`scripts/lib/pltfctl/cilium.sh`).

Consequence: on `lite` and `fleet`, any tool that works by editing kube-proxy's iptables rules has nothing to edit. Submariner is the case that surfaced this. Do not record it as "Cilium conflicts with Submariner": Cilium runs alongside kube-proxy perfectly well and does not need to replace it. Replacing kube-proxy is pltfctl's choice, not a Cilium limitation. Undoing it needs a rebuild and two changes together: drop `--flannel-backend=none` and `--disable-kube-proxy` from the distro's k3d template, and set `PLTF_DISTRO_<D>_CNI=flannel` in `infra/k3d/fleet.env` so Cilium is not installed. Changing only `CNI` would leave the cluster with no network at all.

## CIDRs

| Cluster | Pod CIDR | Service CIDR | Cluster DNS |
|---|---|---|---|
| `lite`, `ops` | 10.42.0.0/16 | 10.43.0.0/16 | 10.43.0.10 |

Source: `infra/k3d/fleet.env`.

**Rule: CIDRs must not overlap within a meshed distro.** ClusterMesh routes pod and service addresses between clusters; if two clusters share a range, an address is ambiguous. Repeating ranges across distros is fine because only one distro runs at a time. CIDRs are create-time only (`infra/k3d/fleet.env`, `docs/contributing/03-fleet.md`).

## k8sServiceHost is the control-plane InternalIP

Cilium must reach the apiserver before any CNI or cluster DNS exists, so `k8sServiceHost` is an IP, not a Service VIP or a container name. It is the InternalIP of the node selected with `node-role.kubernetes.io/control-plane` (`cilium_node_ip` in `scripts/lib/pltfctl/cilium.sh`).

- Without the role selector, the first node in the list can be an agent (on `lite`). The `cilium-agent` config init container then cannot reach the apiserver and crashloops in a way that looks like an eBPF failure.
- The k3d serverlb (the load-balancer container in front of the cluster) is not an alternative: its IP is not in the apiserver certificate's SANs, and its name cannot resolve before cluster DNS exists (`scripts/README.md`).

## The cgroup flag pair

`cgroup.autoMount.enabled=false` and `cgroup.hostRoot=/sys/fs/cgroup` must be set together. k3d nodes are containers with a private cgroup namespace. Cilium's default auto-mount lands on a cgroup with no pods under it, so the socket-level BPF programs that implement kube-proxy replacement never fire. Cilium then reports healthy while every ClusterIP route is dead. "Cilium started" is not evidence the datapath works; only real ClusterIP traffic is (`scripts/lib/pltfctl/cilium.sh`, `scripts/README.md`).

## L2 announcements

`l2announcements.enabled=true` lets a node answer ARP for a LoadBalancer IP, so the address is reachable from outside its own cluster. Without it, Cilium still allocates an IP from a pool and the Service looks healthy, but nothing announces it. It goes with a raised client rate limit (`k8sClientRateLimit.qps=50`, `burst=100`): announcements are held as Kubernetes Leases, and the default 5 qps makes them flap (`scripts/lib/pltfctl/cilium.sh`, `scripts/README.md`).

pltfctl ships no `CiliumLoadBalancerIPPool`. A pool is cluster-wide and claims existing LoadBalancer Services; a test pool was observed taking over the platform gateway's address (`scripts/README.md`).

## DNS

**The Docker bridge gateway is silent.** k3s points a node's `resolv.conf` at the gateway of the Docker bridge network, and CoreDNS forwards there by default. That address runs no DNS listener at all. This was confirmed with a plain Docker container on the same bridge, with no Kubernetes or Cilium involved. Left alone, CoreDNS returns `SERVFAIL` and Flux cannot pull external charts (`infra/k3d/network/resolv.conf`, `scripts/README.md`).

**The fix.** Every k3d template bind-mounts a resolver file at `/etc/pltfctl/resolv.conf` and passes `--resolv-conf=/etc/pltfctl/resolv.conf` to k3s. The default file is `infra/k3d/network/resolv.conf` (`1.1.1.1`, `8.8.8.8`). This applies to all distros, including `lite`, because it is a host fact, not a CNI one (`infra/k3d/*/*.yaml`).

**`PLTF_RESOLV_CONF`** overrides which file is mounted. Use it on a corporate LAN, behind a VPN that blocks outbound port 53, on an air-gapped host, or to reach an internal chart source. Its default is resolved in `scripts/pltfctl` because the plain `envsubst` used for templates cannot expand `${VAR:-default}` (`scripts/pltfctl`, `scripts/README.md`).

## ClusterMesh

ClusterMesh is Cilium's feature for joining clusters so pods and services in one can reach the other. On `fleet` (`PLTF_DISTRO_FLEET_MESH=true`), after every cluster is up (`pltf_up_mesh` in `scripts/lib/pltfctl/cmds.sh`). With the single cluster `ops` only step 1 does anything; steps 2 and 3 apply once a second cluster is added:

1. `clustermesh enable` on each cluster: `clustermesh-apiserver` as a NodePort with kvstoremesh. NodePort, not LoadBalancer, because k3d's servicelb gives no stable cross-cluster address while the shared Docker network makes node IPs routable (`scripts/lib/pltfctl/cilium.sh`).
2. `clustermesh connect` once per **unordered** pair. With two clusters that would be one pair; ClusterMesh is not transitive, so a third cluster would need every pair connected (`scripts/README.md`).
3. A mirror wait once per **ordered** pair (see below).

Each cluster has a Cilium cluster ID (1 to 255, unique in the mesh) from `fleet.env`. Single-cluster Cilium distros also get a name and ID, so they could be meshed later without reinstalling the CNI (`scripts/lib/pltfctl/cmds.sh`).

## MCS-API and clusterset.local

MCS-API (the Kubernetes Multi-Cluster Services API) gives exported services a cross-cluster DNS name under `clusterset.local`. Cilium is installed with `clustermesh.mcsapi.enabled=true` (`scripts/lib/pltfctl/cilium.sh`).

**The zone lives in `coredns-custom`.** Cilium writes the `clusterset.local` zone into the k3s-owned `coredns` ConfigMap once. k3s re-applies its own copy on restart, so the zone vanishes and cross-cluster names return NXDOMAIN while health checks pass. k3s does not reconcile `coredns-custom`, so pltfctl declares the zone there, right after the CNI installs (`pltf_coredns_clusterset_zone` in `scripts/lib/pltfctl/cilium.sh`).

## EndpointSlice sync and the mirror wait

`clustermesh.enableEndpointSliceSynchronization=true` (Beta upstream) mirrors a remote cluster's per-pod EndpointSlices locally. Without it, service-level `clusterset.local` names work but per-pod names (for example `podinfo-0.<cluster>.podinfo.kube-public.svc.clusterset.local`) never resolve (`scripts/README.md`).

The sync annotation must sit on the `ServiceExport`, not the `Service`. Setting it in both places merges both clusters' pod IPs under the same hostnames (`deploy/k3d-lite/kube-public/podinfo-export.yaml`).

`clustermesh connect --wait` proves only connectivity, not that mirroring has finished. `pltf_wait_mesh_mirrors` waits (up to 120s) until the destination carries at least as many mirrored EndpointSlices as the source has ServiceExports. Without it, a `verify` straight after `up` was measured seeing 0/N (`scripts/lib/pltfctl/cilium.sh`, `scripts/README.md`).

## cacheTTL trade-off

`clustermesh.cacheTTL` defaults to `60s` here (`PLTF_CLUSTERMESH_CACHE_TTL`). Upstream defaults to `0s`, never dropping a dead peer's endpoints, so traffic to a stopped cluster hangs instead of failing fast. pltfctl exists to make cluster loss testable, so it opts in. Measured: endpoints dropped about 144s after a cluster stopped (detection plus TTL). The cost: a returning cluster is readmitted only after 3 to 4 minutes. Set `0s` for upstream behaviour. Needs Cilium >= 1.19.0 (`scripts/lib/pltfctl/cilium.sh`).

## Host ports

All host ports bind to the workstation. See [Gateways](03-gateways.md) for the LB ports.

| Cluster | API | LB HTTP | LB HTTPS (reserved) |
|---|---|---|---|
| `lite`, `ops` | 6550 | 8080 | 8443 |
| registry (`lite`, `ops`) | 5001 | | |

The API binds to `127.0.0.1` under the host name `k3d.local.gd`, which resolves to `127.0.0.1`. The registry's `host` is `0.0.0.0` (`infra/k3d/fleet.env`, `infra/k3d/*/*.yaml`).

---

← Previous: [Infrastructure](01-infrastructure.md) · [Index](00-index.md) · Next: [Gateways](03-gateways.md) →
