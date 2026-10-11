#!/usr/bin/env sh
# pltfctl Compose distros: a distro with KIND=compose is one Docker Compose
# stack, infra/compose/<distro>.yaml, instead of k3d clusters. Sourced by
# scripts/pltfctl. Function-only.
#
# Today that is `dev`: AutoMQ (Kafka on S3) over RustFS. The compose file
# reads its images and ports from the environment; pltf_compose exports them.

[ -n "${PLTFCTL_HOME:-}" ] && [ -d "$PLTFCTL_HOME/scripts/lib" ] || {
  printf '[err ] PLTFCTL_HOME unset or not a pltfctl checkout (got: %s)\n' \
    "${PLTFCTL_HOME:-<unset>}" >&2
  exit 1
}

# shellcheck disable=SC2034 # read by projctl's layout check too
PLTF_COMPOSE_DIR="$PLTFCTL_HOME/infra/compose"

pltf_compose_file() { printf '%s/%s.yaml\n' "$PLTF_COMPOSE_DIR" "$1"; } # distro

# `docker compose -p PLTF_<D>_PROJECT -f infra/compose/<d>.yaml ...`, with
# every value the file interpolates exported. A subshell, so the exports do
# not leak into the caller.
pltf_compose() { # distro args...
  _pc_d=$1
  shift
  _pc_proj=$(pltf_distro_project "$_pc_d") ||
    pltf_die "infra/fleet.env has no PLTF_$(pltf_upper "$_pc_d")_PROJECT"
  (
    export AUTOMQ_IMAGE RUSTFS_IMAGE MC_IMAGE
    export PLTF_DEV_KAFKA_PORT PLTF_DEV_S3_PORT PLTF_DEV_S3_CONSOLE_PORT
    docker compose -p "$_pc_proj" -f "$(pltf_compose_file "$_pc_d")" "$@"
  )
}

# True while any container of the distro's project exists (running or not):
# a stopped stack still holds its volumes, and `up` would resume it.
pltf_compose_present() { # distro
  _cp_proj=$(pltf_distro_project "$1") || return 1
  [ -n "$(docker ps -aq --filter "label=com.docker.compose.project=$_cp_proj" 2>/dev/null)" ]
}

# The one container of a service, by Compose's labels.
pltf_compose_container() { # distro service
  docker ps -aq --filter "label=com.docker.compose.project=$(pltf_distro_project "$1")" \
    --filter "label=com.docker.compose.service=$2" | head -n 1
}

pltf_require_compose() {
  pltf_require_cmd docker
  docker compose version >/dev/null 2>&1 ||
    pltf_die "docker compose (v2 plugin) not found; install Docker Compose v2"
}

# Start the stack, then wait for AutoMQ's healthcheck rather than trusting
# `up --wait`: the bucket job exits by design, and older Compose versions read
# any exited container as a failed wait.
cmd_up_compose() { # distro
  pltf_require_compose
  _uc_file=$(pltf_compose_file "$1")
  [ -f "$_uc_file" ] || pltf_die "Missing compose file: ${_uc_file#"$PLTFCTL_HOME"/}"
  pltf_step "docker compose up (${_uc_file#"$PLTFCTL_HOME"/})"
  pltf_compose "$1" up -d --remove-orphans
  pltf_step "waiting for AutoMQ to answer Kafka requests (up to 5m)"
  _uc_i=0
  while :; do
    _uc_c=$(pltf_compose_container "$1" automq)
    _uc_h=$(docker inspect -f '{{.State.Health.Status}}' "$_uc_c" 2>/dev/null) || _uc_h=''
    [ "$_uc_h" = healthy ] && break
    _uc_i=$((_uc_i + 1))
    if [ "$_uc_i" -ge 60 ]; then
      pltf_die "AutoMQ not healthy after 5m (${_uc_h:-no container}); see: docker logs $_uc_c"
    fi
    sleep 5
  done
  pltf_ok "Distro '$1' is up."
  pltf_compose_endpoints
}

pltf_compose_endpoints() {
  printf '       %-14s %s\n' \
    kafka "localhost:$PLTF_DEV_KAFKA_PORT (host)  automq:9092 (compose network)" \
    s3 "http://localhost:$PLTF_DEV_S3_PORT" \
    s3-console "http://localhost:$PLTF_DEV_S3_CONSOLE_PORT"
}

# Round trip through the broker, which proves the S3 path too: AutoMQ
# acknowledges a produce only once it is written to the WAL bucket.
cmd_verify_compose() { # distro
  pltf_require_compose
  _vc_t=pltf-verify
  _vc_msg="pltfctl-verify-$(date +%s)"
  _vc_bin=/opt/automq/kafka/bin
  _vc_bs=automq:9092
  pltf_step "creating topic $_vc_t"
  pltf_compose "$1" exec -T automq "$_vc_bin/kafka-topics.sh" --bootstrap-server "$_vc_bs" \
    --create --if-not-exists --topic "$_vc_t" --partitions 1 >/dev/null ||
    pltf_die "could not create topic $_vc_t"
  pltf_step "producing one message"
  printf '%s\n' "$_vc_msg" | pltf_compose "$1" exec -T automq "$_vc_bin/kafka-console-producer.sh" \
    --bootstrap-server "$_vc_bs" --topic "$_vc_t" >/dev/null ||
    pltf_die "produce to $_vc_t failed"
  pltf_step "consuming it back (up to 30s)"
  if pltf_compose "$1" exec -T automq "$_vc_bin/kafka-console-consumer.sh" \
    --bootstrap-server "$_vc_bs" --topic "$_vc_t" --from-beginning \
    --timeout-ms 30000 2>/dev/null | grep -qx "$_vc_msg"; then
    pltf_ok "Kafka round trip on AutoMQ (S3 via RustFS) works."
  else
    pltf_die "Message not read back from $_vc_t"
  fi
}

# Remove every Compose distro's stack, volumes included.
pltf_down_compose() {
  for _dc_d in $PLTF_DISTROS; do
    [ "$(pltf_distro_kind "$_dc_d")" = compose ] || continue
    pltf_compose_present "$_dc_d" || continue
    pltf_step "docker compose down -v ($_dc_d)"
    pltf_compose "$_dc_d" down -v --remove-orphans
    _down_found=1
  done
}
