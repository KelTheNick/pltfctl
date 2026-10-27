#!/usr/bin/env sh
# pltfctl event bus: a toggle on the running platform, not part of `up`.
# Sourced by scripts/pltfctl. Function-only.
#
#   pltfctl event-bus up [bus]   install the Strimzi operator + Kafka
#   pltfctl event-bus down       remove everything it installed (and the data)
#   pltfctl event-bus status     operator, Kafka and per-broker start-up state
#
# Buses are named in infra/k3d/fleet.env (PLTF_EVENT_BUSES). A bus is one
# manifest, deploy/<ctx>/<namespace>/<bus>.yaml, next to that namespace's
# namespace.yaml and strimzi-operator.yaml. A context has up to two bus
# namespaces, each with its own namespace-scoped Strimzi operator:
#   $PLTF_EVENT_BUS_NS      (kafka-system)  Kafka at KAFKA_BASE_VERSION
#   $PLTF_EVENT_BUS_SECOND_NS (kafka-upgrade) Kafka at KAFKA_VERSION, only
#                           where deploy/<ctx>/kafka-upgrade/ exists (fleet)
# The second reuses the first's CRDs and ClusterRoles, so `up` installs the
# first first and `down` removes it last. flux_apply_tree skips both
# namespaces, so a plain `up` never starts Kafka.

[ -n "${PLTFCTL_HOME:-}" ] && [ -d "$PLTFCTL_HOME/scripts/lib" ] || {
  printf '[err ] PLTFCTL_HOME unset or not a pltfctl checkout (got: %s)\n' \
    "${PLTFCTL_HOME:-<unset>}" >&2
  exit 1
}

pltf_event_bus_names() { printf '%s' "$PLTF_EVENT_BUSES" | tr ' ' '|'; }

# The bus namespaces present for a context, in install order.
pltf_event_bus_namespaces() { # ctx
  printf '%s\n' "$PLTF_EVENT_BUS_NS"
  [ ! -d "$PLTF_DEPLOY_DIR/$1/$PLTF_EVENT_BUS_SECOND_NS" ] || printf '%s\n' "$PLTF_EVENT_BUS_SECOND_NS"
}

pltf_event_bus_known() { # bus
  case " $PLTF_EVENT_BUSES " in *" $1 "*) return 0 ;; esac
  return 1
}

# The cluster the bus runs on: the running distro's first cluster. Dies when
# nothing runs, or when that cluster's deploy tree has no bus.
pltf_event_bus_cluster() {
  _eb_d=$(pltf_running_distro) ||
    pltf_die "No pltfctl cluster is running; start one with: pltfctl up [$(pltf_distro_names)]"
  [ "$(pltf_distro_kind "$_eb_d")" = k3d ] ||
    pltf_die "The $_eb_d distro is Compose and its Kafka is Strimzi's Kafka image (localhost:$PLTF_DEV_KAFKA_PORT); event-bus and event-topic need a k3d distro (lite or fleet)"
  _eb_c=$(pltf_distro_clusters "$_eb_d" | head -n 1)
  [ -d "$PLTF_DEPLOY_DIR/k3d-$_eb_c/$PLTF_EVENT_BUS_NS" ] ||
    pltf_die "The $_eb_d distro has no event bus (no deploy/k3d-$_eb_c/$PLTF_EVENT_BUS_NS/)"
  printf '%s\n' "$_eb_c"
}

# The operator and Kafka images of a bus namespace, pinned in .env.sbom.
pltf_images_event_bus() { # namespace
  case "$1" in
    "$PLTF_EVENT_BUS_SECOND_NS") _ib_kv=$KAFKA_VERSION ;;
    *)                           _ib_kv=$KAFKA_BASE_VERSION ;;
  esac
  printf '%s\n' "quay.io/strimzi/operator:$STRIMZI_VERSION" \
    "quay.io/strimzi/kafka:$STRIMZI_VERSION-kafka-$_ib_kv"
}

# One namespace's operator and Kafka, waited on until Ready.
pltf_event_bus_install() { # name bus namespace
  _eb_name=$1
  _eb_bus=$2
  _eb_ns=$3
  _eb_ctx="k3d-$_eb_name"
  _eb_dir="$PLTF_DEPLOY_DIR/$_eb_ctx/$_eb_ns"
  [ -f "$_eb_dir/$_eb_bus.yaml" ] ||
    pltf_die "No $_eb_bus bus for $_eb_ctx (missing ${_eb_dir#"$PLTFCTL_HOME"/}/$_eb_bus.yaml)"

  # shellcheck disable=SC2046 # one image per word, by design
  pltf_preload_images "$_eb_name" $(pltf_images_event_bus "$_eb_ns")

  pltf_step "installing the Strimzi operator $STRIMZI_VERSION in $_eb_ns on $_eb_ctx"
  flux_apply_file "$_eb_ctx" "$_eb_dir/namespace.yaml" >/dev/null
  flux_apply_file "$_eb_ctx" "$_eb_dir/strimzi-operator.yaml" >/dev/null
  kubectl --context "$_eb_ctx" -n "$_eb_ns" wait --for=condition=Ready \
    helmrelease/strimzi-operator --timeout=300s >/dev/null ||
    pltf_die "Strimzi operator not Ready after 5m (kubectl -n $_eb_ns describe helmrelease strimzi-operator)"

  # The HelmRelease is Ready only after its CRDs are installed, but the API
  # server can take a moment to serve them; retry briefly rather than fail.
  pltf_step "applying the $_eb_bus bus in $_eb_ns on $_eb_ctx"
  _eb_try=0
  until flux_apply_file "$_eb_ctx" "$_eb_dir/$_eb_bus.yaml" >/dev/null 2>&1; do
    _eb_try=$((_eb_try + 1))
    [ "$_eb_try" -lt 12 ] || { flux_apply_file "$_eb_ctx" "$_eb_dir/$_eb_bus.yaml" >/dev/null; break; }
    sleep 5
  done

  pltf_step "waiting for Kafka to report Ready in $_eb_ns (up to 10m)"
  kubectl --context "$_eb_ctx" -n "$_eb_ns" wait --for=condition=Ready \
    kafka --all --timeout=600s >/dev/null ||
    pltf_die "Kafka not Ready after 10m (kubectl -n $_eb_ns get kafka,kafkanodepool,pods)"
  _eb_kc=$(kubectl --context "$_eb_ctx" -n "$_eb_ns" get kafka -o jsonpath='{.items[0].metadata.name}')
  _eb_kv=$(kubectl --context "$_eb_ctx" -n "$_eb_ns" get kafka -o jsonpath='{.items[0].spec.kafka.version}')
  pltf_ok "Kafka $_eb_kv ready on $_eb_ctx: $_eb_kc-kafka-bootstrap.$_eb_ns:9092"
}

