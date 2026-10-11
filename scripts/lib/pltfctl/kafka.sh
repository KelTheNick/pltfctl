#!/usr/bin/env sh
# pltfctl event bus: a toggle on the running platform, not part of `up`.
# Sourced by scripts/pltfctl. Function-only.
#
#   pltfctl event-bus up [bus]   install the Strimzi operator + one Kafka bus
#   pltfctl event-bus down       remove both (and the bus's data)
#   pltfctl event-bus status     operator, Kafka and per-broker start-up state
#
# Buses are named in infra/fleet.env (PLTF_EVENT_BUSES). Each is one manifest,
# deploy/<ctx>/$PLTF_EVENT_BUS_NS/<bus>.yaml, next to the shared
# namespace.yaml and strimzi-operator.yaml. flux_apply_tree skips that
# namespace, so a plain `up` never starts Kafka.

[ -n "${PLTFCTL_HOME:-}" ] && [ -d "$PLTFCTL_HOME/scripts/lib" ] || {
  printf '[err ] PLTFCTL_HOME unset or not a pltfctl checkout (got: %s)\n' \
    "${PLTFCTL_HOME:-<unset>}" >&2
  exit 1
}

pltf_event_bus_names() { printf '%s' "$PLTF_EVENT_BUSES" | tr ' ' '|'; }

pltf_event_bus_known() { # bus
  case " $PLTF_EVENT_BUSES " in *" $1 "*) return 0 ;; esac
  return 1
}

# The cluster the bus runs on: the running distro's first cluster. Dies when
# nothing runs, or when that cluster's deploy tree has no bus (fleet).
pltf_event_bus_cluster() {
  _eb_d=$(pltf_running_distro) ||
    pltf_die "No pltfctl cluster is running; start one with: pltfctl up [$(pltf_distro_names)]"
  [ "$(pltf_distro_kind "$_eb_d")" = k3d ] ||
    pltf_die "The $_eb_d distro is Compose and its Kafka is AutoMQ (localhost:$PLTF_DEV_KAFKA_PORT); event-bus and event-topic need the lite distro"
  _eb_c=$(pltf_distro_clusters "$_eb_d" | head -n 1)
  [ -d "$PLTF_DEPLOY_DIR/k3d-$_eb_c/$PLTF_EVENT_BUS_NS" ] ||
    pltf_die "The $_eb_d distro has no event bus (no deploy/k3d-$_eb_c/$PLTF_EVENT_BUS_NS/)"
  printf '%s\n' "$_eb_c"
}

# The operator and Kafka images, pinned in .env.sbom.
pltf_images_event_bus() {
  printf '%s\n' "quay.io/strimzi/operator:$STRIMZI_VERSION" \
    "quay.io/strimzi/kafka:$STRIMZI_VERSION-kafka-$KAFKA_VERSION"
}

cmd_event_bus_up() { # bus
  _eb_bus=$1
  _eb_name=$(pltf_event_bus_cluster)
  _eb_ctx="k3d-$_eb_name"
  _eb_dir="$PLTF_DEPLOY_DIR/$_eb_ctx/$PLTF_EVENT_BUS_NS"
  [ -f "$_eb_dir/$_eb_bus.yaml" ] ||
    pltf_die "No $_eb_bus bus for $_eb_ctx (missing ${_eb_dir#"$PLTFCTL_HOME"/}/$_eb_bus.yaml)"

  # shellcheck disable=SC2046 # one image per word, by design
  pltf_preload_images "$_eb_name" $(pltf_images_event_bus)

  pltf_step "installing the Strimzi operator $STRIMZI_VERSION on $_eb_ctx"
  flux_apply_file "$_eb_ctx" "$_eb_dir/namespace.yaml" >/dev/null
  flux_apply_file "$_eb_ctx" "$_eb_dir/strimzi-operator.yaml" >/dev/null
  kubectl --context "$_eb_ctx" -n "$PLTF_EVENT_BUS_NS" wait --for=condition=Ready \
    helmrelease/strimzi-operator --timeout=300s >/dev/null ||
    pltf_die "Strimzi operator not Ready after 5m (kubectl -n $PLTF_EVENT_BUS_NS describe helmrelease strimzi-operator)"

  # The HelmRelease is Ready only after its CRDs are installed, but the API
  # server can take a moment to serve them; retry briefly rather than fail.
  pltf_step "applying the $_eb_bus bus on $_eb_ctx"
  _eb_try=0
  until flux_apply_file "$_eb_ctx" "$_eb_dir/$_eb_bus.yaml" >/dev/null 2>&1; do
    _eb_try=$((_eb_try + 1))
    [ "$_eb_try" -lt 12 ] || { flux_apply_file "$_eb_ctx" "$_eb_dir/$_eb_bus.yaml" >/dev/null; break; }
    sleep 5
  done

  pltf_step "waiting for Kafka to report Ready on $_eb_ctx (up to 10m)"
  kubectl --context "$_eb_ctx" -n "$PLTF_EVENT_BUS_NS" wait --for=condition=Ready \
    kafka --all --timeout=600s >/dev/null ||
    pltf_die "Kafka not Ready after 10m (kubectl -n $PLTF_EVENT_BUS_NS get kafka,kafkanodepool,pods)"
  pltf_ok "Event bus '$_eb_bus' ready on $_eb_ctx: strimzi-kafka-bootstrap.$PLTF_EVENT_BUS_NS:9092"
}

