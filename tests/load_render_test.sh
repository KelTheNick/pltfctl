#!/usr/bin/env sh
# Offline test of pltfctl load's renderer and selection helper. Needs no
# cluster: a fixed "kafka-cluster" name stands in for what pltf_topic_target
# would discover live.
#   ./scripts/pltfctl load check
set -eu

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
PLTFCTL_HOME=$(CDPATH='' cd -- "$here/.." && pwd)
export PLTFCTL_HOME

# A small, fixed configuration so the counts below do not depend on
# infra/load.env's defaults.
PLTF_LOAD_TOPIC_COUNT=3
PLTF_LOAD_PARTITIONS=9
export PLTF_LOAD_TOPIC_COUNT PLTF_LOAD_PARTITIONS

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../.env.sbom
. "$PLTFCTL_HOME/.env.sbom"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../infra/k3d/fleet.env
. "$PLTFCTL_HOME/infra/k3d/fleet.env"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../infra/load.env
. "$PLTFCTL_HOME/infra/load.env"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../scripts/lib/core/log.sh
. "$PLTFCTL_HOME/scripts/lib/core/log.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../scripts/lib/pltfctl/load.sh
. "$PLTFCTL_HOME/scripts/lib/pltfctl/load.sh"

fails=0
expect() { # label want got
  if [ "$2" = "$3" ]; then
    pltf_ok "$1"
  else
    pltf_info "[fail] $1: want '$2', got '$3'"
    fails=$((fails + 1))
  fi
}
count() { grep -c -- "$1" || true; } # grep -c exits 1 on zero matches

kc=strimzi
bootstrap=$(pltf_load_bootstrap "$kc")
all=$(pltf_load_render_all "$kc" "$bootstrap")
expect "one KafkaTopic per topic" 3 "$(printf '%s\n' "$all" | count '^kind: KafkaTopic')"
expect "one producer and one consumer StatefulSet per topic" 6 "$(printf '%s\n' "$all" | count '^kind: StatefulSet')"
expect "every StatefulSet starts at 0 replicas" 6 "$(printf '%s\n' "$all" | count '^  replicas: 0$')"
expect "partitions come from config" 3 "$(printf '%s\n' "$all" | count '^  partitions: 9$')"
expect "producers are acks=all and idempotent" 3 "$(printf '%s\n' "$all" | count 'name: IDEMPOTENCE, value: "true"')"
expect "client.id comes from the pod name" 6 "$(printf '%s\n' "$all" | count 'client.id=')"
expect "every pod uses the pinned image" 6 "$(printf '%s\n' "$all" | count "image: $PLTF_LOAD_KAFKA_IMAGE\$")"
expect "names are zero-padded (topic and producer)" 2 "$(printf '%s\n' "$all" | count 'name: sif-load-03$')"
expect "the consumer group is the StatefulSet name" 1 "$(printf '%s\n' "$all" | count 'name: GROUP, value: "sif-consume-02"')"
expect "default bootstrap is the bus's own Service" "$kc-kafka-bootstrap.$PLTF_EVENT_BUS_NS:9092" "$bootstrap"

expect "all selects every topic" "01 02 03" "$(pltf_load_select_ids all '' | tr '\n' ' ' | sed 's/ $//')"
expect "first selects a prefix" "01 02" "$(pltf_load_select_ids first 2 | tr '\n' ' ' | sed 's/ $//')"
expect "list selects exactly those" "03 01" "$(pltf_load_select_ids list 03,1 | tr '\n' ' ' | sed 's/ $//')"
# pltf_die exits, so the out-of-range case runs in a subshell.
if (pltf_load_select_ids first 4 >/dev/null 2>&1); then
  pltf_info "[fail] --first past the topic count is accepted"
  fails=$((fails + 1))
else
  pltf_ok "--first past the topic count is refused"
fi

# Even a client dry run needs the API server for a REST mapping, and the
# KafkaTopic mapping only exists where Strimzi's CRDs are installed. So this
# is a bonus check when a cluster happens to be reachable, never a
# requirement: `load check` stays offline.
if command -v kubectl >/dev/null 2>&1 && kubectl api-versions >/dev/null 2>&1; then
  if printf '%s\n' "$all" | kubectl apply --dry-run=client --validate=false -f - >/dev/null 2>&1; then
    pltf_ok "kubectl accepts the rendered manifests (client dry run)"
  else
    pltf_info "[fail] kubectl rejects the rendered manifests"
    fails=$((fails + 1))
  fi
else
  pltf_info "[skip] kubectl dry run: no reachable cluster"
fi

[ "$fails" -eq 0 ] || pltf_die "$fails check(s) failed"
pltf_ok "pltfctl load render checks pass."
