#!/usr/bin/env sh
# pltfctl event-topic: Kafka topics, and the client identities that use them,
# on the running event bus. Sourced by scripts/pltfctl. Function-only.
#
#   pltfctl event-topic create <topic> [--partitions N] [--replicas N]
#   pltfctl event-topic delete <topic>
#   pltfctl event-topic list
#   pltfctl event-topic grant <user> <topic>[,<topic>...] [--access read|write|all]
#       [--group G] [--produce B/s] [--consume B/s] [--request-pct N]
#       [--csr FILE] [--out DIR]
#   pltfctl event-topic revoke <user>
#   pltfctl event-topic creds <user>
#
# Everything is a Strimzi custom resource: KafkaTopic for a topic, KafkaUser
# for an identity (mTLS certificate + ACLs + quotas). The entity operator
# turns them into Kafka state. ACLs and quotas bind to the certificate's
# principal, so they apply on the `tls` listener (9093) only; `plain` (9092)
# stays open to anyone in the cluster. See wiki/devsecops/08-event-bus.md#identities

[ -n "${PLTFCTL_HOME:-}" ] && [ -d "$PLTFCTL_HOME/scripts/lib" ] || {
  printf '[err ] PLTFCTL_HOME unset or not a pltfctl checkout (got: %s)\n' \
    "${PLTFCTL_HOME:-<unset>}" >&2
  exit 1
}

# Signed client certificates, when the client brings its own key (--csr).
# Strimzi's own user certificates are valid for 365 days too.
PLTF_TOPIC_CERT_DAYS=365

# Where `grant` writes credentials. Gitignored: it holds private keys.
PLTF_TOPIC_CREDS_DIR="$PLTFCTL_HOME/.kafka-creds"

# The bus must be up: prints "<ctx> <kafka-cluster>", or dies.
pltf_topic_target() {
  _tt_ctx="k3d-$(pltf_event_bus_cluster)"
  _tt_kc=$(kubectl --context "$_tt_ctx" -n "$PLTF_EVENT_BUS_NS" get kafka \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || _tt_kc=''
  [ -n "$_tt_kc" ] ||
    pltf_die "No event bus on $_tt_ctx (start one with: pltfctl event-bus up)"
  printf '%s %s\n' "$_tt_ctx" "$_tt_kc"
}

# Topic and user names become resource names, the user's also the cert CN:
# lowercase DNS-1123 subdomains, so they are safe in YAML and openssl too.
pltf_topic_name_ok() { # kind name
  printf '%s' "$2" | grep -Eq '^[a-z0-9]([a-z0-9.-]{0,62}[a-z0-9])?$' ||
    pltf_die "Invalid $1 name: '$2' (lowercase letters, digits, '.', '-'; at most 64)"
}

pltf_topic_int_ok() { # flag value
  case "$2" in '' | *[!0-9]*) pltf_die "$1 needs a whole number (got: '$2')" ;; esac
}

pltf_topic_kubectl() { # ctx args...
  _tk_ctx=$1; shift
  kubectl --context "$_tk_ctx" -n "$PLTF_EVENT_BUS_NS" "$@"
}

cmd_topic_create() { # topic [--partitions N] [--replicas N]
  [ "$#" -ge 1 ] || pltf_die "Usage: pltfctl event-topic create <topic> [--partitions N] [--replicas N]"
  _tc_topic=$1; shift
  pltf_topic_name_ok topic "$_tc_topic"
  _tc_parts=3; _tc_reps=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --partitions) pltf_topic_int_ok "$1" "${2:-}"; _tc_parts=$2; shift 2 ;;
      --replicas) pltf_topic_int_ok "$1" "${2:-}"; _tc_reps=$2; shift 2 ;;
      *) pltf_die "Unknown argument: $1" ;;
    esac
  done
  _tt=$(pltf_topic_target) || exit 1
  # shellcheck disable=SC2086 # "<ctx> <kafka-cluster>" into $1 $2
  set -- $_tt
  # No --replicas: the bus's default.replication.factor (3).
  pltf_step "applying KafkaTopic $_tc_topic on $1"
  {
    printf 'apiVersion: kafka.strimzi.io/v1\nkind: KafkaTopic\nmetadata:\n'
    printf '  name: %s\n  namespace: %s\n' "$_tc_topic" "$PLTF_EVENT_BUS_NS"
    printf '  labels:\n    strimzi.io/cluster: %s\nspec:\n' "$2"
    printf '  partitions: %s\n' "$_tc_parts"
    [ -z "$_tc_reps" ] || printf '  replicas: %s\n' "$_tc_reps"
  } | pltf_topic_kubectl "$1" apply -f - >/dev/null
  pltf_topic_kubectl "$1" wait --for=condition=Ready "kafkatopic/$_tc_topic" --timeout=120s >/dev/null ||
    pltf_die "KafkaTopic $_tc_topic not Ready after 2m (kubectl -n $PLTF_EVENT_BUS_NS describe kafkatopic $_tc_topic)"
  pltf_ok "Topic $_tc_topic ready ($_tc_parts partitions)"
}