# Liveness / start-up state: operator, each Kafka cluster's Ready condition,
# then every broker pod. A broker pod is Ready only once Strimzi's Kafka agent
# reports the broker RUNNING (log recovery done), so "not ready, no waiting
# reason" means the broker process is up but still starting. Non-zero unless
# every Kafka cluster is Ready. `pltfctl status` calls this.
pltf_event_bus_health() { # ctx
  _eb_k="kubectl --context $1 -n $PLTF_EVENT_BUS_NS"
  _eb_rc=0

  _eb_op=$($_eb_k get helmrelease strimzi-operator \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) || _eb_op=''
  if [ "$_eb_op" = True ]; then
    pltf_ok "operator: strimzi-operator Ready"
  else
    pltf_info "[fail] operator: strimzi-operator not Ready (${_eb_op:-missing})"
    _eb_rc=1
  fi

  _eb_ks=$($_eb_k get kafka -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null) || _eb_ks=''
  [ -n "$_eb_ks" ] || { pltf_info "[fail] kafka: no Kafka cluster in $PLTF_EVENT_BUS_NS"; return 1; }
  for _eb_kc in $_eb_ks; do
    _eb_st=$($_eb_k get kafka "$_eb_kc" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    if [ "$_eb_st" = True ]; then
      pltf_ok "kafka: $_eb_kc Ready (bootstrap $_eb_kc-kafka-bootstrap.$PLTF_EVENT_BUS_NS:9092)"
    else
      _eb_why=$($_eb_k get kafka "$_eb_kc" \
        -o jsonpath='{.status.conditions[?(@.type=="NotReady")].reason}{" "}{.status.conditions[?(@.type=="NotReady")].message}')
      pltf_info "[fail] kafka: $_eb_kc not Ready${_eb_why:+ — $_eb_why}"
      _eb_rc=1
    fi
  done
  return "$_eb_rc"
}

# The per-pod lines (state, restarts, CPU, memory, disk, PVCs) come from the
# status table. Exit 1 when no bus is on, or it is not Ready.
cmd_event_bus_status() {
  _eb_name=$(pltf_event_bus_cluster)
  if ! kubectl --context "k3d-$_eb_name" get ns "$PLTF_EVENT_BUS_NS" >/dev/null 2>&1; then
    pltf_info "No event bus on k3d-$_eb_name (start one with: pltfctl event-bus up)"
    return 1
  fi
  cmd_status event-bus
}

# Kafka first, so the operator is still there to tear down what it created;
# then the operator; then the namespace and everything left in it (PVCs).
# The Strimzi CRDs stay: Helm never deletes CRDs, and they cost nothing.
cmd_event_bus_down() {
  _eb_name=$(pltf_event_bus_cluster)
  _eb_ctx="k3d-$_eb_name"
  if ! kubectl --context "$_eb_ctx" get ns "$PLTF_EVENT_BUS_NS" >/dev/null 2>&1; then
    pltf_info "No event bus on $_eb_ctx; nothing to do"
    return 0
  fi
  pltf_step "removing the event bus from $_eb_ctx"
  if kubectl --context "$_eb_ctx" get crd kafkas.kafka.strimzi.io >/dev/null 2>&1; then
    kubectl --context "$_eb_ctx" -n "$PLTF_EVENT_BUS_NS" delete \
      kafka,kafkanodepool --all --wait --timeout=180s >/dev/null
  fi
  kubectl --context "$_eb_ctx" -n "$PLTF_EVENT_BUS_NS" delete \
    helmrelease/strimzi-operator --ignore-not-found --wait --timeout=180s >/dev/null
  kubectl --context "$_eb_ctx" delete ns "$PLTF_EVENT_BUS_NS" --wait --timeout=300s >/dev/null
  pltf_ok "Event bus removed from $_eb_ctx."
}
