#!/usr/bin/env sh
# pltfctl subcommands. Sourced by scripts/pltfctl (which sets PLTFCTL_HOME).
# Function-only — no work at source time.

[ -n "${PLTFCTL_HOME:-}" ] && [ -d "$PLTFCTL_HOME/scripts/lib" ] || {
  printf '[err ] PLTFCTL_HOME unset or not a pltfctl checkout (got: %s)\n' \
    "${PLTFCTL_HOME:-<unset>}" >&2
  exit 1
}

# UI name -> path. The hostname is pltf_ui_host ([<prefix>-]<ui>.<domain>) and every
# pltfctl code path takes the port from pltf_lb_http_port, so no two of them can
# disagree. That helper reads infra/fleet.env, the same file the k3d configs
# are rendered from, so the two cannot drift.
pltf_ui_path() { # ui
  case "$1" in
    argus | hubble | podinfo) printf '/\n' ;;
    gateway)                  printf '/readyz\n' ;;
    *)                        return 1 ;;
  esac
}

PLTF_UIS='argus hubble podinfo gateway'

# Refuse to start a distro while a DIFFERENT one is running: distros share
# host ports, so the second create would fail half-way with a bind error.
pltf_guard_one_distro() { # distro
  _gd_running=$(pltf_running_distro) || return 0
  [ "$_gd_running" = "$1" ] && return 0
  pltf_die "Distro '$_gd_running' is running; distros share host ports. Run 'pltfctl down' first."
}

# Create (or adopt) one cluster's k3d cluster, healing a stale kube context.
pltf_up_k3d() { # name
  if pltf_cluster_exists "$1"; then
    pltf_info "Cluster k3d-$1 already exists; skipping create"
    # k3d's inventory and the kubeconfig `up` depends on can drift apart —
    # "exists" says nothing about whether `kubectl --context k3d-$1` works.
    # `k3d kubeconfig merge` is idempotent, so recovering costs nothing.
    if ! kubectl --context "k3d-$1" version >/dev/null 2>&1; then
      pltf_info "kube context k3d-$1 unusable; running 'k3d kubeconfig merge $1 --kubeconfig-merge-default'"
      k3d kubeconfig merge "$1" --kubeconfig-merge-default >/dev/null || true
      kubectl --context "k3d-$1" version >/dev/null 2>&1 ||
        pltf_die "kube context k3d-$1 is still unusable after 'k3d kubeconfig merge'. Recreate it: k3d cluster delete $1 && ./scripts/pltfctl up $(pltf_cluster_distro "$1")"
    fi
    return 0
  fi
  _uk_cfg=$(pltf_k3d_config "$1")
  [ -f "$_uk_cfg" ] || pltf_die "Missing k3d config: $_uk_cfg"
  pltf_step "k3d cluster create --config ${_uk_cfg#"$PLTFCTL_HOME"/} (envsubst-rendered)"
  # Render first, so a fleet.env gap fails here with its own message rather
  # than as k3d choking on a half-rendered config.
  _uk_yaml=$(pltf_render_k3d_config "$1" "$_uk_cfg")
  printf '%s\n' "$_uk_yaml" | k3d cluster create --config -
  pltf_preload_images "$1"
}

