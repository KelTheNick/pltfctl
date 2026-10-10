#!/usr/bin/env sh
# pltfctl Cilium CNI + ClusterMesh logic. Sourced by scripts/pltfctl.
# Function-only — no work at source time.

[ -n "${PLTFCTL_HOME:-}" ] && [ -d "$PLTFCTL_HOME/scripts/lib" ] || {
  printf '[err ] PLTFCTL_HOME unset or not a pltfctl checkout (got: %s)\n' \
    "${PLTFCTL_HOME:-<unset>}" >&2
  exit 1
}

# CILIUM_VERSION (installed by cilium-cli) comes from .env.sbom; an exported
# CILIUM_VERSION overrides it — see scripts/pltfctl, which restores the
# override after sourcing .env.sbom.

# How long a dead peer's endpoints stay cached before ClusterMesh drops them.
#
# Upstream default is 0s -- never drop. So a stopped cluster keeps being
# advertised by its peers, and traffic to it hangs until timeout instead of
# failing fast. pltfctl exists to make cluster loss testable, so it opts in.
#
# Measured at 60s: endpoints went ~144s after the cluster stopped, because the
# clock is detection (~84s) PLUS the TTL. The cost, and why upstream ships it
# off: a returning cluster is readmitted only after 3-4 minutes. Use 0s for
# upstream behaviour. Needs Cilium >= 1.19.0 (cilium#41643), ignored below.
PLTF_CLUSTERMESH_CACHE_TTL=${PLTF_CLUSTERMESH_CACHE_TTL:-60s}

cilium_installed() { # ctx
  kubectl --context "$1" -n kube-system get daemonset cilium >/dev/null 2>&1
}

# Control-plane node InternalIP: an IP, not a Service VIP or the k3d
# container name, since Cilium needs the apiserver reachable before any CNI
# or DNS exists. Must select node-role.kubernetes.io/control-plane
# specifically — `{.items[0]}` without it can return an agent node and
# crashloop cilium-agent. See scripts/README.md#the-shared-ca
cilium_node_ip() { # ctx
  kubectl --context "$1" get nodes \
    -l node-role.kubernetes.io/control-plane \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'
}

# Reference every Cilium image by tag, not tag@digest. pltf_preload_images
# copies images into the nodes with `k3d image import`, which keeps tags but
# not registry digests, so a digest reference would miss the local copy and
# pull anyway. The tags stay pinned through CILIUM_VERSION.
cilium_image_flags() {
  for _cf in image operator.image envoy.image hubble.relay.image \
    hubble.ui.backend.image hubble.ui.frontend.image clustermesh.apiserver.image; do
    printf -- '--set %s.useDigest=false ' "$_cf"
  done
}