cmd_topic_delete() { # topic
  [ "$#" -eq 1 ] || pltf_die "Usage: pltfctl event-topic delete <topic>"
  pltf_topic_name_ok topic "$1"
  _td_topic=$1
  _tt=$(pltf_topic_target) || exit 1
  # shellcheck disable=SC2086 # "<ctx> <kafka-cluster>" into $1 $2
  set -- $_tt
  pltf_topic_kubectl "$1" delete kafkatopic "$_td_topic" --wait --timeout=120s >/dev/null ||
    pltf_die "Could not delete KafkaTopic $_td_topic"
  pltf_ok "Topic $_td_topic deleted, with its data"
}

cmd_topic_list() {
  _tt=$(pltf_topic_target) || exit 1
  # shellcheck disable=SC2086 # "<ctx> <kafka-cluster>" into $1 $2
  set -- $_tt
  pltf_info "topics on $1"
  pltf_topic_kubectl "$1" get kafkatopic \
    -o custom-columns='TOPIC:.spec.topicName,NAME:.metadata.name,PARTITIONS:.spec.partitions,REPLICAS:.spec.replicas,READY:.status.conditions[?(@.type=="Ready")].status'
  pltf_info "users on $1"
  pltf_topic_kubectl "$1" get kafkauser \
    -o custom-columns='USER:.metadata.name,AUTH:.spec.authentication.type,PRODUCE_B/S:.spec.quotas.producerByteRate,CONSUME_B/S:.spec.quotas.consumerByteRate,READY:.status.conditions[?(@.type=="Ready")].status'
}

# ACL entries for one topic. read: consume (with the group ACL below);
# write: produce; all: both. Describe is needed for metadata either way.
pltf_topic_acl_yaml() { # topic access
  case "$2" in
    read) _ta_ops='Describe, Read' ;;
    write) _ta_ops='Describe, Write' ;;
    all) _ta_ops='Describe, Read, Write' ;;
  esac
  printf '      - resource: { type: topic, name: %s, patternType: literal }\n' "$1"
  printf '        operations: [%s]\n' "$_ta_ops"
}

# The KafkaUser. tls: Strimzi issues the key and certificate (Secret <user>);
# tls-external: the client's own certificate, signed here from its CSR.
pltf_topic_user_yaml() { # kafka-cluster user auth topics access group produce consume reqpct
  printf 'apiVersion: kafka.strimzi.io/v1\nkind: KafkaUser\nmetadata:\n'
  printf '  name: %s\n  namespace: %s\n' "$2" "$PLTF_EVENT_BUS_NS"
  printf '  labels:\n    strimzi.io/cluster: %s\nspec:\n' "$1"
  printf '  authentication:\n    type: %s\n' "$3"
  printf '  authorization:\n    type: simple\n    acls:\n'
  for _tu_t in $(printf '%s' "$4" | tr ',' ' '); do pltf_topic_acl_yaml "$_tu_t" "$5"; done
  [ "$5" = write ] ||
    printf '      - resource: { type: group, name: %s, patternType: prefix }\n        operations: [Read]\n' "$6"
  [ -n "$7$8$9" ] || return 0
  printf '  quotas:\n'
  [ -z "$7" ] || printf '    producerByteRate: %s\n' "$7"
  [ -z "$8" ] || printf '    consumerByteRate: %s\n' "$8"
  [ -z "$9" ] || printf '    requestPercentage: %s\n' "$9"
}