cmd_up() { # distro
  _distro=${1:-$PLTF_DEFAULT_DISTRO}
  _clusters=$(pltf_distro_clusters "$_distro") ||
    pltf_die "Unknown distro: $_distro (expected: $(pltf_distro_names))"
  _cni=$(pltf_distro "$_distro" CNI)
  pltf_require_cmd docker
  pltf_require_cmd k3d
  pltf_require_cmd kubectl
  [ "$_cni" = cilium ] && pltf_require_cmd cilium
  pltf_guard_one_distro "$_distro"

  _head=$(printf '%s\n' "$_clusters" | head -n 1)
  for _name in $_clusters; do
    pltf_up_k3d "$_name"
    if [ "$_cni" = cilium ]; then
      if [ "$_name" != "$_head" ]; then
        cilium_propagate_ca "k3d-$_head" "k3d-$_name"
      fi
      cilium_install "$_name"
      # Immediately after the CNI, and before anything needs cross-cluster DNS.
      pltf_coredns_clusterset_zone "k3d-$_name"
    fi
    pltf_apply_cluster_info "$_name"
    pltf_apply_podinfo_tls "$_name"
    flux_bootstrap "k3d-$_name"
    pltf_step "applying deploy/k3d-$_name to k3d-$_name"
    flux_apply_tree "k3d-$_name"
    pltf_step "waiting for k3d-$_name HelmReleases to converge (up to 10m)"
    kubectl --context "k3d-$_name" -n kube-system wait --for=condition=Ready \
      --timeout=600s helmrelease --all >/dev/null 2>&1 ||
      pltf_info "[warn] not every HelmRelease on k3d-$_name is Ready yet; see 'pltfctl status'"
    pltf_wait_gateway "$_name"
    pltf_wait_sample_workloads "$_name"
    pltf_ok "k3d-$_name fabric applied (LB on :$(pltf_lb_http_port "$_name"))."
  done

  _count=$(printf '%s\n' "$_clusters" | wc -l | tr -d ' ')
  [ "$_count" -ge 2 ] && pltf_up_mesh "$_clusters"
  pltf_ok "Distro '$_distro' is up. Try: http://$(pltf_ui_host "$_head" argus):$(pltf_lb_http_port "$_head")/"
}

# The Gateway's proxy Deployment is created by the kgateway controller only
# AFTER its HelmRelease is Ready and the Gateway is reconciled, so "every
# HelmRelease Ready" still leaves a window where nothing listens on the LB
# port. Measured on lite: the proxy appeared ~50s after `up` had returned.
# Wait for it to exist, then to roll out, so `up` returning means the routes
# answer. Non-fatal, like the other waits: `status` reports the outcome.
pltf_wait_gateway() { # name
  pltf_step "waiting for the k3d-$1 gateway proxy to serve (up to 5m)"
  _wg_i=0
  until kubectl --context "k3d-$1" -n kube-system get deploy/gw-api-kgateway >/dev/null 2>&1; do
    _wg_i=$((_wg_i + 1))
    if [ "$_wg_i" -ge 60 ]; then
      pltf_info "[warn] gateway proxy deploy/gw-api-kgateway never appeared on k3d-$1"
      return 0
    fi
    sleep 5
  done
  kubectl --context "k3d-$1" -n kube-system rollout status deploy/gw-api-kgateway \
    --timeout=300s >/dev/null 2>&1 ||
    pltf_info "[warn] gateway proxy did not roll out within 5m on k3d-$1"
}

# podinfo's image pull can be slow on a cold node, and EndpointSlice sync
# cannot mirror a pod that
# does not exist yet — waiting here buys `verify` a head start. podinfo is in
# k3d-base, so every distro has it. Non-fatal: a slow pull on a constrained
# host should not hard-fail `up`.
pltf_wait_sample_workloads() { # name
  pltf_step "waiting for k3d-$1 podinfo to roll out (up to 5m)"
  kubectl --context "k3d-$1" -n kube-public rollout status \
    statefulset/podinfo --timeout=300s >/dev/null 2>&1 ||
    pltf_info "[warn] podinfo did not roll out within 5m on k3d-$1; 'verify' may need a retry"
}

# ClusterMesh across every cluster of a multi-cluster distro. Cilium is still
# installed with cluster.name/cluster.id on single-cluster distros, so they
# could be meshed later without reinstalling the CNI.
pltf_up_mesh() { # clusters (newline-separated)
  for _name in $1; do
    clustermesh_enable "k3d-$_name"
  done
  # Connect every UNORDERED pair: ClusterMesh is not transitive, and `_seen`
  # keeps each pair to one (bidirectional) connect.
  # See scripts/README.md#mesh-convergence
  _seen=''
  for _a in $1; do
    for _b in $1; do
      if [ "$_a" = "$_b" ]; then continue; fi
      case " $_seen " in *" $_b:$_a "*) continue ;; esac
      clustermesh_connect "k3d-$_a" "k3d-$_b"
      _seen="$_seen $_a:$_b"
    done
  done
  # --wait above proves connectivity, not that mirroring has caught up. This
  # runs over every ORDERED pair, because mirroring is directional.
  # See scripts/README.md#mesh-convergence
  for _a in $1; do
    for _b in $1; do
      if [ "$_a" = "$_b" ]; then continue; fi
      pltf_wait_mesh_mirrors "$_a" "k3d-$_a" "k3d-$_b"
    done
  done
}

