#!/usr/bin/env sh
# pltfctl load: event-driven load on the running event bus. One producer
# StatefulSet and one consumer-group StatefulSet per topic. Sourced by
# scripts/pltfctl. Function-only.
#
#   pltfctl load up                      create the topics and the (stopped) workloads
#   pltfctl load start [selection] ...   scale producers and consumers up
#   pltfctl load stop  [selection]       scale them to 0
#   pltfctl load status                  pods per topic, and consumer-group lag
#   pltfctl load down                    delete the workloads and the topics
#   pltfctl load render                  print the manifests
#   pltfctl load doctor                  tools, and the bus is Ready
#   pltfctl load check                   offline render test (no cluster needed)
#
# load never runs Kafka: that is `pltfctl event-bus`. It loads whichever
# Kafka is running, found the same way `event-topic` finds it
# (pltf_topic_target in topic.sh), so it refuses when no bus is up.
# wiki/devsecops/10-load-generation.md

[ -n "${PLTFCTL_HOME:-}" ] && [ -d "$PLTFCTL_HOME/scripts/lib" ] || {
  printf '[err ] PLTFCTL_HOME unset or not a pltfctl checkout (got: %s)\n' \
    "${PLTFCTL_HOME:-<unset>}" >&2
  exit 1
}

# The load pods reuse the event bus's own pinned image (never a separate
# pin): quay.io/strimzi/kafka:<STRIMZI_VERSION>-kafka-<KAFKA_BASE_VERSION>,
# the same image pltf_images_event_bus computes for kafka-system.
PLTF_LOAD_KAFKA_IMAGE="quay.io/strimzi/kafka:$STRIMZI_VERSION-kafka-$KAFKA_BASE_VERSION"

pltf_load_kubectl() { # ctx args...
  _lk_ctx=$1; shift
  kubectl --context "$_lk_ctx" "$@"
}

# 1 -> 01. Two digits keep names sorted up to 99 topics.
pltf_load_id() { printf '%02d' "$1"; }

# Every id from 1 to PLTF_LOAD_TOPIC_COUNT, one per line, zero-padded.
pltf_load_all_ids() {
  _li=1
  while [ "$_li" -le "$PLTF_LOAD_TOPIC_COUNT" ]; do
    pltf_load_id "$_li"
    printf '\n'
    _li=$((_li + 1))
  done
}

# Topic ids for a selection, one zero-padded id per line.
#   all            every topic (the default)
#   first:N        topics 1..N
#   list:03,07     exactly those
# Dies on an id outside 1..PLTF_LOAD_TOPIC_COUNT.
pltf_load_select_ids() { # mode value
  case "$1" in
    all)
      pltf_load_all_ids
      ;;
    first)
      _ls_n=$2
      case "$_ls_n" in '' | *[!0-9]*) pltf_die "--first needs a number, got '$_ls_n'" ;; esac
      [ "$_ls_n" -ge 1 ] && [ "$_ls_n" -le "$PLTF_LOAD_TOPIC_COUNT" ] ||
        pltf_die "--first $_ls_n is outside 1..$PLTF_LOAD_TOPIC_COUNT"
      _ls_i=1
      while [ "$_ls_i" -le "$_ls_n" ]; do
        pltf_load_id "$_ls_i"
        printf '\n'
        _ls_i=$((_ls_i + 1))
      done
      ;;
    list)
      for _ls_v in $(printf '%s' "$2" | tr ',' ' '); do
        case "$_ls_v" in '' | *[!0-9]*) pltf_die "--topics needs numbers, got '$_ls_v'" ;; esac
        _ls_d=$(printf '%s' "$_ls_v" | sed 's/^0*//') # 07 -> 7: a leading zero would read as octal
        [ -n "$_ls_d" ] || _ls_d=0
        [ "$_ls_d" -ge 1 ] && [ "$_ls_d" -le "$PLTF_LOAD_TOPIC_COUNT" ] ||
          pltf_die "topic $_ls_v is outside 1..$PLTF_LOAD_TOPIC_COUNT"
        pltf_load_id "$_ls_d"
        printf '\n'
      done
      ;;
    *) pltf_die "unknown selection mode: $1" ;;
  esac
}

