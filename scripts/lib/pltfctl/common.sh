#!/usr/bin/env sh
# pltfctl shared logic. Sourced by scripts/pltfctl (which sets PLTFCTL_HOME
# and sources scripts/lib/core/log.sh + infra/k3d/fleet.env first).
# Defines functions plus a few derived constants — no work at source time.

[ -n "${PLTFCTL_HOME:-}" ] && [ -d "$PLTFCTL_HOME/scripts/lib" ] || {
  printf '[err ] PLTFCTL_HOME unset or not a pltfctl checkout (got: %s)\n' \
    "${PLTFCTL_HOME:-<unset>}" >&2
  exit 1
}

# ----- Layout & inventory --------------------------------------------------
# Inventory VALUES (cluster names, ports, CIDRs, IDs, network, registry) live
# in infra/k3d/fleet.env; this section only reads them.

# shellcheck disable=SC2034 # consumed by scripts/lib/pltfctl/cmds.sh (cmd_up)
PLTF_K3D_DIR="$PLTFCTL_HOME/infra/k3d"
# shellcheck disable=SC2034 # consumed by scripts/lib/pltfctl/flux.sh (flux_apply_tree)
PLTF_DEPLOY_DIR="$PLTFCTL_HOME/deploy"

# Opt-in extras, off by default to save memory on a 16GB laptop:
#   PLTF_ENABLE=hubble ./scripts/pltfctl up lite
# `hubble` is Cilium's relay + UI (Cilium distros; read at Cilium install).
PLTF_ENABLE=${PLTF_ENABLE:-}
pltf_enabled() { case " $PLTF_ENABLE " in *" $1 "*) return 0 ;; esac; return 1; }

# ----- Distros --------------------------------------------------------------
# A distro is a fixed posture: which clusters, which CNI, registry or not,
# o11y or not. The list and each kind are in infra/.infra.env; a k3d
# distro's clusters, CNI, registry and o11y in infra/k3d/fleet.env (PLTF_DISTRO_*).
#
# `fleet` has one cluster with ClusterMesh enabled (PLTF_DISTRO_FLEET_MESH):
# the mesh API server is up, so another cluster can be joined, but a single
# Mac cannot afford a second. `lite` is plain single-cluster Cilium.

pltf_upper() { printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_'; } # ops -> OPS

# `pltf_distro lite CNI` reads PLTF_DISTRO_LITE_CNI. Non-zero for an unknown
# distro or an unset key, so it doubles as a distro-name validator.
pltf_distro() { # distro key
  case " $PLTF_DISTROS " in *" $1 "*) ;; *) return 1 ;; esac
  eval "_dv=\${PLTF_DISTRO_$(pltf_upper "$1")_$2:-}"
  [ -n "$_dv" ] || return 1
  printf '%s\n' "$_dv"
}

# One cluster per line. Not `pltf_distro … | tr`: the pipe would report tr's
# success and hide an unknown distro.
pltf_distro_clusters() { # distro
  _dcl=$(pltf_distro "$1" CLUSTERS) || return 1
  # shellcheck disable=SC2086 # split the space-joined list into lines
  printf '%s\n' $_dcl
}
pltf_distro_names() { printf '%s' "$PLTF_DISTROS" | tr ' ' '|'; }
pltf_distro_known() { case " $PLTF_DISTROS " in *" $1 "*) return 0 ;; esac; return 1; }

# k3d (clusters) or compose (one Docker Compose stack). Unset means k3d.
pltf_distro_kind() { # distro
  pltf_distro "$1" KIND || printf 'k3d\n'
}

# A Compose distro's project name: PLTF_<DISTRO>_PROJECT.
pltf_distro_project() { # distro
  eval "_dp=\${PLTF_$(pltf_upper "$1")_PROJECT:-}"
  [ -n "$_dp" ] || return 1
  printf '%s\n' "$_dp"
}

# Which distro a cluster belongs to.
pltf_cluster_distro() { # name
  for _cd in $PLTF_DISTROS; do
    case " $(pltf_distro "$_cd" CLUSTERS) " in *" $1 "*) printf '%s\n' "$_cd"; return 0 ;; esac
  done
  return 1
}

# `pltf_cluster_is <name> CNI cilium` — test one distro setting for a cluster.
pltf_cluster_is() { # name key value
  _ci_d=$(pltf_cluster_distro "$1") || return 1
  [ "$(pltf_distro "$_ci_d" "$2")" = "$3" ]
}

# The first cluster of a cluster's distro: owner of the registry and the CA.
pltf_distro_head() { # name
  pltf_distro "$(pltf_cluster_distro "$1")" CLUSTERS | cut -d' ' -f1
}

# The distro currently running: whichever pltfctl cluster exists, else
# whichever Compose distro has containers.
pltf_running_distro() {
  for _rd in $(pltf_existing_clusters); do pltf_cluster_distro "$_rd"; return 0; done
  for _rd in $PLTF_DISTROS; do
    [ "$(pltf_distro_kind "$_rd")" = compose ] || continue
    pltf_compose_present "$_rd" && { printf '%s\n' "$_rd"; return 0; }
  done
  return 1
}

# ----- Clusters -------------------------------------------------------------

