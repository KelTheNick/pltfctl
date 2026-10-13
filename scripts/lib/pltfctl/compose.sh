#!/usr/bin/env sh
# pltfctl Compose distros: a distro with KIND=compose is one Docker Compose
# stack instead of k3d clusters. Sourced by scripts/pltfctl. Function-only.
#
# A Compose distro comes in variants, one file each:
# infra/compose/<distro>-<variant>.yaml. The variant is VARIANT_KAFKA, from
# the environment if exported, else infra/compose/.variant.env. Today that is
# `dev`: strimzi-kraft (default), aiven-tiered, automq. Every variant names its
# broker service `kafka`. The files read images, pins and ports from the
# environment; pltf_compose exports them.

[ -n "${PLTFCTL_HOME:-}" ] && [ -d "$PLTFCTL_HOME/scripts/lib" ] || {
  printf '[err ] PLTFCTL_HOME unset or not a pltfctl checkout (got: %s)\n' \
    "${PLTFCTL_HOME:-<unset>}" >&2
  exit 1
}

# shellcheck disable=SC2034 # read by projctl's layout check too
PLTF_COMPOSE_DIR="$PLTFCTL_HOME/infra/compose"

PLTF_VARIANT_ENV="$PLTF_COMPOSE_DIR/.variant.env"

pltf_compose_file() { # distro variant
  printf '%s/%s-%s.yaml\n' "$PLTF_COMPOSE_DIR" "$1" "$2"
}

