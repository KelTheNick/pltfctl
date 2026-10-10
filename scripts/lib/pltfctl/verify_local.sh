#!/usr/bin/env sh
# pltfctl single-cluster verify + external checks. Sourced by scripts/pltfctl.
# Function-only.
#
# In-cluster: deploy/k3d-base/default/verify-<protocol>.yaml, one Job per
# protocol (clients in `default` hitting podinfo in `kube-public`). `up` does
# not apply them; this does, watches each Job's status, and leaves the last
# run's Jobs and pods in place for inspection until the next run.
# External: curl from the host to the cluster's gateway hostnames.

[ -n "${PLTFCTL_HOME:-}" ] && [ -d "$PLTFCTL_HOME/scripts/lib" ] || {
  printf '[err ] PLTFCTL_HOME unset or not a pltfctl checkout (got: %s)\n' \
    "${PLTFCTL_HOME:-<unset>}" >&2
  exit 1
}

PLTF_VERIFY_DIR="$PLTFCTL_HOME/deploy/k3d-base/default"
PLTF_VERIFY_LABEL=app.kubernetes.io/name=pltf-verify
PLTF_VERIFY_PROTOCOLS='http tcp tls grpc'

pltf_verify_jobs_cleanup() { # ctx
  kubectl --context "$1" -n default delete job -l "$PLTF_VERIFY_LABEL" \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

# Poll until the Job has succeeded or failed (kubectl wait takes one
# condition at a time, and waiting only for Complete would sit out the whole
# timeout on a failure). Up to 3m: a cold image pull dominates.
pltf_verify_job_wait() { # ctx job
  _vw_i=0
  while [ "$_vw_i" -lt 36 ]; do
    _vw_s=$(kubectl --context "$1" -n default get job "$2" \
      -o jsonpath='{.status.succeeded}/{.status.failed}' 2>/dev/null) || _vw_s=/
    case "$_vw_s" in
      1/*) return 0 ;;
      */1) return 1 ;;
    esac
    _vw_i=$((_vw_i + 1))
    sleep 5
  done
  return 1
}

# In-cluster: run the Jobs and report each one's last log line.
pltf_verify_in_cluster() { # name
  _vi_ctx="k3d-$1"
  pltf_step "[$1] in-cluster: Jobs in default -> podinfo in kube-public"
  # A finished Job never re-runs on re-apply, so clear the previous run.
  pltf_verify_jobs_cleanup "$_vi_ctx"
  kubectl --context "$_vi_ctx" -n default wait --for=delete job \
    -l "$PLTF_VERIFY_LABEL" --timeout=60s >/dev/null 2>&1 || true
  for _p in $PLTF_VERIFY_PROTOCOLS; do
    _vi_file="$PLTF_VERIFY_DIR/verify-$_p.yaml"
    [ -f "$_vi_file" ] || pltf_die "missing ${_vi_file#"$PLTFCTL_HOME"/}"
    flux_apply_file "$_vi_ctx" "$_vi_file" >/dev/null
  done
  _vi_rc=0
  for _p in $PLTF_VERIFY_PROTOCOLS; do
    _vi_job="pltf-verify-$_p"
    _vi_ok=0
    pltf_verify_job_wait "$_vi_ctx" "$_vi_job" && _vi_ok=1
    _vi_log=$(kubectl --context "$_vi_ctx" -n default logs "job/$_vi_job" 2>/dev/null | tail -n 1) || _vi_log=''
    if [ "$_vi_ok" -eq 1 ]; then
      pltf_ok "$_p: $_vi_log"
    else
      _vi_rc=1
      pltf_info "[fail] $_p: ${_vi_log:-job did not finish within 3m (kubectl --context $_vi_ctx -n default describe job/$_vi_job)}"
    fi
  done
  return "$_vi_rc"
}

# External: from the host, through the k3d load balancer and the Gateway.
# Only HTTP is reachable from outside — the Gateway has a single HTTP
# listener and the HTTPS host port is reserved, not served — so TLS, gRPC and
# raw TCP are in-cluster checks only.
pltf_verify_external() { # name
  pltf_require_cmd curl
  _ve_port=$(pltf_lb_http_port "$1")
  _ve_rc=0
  pltf_step "[$1] external: curl from this host -> :$_ve_port"
  _ve_url="http://$(pltf_ui_host "$1" gateway):$_ve_port/readyz"
  _ve_code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$_ve_url") || _ve_code=000
  if [ "$_ve_code" = 200 ]; then
    pltf_ok "gateway: $_ve_url -> 200"
  else
    pltf_info "[fail] gateway: $_ve_url -> $_ve_code"; _ve_rc=1
  fi
  _ve_url="http://$(pltf_ui_host "$1" podinfo):$_ve_port/api/info"
  _ve_msg=$(curl -s -m 5 "$_ve_url" | grep '"message"' | cut -d'"' -f4) || _ve_msg=''
  if [ "$_ve_msg" = "$1" ]; then
    pltf_ok "podinfo: $_ve_url answered by $1"
  else
    pltf_info "[fail] podinfo: $_ve_url answered '${_ve_msg:-<no answer>}', want $1"; _ve_rc=1
  fi
  return "$_ve_rc"
}

cmd_verify_local() { # name
  _vl_rc=0
  pltf_verify_in_cluster "$1" || _vl_rc=1
  pltf_verify_external "$1" || _vl_rc=1
  if [ "$_vl_rc" -eq 0 ]; then
    pltf_ok "k3d-$1 verified: http, tcp, tls, grpc in-cluster; http from this host."
    pltf_info "this run's Jobs stay in default for inspection: kubectl --context k3d-$1 -n default get jobs,pods -l $PLTF_VERIFY_LABEL"
  else
    pltf_die "Verification FAILED on k3d-$1; see the failures above."
  fi
}