# Sign a client's CSR with the bus's clients CA, the CA the tls listener
# trusts. The CA key is copied to a private temp dir for openssl and removed
# straight after. The CSR's subject must be exactly CN=<user>: that is the
# principal Kafka sees, and the one the ACLs name.
pltf_topic_sign_csr() { # ctx kafka-cluster user csr out-crt
  pltf_require_cmd openssl
  [ -r "$4" ] || pltf_die "Cannot read CSR: $4"
  openssl req -in "$4" -noout -verify >/dev/null 2>&1 ||
    pltf_die "Not a valid, self-signed CSR: $4"
  _ts_subj=$(openssl req -in "$4" -noout -subject | sed 's/^subject= *//; s#^/##; s/ //g')
  [ "$_ts_subj" = "CN=$3" ] ||
    pltf_die "CSR subject is '$_ts_subj'; it must be exactly CN=$3 (openssl req -new -key k.pem -subj /CN=$3)"
  _ts_dir=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/pltfctl-csr.XXXXXX") || pltf_die "mktemp failed"
  # shellcheck disable=SC2064 # expand now: the trap must remove this dir
  trap "rm -rf '$_ts_dir'" EXIT
  pltf_topic_kubectl "$1" get secret "$2-clients-ca" -o jsonpath='{.data.ca\.key}' |
    base64 -d >"$_ts_dir/ca.key"
  pltf_topic_kubectl "$1" get secret "$2-clients-ca-cert" -o jsonpath='{.data.ca\.crt}' |
    base64 -d >"$_ts_dir/ca.crt"
  [ -s "$_ts_dir/ca.key" ] && [ -s "$_ts_dir/ca.crt" ] ||
    pltf_die "Clients CA not found ($2-clients-ca, $2-clients-ca-cert in $PLTF_EVENT_BUS_NS)"
  printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=clientAuth\n' \
    >"$_ts_dir/ext.cnf"
  openssl x509 -req -in "$4" -CA "$_ts_dir/ca.crt" -CAkey "$_ts_dir/ca.key" \
    -set_serial "0x$(openssl rand -hex 16)" -days "$PLTF_TOPIC_CERT_DAYS" -sha256 \
    -extfile "$_ts_dir/ext.cnf" -out "$5" >/dev/null 2>&1 ||
    pltf_die "openssl could not sign $4"
  rm -rf "$_ts_dir"
  trap - EXIT
}

# Write the client's files: ca.crt (the cluster CA, to trust the brokers),
# user.crt, user.key + user.pem (key and cert in one, for Kafka's PEM
# keystore) when Strimzi issued the key, and client.properties.
pltf_topic_write_creds() { # ctx kafka-cluster user dir
  (umask 077 && mkdir -p "$4")
  rm -f "$4"/user.*
  pltf_topic_kubectl "$1" get secret "$2-cluster-ca-cert" -o jsonpath='{.data.ca\.crt}' |
    base64 -d >"$4/ca.crt"
  if pltf_topic_kubectl "$1" get secret "$3" >/dev/null 2>&1; then
    for _tw_k in user.crt user.key; do
      pltf_topic_kubectl "$1" get secret "$3" -o jsonpath="{.data.${_tw_k%.*}\\.${_tw_k#*.}}" |
        base64 -d >"$4/$_tw_k"
    done
  fi
  _tw_ks="$4/user.pem"
  if [ -s "$4/user.key" ]; then
    cat "$4/user.key" "$4/user.crt" >"$_tw_ks"
  else
    _tw_ks="<your key + $4/user.crt, concatenated>"
  fi
  chmod 600 "$4"/*
  cat >"$4/client.properties" <<EOF
bootstrap.servers=$2-kafka-bootstrap.$PLTF_EVENT_BUS_NS:9093
security.protocol=SSL
ssl.truststore.type=PEM
ssl.truststore.location=$4/ca.crt
ssl.keystore.type=PEM
ssl.keystore.location=$_tw_ks
EOF
}

cmd_topic_grant() { # user topics [flags]
  [ "$#" -ge 2 ] ||
    pltf_die "Usage: pltfctl event-topic grant <user> <topic>[,<topic>...] [--access read|write|all] [--group G] [--produce B/s] [--consume B/s] [--request-pct N] [--csr FILE] [--out DIR]"
  _tg_user=$1 _tg_topics=$2; shift 2
  pltf_topic_name_ok user "$_tg_user"
  for _tg_t in $(printf '%s' "$_tg_topics" | tr ',' ' '); do pltf_topic_name_ok topic "$_tg_t"; done
  _tg_access=all _tg_group=$_tg_user _tg_prod='' _tg_cons='' _tg_req='' _tg_csr='' _tg_out=''
  while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || pltf_die "$1 needs a value"
    case "$1" in
      --access) case "$2" in read | write | all) _tg_access=$2 ;; *) pltf_die "--access is read, write or all" ;; esac ;;
      --group) pltf_topic_name_ok group "$2"; _tg_group=$2 ;;
      --produce) pltf_topic_int_ok "$1" "$2"; _tg_prod=$2 ;;
      --consume) pltf_topic_int_ok "$1" "$2"; _tg_cons=$2 ;;
      --request-pct) pltf_topic_int_ok "$1" "$2"; _tg_req=$2 ;;
      --csr) _tg_csr=$2 ;;
      --out) _tg_out=$2 ;;
      *) pltf_die "Unknown argument: $1" ;;
    esac
    shift 2
  done
  _tt=$(pltf_topic_target) || exit 1
  # shellcheck disable=SC2086 # "<ctx> <kafka-cluster>" into $1 $2
  set -- $_tt
  _tg_out=${_tg_out:-$PLTF_TOPIC_CREDS_DIR/${1#k3d-}/$_tg_user}
  _tg_auth=tls
  [ -z "$_tg_csr" ] || _tg_auth=tls-external

  pltf_step "applying KafkaUser $_tg_user ($_tg_access on $_tg_topics, auth $_tg_auth) on $1"
  pltf_topic_user_yaml "$2" "$_tg_user" "$_tg_auth" "$_tg_topics" "$_tg_access" \
    "$_tg_group" "$_tg_prod" "$_tg_cons" "$_tg_req" |
    pltf_topic_kubectl "$1" apply -f - >/dev/null
  pltf_topic_kubectl "$1" wait --for=condition=Ready "kafkauser/$_tg_user" --timeout=120s >/dev/null ||
    pltf_die "KafkaUser $_tg_user not Ready after 2m (kubectl -n $PLTF_EVENT_BUS_NS describe kafkauser $_tg_user)"

  pltf_topic_write_creds "$1" "$2" "$_tg_user" "$_tg_out"
  if [ -n "$_tg_csr" ]; then
    pltf_topic_sign_csr "$1" "$2" "$_tg_user" "$_tg_csr" "$_tg_out/user.crt"
    chmod 600 "$_tg_out/user.crt"
  fi
  pltf_ok "User $_tg_user ready. Credentials in $_tg_out:"
  for _tg_f in "$_tg_out"/*; do printf "         %s\n" "${_tg_f##*/}"; done
  pltf_info "print them with: pltfctl event-topic creds $_tg_user"
}

