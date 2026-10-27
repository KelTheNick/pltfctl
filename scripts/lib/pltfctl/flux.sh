#!/usr/bin/env sh
# pltfctl Flux GitOps logic. Sourced by scripts/pltfctl (which sets PLTFCTL_HOME).
# Function-only — no work at source time.
#
# The fabric is reconciled by Flux from deploy/<kube-context>/<namespace>/.
# pltfctl bootstraps Flux + the Gateway API CRDs per cluster, then applies
# that cluster's deploy tree; Flux does the reconciling.

[ -n "${PLTFCTL_HOME:-}" ] && [ -d "$PLTFCTL_HOME/scripts/lib" ] || {
  printf '[err ] PLTFCTL_HOME unset or not a pltfctl checkout (got: %s)\n' \
    "${PLTFCTL_HOME:-<unset>}" >&2
  exit 1
}

# Both pinned by version from .env.sbom. Flux was on `releases/latest` before
# the SBOM landed, which meant two `up` runs a week apart installed different
# controllers. See scripts/README.md#the-sbom
FLUX_INSTALL_URL=${FLUX_INSTALL_URL:-https://github.com/fluxcd/flux2/releases/download/$FLUX_VERSION/install.yaml}
GATEWAY_API_URL=${GATEWAY_API_URL:-https://github.com/kubernetes-sigs/gateway-api/releases/download/$GATEWAY_API_VERSION/standard-install.yaml}

# The pinned Flux install manifest, downloaded once per Flux version and
# cached under $TMPDIR: image preloading and flux_bootstrap both read it.
flux_install_manifest() {
  _fm_cache="${TMPDIR:-/tmp}/pltfctl-flux-install-$FLUX_VERSION.yaml"
  if [ ! -s "$_fm_cache" ]; then
    if ! curl -fsSL "$FLUX_INSTALL_URL" -o "$_fm_cache.part"; then
      rm -f "$_fm_cache.part"
      return 1
    fi
    mv "$_fm_cache.part" "$_fm_cache"
  fi
  cat "$_fm_cache"
}

# Keep only source-controller and helm-controller. Every other controller's
# install.yaml documents (CRDs, ServiceAccounts, Deployments, all labelled
# app.kubernetes.io/component) are dropped: pltfctl pins versions in
# .env.sbom and applies deploy/ from the checkout itself, so there are no
# Kustomizations, image policies, alerts or artifact generators to reconcile.
# --events-addr goes too: it points at the dropped notification-controller,
# and every event would otherwise log a failed POST.
flux_drop_unused_controllers() {
  awk '
    function flush() {
      if (doc != "" && doc !~ /app\.kubernetes\.io\/component: (image-reflector-controller|image-automation-controller|kustomize-controller|notification-controller|source-watcher)\n/)
        printf "---\n%s", doc
      doc = ""
    }
    /^---[[:space:]]*$/ { flush(); next }
    /--events-addr=/ { next }
    { doc = doc $0 "\n" }
    END { flush() }
  '
}

# Install the Flux controllers (idempotent) plus the upstream Gateway API
# standard-channel CRDs (kgateway-crds ships only gateway.kgateway.dev CRDs).
flux_bootstrap() { # ctx
  _ctx=$1
  if kubectl --context "$_ctx" get ns flux-system >/dev/null 2>&1; then
    pltf_info "Flux already installed on $_ctx (flux-system present)"
  else
    pltf_step "installing Flux controllers on $_ctx (source + helm only)"
    _fb_yaml=$(flux_install_manifest) ||
      pltf_die "could not download Flux install manifest: $FLUX_INSTALL_URL"
    printf '%s\n' "$_fb_yaml" | flux_drop_unused_controllers |
      kubectl --context "$_ctx" apply -f - >/dev/null
  fi
  pltf_step "waiting for Flux source/helm controllers on $_ctx"
  kubectl --context "$_ctx" -n flux-system wait --for=condition=Available \
    deploy/source-controller deploy/helm-controller --timeout=180s >/dev/null
  pltf_step "applying Gateway API standard CRDs on $_ctx"
  kubectl --context "$_ctx" apply -f "$GATEWAY_API_URL" >/dev/null
  pltf_ok "Flux + Gateway API CRDs ready on $_ctx."
}

# Applies deploy/k3d-base/<namespace>/*.yaml (shared by every distro), then
# deploy/<ctx>/<namespace>/*.yaml (this context's additions; optional — lite
# has none). Each namespace's namespace.yaml goes first so the rest can land
# in it, then Flux sources (repositories.yaml, registry.yaml), then
# everything else. Rounds, not per-file exhaustion: a manifest can depend on
# a CRD that a DIFFERENT manifest's HelmRelease is still installing, and
# which depends on which varies — a per-file retry budget would starve the
# very file that unblocks it. See scripts/README.md#the-apply-loop
flux_apply_tree() { # ctx
  _ctx=$1
  _trees="$PLTF_DEPLOY_DIR/k3d-base"
  [ -d "$PLTF_DEPLOY_DIR/$_ctx" ] && _trees="$_trees $PLTF_DEPLOY_DIR/$_ctx"

  for _tree in $_trees; do
    for _ns_dir in "$_tree"/*/; do
      # The event bus is a toggle (`pltfctl event-bus up`), never part of `up`.
      case "$_ns_dir" in */"$PLTF_EVENT_BUS_NS"/ | */"$PLTF_EVENT_BUS_UPGRADE_NS"/) continue ;; esac
      for _f in "$_ns_dir"namespace.yaml "$_ns_dir"repositories.yaml "$_ns_dir"registry.yaml; do
        [ -e "$_f" ] && flux_apply_file "$_ctx" "$_f" >/dev/null
      done
    done
  done

  _pending=''
  for _tree in $_trees; do
    for _f in "$_tree"/*/*.yaml; do
      [ -e "$_f" ] || continue
      # verify-*.yaml are run-on-demand checks (Jobs) that `pltfctl verify`
      # applies itself; applying them here would run them on every `up`.
      case "${_f##*/}" in verify-*) continue ;; esac
      case "$_f" in */"$PLTF_EVENT_BUS_NS"/* | */"$PLTF_EVENT_BUS_UPGRADE_NS"/*) continue ;; esac
      _pending="$_pending $_f"
    done
  done

  # If the tree is empty/renamed, _pending stays empty and the loop below
  # never runs — `up` would report success having applied nothing. Fail
  # loudly here instead.
  [ -n "$_pending" ] || pltf_die "no manifests found under: $_trees"

  _round=0
  while [ -n "$_pending" ]; do
    _round=$((_round + 1))
    _next=''
    # shellcheck disable=SC2086 # _pending is a space-joined list of paths by design
    for _f in $_pending; do
      if ! flux_apply_file "$_ctx" "$_f" >/dev/null 2>&1; then
        _next="$_next $_f"
      fi
    done
    _pending=$_next
    [ -z "$_pending" ] && break
    if [ "$_round" -ge 24 ]; then
      # shellcheck disable=SC2086 # _pending is a space-joined list of paths by design
      for _f in $_pending; do
        flux_apply_file "$_ctx" "$_f" || pltf_die "apply failed: $_f"
      done
      break
    fi
    [ "$_round" -eq 1 ] && pltf_info "waiting on CRDs for:$_pending (retrying)"
    sleep 5
  done
}

# Apply one deploy/ manifest, substituting ${PLTF_HOST_PREFIX} — and ONLY
# that variable, named explicitly to envsubst — with the cluster's
# "<prefix>-" (or "" when it has none). That one placeholder is how a
# cluster-agnostic tree still gives each fleet cluster its own route
# hostnames; every other `$` in the YAML passes through untouched.
# shellcheck disable=SC2016 # the single-quoted $VAR is envsubst's allow-list
flux_apply_file() { # ctx file
  PLTF_HOST_PREFIX=$(pltf_host_prefix "${1#k3d-}") \
    envsubst '${PLTF_HOST_PREFIX}' <"$2" |
    kubectl --context "$1" apply -f -
}