# Every bus namespace of the cluster, in order: the second operator needs the
# CRDs and ClusterRoles the first one's release installs.
cmd_event_bus_up() { # bus
  _eb_upname=$(pltf_event_bus_cluster)
  for _eb_upns in $(pltf_event_bus_namespaces "k3d-$_eb_upname"); do
    pltf_event_bus_install "$_eb_upname" "$1" "$_eb_upns"
  done
}

# Liveness / start-up state: operator, each Kafka cluster's Ready condition,
# then every broker pod. A broker pod is Ready only once Strimzi's Kafka agent
# reports the broker RUNNING (log recovery done), so "not ready, no waiting
# reason" means the broker process is up but still starting. Non-zero unless
# every Kafka cluster is Ready. `pltfctl status` calls this.
pltf_event_bus_health() { # ctx [namespace]
  _eb_hns=${2:-$PLTF_EVENT_BUS_NS}
  _eb_k="kubectl --context $1 -n $_eb_hns"
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
  [ -n "$_eb_ks" ] || { pltf_info "[fail] kafka: no Kafka cluster in $_eb_hns"; return 1; }
  for _eb_kc in $_eb_ks; do
    _eb_st=$($_eb_k get kafka "$_eb_kc" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    if [ "$_eb_st" = True ]; then
      pltf_ok "kafka: $_eb_kc Ready (bootstrap $_eb_kc-kafka-bootstrap.$_eb_hns:9092)"
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
# status table, for kafka-system. A second Kafka, if the cluster has one and it
# is on, is checked after it with the same health lines. Exit 1 when no bus is
# on, or one is not Ready.
cmd_event_bus_status() {
  _eb_name=$(pltf_event_bus_cluster)
  _eb_ctx="k3d-$_eb_name"
  if ! kubectl --context "$_eb_ctx" get ns "$PLTF_EVENT_BUS_NS" >/dev/null 2>&1; then
    pltf_info "No event bus on $_eb_ctx (start one with: pltfctl event-bus up)"
    return 1
  fi
  _eb_rc=0
  cmd_status event-bus || _eb_rc=1
  if [ -d "$PLTF_DEPLOY_DIR/$_eb_ctx/$PLTF_EVENT_BUS_SECOND_NS" ]; then
    pltf_step "$PLTF_EVENT_BUS_SECOND_NS"
    if kubectl --context "$_eb_ctx" get ns "$PLTF_EVENT_BUS_SECOND_NS" >/dev/null 2>&1; then
      pltf_event_bus_health "$_eb_ctx" "$PLTF_EVENT_BUS_SECOND_NS" || _eb_rc=1
    else
      pltf_info "off (start it with: pltfctl event-bus up)"; _eb_rc=1
    fi
  fi
  return "$_eb_rc"
}

# Kafka first, so the operator is still there to tear down what it created;
# then the operator; then the namespace and everything left in it (PVCs).
# The Strimzi CRDs stay: Helm never deletes CRDs, and they cost nothing.
pltf_event_bus_remove() { # ctx namespace
  kubectl --context "$1" get ns "$2" >/dev/null 2>&1 || return 0
  pltf_step "removing $2 from $1"
  if kubectl --context "$1" get crd kafkas.kafka.strimzi.io >/dev/null 2>&1; then
    kubectl --context "$1" -n "$2" delete \
      kafka,kafkanodepool --all --wait --timeout=180s >/dev/null
  fi
  kubectl --context "$1" -n "$2" delete \
    helmrelease/strimzi-operator --ignore-not-found --wait --timeout=180s >/dev/null
  kubectl --context "$1" delete ns "$2" --wait --timeout=300s >/dev/null
}

# The second Kafka goes first: it borrows the first operator's ClusterRoles,
# which die with that release.
cmd_event_bus_down() {
  _eb_name=$(pltf_event_bus_cluster)
  _eb_ctx="k3d-$_eb_name"
  if ! kubectl --context "$_eb_ctx" get ns "$PLTF_EVENT_BUS_NS" >/dev/null 2>&1 &&
    ! kubectl --context "$_eb_ctx" get ns "$PLTF_EVENT_BUS_SECOND_NS" >/dev/null 2>&1; then
    pltf_info "No event bus on $_eb_ctx; nothing to do"
    return 0
  fi
  pltf_event_bus_remove "$_eb_ctx" "$PLTF_EVENT_BUS_SECOND_NS"
  kubectl --context "$_eb_ctx" delete clusterrolebinding \
    strimzi-cluster-operator-kafka-upgrade --ignore-not-found >/dev/null
  pltf_event_bus_remove "$_eb_ctx" "$PLTF_EVENT_BUS_NS"
  pltf_ok "Event bus removed from $_eb_ctx."
}