# Install Cilium on one cluster and block until it reports healthy.
# Takes the SHORT cluster name (dev|1|2|3), not the kube context.
cilium_install() { # name
  # _ci_* names avoid clobbering cmd_up's per-cluster loop vars (_name/_ctx),
  # which this function runs inside of.
  _ci_name=$1
  _ci_ctx="k3d-$_ci_name"
  _ci_id=$(pltf_cluster_id "$_ci_name") || pltf_die "No cluster id for: $_ci_name"
  if cilium_installed "$_ci_ctx"; then
    pltf_info "Cilium already installed on $_ci_ctx; skipping install"
  else
    # `|| _ci_ip=''` matters under `set -eu`: without it, a failing
    # cilium_node_ip aborts here with kubectl's own error, and the
    # `[ -n "$_ci_ip" ]` guard's clearer pltfctl message never runs.
    _ci_ip=$(cilium_node_ip "$_ci_ctx") || _ci_ip=''
    [ -n "$_ci_ip" ] || pltf_die "Could not read a node InternalIP on $_ci_ctx"
    # Hubble relay + UI are opt-in (PLTF_ENABLE=hubble), read only here at
    # install. On a running cluster: cilium hubble enable --ui --context <ctx>
    _ci_hub=false; pltf_enabled hubble && _ci_hub=true
    pltf_step "installing Cilium $CILIUM_VERSION on $_ci_ctx (cluster.id=$_ci_id)"
    # clustermesh.enableEndpointSliceSynchronization=true is Beta upstream;
    # without it, per-pod clusterset.local records for a remote cluster's
    # members never resolve even though Service-level names work.
    # cgroup.autoMount.enabled=false + cgroup.hostRoot=/sys/fs/cgroup must
    # stay paired: without both, Cilium reports healthy while every
    # ClusterIP route is dead. See scripts/README.md#cgroup-and-the-datapath
    # l2announcements makes LoadBalancer IPs reachable OFF their own node.
    # Without it Cilium still ALLOCATES an IP from a CiliumLoadBalancerIPPool
    # and the Service looks healthy, but nothing ARPs for it, so the address
    # works only inside its own cluster. The raised k8sClientRateLimit goes
    # with it: L2 announcements hold leases, and the 5qps default throttles
    # the agent into flapping them. See scripts/README.md#l2-announcements
    # tls.secretsNamespace.name=kube-system requires create=false alongside
    # it, or Helm fails trying to adopt the pre-existing kube-system
    # namespace. See scripts/README.md#cilium-flag-pairs
    # --wait-duration defaults to 5m, which is the time cilium-cli allows for
    # its POST-INSTALL jobs. cilium-coredns-mcsapi-autoconfig rewrites the
    # CoreDNS config and restarts it, and its own pod has to pull an image
    # first -- so on a host with a cold or contended image cache it routinely
    # exceeds 5m. Measured at 5m48s and 7m+ on the same laptop.
    #
    # The failure is nasty because it is a LIE: `cilium install` prints
    # "context deadline exceeded" and returns non-zero, cmd_up treats the
    # cluster as failed and stops -- while the job goes on to complete
    # successfully seconds later. You are left with a partial fleet and an
    # error that reads like a broken install. See troubleshooting §5b in the
    # multi-cluster-kafka-poc repo.
    # shellcheck disable=SC2046 # word-split the flag list on purpose
    cilium install --context "$_ci_ctx" --version "$CILIUM_VERSION" $(cilium_image_flags) \
      --wait-duration 15m \
      --set cluster.name="$_ci_name" \
      --set cluster.id="$_ci_id" \
      --set ipam.mode=kubernetes \
      --set kubeProxyReplacement=true \
      --set k8sServiceHost="$_ci_ip" \
      --set k8sServicePort=6443 \
      --set cgroup.autoMount.enabled=false \
      --set cgroup.hostRoot=/sys/fs/cgroup \
      --set operator.replicas=1 \
      --set tls.secretsNamespace.name=kube-system \
      --set tls.secretsNamespace.create=false \
      --set hubble.relay.enabled="$_ci_hub" \
      --set hubble.ui.enabled="$_ci_hub" \
      --set clustermesh.mcsapi.enabled=true \
      --set clustermesh.mcsapi.corednsAutoConfigure.enabled=true \
      --set clustermesh.enableEndpointSliceSynchronization=true \
      --set clustermesh.cacheTTL="$PLTF_CLUSTERMESH_CACHE_TTL" \
      --set l2announcements.enabled=true \
      --set k8sClientRateLimit.qps=50 \
      --set k8sClientRateLimit.burst=100
  fi
  pltf_step "waiting for Cilium to report healthy on $_ci_ctx"
  # A DaemonSet can exist without a completed Helm release if `cilium
  # install` was interrupted, and cilium_installed's check alone can't tell
  # the difference — fail loudly with the exact recovery instead of hanging
  # in --wait or attempting an automatic repair.
  cilium status --context "$_ci_ctx" --wait ||
    pltf_die "Cilium never reported healthy on $_ci_ctx. If a previous 'cilium install' was interrupted, the DaemonSet can exist without a completed release, wedging every future 'up' here. Recover with: k3d cluster delete $_ci_name && ./scripts/pltfctl up $(pltf_cluster_distro "$_ci_name")"
  pltf_ok "Cilium ready on $_ci_ctx."
}