pltf_load_render_namespace() {
  cat <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $PLTF_LOAD_NS
  labels:
    app.kubernetes.io/managed-by: pltfctl-load
EOF
}

pltf_load_render_topics() { # kafka-cluster
  for _lt in $(pltf_load_all_ids); do
    cat <<EOF
---
apiVersion: kafka.strimzi.io/v1
kind: KafkaTopic
metadata:
  name: $PLTF_LOAD_PRODUCER_PREFIX-$_lt
  namespace: $PLTF_EVENT_BUS_NS
  labels:
    strimzi.io/cluster: $1
    app.kubernetes.io/managed-by: pltfctl-load
spec:
  partitions: $PLTF_LOAD_PARTITIONS
  replicas: $PLTF_LOAD_REPLICAS
  config:
    min.insync.replicas: $PLTF_LOAD_MIN_ISR
EOF
  done
}

# The container scripts are static text: every value they use is a container
# env var, so the quoted heredocs need no escaping.
pltf_load_producer_script() {
  cat <<'EOF'
              while true; do
                /opt/kafka/bin/kafka-producer-perf-test.sh \
                  --topic "$TOPIC" --num-records 2147483647 \
                  --record-size "$RECORD_SIZE" --throughput "$THROUGHPUT" \
                  --producer-props bootstrap.servers="$BOOTSTRAP" client.id="$POD_NAME" \
                    acks="$ACKS" enable.idempotence="$IDEMPOTENCE" linger.ms="$LINGER_MS" \
                    batch.size="$BATCH_SIZE" compression.type="$COMPRESSION"
                sleep 1
              done
EOF
}

# --timeout is an hour of silence, not a run length: the tool exits after it
# sees no records for that long, and the loop restarts it, so an idle topic
# does not churn the group.
pltf_load_consumer_script() {
  cat <<'EOF'
              printf 'client.id=%s\nauto.offset.reset=earliest\n' "$POD_NAME" >/tmp/consumer.properties
              while true; do
                /opt/kafka/bin/kafka-consumer-perf-test.sh \
                  --bootstrap-server "$BOOTSTRAP" \
                  --topic "$TOPIC" --group "$GROUP" \
                  --messages 2147483647 --timeout 3600000 \
                  --reporting-interval 5000 --show-detailed-stats \
                  --consumer.config /tmp/consumer.properties
                sleep 1
              done
EOF
}

# name role topic bootstrap ; role is producer or consumer
pltf_load_statefulset() {
  _ls_n=$1 _ls_r=$2 _ls_t=$3 _ls_b=$4
  cat <<EOF
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: $_ls_n
  namespace: $PLTF_LOAD_NS
  labels:
    app.kubernetes.io/name: $_ls_r
    app.kubernetes.io/instance: $_ls_n
    app.kubernetes.io/managed-by: pltfctl-load
spec:
  serviceName: $_ls_r
  replicas: 0
  podManagementPolicy: Parallel
  selector:
    matchLabels:
      app.kubernetes.io/name: $_ls_r
      app.kubernetes.io/instance: $_ls_n
  template:
    metadata:
      labels:
        app.kubernetes.io/name: $_ls_r
        app.kubernetes.io/instance: $_ls_n
    spec:
      terminationGracePeriodSeconds: 5
      containers:
        - name: $_ls_r
          image: $PLTF_LOAD_KAFKA_IMAGE
          command: ["/bin/sh", "-c"]
          args:
            - |
EOF
  if [ "$_ls_r" = producer ]; then pltf_load_producer_script; else pltf_load_consumer_script; fi
  cat <<EOF
          env:
            - { name: TOPIC, value: "$_ls_t" }
            - { name: BOOTSTRAP, value: "$_ls_b" }
            - { name: KAFKA_HEAP_OPTS, value: "$PLTF_LOAD_HEAP" }
            - name: POD_NAME
              valueFrom:
                fieldRef: { fieldPath: metadata.name }
EOF
  if [ "$_ls_r" = producer ]; then
    cat <<EOF
            - { name: RECORD_SIZE, value: "$PLTF_LOAD_RECORD_SIZE" }
            - { name: THROUGHPUT, value: "$PLTF_LOAD_THROUGHPUT" }
            - { name: ACKS, value: "$PLTF_LOAD_ACKS" }
            - { name: IDEMPOTENCE, value: "$PLTF_LOAD_IDEMPOTENCE" }
            - { name: LINGER_MS, value: "$PLTF_LOAD_LINGER_MS" }
            - { name: BATCH_SIZE, value: "$PLTF_LOAD_BATCH_SIZE" }
            - { name: COMPRESSION, value: "$PLTF_LOAD_COMPRESSION" }
EOF
  else
    printf '            - { name: GROUP, value: "%s" }\n' "$_ls_n"
  fi
  cat <<EOF
          resources:
            requests: { cpu: $PLTF_LOAD_CPU_REQUEST, memory: $PLTF_LOAD_MEMORY_REQUEST }
            limits: { memory: $PLTF_LOAD_MEMORY_LIMIT }
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            capabilities: { drop: [ALL] }
EOF
}

