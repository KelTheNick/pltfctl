#!/usr/bin/env sh
# projctl scaffolding: new deploy/<ctx>/<ns>/ entries. Sourced by
# scripts/projctl. Function-only. Never overwrites an existing file.

# DNS-1123 label: what Kubernetes accepts for namespace and release names.
proj_valid_name() {
  printf '%s' "$1" | grep -Eq '^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$'
}

# Validate <ctx> against the fleet and <ns> as a name; echo the target dir.
proj_target_dir() { # ctx ns
  case " base $PLTF_ALL_CLUSTERS " in
    *" ${1#k3d-} "*) [ "$1" != "${1#k3d-}" ] || pltf_die "Context must be k3d-<cluster>: $1" ;;
    *) pltf_die "Unknown context: $1 (known: k3d-base $(printf '%s' "$PLTF_ALL_CLUSTERS" | sed 's/[a-z0-9-]*/k3d-&/g'))" ;;
  esac
  proj_valid_name "$2" || pltf_die "Invalid namespace name: $2"
  printf '%s\n' "$PLTFCTL_HOME/deploy/$1/$2"
}

# Warn when a write lands in a dir shared with other contexts by symlink.
proj_warn_shared() { # dir
  [ -h "$1" ] && pltf_info "note: $1 is a symlink to $(readlink "$1") — this change applies to every context sharing it"
  return 0
}

proj_write_new() { # file — stdin is the content
  [ ! -e "$1" ] || pltf_die "Refusing to overwrite: ${1#"$PLTFCTL_HOME"/}"
  cat >"$1"
  pltf_ok "wrote ${1#"$PLTFCTL_HOME"/}"
}

proj_new_ns() { # ctx ns
  [ $# -eq 2 ] || pltf_die "usage: projctl new-ns <ctx> <ns>"
  _dir=$(proj_target_dir "$1" "$2")
  case "$2" in kube-system | kube-public | default)
    pltf_die "$2 is pre-created by Kubernetes; scaffold apps into it with new-app" ;;
  esac
  mkdir -p "$_dir"
  proj_write_new "$_dir/namespace.yaml" <<EOF
# Applied first by pltfctl's flux_apply_tree, before anything else in $2/.
apiVersion: v1
kind: Namespace
metadata:
  name: $2
EOF
}

proj_new_app() { # ctx ns app
  [ $# -eq 3 ] || pltf_die "usage: projctl new-app <ctx> <ns> <app>"
  _dir=$(proj_target_dir "$1" "$2")
  proj_valid_name "$3" || pltf_die "Invalid app name: $3"
  [ -d "$_dir" ] || pltf_die "deploy/$1/$2/ does not exist — run: projctl new-ns $1 $2"
  proj_warn_shared "$_dir"
  proj_write_new "$_dir/$3.yaml" <<EOF
# $3 — pulls its chart from the project's local OCI registry.
# Push it first:  helm push $3-<ver>.tgz oci://localhost:$PLTF_REGISTRY_HOST_PORT/charts
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: $3
  namespace: flux-system   # every Flux source lives in flux-system
spec:
  interval: 1m
  url: oci://$PLTF_REGISTRY_NAME:$PLTF_REGISTRY_PORT/charts/$3
  insecure: true          # local registry is plain HTTP
  ref:
    semver: ">=0.0.0-0"   # pin once the chart stabilises
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: $3
  namespace: $2
spec:
  interval: 5m
  chartRef:
    kind: OCIRepository
    name: $3
    namespace: flux-system
  values: {}
EOF
}