# Existing pltfctl clusters, in teardown-safe order. Pass the names to look
# for; the default is every current distro's (PLTF_ALL_CLUSTERS).
pltf_existing_clusters() { # [names]
  _ec_list=$(k3d cluster list --output json 2>/dev/null) || _ec_list=''
  for _name in ${1:-$PLTF_ALL_CLUSTERS}; do
    if printf '%s' "$_ec_list" | grep -q "\"name\"[[:space:]]*:[[:space:]]*\"$_name\""; then
      printf '%s\n' "$_name"
    fi
  done
}

# Look up one per-cluster value from infra/k3d/fleet.env: `pltf_fleet lite
# HTTP_PORT` reads PLTF_LITE_HTTP_PORT. Non-zero for an unknown cluster or an
# unset/empty key, so callers can use it as a cluster-name validator too.
pltf_fleet() { # name key
  case " $PLTF_ALL_CLUSTERS " in *" $1 "*) ;; *) return 1 ;; esac
  eval "_fl_val=\${PLTF_$(pltf_upper "$1")_$2:-}"
  [ -n "$_fl_val" ] || return 1
  printf '%s\n' "$_fl_val"
}

# Host port the cluster's LB HTTP listener is published on.
pltf_lb_http_port() { pltf_fleet "$1" HTTP_PORT; }

# Cilium ClusterMesh cluster ID (1-255, unique per cluster in the mesh).
pltf_cluster_id() { pltf_fleet "$1" ID; }

# "ops-" for a cluster with a HOST_PREFIX, "" otherwise. Prepended to every
# route hostname, so a fleet URL names the cluster that serves it.
pltf_host_prefix() { # name
  _hp=$(pltf_fleet "$1" HOST_PREFIX) || _hp=''
  [ -n "$_hp" ] && printf '%s-' "$_hp"
  return 0
}

# Full URL host for a UI on a cluster: [<prefix>-]<ui>.<domain>
pltf_ui_host() { # name ui
  printf '%s%s.%s\n' "$(pltf_host_prefix "$1")" "$2" "$PLTF_DOMAIN"
}

# k3d config template for a cluster: infra/k3d/<distro>/<cluster>.yaml
pltf_k3d_config() { # name
  printf '%s/%s/%s.yaml\n' "$PLTF_K3D_DIR" "$(pltf_cluster_distro "$1")" "$1"
}

pltf_cluster_exists() {
  k3d cluster list --output json 2>/dev/null |
    grep -q "\"name\"[[:space:]]*:[[:space:]]*\"$1\""
}

pltf_registry_exists() {
  # k3d does not prefix the registry's own name with "k3d-" (unlike cluster
  # nodes); matched loosely in case a future k3d version does.
  k3d registry list 2>/dev/null | grep -q "$PLTF_REGISTRY_NAME"
}

pltf_kube_unset_user() {
  kubectl config unset "users.k3d-$1" >/dev/null 2>&1 || true
}

# Publish this cluster's identity for cluster-agnostic manifests to consume.
# The deploy tree is applied identically to every cluster, so per-cluster
# values cannot live in it. Written to BOTH namespaces because ConfigMaps are
# namespace-scoped and cannot be referenced across namespaces: kube-system is
# the canonical platform record, kube-public is where the sample workloads
# read it, and default is where the verify Jobs read it.
pltf_apply_cluster_info() { # name
  for _ci_ns in kube-system kube-public default; do
    kubectl --context "k3d-$1" -n "$_ci_ns" create configmap pltf-cluster-info \
      --from-literal=cluster="$1" --dry-run=client -o yaml |
      kubectl --context "k3d-$1" -n "$_ci_ns" apply -f - >/dev/null
  done
}

# Render a k3d config template with envsubst. Exports this cluster's
# infra/k3d/fleet.env values under the generic PLTF_CLUSTER_* names the templates
# use, plus the fleet-wide ones, so all three templates stay structurally
# identical. Runs in a subshell so the exports do not leak between clusters.
pltf_render_k3d_config() { # name file
  pltf_require_cmd envsubst
  (
    for _rk in API_PORT HTTP_PORT HTTPS_PORT POD_CIDR SVC_CIDR DNS_IP; do
      _rv=$(pltf_fleet "$1" "$_rk") || pltf_die "infra/k3d/fleet.env has no $_rk for cluster: $1"
      export "PLTF_CLUSTER_$_rk=$_rv"
    done
    export PLTF_NETWORK PLTF_API_HOST PLTF_REGISTRY_NAME PLTF_REGISTRY_HOST_PORT
    envsubst <"$2"
  )
}

# podinfo's TLS port needs a cert. Generated here, on the host, once per
# cluster (skipped if the Secret exists), so no openssl image runs in-cluster.
# Self-signed and throwaway: clients use curl -k. The key never touches git.
pltf_apply_podinfo_tls() { # name
  kubectl --context "k3d-$1" -n kube-public get secret podinfo-tls >/dev/null 2>&1 && return 0
  pltf_require_cmd openssl
  _pt_dir=$(mktemp -d)
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -subj "/CN=podinfo.kube-public.svc" \
    -keyout "$_pt_dir/tls.key" -out "$_pt_dir/tls.crt" >/dev/null 2>&1 ||
    { rm -rf "$_pt_dir"; pltf_die "openssl could not generate the podinfo TLS cert"; }
  kubectl --context "k3d-$1" -n kube-public create secret tls podinfo-tls \
    --cert="$_pt_dir/tls.crt" --key="$_pt_dir/tls.key" >/dev/null
  rm -rf "$_pt_dir"
}
