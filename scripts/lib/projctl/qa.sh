#!/usr/bin/env sh
# projctl quality checks: lint the scripts, check the layout invariants.
# Sourced by scripts/projctl. Function-only.

# Every shell script: the executable entrypoints in scripts/ (no extension)
# plus the sourced libs. Symlinks excluded — they would be linted
# twice under two names).
proj_scripts() {
  { find "$PLTFCTL_HOME/scripts/lib" -type f -name '*.sh'
    find "$PLTFCTL_HOME/scripts" -maxdepth 1 -type f -perm -u+x; } | sort
}

proj_lint() {
  [ $# -eq 0 ] || pltf_die "lint takes no arguments"
  _rc=0
  for _f in $(proj_scripts); do
    sh -n "$_f" || { pltf_info "[fail] syntax: ${_f#"$PLTFCTL_HOME"/}"; _rc=1; }
  done
  [ "$_rc" -eq 0 ] && pltf_ok "sh -n: every script parses."
  if command -v shellcheck >/dev/null 2>&1; then
    # -x follows `. file` sources; -P resolves them relative to each script.
    # shellcheck disable=SC2046 # word-splitting the file list is intended
    if (cd "$PLTFCTL_HOME/scripts" && shellcheck -x -P SCRIPTDIR $(proj_scripts)); then
      pltf_ok "shellcheck: clean."
    else
      _rc=1
    fi
  else
    pltf_info "shellcheck not installed; skipped (brew install shellcheck)"
  fi
  return "$_rc"
}

# Fail-collecting check: report every broken invariant, not just the first.
proj_fail() { pltf_info "[fail] $*"; _pc_rc=1; }

proj_check() {
  [ $# -eq 0 ] || pltf_die "check takes no arguments"
  _pc_rc=0
  _all=''; _cl=''; _cni=''; _kind=''; _proj=''
  for _d in $PLTF_DISTROS; do
    _du=$(printf '%s' "$_d" | tr '[:lower:]' '[:upper:]')
    eval "_kind=\${PLTF_DISTRO_${_du}_KIND:-k3d}"
    case "$_kind" in
      k3d) ;;
      compose)
        # A Compose distro has no clusters: one stack file and a project name.
        [ -f "$PLTFCTL_HOME/infra/compose/$_d.yaml" ] ||
          proj_fail "infra/compose/$_d.yaml missing for compose distro '$_d'"
        eval "_proj=\${PLTF_${_du}_PROJECT:-}"
        [ -n "$_proj" ] || proj_fail "infra/fleet.env: PLTF_${_du}_PROJECT unset"
        continue ;;
      *) proj_fail "infra/fleet.env: PLTF_DISTRO_${_du}_KIND must be k3d|compose (got '$_kind')"; continue ;;
    esac
    eval "_cl=\${PLTF_DISTRO_${_du}_CLUSTERS:-}"
    eval "_cni=\${PLTF_DISTRO_${_du}_CNI:-}"
    [ -n "$_cl" ] || { proj_fail "infra/fleet.env: PLTF_DISTRO_${_du}_CLUSTERS unset"; continue; }
    case "$_cni" in flannel | cilium) ;; *) proj_fail "infra/fleet.env: PLTF_DISTRO_${_du}_CNI must be flannel|cilium (got '$_cni')" ;; esac
    # Ports, CIDRs and IDs must be unique WITHIN a distro; across distros they
    # deliberately repeat (only one distro runs at a time).
    _seen=''
    for _n in $_cl; do
      _all="$_all $_n"
      _up=$(printf '%s' "$_n" | tr '[:lower:]-' '[:upper:]_')
      [ -f "$PLTFCTL_HOME/infra/k3d/$_d/$_n.yaml" ] ||
        proj_fail "infra/k3d/$_d/$_n.yaml missing for $_d cluster '$_n'"
      _keys='API_PORT HTTP_PORT HTTPS_PORT POD_CIDR SVC_CIDR DNS_IP'
      [ "$_cni" = cilium ] && _keys="ID $_keys"
      for _k in $_keys; do
        eval "_v=\${PLTF_${_up}_$_k:-}"
        if [ -z "$_v" ]; then
          proj_fail "infra/fleet.env: PLTF_${_up}_$_k unset"
          continue
        fi
        case "$_k" in DNS_IP) continue ;; ID) _key="ID=$_v" ;; *CIDR) _key="CIDR=$_v" ;; *) _key="PORT=$_v" ;; esac
        case " $_seen " in *" $_key "*) proj_fail "infra/fleet.env: $_key reused within distro $_d (at $_n)" ;; esac
        _seen="$_seen $_key"
      done
    done
  done
  # PLTF_ALL_CLUSTERS (teardown order) must name exactly the distros' clusters.
  for _n in $_all; do
    case " $PLTF_ALL_CLUSTERS " in *" $_n "*) ;; *) proj_fail "infra/fleet.env: $_n missing from PLTF_ALL_CLUSTERS" ;; esac
  done
  for _n in $PLTF_ALL_CLUSTERS; do
    case " $_all " in *" $_n "*) ;; *) proj_fail "infra/fleet.env: PLTF_ALL_CLUSTERS names $_n, which no distro has" ;; esac
  done
  # deploy/k3d-base is shared by every distro; every other deploy/ dir is
  # one context's additions (optional) and must be a known cluster. No
  # symlink may dangle.
  [ -d "$PLTFCTL_HOME/deploy/k3d-base" ] || proj_fail "deploy/k3d-base/ missing"
  for _d in "$PLTFCTL_HOME"/deploy/*/; do
    _ctx=$(basename "$_d")
    case " base $_all " in
      *" ${_ctx#k3d-} "*) ;;
      *) proj_fail "deploy/$_ctx/ matches no distro cluster (infra/fleet.env)" ;;
    esac
    for _p in "$_d"* "$_d"*/*; do
      [ -h "$_p" ] && [ ! -e "$_p" ] && proj_fail "dangling symlink: ${_p#"$PLTFCTL_HOME"/}"
    done
  done
  [ "$_pc_rc" -eq 0 ] && pltf_ok "Layout matches infra/fleet.env."
  return "$_pc_rc"
}