cmd_down() {
  pltf_require_cmd k3d
  _found=0
  for _name in $(pltf_existing_clusters); do
    _found=1
    pltf_step "k3d cluster delete $_name"
    k3d cluster delete "$_name"
    pltf_kube_unset_user "$_name"
  done
  # The registry is cluster-managed (created by the distro's first cluster)
  # and normally dies with it; delete any imperative leftover so the next
  # `up` never hits a name/port collision.
  if pltf_registry_exists; then
    pltf_step "k3d registry delete $PLTF_REGISTRY_NAME"
    k3d registry delete "$PLTF_REGISTRY_NAME" || true
  fi
  # k3d can leave the shared cluster network behind when the registry still had
  # an endpoint at delete time, and it never garbage-collects a network it did
  # not create. Remove it quietly.
  docker network rm "$PLTF_NETWORK" >/dev/null 2>&1 || true
  if [ "$_found" -eq 1 ]; then
    pltf_ok "All pltfctl clusters are down."
  else
    pltf_info "No pltfctl clusters present; nothing to delete"
  fi
}

# cmd_status lives in status.sh.

PLTF_PROBE_POD=mesh-probe

# One container on the podinfo image: it ships curl, nc and podcli, which
# cover every protocol, so the probe pulls no image the server did not.
# See scripts/README.md#the-probe-pod
#
# Created once per PROBE CLUSTER and reused by every assertion made from it,
# including those against several targets; cmd_verify's trap removes every
# cluster's probe pod even when an assertion fails or a run dies outright.
#
# sleep 2700 is sized for the three-cluster worst case (~1150s of sampling
# plus startup); 1800 was sized for two. If the containers exit mid-run, the
# remaining `kubectl exec`s fail and checks report 0/N — indistinguishable
# from a genuine mesh failure. See scripts/README.md#the-probe-pod
pltf_probe_start() { # ctx
  kubectl --context "$1" -n kube-public delete pod "$PLTF_PROBE_POD" \
    --ignore-not-found --wait=true >/dev/null 2>&1 || true
  pltf_step "starting probe pod in $1"
  kubectl --context "$1" -n kube-public apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $PLTF_PROBE_POD
  namespace: kube-public
spec:
  restartPolicy: Never
  containers:
    - name: probe
      image: $PODINFO_IMAGE
      command: ["sleep", "2700"]
EOF
  kubectl --context "$1" -n kube-public wait --for=condition=Ready \
    "pod/$PLTF_PROBE_POD" --timeout=120s >/dev/null ||
    pltf_die "probe pod never became ready in $1"
}

pltf_probe_stop() { # ctx
  kubectl --context "$1" -n kube-public delete pod "$PLTF_PROBE_POD" \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

# The probe pod has a single container that speaks every protocol.
pltf_probe_container() { # protocol
  printf 'probe\n'
}

# Prints the in-pod shell command for one sample from $2 over protocol $1,
# writing the responding cluster's bare name to stdout — every protocol
# resolves to the same output shape so the tally logic stays protocol-blind.
#
# tcp's \r\n is resolved by THIS printf (run on the host by pltfctl); the
# in-pod printf that ends up executing already receives literal CR/LF bytes
# and must not itself try to interpret \r\n, or the request line
# double-escapes and breaks. See scripts/README.md#the-probe-pod
pltf_probe_snippet() { # protocol fqdn
  case "$1" in
    http)
      printf "curl -s -m 5 http://%s/api/info | grep '\"message\"' | cut -d'\"' -f4" "$2" ;;
    tls)
      printf "curl -sk -m 5 https://%s/api/info | grep '\"message\"' | cut -d'\"' -f4" "$2" ;;
    tcp)
      printf "printf 'GET /api/info HTTP/1.0\\r\\n\\r\\n' | nc -w 5 %s %s | grep '\"message\"' | cut -d'\"' -f4" \
        "${2%:*}" "${2##*:}" ;;
    grpc)
      # podinfo registers gRPC health only under its own cluster name, so
      # asking for each fleet cluster's name in turn prints the one that
      # answered SERVING. On a per-pod address only the owner can answer.
      # shellcheck disable=SC2016 # $c expands in the pod, not here
      printf 'for c in %s; do podcli check grpc %s --service=$c --timeout=5s >/dev/null 2>&1 && echo $c; done' \
        "$PLTF_VERIFY_FLEET" "$2" ;;
    *)
      return 1 ;;
  esac
}