pltf_load_headless_service() { # role
  cat <<EOF
---
apiVersion: v1
kind: Service
metadata:
  name: $1
  namespace: $PLTF_LOAD_NS
  labels:
    app.kubernetes.io/managed-by: pltfctl-load
spec:
  clusterIP: None
  selector:
    app.kubernetes.io/name: $1
EOF
}

pltf_load_render_workloads() { # kafka-cluster bootstrap
  pltf_load_headless_service producer
  pltf_load_headless_service consumer
  for _lw in $(pltf_load_all_ids); do
    pltf_load_statefulset "$PLTF_LOAD_PRODUCER_PREFIX-$_lw" producer "$PLTF_LOAD_PRODUCER_PREFIX-$_lw" "$2"
    pltf_load_statefulset "$PLTF_LOAD_CONSUMER_PREFIX-$_lw" consumer "$PLTF_LOAD_PRODUCER_PREFIX-$_lw" "$2"
  done
}

pltf_load_render_all() { # kafka-cluster bootstrap
  pltf_load_render_namespace
  pltf_load_render_topics "$1"
  pltf_load_render_workloads "$1" "$2"
}

# The bootstrap address: PLTF_LOAD_BOOTSTRAP if exported (the mesh case), else
# the running bus's own Service.
pltf_load_bootstrap() { # kafka-cluster
  [ -z "$PLTF_LOAD_BOOTSTRAP" ] || { printf '%s\n' "$PLTF_LOAD_BOOTSTRAP"; return 0; }
  printf '%s-kafka-bootstrap.%s:9092\n' "$1" "$PLTF_EVENT_BUS_NS"
}

# Parses the options shared by start and stop into _ls_mode/_ls_value, plus
# start's --producers/--consumers/--force. Sets _ls_np, _ls_nc, _ls_force.
pltf_load_parse_selection() {
  _ls_mode=all
  _ls_value=''
  _ls_np=$PLTF_LOAD_PRODUCERS
  _ls_nc=$PLTF_LOAD_CONSUMERS
  _ls_force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --first) _ls_mode=first; _ls_value=${2:?--first needs a number}; shift 2 ;;
      --topics) _ls_mode=list; _ls_value=${2:?--topics needs a list like 03,07}; shift 2 ;;
      --producers) _ls_np=${2:?--producers needs a number}; shift 2 ;;
      --consumers) _ls_nc=${2:?--consumers needs a number}; shift 2 ;;
      --force) _ls_force=1; shift ;;
      *) pltf_die "unknown option: $1" ;;
    esac
  done
  for _ls_pv in "$_ls_np" "$_ls_nc"; do
    case "$_ls_pv" in '' | *[!0-9]*) pltf_die "replica counts must be numbers, got '$_ls_pv'" ;; esac
  done
}