# Copies cilium-ca from src to dst, stamped with Helm ownership metadata so
# cilium-cli's Helm release ADOPTS the secret instead of failing with
# "invalid ownership metadata". Idempotent when the CA matches; a CA present
# but DIFFERING from src must fail loudly, not skip silently — the only
# alternative is a permanently mismatched mesh with mTLS failures that never
# point back here. See scripts/README.md#the-shared-ca
cilium_propagate_ca() { # src_ctx dst_ctx
  # _cm_* names avoid clobbering cmd_up's per-cluster loop vars, which call
  # this function for a DIFFERENT cluster than src/dst here.
  _cm_src=$1
  _cm_dst=$2
  _cm_have=$(kubectl --context "$_cm_dst" -n kube-system get secret cilium-ca \
    -o jsonpath='{.data.ca\.crt}' 2>/dev/null) || _cm_have=''
  if [ -n "$_cm_have" ]; then
    _cm_src_crt=$(kubectl --context "$_cm_src" -n kube-system get secret cilium-ca \
      -o jsonpath='{.data.ca\.crt}' 2>/dev/null) || _cm_src_crt=''
    [ "$_cm_have" = "$_cm_src_crt" ] ||
      pltf_die "cilium-ca on $_cm_dst differs from $_cm_src; mesh mTLS will fail. Recreate the fleet: ./scripts/pltfctl down && ./scripts/pltfctl up fleet"
    pltf_info "cilium-ca already present on $_cm_dst; skipping propagation"
    return 0
  fi
  _cm_crt=$(kubectl --context "$_cm_src" -n kube-system get secret cilium-ca \
    -o jsonpath='{.data.ca\.crt}' 2>/dev/null) || _cm_crt=''
  _cm_key=$(kubectl --context "$_cm_src" -n kube-system get secret cilium-ca \
    -o jsonpath='{.data.ca\.key}' 2>/dev/null) || _cm_key=''
  [ -n "$_cm_crt" ] && [ -n "$_cm_key" ] ||
    pltf_die "cilium-ca not found on $_cm_src; install Cilium there first"
  pltf_step "propagating cilium-ca from $_cm_src to $_cm_dst"
  kubectl --context "$_cm_dst" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: cilium-ca
  namespace: kube-system
  labels:
    app.kubernetes.io/managed-by: Helm
  annotations:
    meta.helm.sh/release-name: cilium
    meta.helm.sh/release-namespace: kube-system
data:
  ca.crt: $_cm_crt
  ca.key: $_cm_key
EOF
}

# Deploy clustermesh-apiserver. NodePort rather than LoadBalancer: k3d's
# klipper servicelb gives no stable address across clusters, while the shared
# Docker network makes node IPs directly routable.
clustermesh_enable() { # ctx
  if kubectl --context "$1" -n kube-system get deploy clustermesh-apiserver \
    >/dev/null 2>&1; then
    pltf_info "clustermesh already enabled on $1; skipping"
  else
    pltf_step "enabling clustermesh on $1 (NodePort, kvstoremesh)"
    cilium clustermesh enable --context "$1" \
      --service-type NodePort --enable-kvstoremesh
  fi
  cilium status --context "$1" --wait >/dev/null
}

# One-way invocation, bidirectional effect.
clustermesh_connect() { # src_ctx dst_ctx
  pltf_step "connecting $1 <-> $2"
  cilium clustermesh connect --context "$1" --destination-context "$2"
  pltf_step "waiting for the mesh to converge (up to 5m)"
  cilium clustermesh status --context "$1" --wait --wait-duration 5m
  pltf_ok "ClusterMesh established between $1 and $2."
}

clustermesh_status() { # ctx
  cilium clustermesh status --context "$1" ||
    pltf_info "[fail] clustermesh status unavailable on $1"
}