# Sample $3 N times over protocol $1 from the probe pod in $2; print one
# "<count> <cluster>" line per responding cluster. $3 may embed a port (e.g.
# "host:9898"), inlined straight into whichever client the protocol
# dispatches to.
pltf_probe_tally() { # protocol ctx fqdn attempts
  _pt_snip=$(pltf_probe_snippet "$1" "$3") || pltf_die "unknown probe protocol: $1"
  kubectl --context "$2" -n kube-public exec "$PLTF_PROBE_POD" \
    -c "$(pltf_probe_container "$1")" -- \
    sh -c "for i in \$(seq 1 $4); do $_pt_snip; done" 2>/dev/null |
    sort | uniq -c
}

# Sum a tally's samples for one cluster. The tally is `uniq -c` output
# ("<count> <cluster>" lines) and may hold SEVERAL lines per cluster once
# rounds are accumulated, so this sums rather than reads the first match.
# Prints 0 for a cluster that never answered.
pltf_tally_count() { # tally_text cluster
  printf '%s\n' "$1" | awk -v c="$2" '$2==c{n+=$1} END{print n+0}'
}

# Fail unless EVERY cluster in the fleet served at least one response.
#
# Fleet-derived, not hardcoded: testing clusters by literal name silently
# degraded the moment a third cluster joined, since a fleet-wide name reaching
# only two of three would still have passed.
#
# Self-extends up to two extra rounds. Safe ONLY because this asserts a
# MONOTONE property, unlike pltf_assert_all_from below — never add retries
# there. The skew this absorbs gets harder as the fleet grows.
# See scripts/README.md#the-assertion-asymmetry
pltf_assert_all_clusters() { # protocol ctx fqdn attempts label
  _aac_fleet=$(pltf_existing_clusters | tr '\n' ' ')
  _aac_acc=''
  _aac_total=0
  _aac_round=0
  _aac_missing=''
  while [ "$_aac_round" -lt 3 ]; do
    _aac_round=$((_aac_round + 1))
    # Accumulate raw tally text across rounds and re-sum, rather than keeping
    # per-cluster running totals: with a variable-length fleet there are no
    # arrays in POSIX sh to hold them in.
    _aac_acc="$_aac_acc
$(pltf_probe_tally "$1" "$2" "$3" "$4")"
    _aac_total=$((_aac_total + $4))
    _aac_missing=''
    for _aac_c in $_aac_fleet; do
      if [ "$(pltf_tally_count "$_aac_acc" "$_aac_c")" -eq 0 ]; then
        _aac_missing="$_aac_missing $_aac_c"
      fi
    done
    if [ -z "$_aac_missing" ]; then break; fi
  done
  _aac_line=''
  for _aac_c in $_aac_fleet; do
    _aac_line="$_aac_line   $_aac_c: $(pltf_tally_count "$_aac_acc" "$_aac_c")/$_aac_total"
  done
  printf '      %s   (%s round(s) sampled)\n' "$_aac_line" "$_aac_round"
  if [ -z "$_aac_missing" ]; then
    if [ "$_aac_round" -gt 1 ]; then
      pltf_ok "$5 (needed extension: $_aac_total samples across $_aac_round rounds)"
    else
      pltf_ok "$5"
    fi
    return 0
  fi
  pltf_info "[fail] $5 (no response from:$_aac_missing — every cluster in the fleet must answer at least once; $_aac_total samples across $_aac_round rounds)"
  return 1
}