pltf_load_scale() { # ctx kind-prefix id replicas
  pltf_load_kubectl "$1" -n "$PLTF_LOAD_NS" scale "sts/$2-$3" --replicas="$4" >/dev/null
}

cmd_load_render() {
  _lr=$(pltf_topic_target) || exit 1
  # shellcheck disable=SC2086 # "<ctx> <kafka-cluster>" into $1 $2
  set -- $_lr
  pltf_load_render_all "$2" "$(pltf_load_bootstrap "$2")"
}

cmd_load_up() {
  _lu=$(pltf_topic_target) || exit 1
  # shellcheck disable=SC2086 # "<ctx> <kafka-cluster>" into $1 $2
  set -- $_lu
  pltf_step "creating $PLTF_LOAD_TOPIC_COUNT topics in $PLTF_EVENT_BUS_NS on $1 ($PLTF_LOAD_PARTITIONS partitions, RF $PLTF_LOAD_REPLICAS)"
  pltf_load_render_namespace | pltf_load_kubectl "$1" apply -f - >/dev/null
  pltf_load_render_topics "$2" | pltf_load_kubectl "$1" apply -f - >/dev/null
  pltf_step "creating the producers and consumers in $PLTF_LOAD_NS (stopped: replicas 0)"
  pltf_load_render_workloads "$2" "$(pltf_load_bootstrap "$2")" | pltf_load_kubectl "$1" apply -f - >/dev/null
  pltf_load_kubectl "$1" -n "$PLTF_EVENT_BUS_NS" wait kafkatopic \
    -l app.kubernetes.io/managed-by=pltfctl-load --for=condition=Ready --timeout=180s >/dev/null ||
    pltf_die "Topics not Ready after 3m (kubectl --context $1 -n $PLTF_EVENT_BUS_NS get kafkatopic)"
  pltf_ok "Ready. Start the load with: pltfctl load start --first 1"
}

cmd_load_start() {
  pltf_load_parse_selection "$@"
  _lst=$(pltf_topic_target) || exit 1
  # shellcheck disable=SC2086 # "<ctx> <kafka-cluster>" into $1 $2
  set -- $_lst
  _ls_ids=$(pltf_load_select_ids "$_ls_mode" "$_ls_value")
  _ls_n=$(printf '%s\n' "$_ls_ids" | wc -l | tr -d ' ')
  _ls_pods=$((_ls_n * (_ls_np + _ls_nc)))
  if [ "$_ls_pods" -gt "$PLTF_LOAD_MAX_PODS" ] && [ "$_ls_force" -ne 1 ]; then
    pltf_die "$_ls_n topic(s) x ($_ls_np producers + $_ls_nc consumers) = $_ls_pods pods, over PLTF_LOAD_MAX_PODS=$PLTF_LOAD_MAX_PODS (about 150Mi each). Pick fewer (--first N, --topics 03,07), or pass --force"
  fi
  pltf_load_kubectl "$1" -n "$PLTF_LOAD_NS" get ns >/dev/null 2>&1 || pltf_die "Not set up on $1; run: pltfctl load up"
  pltf_step "starting $_ls_n topic(s): $_ls_np producers and $_ls_nc consumers each ($_ls_pods pods)"
  # Consumers first, so each group is joined before the first record arrives.
  for _ls_i in $_ls_ids; do pltf_load_scale "$1" "$PLTF_LOAD_CONSUMER_PREFIX" "$_ls_i" "$_ls_nc"; done
  for _ls_i in $_ls_ids; do pltf_load_scale "$1" "$PLTF_LOAD_PRODUCER_PREFIX" "$_ls_i" "$_ls_np"; done
  pltf_ok "Scaled. Watch it with: pltfctl load status"
}

