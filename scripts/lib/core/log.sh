#!/usr/bin/env sh
# Shared logging for every script under scripts/. Function-only.
#
# Plain, prefix-tagged lines. ANSI colour suppressed when stdout is not a
# TTY (CI, pipes, redirected output) so log files stay clean.

if [ -t 1 ]; then
  PLTF_C_OK=$(printf '\033[32m')   # green
  PLTF_C_INF=$(printf '\033[36m')  # cyan
  PLTF_C_STP=$(printf '\033[33m')  # yellow
  PLTF_C_ERR=$(printf '\033[31m')  # red
  PLTF_C_RST=$(printf '\033[0m')
else
  PLTF_C_OK=''; PLTF_C_INF=''; PLTF_C_STP=''; PLTF_C_ERR=''; PLTF_C_RST=''
fi

pltf_info() { printf '%s[info]%s %s\n' "$PLTF_C_INF" "$PLTF_C_RST" "$*"; }
pltf_step() { printf '%s[step]%s %s\n' "$PLTF_C_STP" "$PLTF_C_RST" "$*"; }
pltf_ok()   { printf '%s[ ok ]%s %s\n' "$PLTF_C_OK"  "$PLTF_C_RST" "$*"; }
pltf_die()  { printf '%s[err ]%s %s\n' "$PLTF_C_ERR" "$PLTF_C_RST" "$*" >&2; exit 1; }

pltf_require_cmd() {
  command -v "$1" >/dev/null 2>&1 || pltf_die "Required command not found on PATH: $1"
}