# Fail unless EVERY response names $5 — per-pod addressing, where a single
# mis-attributed response is proof of a bug, not noise. Non-monotone: more
# samples only create more chances to fail; that is deliberate, not a gap.
# See scripts/README.md#the-assertion-asymmetry
pltf_assert_all_from() { # protocol ctx fqdn attempts want_cluster label
  _tally=$(pltf_probe_tally "$1" "$2" "$3" "$4")
  _want=$(printf '%s\n' "$_tally" | awk -v c="$5" '$2==c{print $1}')
  _other=$(printf '%s\n' "$_tally" | awk -v c="$5" '$2!=c{n+=$1} END{print n+0}')
  [ -n "$_want" ] || _want=0
  printf '       %s: %s/%s   other-cluster: %s/%s\n' "$5" "$_want" "$4" "$_other" "$4"
  if [ "$_want" -eq "$4" ] && [ "$_other" -eq 0 ]; then
    pltf_ok "$6"
    return 0
  fi
  pltf_info "[fail] $6 ($5=$_want other-cluster=$_other of $4; every response must name $5)"
  return 1
}

# Run the full assertion set with the probe pod living in $1 (context),
# proving that $2 can reach EVERY cluster named in $3.. through the mesh.
# Called once per probe cluster, so a one-way mesh failure cannot hide behind
# a probe that only ever runs from the other side.
#
# Targets are variadic because ClusterMesh is not transitive: three clusters
# means six ordered directions, and a call-per-direction would start six probe
# pods and re-run the target-independent aggregate checks six times instead of
# three. Aggregates run ONCE per probe cluster; per-pod and grpc-health checks
# run once per target.
#
# Uses _dir_rc, not cmd_verify's _rc: POSIX sh has no `local`, so reusing the
# caller's accumulator would let a later probe cluster's reset-on-entry erase
# a failure an earlier one recorded.
pltf_verify_from() { # probe_ctx probe_name target_name...
  _vf_ctx=$1
  _vf_name=$2
  shift 2
  _vf_targets="$*"
  pltf_probe_start "$_vf_ctx"
  _dir_rc=0

  # Aggregate + per-pod for each protocol. Aggregate proves the fleet-wide
  # name load-balances across clusters; per-pod proves a specific NAMED pod in
  # a remote cluster is addressable. Both matter: any workload whose members
  # hand each other their own address needs the second, not just the first.
  #
  # Each per-pod name ($_svc-0, e.g. podinfo-0) exists in EVERY cluster —
  # every StatefulSet manifest here is applied unchanged to each cluster — so
  # it is the `.<cluster>.` segment in the FQDN, not pod-name uniqueness,
  # that disambiguates which cluster's pod is being addressed. The tally
  # (parsed by pltf_probe_snippet's protocol-specific cut) is what proves the
  # resolved record is actually attributed to that cluster rather than some
  # mix of both.
  #
  # Per-pod records resolve to the bare pod IP with NO Service-level port
  # translation, so both columns use the same port here only because the
  # Services deliberately publish the container ports unchanged.
  for _proto in http tcp tls grpc; do
    case "$_proto" in
      http) _svc=podinfo;       _port=9898 ;;
      tcp)  _svc=podinfo;       _port=9898 ;;  # raw socket, not curl
      tls)  _svc=podinfo;       _port=9899 ;;
      grpc) _svc=podinfo;       _port=9999 ;;
    esac

    _agg="$_svc.kube-public.svc.clusterset.local:$_port"
    pltf_step "[$_vf_name -> mesh] $_proto aggregate -> $_agg"
    pltf_assert_all_clusters "$_proto" "$_vf_ctx" "$_agg" 10 \
      "$_proto: fleet-wide FQDN load-balances across every cluster" || _dir_rc=1

    for _tgt in $_vf_targets; do
      _pod="$_svc-0.$_tgt.$_svc.kube-public.svc.clusterset.local:$_port"
      pltf_step "[$_vf_name -> $_tgt] $_proto per-pod -> $_pod (10x, every response must be $_tgt)"
      pltf_assert_all_from "$_proto" "$_vf_ctx" "$_pod" 10 "$_tgt" \
        "$_proto: per-pod cross-cluster FQDN resolves from $_vf_name to $_tgt" || _dir_rc=1
    done
  done

  # Cilium global services work independently of MCS-API. This tests a Cilium
  # mechanism rather than a protocol, so it runs once on HTTP rather than four
  # times — and once per probe cluster rather than once per target, since it
  # names no target.
  _cl="podinfo.kube-public.svc.cluster.local:9898"
  pltf_step "[$_vf_name -> mesh] global service -> $_cl"
  pltf_assert_all_clusters http "$_vf_ctx" "$_cl" 10 \
    "global service resolves fleet-wide" || _dir_rc=1

  # A second, protocol-native attribution signal for gRPC: podinfo registers
  # its health service under --grpc-service-name, which is set to the cluster
  # name. Asking the remote pod whether it serves "$_tgt" therefore SERVES
  # only if that pod really is in $_tgt. (The per-pod gRPC samples above use
  # the same signal; this is the single, explicit health assertion.)
  for _tgt in $_vf_targets; do
    _hfq="podinfo-0.$_tgt.podinfo.kube-public.svc.clusterset.local:9999"
    pltf_step "[$_vf_name -> $_tgt] grpc health -> $_hfq (service=$_tgt must be SERVING)"
    if kubectl --context "$_vf_ctx" -n kube-public exec "$PLTF_PROBE_POD" -c probe -- \
      podcli check grpc "$_hfq" --service="$_tgt" --timeout=5s >/dev/null 2>&1; then
      pltf_ok "grpc: health service names $_tgt on the remote pod"
    else
      pltf_info "[fail] grpc health check for service=$_tgt did not return SERVING at $_hfq"
      _dir_rc=1
    fi
  done

  pltf_probe_stop "$_vf_ctx"
  return $_dir_rc
}