cmd_load_stop() {
  pltf_load_parse_selection "$@"
  _lsp=$(pltf_topic_target) || exit 1
  # shellcheck disable=SC2086 # "<ctx> <kafka-cluster>" into $1 $2
  set -- $_lsp
  _ls_ids=$(pltf_load_select_ids "$_ls_mode" "$_ls_value")
  pltf_step "stopping producers, then consumers"
  for _ls_i in $_ls_ids; do pltf_load_scale "$1" "$PLTF_LOAD_PRODUCER_PREFIX" "$_ls_i" 0; done
  for _ls_i in $_ls_ids; do pltf_load_scale "$1" "$PLTF_LOAD_CONSUMER_PREFIX" "$_ls_i" 0; done
  pltf_ok "Stopped."
}

# Ready pods per StatefulSet that has any, then the lag of each active group,
# read from a broker with Kafka's own kafka-consumer-groups.sh.
cmd_load_status() {
  _lss=$(pltf_topic_target) || exit 1
  # shellcheck disable=SC2086 # "<ctx> <kafka-cluster>" into $1 $2
  set -- $_lss
  pltf_load_kubectl "$1" -n "$PLTF_LOAD_NS" get ns >/dev/null 2>&1 || pltf_die "Not set up on $1; run: pltfctl load up"
  pltf_step "running workloads in $PLTF_LOAD_NS"
  pltf_load_kubectl "$1" -n "$PLTF_LOAD_NS" get sts \
    -o custom-columns='NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas' --no-headers |
    awk '$3 > 0 { print }' | { grep . || echo "  nothing running (pltfctl load start)"; }
  _ls_broker=$(pltf_load_kubectl "$1" -n "$PLTF_EVENT_BUS_NS" get pod \
    -l "strimzi.io/cluster=$2,strimzi.io/kind=Kafka" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || _ls_broker=''
  [ -n "$_ls_broker" ] || { pltf_info "no broker pod found in $PLTF_EVENT_BUS_NS; skipping lag"; return 0; }
  pltf_step "consumer-group lag (records, summed over partitions)"
  pltf_load_kubectl "$1" -n "$PLTF_EVENT_BUS_NS" exec "$_ls_broker" -c kafka -- \
    /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
    --describe --all-groups 2>/dev/null |
    awk -v p="$PLTF_LOAD_CONSUMER_PREFIX" '
      $1 ~ "^" p && $6 ~ /^[0-9]+$/ { lag[$1] += $6; parts[$1]++ }
      END { for (g in lag) printf "  %-20s %6d partitions  lag %d\n", g, parts[g], lag[g] }' |
    sort | { grep . || echo "  no active consumer groups"; }
}

# Workloads first, so nothing writes to a topic as it is deleted.
cmd_load_down() {
  _lsd=$(pltf_topic_target) || exit 1
  # shellcheck disable=SC2086 # "<ctx> <kafka-cluster>" into $1 $2
  set -- $_lsd
  pltf_step "deleting $PLTF_LOAD_NS and the load topics in $PLTF_EVENT_BUS_NS on $1"
  pltf_load_kubectl "$1" delete ns "$PLTF_LOAD_NS" --ignore-not-found --wait --timeout=120s >/dev/null
  pltf_load_kubectl "$1" -n "$PLTF_EVENT_BUS_NS" delete kafkatopic \
    -l app.kubernetes.io/managed-by=pltfctl-load --ignore-not-found --wait --timeout=120s >/dev/null 2>&1 || true
  pltf_ok "Removed."
}

cmd_load_doctor() {
  pltf_require_cmd kubectl
  pltf_ok "kubectl found"
  _lsdc=$(pltf_topic_target) || exit 1
  # shellcheck disable=SC2086 # "<ctx> <kafka-cluster>" into $1 $2
  set -- $_lsdc
  pltf_ok "Kafka $PLTF_EVENT_BUS_NS/$2 Ready on $1"
  pltf_ok "clients connect to $(pltf_load_bootstrap "$2"); image $PLTF_LOAD_KAFKA_IMAGE"
}

cmd_load_check() { sh "$PLTFCTL_HOME/tests/load_render_test.sh"; }
