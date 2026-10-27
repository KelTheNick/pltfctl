#!/usr/bin/env sh
# pltfctl SBOM drift check. Sourced by scripts/pltfctl.
# Function-only — no work at source time.

[ -n "${PLTFCTL_HOME:-}" ] && [ -d "$PLTFCTL_HOME/scripts/lib" ] || {
  printf '[err ] PLTFCTL_HOME unset or not a pltfctl checkout (got: %s)\n' \
    "${PLTFCTL_HOME:-<unset>}" >&2
  exit 1
}

# Assert a deploy/ manifest still carries the version .env.sbom claims for it.
# COUNT is part of the assertion, not decoration: kgateway's version appears
# twice and podinfo's in two files, so a presence-only check would pass a
# half-finished bump — the likeliest drift there is.
# See scripts/README.md#the-sbom
pltf_sbom_expect() { # rel_path literal count label
  # A missing file must not read as "0 matches, therefore drift". Distinguish
  # it, or a renamed manifest reports as a version mismatch and sends the
  # reader looking in the wrong place.
  if [ ! -f "$PLTFCTL_HOME/$1" ]; then
    pltf_info "[fail] SBOM: $1 not found, so $4 cannot be checked"
    return 1
  fi
  # grep -c exits 1 on zero matches, which `set -e` would take as fatal; the
  # count on stdout is what matters here, so capture it and ignore the status.
  _sb_n=$(grep -cF "$2" "$PLTFCTL_HOME/$1") || _sb_n=0
  [ "$_sb_n" -eq "$3" ] && return 0
  pltf_info "[fail] SBOM drift: $4 — $1 has $_sb_n occurrence(s) of '$2', .env.sbom says $3"
  return 1
}

# Every deploy/-side pin, checked against .env.sbom. Returns non-zero if any
# disagree. The scripts/-side pins need no check: they are read FROM .env.sbom at
# runtime, so they cannot drift from it.
pltf_sbom_check() {
  _sb_rc=0
  pltf_sbom_expect deploy/k3d-base/kube-system/kgateway.yaml \
    "version: \"$KGATEWAY_CHART_VERSION\"" 2 "kgateway chart" || _sb_rc=1
  pltf_sbom_expect deploy/k3d-lite/kafka-system/strimzi-operator.yaml \
    "version: \"$STRIMZI_VERSION\"" 1 "strimzi chart" || _sb_rc=1
  pltf_sbom_expect deploy/k3d-lite/kafka-system/kraft.yaml \
    "version: $KAFKA_VERSION" 1 "lite Kafka version" || _sb_rc=1
  pltf_sbom_expect deploy/k3d-base/kube-public/podinfo.yaml \
    "image: $PODINFO_IMAGE" 1 "podinfo image" || _sb_rc=1
  pltf_sbom_expect deploy/k3d-base/default/verify-http.yaml \
    "image: $PODINFO_IMAGE" 1 "verify-http Job image" || _sb_rc=1
  pltf_sbom_expect deploy/k3d-base/default/verify-tcp.yaml \
    "image: $PODINFO_IMAGE" 1 "verify-tcp Job image" || _sb_rc=1
  pltf_sbom_expect deploy/k3d-base/default/verify-tls.yaml \
    "image: $PODINFO_IMAGE" 1 "verify-tls Job image" || _sb_rc=1
  pltf_sbom_expect deploy/k3d-base/default/verify-grpc.yaml \
    "image: $PODINFO_IMAGE" 1 "verify-grpc Job image" || _sb_rc=1
  [ "$_sb_rc" -eq 0 ] && pltf_ok "SBOM: deploy/ manifests match .env.sbom."
  return "$_sb_rc"
}