cmd_verify() {
  pltf_require_cmd k3d
  pltf_require_cmd kubectl
  _fleet=$(pltf_existing_clusters | tr '\n' ' ')
  # Names the gRPC sample snippet tries as health-service names.
  PLTF_VERIFY_FLEET=$_fleet
  _fleet_n=0
  for _c in $_fleet; do _fleet_n=$((_fleet_n + 1)); done
  [ "$_fleet_n" -ge 1 ] || pltf_die "No pltfctl cluster is running; run 'pltfctl up'"
  # One cluster (lite, dev): the same four protocols, client and server in
  # different namespaces of that cluster. See scripts/lib/pltfctl/verify_local.sh
  if [ "$_fleet_n" -eq 1 ]; then
    cmd_verify_local "$(printf '%s' "$_fleet" | tr -d ' ')"
    return
  fi

  # EVERY cluster's probe pod, unconditionally: whichever probe cluster is
  # running (or was interrupted) when something dies, this must still clean up
  # the pods in all contexts, not just the one active at trap time.
  # PLTF_ALL_CLUSTERS rather than $_fleet so this stays correct even if the
  # fleet could not be computed; pltf_probe_stop is already a no-op against a
  # context that does not exist.
  # shellcheck disable=SC2064 # deliberately expanded at trap time, not now
  trap 'for _c in $PLTF_ALL_CLUSTERS; do pltf_probe_stop "k3d-$_c"; done' EXIT INT TERM

  # One probe cluster at a time, each verifying every OTHER cluster. At three
  # clusters this is three probe pods covering six ordered directions.
  _rc=0
  for _probe in $_fleet; do
    _targets=''
    for _c in $_fleet; do
      if [ "$_c" != "$_probe" ]; then _targets="$_targets $_c"; fi
    done
    pltf_step "== probe in $_probe -> targets:$_targets =="
    # shellcheck disable=SC2086 # _targets is a space-joined list by design
    pltf_verify_from "k3d-$_probe" "$_probe" $_targets || _rc=1
  done
  for _c in $_fleet; do
    pltf_verify_external "$_c" || _rc=1
  done

  if [ "$_rc" -eq 0 ]; then
    pltf_ok "ClusterMesh verified from every cluster to every other ($_fleet_n clusters,$_fleet)."
  else
    pltf_die "Mesh verification FAILED; see the failures above."
  fi
}

