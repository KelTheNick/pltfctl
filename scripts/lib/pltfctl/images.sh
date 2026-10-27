#!/usr/bin/env sh
# pltfctl image preloading. Sourced by scripts/pltfctl. Function-only.
#
# Every k3d node keeps its own image cache, and `down` throws it away, so
# without this each `up` re-downloads every image on every node. Instead the
# host pulls each image once into its Docker cache and `k3d image import`
# copies it into the new cluster's nodes. Best-effort: on any failure the
# nodes simply pull as they did before.
#
# Every image is derived from a pin in .env.sbom — nothing is listed twice.

[ -n "${PLTFCTL_HOME:-}" ] && [ -d "$PLTFCTL_HOME/scripts/lib" ] || {
  printf '[err ] PLTFCTL_HOME unset or not a pltfctl checkout (got: %s)\n' \
    "${PLTFCTL_HOME:-<unset>}" >&2
  exit 1
}

# Flux controller images, read from the pinned install manifest after the
# controller filter (so dropped controllers are not pulled).
pltf_images_flux() {
  flux_install_manifest | flux_drop_unused_controllers |
    sed -n 's/^[[:space:]]*image:[[:space:]]*//p' | tr -d '"' | sort -u
}

# Cilium images, from a dry run with the same digest-less image settings
# cilium_install uses (a k3d-imported image is found by tag, never by
# digest). clustermesh-apiserver only on multi-cluster distros.
pltf_images_cilium() { # distro
  _ic_mesh=false; _ic_hub=false
  pltf_enabled hubble && _ic_hub=true
  [ "$(pltf_distro "$1" MESH)" = true ] && _ic_mesh=true
  # shellcheck disable=SC2046 # word-split the flag list on purpose
  cilium install --version "$CILIUM_VERSION" --dry-run \
    --set k8sServiceHost=127.0.0.1 --set k8sServicePort=6443 \
    --set hubble.relay.enabled="$_ic_hub" --set hubble.ui.enabled="$_ic_hub" \
    --set clustermesh.useAPIServer="$_ic_mesh" \
    $(cilium_image_flags) 2>/dev/null |
    sed -n 's/^[[:space:]]*image:[[:space:]]*//p' | tr -d '"' | sort -u
}

# Every image a cluster of this distro runs.
pltf_images_for() { # name
  _if_d=$(pltf_cluster_distro "$1")
  printf '%s\n' "$PODINFO_IMAGE" \
    "cr.kgateway.dev/kgateway-dev/kgateway:v$KGATEWAY_CHART_VERSION" \
    "cr.kgateway.dev/kgateway-dev/envoy-wrapper:v$KGATEWAY_CHART_VERSION"
  pltf_images_flux
  if [ "$(pltf_distro "$_if_d" CNI)" = cilium ]; then pltf_images_cilium "$_if_d"; fi
}

# Pull anything missing from the host cache, then import all of it into the
# cluster's nodes in one k3d call. Non-fatal throughout. With no image list,
# preloads everything `up` needs (pltf_images_for); `event-bus up` passes its own.
pltf_preload_images() { # name [image...]
  _pi_name=$1; shift
  if [ "$#" -gt 0 ]; then
    _pi_list=$(printf '%s\n' "$@" | sort -u)
  else
    _pi_list=$(pltf_images_for "$_pi_name" | sort -u) || _pi_list=''
  fi
  [ -n "$_pi_list" ] || { pltf_info "[warn] no images resolved to preload; nodes will pull"; return 0; }
  _pi_n=$(printf '%s\n' "$_pi_list" | wc -l | tr -d ' ')
  pltf_step "preloading $_pi_n images into k3d-$_pi_name (host pulls once, k3d imports)"
  _pi_ok=''
  for _pi_img in $_pi_list; do
    if docker image inspect "$_pi_img" >/dev/null 2>&1 || docker pull -q "$_pi_img" >/dev/null 2>&1; then
      _pi_ok="$_pi_ok $_pi_img"
    else
      pltf_info "[warn] could not pull $_pi_img on the host; the node will pull it"
    fi
  done
  [ -n "$_pi_ok" ] || return 0
  # shellcheck disable=SC2086 # _pi_ok is a space-joined list by design
  k3d image import -c "$_pi_name" $_pi_ok >/dev/null 2>&1 ||
    pltf_info "[warn] k3d image import failed for k3d-$_pi_name; nodes will pull instead"
}