# clustermesh_connect's own --wait only confirms cluster-to-cluster
# connectivity, not that per-service EndpointSlice mirroring has populated
# the peer's kube-public namespace yet — a measured gap of several seconds
# on a clean `up`, during which `verify`'s first assertion can race the
# mirror and see a hard 0/N. Waiting HERE, not only inside `verify`, means
# every consumer of `up` gets an accurate signal. Self-adjusting: counts the
# source's own ServiceExports rather than a hardcoded number, so a third
# sample workload's ServiceExport is never silently under-waited.
# See scripts/README.md#mesh-convergence
pltf_wait_mesh_mirrors() { # src_name src_ctx dst_ctx
  # Never use `$(kubectl … | wc -l)` for either count: a pipeline's exit
  # status comes from the LAST command, so `wc` succeeding on empty input
  # from a FAILED kubectl masks the failure as a plausible zero — silently
  # skipping the wait, or turning an API failure into a bogus mirroring
  # timeout. Each query's own exit status is captured first, as a separate
  # step.
  if ! _wmm_out=$(kubectl --context "$2" -n kube-public get serviceexports \
    -o name 2>&1); then
    pltf_die "cannot list ServiceExports in kube-public on $2, so the mesh-mirror wait cannot run — refusing to skip it silently and let 'up' claim the mesh is ready. kubectl said: $_wmm_out"
  fi
  _wmm_want=$(printf '%s' "$_wmm_out" | grep -c . || true)
  if [ "$_wmm_want" -eq 0 ]; then
    pltf_info "no ServiceExports in kube-public on $2; nothing for $3 to mirror, skipping the wait"
    return 0
  fi

  pltf_step "waiting for $3 to mirror $2's $_wmm_want ServiceExport(s) (up to 120s)"
  _wmm_elapsed=0
  _wmm_have=0
  _wmm_lasterr=''
  while :; do
    # A transient API blip retries within budget rather than aborting `up`
    # or masquerading as slow mirroring.
    if _wmm_out=$(kubectl --context "$3" -n kube-public get endpointslices \
      -l "multicluster.kubernetes.io/source-cluster=$1" -o name 2>&1); then
      _wmm_lasterr=''
      _wmm_have=$(printf '%s' "$_wmm_out" | grep -c . || true)
      [ "$_wmm_have" -ge "$_wmm_want" ] && break
    else
      _wmm_lasterr=$_wmm_out
      # Throttled to avoid ~60 identical lines burying the error that ends
      # the loop.
      if [ "$((_wmm_elapsed % 30))" -eq 0 ]; then
        pltf_info "[warn] could not query $3's EndpointSlices, retrying: $_wmm_out"
      fi
    fi
    if [ "$_wmm_elapsed" -ge 120 ]; then
      if [ -n "$_wmm_lasterr" ]; then
        pltf_die "mesh convergence check failed after 120s: could not query $3's EndpointSlices. This is an API/access failure, NOT evidence that mirroring is broken — check the context and cluster before investigating ClusterMesh. kubectl said: $_wmm_lasterr"
      fi
      pltf_die "mesh convergence timed out after 120s: $3 mirrors $_wmm_have/$_wmm_want of $1's ServiceExports (label multicluster.kubernetes.io/source-cluster=$1 in kube-public). ClusterMesh reported connected but EndpointSlice mirroring never caught up — inspect 'kubectl --context $3 -n kube-public get endpointslices -l multicluster.kubernetes.io/source-cluster=$1', or recreate the fleet: ./scripts/pltfctl down && ./scripts/pltfctl up fleet"
    fi
    sleep 2
    _wmm_elapsed=$((_wmm_elapsed + 2))
  done
  pltf_ok "$3 mirrors all $_wmm_want of $1's ServiceExports (converged in ${_wmm_elapsed}s)."
}

# ---------------------------------------------------- clusterset DNS zone ----
# Put the clusterset.local zone in `coredns-custom`, which k3s does not own.
#
# THE PROBLEM. Cilium writes that zone into the `coredns` ConfigMap once, at
# install. k3s owns that ConfigMap as a bundled addon and re-applies its own
# copy on restart, so the zone vanishes. Nothing is misbehaving -- k3s owns the
# object, Cilium wrote once and assumed it would stay. Health checks all pass
# while every cross-cluster name returns NXDOMAIN.
#
# THE FIX. k3s's Corefile ends with `import /etc/coredns/custom/*.server`, fed
# by the `coredns-custom` ConfigMap, which k3s does NOT reconcile (k3s#7639,
# v1.27.3+k3s1). Declaring the zone there leaves nothing to revert -- the
# damage stops happening rather than being detected and undone.
#
# Measured: zone deleted from the k3s-owned ConfigMap, cluster restarted, no
# repair run -- names kept resolving and `verify` passed 45/45. corednsAuto-
# Configure stays on: its write is redundant now, but harmless as a fallback.
pltf_coredns_clusterset_zone() { # ctx
  pltf_step "serving clusterset.local from coredns-custom on $1 (survives restarts)"
  kubectl --context "$1" apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  clusterset.server: |
    clusterset.local:53 {
      errors
      ready
      kubernetes clusterset.local {
        multicluster clusterset.local
        pods insecure
      }
      cache 30
      loop
      reload
    }
YAML
  kubectl --context "$1" -n kube-system rollout restart deploy/coredns >/dev/null 2>&1 || true
  kubectl --context "$1" -n kube-system rollout status deploy/coredns --timeout=180s >/dev/null 2>&1 || true
}