cmd_doctor() {
  _rc=0
  # docker + k3d provision the clusters; cilium installs the CNI and meshes
  # the clusters; kubectl drives Flux and the fabric; envsubst renders the k3d
  # configs; curl probes the smoke routes; openssl makes podinfo's TLS cert;
  # jq reads the pod and kubelet JSON behind `status`'s resource tables.
  for _c in docker k3d cilium kubectl envsubst curl openssl jq; do
    if command -v "$_c" >/dev/null 2>&1; then
      pltf_ok "$_c found ($(command -v "$_c"))"
    else
      pltf_info "[missing] $_c"
      case "$_c" in
        envsubst) pltf_info "  install: brew install gettext (macOS) / apt install gettext-base (Ubuntu)" ;;
        cilium)   pltf_info "  install: brew install cilium-cli (macOS) / see https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default/" ;;
        *)        pltf_info "  install: brew install $_c (macOS) / see vendor docs (Ubuntu)" ;;
      esac
      _rc=1
    fi
  done
  # Optional: helm pushes charts to the local registry; the flux CLI helps
  # debugging. Neither is needed by up/down/status.
  for _c in helm flux; do
    if command -v "$_c" >/dev/null 2>&1; then
      pltf_ok "$_c found (optional)"
    else
      pltf_info "[opt ] $_c not found (optional: helm = chart pushes, flux = debugging)"
    fi
  done
  # Needs no cluster, so it belongs here rather than in `status`: this is the
  # "is this checkout sane" command, and an SBOM nobody checks drifts silently.
  pltf_sbom_check || _rc=1
  return $_rc
}

# The UIs a cluster actually serves: hubble needs Cilium and is opt-in
# (PLTF_ENABLE=hubble), so it is absent on lite and by default.
pltf_uis_for() { # name
  for _u in $PLTF_UIS; do
    if [ "$_u" = hubble ] && { ! pltf_cluster_is "$1" CNI cilium || ! pltf_enabled hubble; }; then continue; fi
    printf '%s ' "$_u"
  done
}

# Print or open the fabric UIs. Listing needs no cluster — it only builds URLs
# — but launching does, because a tab onto a cluster that is not running is
# worse than a clear refusal.
cmd_open() { # [ui|cluster] [cluster]
  _op_ui=''
  # Default: the running distro's first cluster, else the default distro's.
  _op_distro=$(pltf_running_distro) || _op_distro=$PLTF_DEFAULT_DISTRO
  _op_cluster=$(pltf_distro_clusters "$_op_distro" | head -n 1)
  _op_known=$(printf '%s' "$PLTF_ALL_CLUSTERS" | tr ' ' '|')

  # A lone argument naming a cluster lists that cluster rather than being
  # reported as an unknown UI. UI names and cluster names do not collide.
  if [ "$#" -ge 1 ]; then
    if pltf_lb_http_port "$1" >/dev/null 2>&1; then _op_cluster=$1; else _op_ui=$1; fi
  fi
  if [ "$#" -ge 2 ]; then
    pltf_lb_http_port "$2" >/dev/null 2>&1 ||
      pltf_die "Unknown cluster: $2 (expected: $_op_known)"
    _op_cluster=$2
  fi
  _op_port=$(pltf_lb_http_port "$_op_cluster")
  _op_uis=$(pltf_uis_for "$_op_cluster")

  if [ -z "$_op_ui" ]; then
    pltf_info "UIs on k3d-$_op_cluster (distro $(pltf_cluster_distro "$_op_cluster"))"
    for _op_each in $_op_uis; do
      printf '       %-8s http://%s:%s%s\n' "$_op_each" \
        "$(pltf_ui_host "$_op_cluster" "$_op_each")" "$_op_port" "$(pltf_ui_path "$_op_each")"
    done
    pltf_info "open one with: pltfctl open <ui> [$_op_known]"
    return 0
  fi

  case " $_op_uis" in
    *" $_op_ui "*) ;;
    *) pltf_die "Unknown UI on k3d-$_op_cluster: $_op_ui (expected: $_op_uis)" ;;
  esac
  pltf_cluster_exists "$_op_cluster" ||
    pltf_die "Cluster k3d-$_op_cluster is not running; start it with 'pltfctl up $(pltf_cluster_distro "$_op_cluster")'"

  _op_url="http://$(pltf_ui_host "$_op_cluster" "$_op_ui"):$_op_port$(pltf_ui_path "$_op_ui")"
  # A missing browser opener is not a failure worth a non-zero exit — the URL
  # is the useful output either way.
  if command -v open >/dev/null 2>&1; then
    pltf_ok "opening $_op_url"; open "$_op_url"
  elif command -v xdg-open >/dev/null 2>&1; then
    pltf_ok "opening $_op_url"; xdg-open "$_op_url"
  else
    pltf_info "no 'open' or 'xdg-open' on PATH — $_op_url"
  fi
}