# Every variant a distro has: one per infra/compose/<distro>-*.yaml.
pltf_compose_variants() { # distro
  for _cv_f in "$PLTF_COMPOSE_DIR/$1"-*.yaml; do
    [ -e "$_cv_f" ] || continue
    _cv_v=${_cv_f##*/"$1"-}
    printf '%s\n' "${_cv_v%.yaml}"
  done
}

# The chosen variant: an exported VARIANT_KAFKA, else .variant.env's. Read
# with sed rather than sourced, so the file can never run code. Dies on a
# variant with no compose file.
pltf_compose_variant() { # distro
  _vr=${VARIANT_KAFKA:-}
  if [ -z "$_vr" ] && [ -f "$PLTF_VARIANT_ENV" ]; then
    _vr=$(sed -n 's/^VARIANT_KAFKA=\([A-Za-z0-9-]*\).*/\1/p' "$PLTF_VARIANT_ENV" | tail -n 1)
  fi
  [ -n "$_vr" ] || pltf_die "VARIANT_KAFKA unset (export it, or set it in ${PLTF_VARIANT_ENV#"$PLTFCTL_HOME"/})"
  [ -f "$(pltf_compose_file "$1" "$_vr")" ] ||
    pltf_die "Unknown VARIANT_KAFKA: $_vr (expected: $(pltf_compose_variants "$1" | paste -sd'|' -))"
  printf '%s\n' "$_vr"
}

# The variant whose stack exists, from the compose file Compose recorded on
# the kafka container. Non-zero when none runs.
pltf_compose_running_variant() { # distro
  _rv_c=$(pltf_compose_container "$1" kafka)
  [ -n "$_rv_c" ] || return 1
  _rv_f=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$_rv_c" 2>/dev/null) || return 1
  _rv_f=${_rv_f##*/"$1"-}
  printf '%s\n' "${_rv_f%.yaml}"
}

# `docker compose -p PLTF_<D>_PROJECT -f infra/compose/<d>-<variant>.yaml
# ...`, with every value the files interpolate exported. A subshell, so the
# exports do not leak into the caller.
pltf_compose() { # distro variant args...
  _pc_d=$1
  _pc_v=$2
  shift 2
  _pc_proj=$(pltf_distro_project "$_pc_d") ||
    pltf_die "infra/compose/compose.env has no PLTF_$(pltf_upper "$_pc_d")_PROJECT"
  (
    # The broker image lite's Strimzi operator runs, derived from its pins.
    STRIMZI_KAFKA_IMAGE="quay.io/strimzi/kafka:$STRIMZI_VERSION-kafka-$KAFKA_VERSION"
    export STRIMZI_KAFKA_IMAGE KAFKA_IMAGE AUTOMQ_IMAGE RUSTFS_IMAGE MC_IMAGE CURL_IMAGE
    export TS_PLUGIN_VERSION TS_PLUGIN_CORE_SHA256 TS_PLUGIN_S3_SHA256
    export PLTF_DEV_KAFKA_PORT PLTF_DEV_S3_PORT PLTF_DEV_S3_CONSOLE_PORT
    docker compose -p "$_pc_proj" -f "$(pltf_compose_file "$_pc_d" "$_pc_v")" "$@"
  )
}

# Kafka's CLI directory in a variant's broker image.
pltf_compose_kafka_bin() { # variant
  case "$1" in automq) printf '/opt/automq/kafka/bin\n' ;; *) printf '/opt/kafka/bin\n' ;; esac
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

# Start the stack, then wait for Kafka's healthcheck rather than trusting
# `up --wait`: the bucket and plugin jobs exit by design, and older Compose
# versions read any exited container as a failed wait. The first `up`
# downloads the tiered-storage plugin (~100 MB), hence the generous wait.
cmd_up_compose() { # distro
  pltf_require_compose
  _uc_v=$(pltf_compose_variant "$1")
  if _uc_run=$(pltf_compose_running_variant "$1") && [ "$_uc_run" != "$_uc_v" ]; then
    pltf_die "The $1 stack is running variant '$_uc_run', not '$_uc_v'. Run 'pltfctl down' first."
  fi
  _uc_file=$(pltf_compose_file "$1" "$_uc_v")
  [ -f "$_uc_file" ] || pltf_die "Missing compose file: ${_uc_file#"$PLTFCTL_HOME"/}"
  pltf_step "docker compose up: VARIANT_KAFKA=$_uc_v (${_uc_file#"$PLTFCTL_HOME"/})"
  pltf_compose "$1" "$_uc_v" up -d --remove-orphans
  pltf_step "waiting for Kafka to answer requests (up to 5m)"
  _uc_i=0
  while :; do
    _uc_c=$(pltf_compose_container "$1" kafka)
    _uc_h=$(docker inspect -f '{{.State.Health.Status}}' "$_uc_c" 2>/dev/null) || _uc_h=''
    [ "$_uc_h" = healthy ] && break
    _uc_i=$((_uc_i + 1))
    if [ "$_uc_i" -ge 60 ]; then
      pltf_die "Kafka not healthy after 5m (${_uc_h:-no container}); see: docker logs $_uc_c"
    fi
    sleep 5
  done
  pltf_ok "Distro '$1' is up (VARIANT_KAFKA=$_uc_v)."
  pltf_compose_endpoints "$1" "$_uc_v"
}

# Kafka always; the S3 store only in a variant that runs one.
pltf_compose_endpoints() { # distro variant
  printf '       %-14s %s\n' variant "$2" \
    kafka "localhost:$PLTF_DEV_KAFKA_PORT (host)  kafka:9092 (compose network)"
  grep -q '^  rustfs:' "$(pltf_compose_file "$1" "$2")" || return 0
  printf '       %-14s %s\n' \
    s3 "http://localhost:$PLTF_DEV_S3_PORT" \
    s3-console "http://localhost:$PLTF_DEV_S3_CONSOLE_PORT"
}

# Objects under the tiered-storage bucket, counted from a throwaway mc
# container on the stack's network (the bucket job's service definition).
pltf_compose_tiered_objects() { # distro variant
  # shellcheck disable=SC2016 # $S3_KEY/$S3_SECRET expand inside the container
  pltf_compose "$1" "$2" run --rm --no-deps -T --entrypoint /bin/sh buckets -c \
    'mc alias set s3 http://rustfs:9000 "$S3_KEY" "$S3_SECRET" >/dev/null && mc ls -r s3/kafka-tiered | wc -l' \
    2>/dev/null | tr -d ' \r'
}

# Checks the RUNNING variant, on a fresh topic deleted afterwards:
#   every variant: one marker produced and read back from offset 0;
#   aiven-tiered also: the topic tiers (remote.storage.enable=true, 1 MiB
#     segments, 1s local retention), ~3 MiB of filler must put closed
#     segments in s3://kafka-tiered, and the marker is read only after its
#     local segment is gone, so that read is served from RustFS;
#   automq: its acknowledged produce is already in S3 (the WAL bucket).
cmd_verify_compose() { # distro
  pltf_require_compose
  _vc_v=$(pltf_compose_running_variant "$1") ||
    pltf_die "The $1 stack is not running; start it with 'pltfctl up $1'"
  _vc_t="pltf-verify-$(date +%s)"
  _vc_msg="$_vc_t-marker"
  _vc_bin=$(pltf_compose_kafka_bin "$_vc_v")
  _vc_bs=kafka:9092
  _vc_rc=0
  _vc_cfg=''
  [ "$_vc_v" = aiven-tiered ] &&
    _vc_cfg='--config remote.storage.enable=true --config segment.bytes=1048576 --config local.retention.ms=1000'
  pltf_step "VARIANT_KAFKA=$_vc_v: creating topic $_vc_t"
  # shellcheck disable=SC2086 # _vc_cfg is a word list by design
  pltf_compose "$1" "$_vc_v" exec -T kafka "$_vc_bin/kafka-topics.sh" --bootstrap-server "$_vc_bs" \
    --create --topic "$_vc_t" --partitions 1 $_vc_cfg >/dev/null ||
    pltf_die "could not create topic $_vc_t (docker logs $(pltf_compose_container "$1" kafka))"
  pltf_step "producing a marker"
  printf '%s\n' "$_vc_msg" | pltf_compose "$1" "$_vc_v" exec -T kafka "$_vc_bin/kafka-console-producer.sh" \
    --bootstrap-server "$_vc_bs" --topic "$_vc_t" >/dev/null ||
    pltf_die "produce to $_vc_t failed"

  if [ "$_vc_v" = aiven-tiered ]; then
    pltf_step "producing ~3 MiB of filler to close segments"
    pltf_compose "$1" "$_vc_v" exec -T kafka "$_vc_bin/kafka-producer-perf-test.sh" --topic "$_vc_t" \
      --num-records 3000 --record-size 1024 --throughput -1 \
      --producer-props bootstrap.servers="$_vc_bs" >/dev/null ||
      pltf_die "filler produce to $_vc_t failed"
    pltf_step "waiting for closed segments to reach RustFS (up to 90s)"
    _vc_i=0
    _vc_n=0
    while [ "$_vc_i" -lt 18 ]; do
      _vc_n=$(pltf_compose_tiered_objects "$1" "$_vc_v") || _vc_n=0
      [ "${_vc_n:-0}" -gt 0 ] && break
      _vc_i=$((_vc_i + 1))
      sleep 5
    done
    if [ "${_vc_n:-0}" -gt 0 ]; then
      pltf_ok "tiered storage: $_vc_n object(s) in s3://kafka-tiered"
    else
      pltf_info "[fail] tiered storage: nothing in s3://kafka-tiered after 90s"
      _vc_rc=1
    fi
    # Local retention is 1s and this variant's retention check runs every
    # 10s (dev-aiven-tiered.yaml), so after 20s the marker's segment is gone
    # from the broker's disk and offset 0 can only come from RustFS.
    sleep 20
  fi

  pltf_step "reading the marker back from offset 0 (up to 30s)"
  if pltf_compose "$1" "$_vc_v" exec -T kafka "$_vc_bin/kafka-console-consumer.sh" \
    --bootstrap-server "$_vc_bs" --topic "$_vc_t" --from-beginning --max-messages 1 \
    --timeout-ms 30000 2>/dev/null | grep -qx "$_vc_msg"; then
    pltf_ok "round trip: marker read back from offset 0"
  else
    pltf_info "[fail] round trip: marker not read back from $_vc_t"
    _vc_rc=1
  fi

  pltf_compose "$1" "$_vc_v" exec -T kafka "$_vc_bin/kafka-topics.sh" --bootstrap-server "$_vc_bs" \
    --delete --topic "$_vc_t" >/dev/null 2>&1 || true
  [ "$_vc_rc" -eq 0 ] || pltf_die "$1 verification FAILED; see the failures above."
  pltf_ok "VARIANT_KAFKA=$_vc_v verified."
}

# Remove every Compose distro's stack, volumes included, whichever variant
# made it: `down` is run once per variant file, so each variant's volumes
# (named in its own file) go too.
pltf_down_compose() {
  for _dc_d in $PLTF_DISTROS; do
    [ "$(pltf_distro_kind "$_dc_d")" = compose ] || continue
    pltf_compose_present "$_dc_d" || continue
    for _dc_v in $(pltf_compose_variants "$_dc_d"); do
      pltf_step "docker compose down -v ($_dc_d, $_dc_v)"
      pltf_compose "$_dc_d" "$_dc_v" down -v --remove-orphans
    done
    _down_found=1
  done
}