cmd_topic_revoke() { # user
  [ "$#" -eq 1 ] || pltf_die "Usage: pltfctl event-topic revoke <user>"
  pltf_topic_name_ok user "$1"
  _tr_user=$1
  _tt=$(pltf_topic_target) || exit 1
  # shellcheck disable=SC2086 # "<ctx> <kafka-cluster>" into $1 $2
  set -- $_tt
  # Removes the ACLs and quotas. A certificate already issued stays valid
  # until it expires, but with no ACLs it can no longer reach any topic.
  pltf_topic_kubectl "$1" delete kafkauser "$_tr_user" --wait --timeout=120s >/dev/null ||
    pltf_die "Could not delete KafkaUser $_tr_user"
  rm -rf "${PLTF_TOPIC_CREDS_DIR:?}/${1#k3d-}/$_tr_user"
  pltf_ok "User $_tr_user revoked; its ACLs, quotas and local credentials are gone"
}

# PEM to stdout, so it can be piped or redirected; nothing else goes there.
# The cluster CA's private key is never printed: clients only need its cert.
cmd_topic_creds() { # user
  [ "$#" -eq 1 ] || pltf_die "Usage: pltfctl event-topic creds <user>"
  pltf_topic_name_ok user "$1"
  _tk_user=$1
  _tt=$(pltf_topic_target) || exit 1
  # shellcheck disable=SC2086 # "<ctx> <kafka-cluster>" into $1 $2
  set -- $_tt
  _tk_dir="$PLTF_TOPIC_CREDS_DIR/${1#k3d-}/$_tk_user"
  pltf_topic_kubectl "$1" get kafkauser "$_tk_user" >/dev/null 2>&1 ||
    pltf_die "No KafkaUser $_tk_user (create it with: pltfctl event-topic grant $_tk_user <topic>)"
  [ -s "$_tk_dir/user.crt" ] || pltf_topic_write_creds "$1" "$2" "$_tk_user" "$_tk_dir"
  [ -s "$_tk_dir/user.crt" ] ||
    pltf_die "$_tk_user's certificate was signed from a CSR on another host; re-run grant with --csr"
  printf '# cluster CA certificate (truststore): %s-cluster-ca-cert\n' "$2"
  cat "$_tk_dir/ca.crt"
  printf '# client certificate: CN=%s\n' "$_tk_user"
  cat "$_tk_dir/user.crt"
  if [ -s "$_tk_dir/user.key" ]; then
    printf '# client private key\n'
    cat "$_tk_dir/user.key"
  else
    printf '# client private key: held by the client (signed from its CSR)\n'
  fi
}
