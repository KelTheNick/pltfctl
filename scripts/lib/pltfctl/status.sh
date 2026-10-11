#!/usr/bin/env sh
# pltfctl status: health plus CPU, memory and disk per platform component.
# Sourced by scripts/pltfctl. Function-only.
#
#   pltfctl status               every component's health, then one total of
#                                their usage (no per-pod or per-component rows)
#   pltfctl <component> status   one component (nodes, gateway, event-bus, ...),
#                                the same shape as `pltfctl event-bus status`
#
# One snapshot per cluster feeds every component's table: pod specs
# (requests, limits, claims), the kubelet summary API per node (CPU, working
# set memory, ephemeral storage), and `du` over local-path's directories
# inside each node container (PVC bytes actually used; the summary API does
# not measure hostPath-backed volumes). See scripts/README.md#status-numbers

[ -n "${PLTFCTL_HOME:-}" ] && [ -d "$PLTFCTL_HOME/scripts/lib" ] || {
  printf '[err ] PLTFCTL_HOME unset or not a pltfctl checkout (got: %s)\n' \
    "${PLTFCTL_HOME:-<unset>}" >&2
  exit 1
}

PLTF_COMPONENTS='nodes cni mesh core flux gateway dashboard samples event-bus'

# k3s's local-path provisioner keeps each PVC in <dir>/pvc-<uid>_<ns>_<claim>.
PLTF_LOCAL_PATH_DIR=/var/lib/rancher/k3s/storage

pltf_component_names() { printf '%s' "$PLTF_COMPONENTS" | tr ' ' '|'; }

pltf_component_known() { # component
  case " $PLTF_COMPONENTS " in *" $1 "*) return 0 ;; esac
  return 1
}

# Where a component's pods live: "<namespace> <pod-name ERE>". `nodes` has
# none: it is measured from the node containers themselves.
pltf_component_pods() { # component
  case "$1" in
    cni)       printf 'kube-system ^(cilium|hubble)-\n' ;;
    mesh)      printf 'kube-system ^clustermesh-apiserver-\n' ;;
    core)      printf 'kube-system ^(coredns|local-path-provisioner|metrics-server)-\n' ;;
    flux)      printf 'flux-system .\n' ;;
    gateway)   printf 'kube-system ^(kgateway|gw-api-kgateway|svclb-gw-api-kgateway)-\n' ;;
    dashboard) printf 'kube-system ^kube-argus-\n' ;;
    samples)   printf 'kube-public ^podinfo-\n' ;;
    event-bus) printf '%s .\n' "$PLTF_EVENT_BUS_NS" ;;
    *)         return 1 ;;
  esac
}

# Whether a component belongs on a cluster at all. Absent ones are skipped
# rather than reported as failures.
pltf_component_on() { # name component
  case "$2" in
    mesh)
      [ "$(pltf_distro_clusters "$(pltf_cluster_distro "$1")" | wc -l)" -gt 1 ] ;;
    event-bus) [ -d "$PLTF_DEPLOY_DIR/k3d-$1/$PLTF_EVENT_BUS_NS" ] ;;
    *)         return 0 ;;
  esac
}

# ----- Snapshot --------------------------------------------------------------

# Kubernetes quantity -> number (cores for CPU, bytes for memory/storage).
# shellcheck disable=SC2016 # jq program, not shell
PLTF_JQ_Q='def q: if . == null then 0 else (tostring | capture("^(?<n>[0-9.]+)(?<u>[A-Za-z]*)$")) as $m
  | ($m.n | tonumber) * ({"": 1, "m": 0.001, "k": 1e3, "M": 1e6, "G": 1e9, "T": 1e12,
      "Ki": 1024, "Mi": 1048576, "Gi": 1073741824, "Ti": 1099511627776}[$m.u] // 1) end;'

# Writes pods.tsv, usage.tsv and pvc.tsv into dir. Each source is
# best-effort: a node whose summary call fails just shows "-" for usage.
pltf_status_snapshot() { # name dir
  _sn_ctx="k3d-$1"
  # ns pod node phase ready total restarts waiting req_cpu_m req_mem lim_mem claims
  kubectl --context "$_sn_ctx" get pods -A -o json 2>/dev/null | jq -r "$PLTF_JQ_Q"'
    .items[] | select(.status.phase != "Succeeded") |
    [ .metadata.namespace, .metadata.name, (.spec.nodeName // "-"), .status.phase,
      ([.status.containerStatuses[]? | select(.ready)] | length),
      (.spec.containers | length),
      ([.status.containerStatuses[]?.restartCount] | add // 0),
      (([.status.containerStatuses[]?.state.waiting.reason // empty] | first) // "-"),
      ([.spec.containers[].resources.requests.cpu | q] | add * 1000 | floor),
      ([.spec.containers[].resources.requests.memory | q] | add | floor),
      (if all(.spec.containers[]; .resources.limits.memory != null)
       then ([.spec.containers[].resources.limits.memory | q] | add | floor) else -1 end),
      ([.spec.volumes[]?.persistentVolumeClaim.claimName // empty]
       | if length == 0 then "-" else join(",") end)
    ] | @tsv' >"$2/pods.tsv" || : >"$2/pods.tsv"

  # ns pod cpu_m mem_bytes ephemeral_bytes
  : >"$2/usage.tsv"
  for _sn_node in $(kubectl --context "$_sn_ctx" get nodes -o name 2>/dev/null); do
    kubectl --context "$_sn_ctx" get --raw "/api/v1/nodes/${_sn_node#node/}/proxy/stats/summary" 2>/dev/null |
      jq -r '.pods[]? | [ .podRef.namespace, .podRef.name,
        ((.cpu.usageNanoCores // 0) / 1e6 | floor),
        (.memory.workingSetBytes // 0), (."ephemeral-storage".usedBytes // 0) ] | @tsv' \
      >>"$2/usage.tsv" 2>/dev/null || :
  done

  # ns claim size_bytes used_bytes(-1 = not measured)
  for _sn_c in $(pltf_node_containers "$1"); do
    docker exec "$_sn_c" sh -c "du -sk $PLTF_LOCAL_PATH_DIR/pvc-* 2>/dev/null" 2>/dev/null || :
  done >"$2/du.txt"
  kubectl --context "$_sn_ctx" get pvc -A -o json 2>/dev/null | jq -r "$PLTF_JQ_Q"'
    .items[] | [ .metadata.namespace, .metadata.name,
      ((.status.capacity.storage // .spec.resources.requests.storage) | q | floor) ] | @tsv' |
    awk -F'\t' 'FILENAME == ARGV[1] {
        n = split($0, p, "/"); split(p[n], f, "_")   # pvc-<uid>_<ns>_<claim>
        used[f[2] "/" f[3]] = $1 * 1024; next
      }
      { k = $1 "/" $2; printf "%s\t%s\t%s\t%s\n", $1, $2, $3, (k in used ? used[k] : -1) }' \
      "$2/du.txt" - >"$2/pvc.tsv" || : >"$2/pvc.tsv"
}

# The k3d node containers of a cluster (servers and agents, not the LB).
pltf_node_containers() { # name
  docker ps --format '{{.Names}}' 2>/dev/null | grep -E "^k3d-$1-(server|agent)-[0-9]+\$" || :
}

# ----- Tables ----------------------------------------------------------------

# One row per pod of a component, then a total. Exits non-zero when the
# component has no pods or any pod is not Ready, so callers can flag it.
pltf_component_table() { # name dir component
  _ct_sel=$(pltf_component_pods "$3")
  awk -F'\t' -v ns="${_ct_sel%% *}" -v re="${_ct_sel#* }" -v node_prefix="k3d-$1-" \
    -v comp="$3" -v totals="$2/totals.tsv" '
    function mib(b) {
      if (b < 0) return "-"
      if (b >= 1073741824) return sprintf("%.1fGi", b / 1073741824)
      return sprintf("%dMi", b / 1048576 + 0.5)
    }
    function row(pod, node, state, rst, cpu, mem, disk, pvc) {
      printf "       %-44s %-10s %-16s %3s  %-12s %-21s %-7s %s\n", pod, node, state, rst, cpu, mem, disk, pvc
    }
    FILENAME == ARGV[1] { k = $1 "/" $2; ucpu[k] = $3; umem[k] = $4; ueph[k] = $5; seen[k] = 1; next }
    FILENAME == ARGV[2] { psize[$1 "/" $2] = $3; pused[$1 "/" $2] = $4; next }
    $1 == ns && $2 ~ re {
      k = $1 "/" $2; n++
      if ($5 == $6)          state = "live"
      else if ($8 != "-")    state = $8
      else if ($4 == "Running") state = "starting"
      else                   state = $4
      if (state != "live") bad++
      node = $3; sub("^" node_prefix, "", node)
      ps = 0; pu = 0; known = 0; pvc = "-"
      if ($12 != "-") {
        m = split($12, cl, ",")
        for (i = 1; i <= m; i++) {
          c = $1 "/" cl[i]; ps += psize[c]
          if (c in pused && pused[c] >= 0) { pu += pused[c]; known++ }
        }
        pvc = (known ? mib(pu) : "-") "/" mib(ps); tps += ps; tpu += pu
      }
      if (k in seen) {
        cpu = ucpu[k] "m/" $9 "m"; mem = mib(umem[k]) "/" mib($10) "/" mib($11); disk = mib(ueph[k])
        tc += ucpu[k]; tm += umem[k]; te += ueph[k]
      } else { cpu = "-/" $9 "m"; mem = "-/" mib($10) "/" mib($11); disk = "-" }
      trc += $9; trm += $10
      if (n == 1) row("POD", "NODE", "STATE", "RST", "CPU use/req", "MEM use/req/limit", "DISK", "PVC use/size")
      row($2, node, state, $7, cpu, mem, disk, pvc)
    }
    END {
      # comp pods cpu_use cpu_req mem_use mem_req disk pvc_use pvc_size
      printf "%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", comp, n, tc, trc, tm, trm, te, tpu, tps >>totals
      if (n == 0) { print "       (no pods)"; exit 1 }
      row(sprintf("total (%d pods)", n), "", "", "", (tc + 0) "m/" (trc + 0) "m", mib(tm) "/" mib(trm), mib(te),
        tps > 0 ? mib(tpu) "/" mib(tps) : "-")
      exit (bad > 0)
    }' "$2/usage.tsv" "$2/pvc.tsv" "$2/pods.tsv"
}

# The node containers as Docker sees them: what the VM actually pays,
# k3s itself (apiserver, kubelet, containerd, flannel on lite) included.
pltf_nodes_table() { # name [dir]
  _nt_names=$(pltf_node_containers "$1")
  # The registry is shared by the distro; count it once, on its head cluster.
  if [ "$(pltf_distro "$(pltf_cluster_distro "$1")" REGISTRY)" = true ] &&
    [ "$(pltf_distro_head "$1")" = "$1" ]; then
    _nt_names="$_nt_names $(docker ps --format '{{.Names}}' 2>/dev/null |
      grep -E "^(k3d-)?$PLTF_REGISTRY_NAME\$" || :)"
  fi
  [ -n "$(printf '%s' "$_nt_names" | tr -d ' ')" ] || { printf '       (no node containers)\n'; return 1; }
  # shellcheck disable=SC2086 # one container name per word
  docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' $_nt_names 2>/dev/null |
    while IFS="$(printf '\t')" read -r _nt_c _nt_cpu _nt_mem; do
      _nt_disk=$(docker exec "$_nt_c" du -sxk /var/lib/rancher/k3s 2>/dev/null | cut -f1) || _nt_disk=''
      printf '%s\t%s\t%s\t%s\n' "$_nt_c" "$_nt_cpu" "${_nt_mem%% / *}" "${_nt_disk:--}"
    done |
    awk -F'\t' -v vm="$(docker info --format '{{.MemTotal}}' 2>/dev/null)" -v out="${2:-/dev/null}" '
      function bytes(s,  n, u) {
        n = s + 0; u = s; sub(/^[0-9.]+/, "", u)
        return n * (u == "GiB" ? 1073741824 : u == "MiB" ? 1048576 : u == "KiB" ? 1024 : u == "GB" ? 1e9 : u == "MB" ? 1e6 : u == "kB" ? 1e3 : 1)
      }
      function mib(b) { return b >= 1073741824 ? sprintf("%.1fGi", b / 1073741824) : sprintf("%dMi", b / 1048576 + 0.5) }
      BEGIN { printf "       %-30s %8s  %-9s %s\n", "CONTAINER", "CPU", "MEM", "DISK (k3s data, images included)" }
      {
        m = bytes($3); tm += m; c = $2; sub(/%/, "", c); tc += c
        printf "       %-30s %8s  %-9s %s\n", $1, $2, mib(m), ($4 == "-" ? "-" : mib($4 * 1024))
        if ($4 != "-") td += $4 * 1024
      }
      END {
        printf "       %-30s %7.1f%%  %-9s %s\n", "total", tc, mib(tm), mib(td)
        printf "%.1f\t%d\t%d\t%d\n", tc, tm, td, vm >out
        if (vm > 0) printf "       of the Docker VM: %s memory (%.0f%% used by this cluster)\n", mib(vm), 100 * tm / vm
      }'
}

# ----- Health ----------------------------------------------------------------

pltf_hr_ready() { # ctx ns release
  _hr=$(kubectl --context "$1" -n "$2" get helmrelease "$3" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) || _hr=''
  if [ "$_hr" = True ]; then pltf_ok "HelmRelease $3 Ready"; return 0; fi
  pltf_info "[fail] HelmRelease $3 not Ready (${_hr:-missing})"
  return 1
}

pltf_url_ok() { # what url
  command -v curl >/dev/null 2>&1 || { pltf_info "[skip] curl not on PATH; $1 not probed"; return 0; }
  if curl -fsS -m 5 "$2" >/dev/null 2>&1; then pltf_ok "$1 responding: $2"; return 0; fi
  pltf_info "[fail] $1 not responding: $2"
  return 1
}

# Component health lines. 0 = healthy, 1 = a check failed, 2 = the
# component is off or has no pods by design, so no table follows.
pltf_component_health() { # name component
  _ch_ctx="k3d-$1"
  _ch_port=$(pltf_lb_http_port "$1")
  _ch_rc=0
  case "$2" in
    nodes)
      _ch_nr=$(kubectl --context "$_ch_ctx" get nodes -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null) || _ch_nr=''
      _ch_all=$(printf '%s\n' "$_ch_nr" | grep -c . || :)
      _ch_ok=$(printf '%s\n' "$_ch_nr" | grep -c '^True$' || :)
      if [ "$_ch_all" -gt 0 ] && [ "$_ch_ok" -eq "$_ch_all" ]; then
        pltf_ok "$_ch_ok/$_ch_all Kubernetes nodes Ready"
      else
        pltf_info "[fail] $_ch_ok/$_ch_all Kubernetes nodes Ready"; _ch_rc=1
      fi
      ;;
    cni)
      # cilium-cli is required by `up` but not pltf_require_cmd'd here, so a
      # missing binary must not fall through to `cilium status` below and get
      # misreported as "[fail] cilium not healthy" — indistinguishable from an
      # actually unhealthy cluster. `cilium status` below deliberately keeps its
      # stderr so a real cilium-cli failure — changed flag, unreachable context —
      # prints its own reason instead of collapsing into that same generic
      # message. Do not add 2>/dev/null.
      if ! pltf_cluster_is "$1" CNI cilium; then
        pltf_info "flannel + kube-proxy run inside k3s; their usage is in 'nodes'"
        return 2
      fi
      if command -v cilium >/dev/null 2>&1; then
        cilium status --context "$_ch_ctx" || { pltf_info "[fail] cilium not healthy on $_ch_ctx"; _ch_rc=1; }
      else
        pltf_info "[skip] cilium-cli not found on PATH; skipping cilium health checks"
      fi
      # clusterset.local is MCS-API, which only the cilium distros install.
      if kubectl --context "$_ch_ctx" -n kube-system get configmap coredns \
        -o jsonpath='{.data.Corefile}' 2>/dev/null | grep -q clusterset.local; then
        pltf_ok "CoreDNS serves the clusterset.local zone"
      else
        pltf_info "[fail] CoreDNS is missing the clusterset.local zone"; _ch_rc=1
      fi
      ;;
    mesh)
      if command -v cilium >/dev/null 2>&1; then
        cilium clustermesh status --context "$_ch_ctx" ||
          { pltf_info "[fail] clustermesh status unavailable on $_ch_ctx"; _ch_rc=1; }
      else
        pltf_info "[skip] cilium-cli not found on PATH; skipping clustermesh status"
      fi
      ;;
    core) ;;
    flux)
      if kubectl --context "$_ch_ctx" -n flux-system get deploy helm-controller >/dev/null 2>&1; then
        pltf_ok "Flux control plane installed"
      else
        pltf_info "[fail] Flux not installed; run 'pltfctl up'"; return 1
      fi
      kubectl --context "$_ch_ctx" get helmrelease -A 2>/dev/null || :
      ;;
    gateway)
      pltf_hr_ready "$_ch_ctx" kube-system kgateway || _ch_rc=1
      kubectl --context "$_ch_ctx" -n kube-system get gateway 2>/dev/null || :
      pltf_url_ok gateway "http://$(pltf_ui_host "$1" gateway):$_ch_port/readyz" || _ch_rc=1
      ;;
    dashboard)
      pltf_hr_ready "$_ch_ctx" kube-system kube-argus || _ch_rc=1
      pltf_url_ok kube-argus "http://$(pltf_ui_host "$1" argus):$_ch_port/" || _ch_rc=1
      ;;
    samples)
      pltf_url_ok podinfo "http://$(pltf_ui_host "$1" podinfo):$_ch_port/" || _ch_rc=1
      ;;
    event-bus)
      if ! kubectl --context "$_ch_ctx" get ns "$PLTF_EVENT_BUS_NS" >/dev/null 2>&1; then
        pltf_info "off (start it with: pltfctl event-bus up)"
        return 2
      fi
      pltf_event_bus_health "$_ch_ctx" || _ch_rc=1
      ;;
  esac
  return "$_ch_rc"
}

# Run a command, discarding its stdout when brief is non-empty.
pltf_status_quiet() { # brief cmd [args...]
  if [ -n "$1" ]; then shift; "$@" >/dev/null; else shift; "$@"; fi
}

# One component on one cluster: health, then the resource table. With
# brief, the table is only tallied into the total, not printed; the
# breakdown is what `pltfctl <component> status` is for.
pltf_status_component() { # name dir component [brief]
  printf '\n-- %s --\n' "$3"
  if pltf_component_health "$1" "$3"; then _sc=0; else _sc=$?; fi
  [ "$_sc" -eq 2 ] && return 0
  if [ "$3" = nodes ]; then
    pltf_status_quiet "${4:-}" pltf_nodes_table "$1" "$2/nodes.tsv" || _sc=1
  else
    pltf_status_quiet "${4:-}" pltf_component_table "$1" "$2" "$3" || {
      pltf_info "[fail] $3: a pod is missing or not Ready"; _sc=1
    }
  fi
  return "$_sc"
}

# ----- Summary ---------------------------------------------------------------

# The total across every component's pods, then what the node containers
# cost the Docker VM (k3s and images included).
pltf_status_summary() { # dir
  [ -s "$1/totals.tsv" ] || return 0
  printf '\n-- total --\n'
  awk -F'\t' -v nodes="$1/nodes.tsv" '
    function mib(b) { return b >= 1073741824 ? sprintf("%.1fGi", b / 1073741824) : sprintf("%dMi", b / 1048576 + 0.5) }
    { for (i = 2; i <= 9; i++) t[i] += $i }
    END {
      printf "       components  %d pods, CPU %dm used / %dm requested, MEM %s used / %s requested\n", t[2], t[3], t[4], mib(t[5]), mib(t[6])
      printf "                   DISK %s, PVC %s\n", mib(t[7]), (t[9] > 0 ? mib(t[8]) " used / " mib(t[9]) : "none")
      if ((getline l < nodes) > 0) {
        split(l, v, "\t")
        printf "       nodes       CPU %s%%, MEM %s", v[1], mib(v[2])
        if (v[4] > 0) printf " (%.0f%% of the Docker VM'"'"'s %s)", 100 * v[2] / v[4], mib(v[4])
        printf ", k3s data %s\n", mib(v[3])
      }
      print "       per component: pltfctl <component> status"
    }' "$1/totals.tsv"
}

# ----- Command ---------------------------------------------------------------

# Prints; always exits 0 for the full report (gate on `verify`). One
# component (`pltfctl <component> status`) exits 1 when it is unhealthy.
cmd_status() { # [component]
  if _st_d=$(pltf_running_distro) && [ "$(pltf_distro_kind "$_st_d")" = compose ]; then
    pltf_info "status is not available in dev mode: it reports on k3d distros only, and '$_st_d' is a Compose stack."
    return 0
  fi
  pltf_require_cmd k3d
  pltf_require_cmd kubectl
  pltf_require_cmd docker
  pltf_require_cmd jq
  _st_one=${1:-}
  _st_brief=brief
  [ -z "$_st_one" ] || _st_brief=''
  if [ -z "$_st_one" ]; then
    k3d cluster list
    k3d registry list 2>/dev/null || :
  fi
  _st_rc=0
  _st_found=0
  for _st_name in $(pltf_existing_clusters); do
    _st_found=1
    _st_ctx="k3d-$_st_name"
    printf '\n== %s (distro %s, LB HTTP :%s) ==\n' "$_st_ctx" \
      "$(pltf_cluster_distro "$_st_name")" "$(pltf_lb_http_port "$_st_name")"
    if ! kubectl --context "$_st_ctx" version >/dev/null 2>&1; then
      pltf_info "[fail] kube context $_st_ctx unreachable"; _st_rc=1
      continue
    fi
    _st_dir=$(mktemp -d)
    [ "$_st_one" = nodes ] || pltf_status_snapshot "$_st_name" "$_st_dir"
    for _st_c in ${_st_one:-$PLTF_COMPONENTS}; do
      if ! pltf_component_on "$_st_name" "$_st_c"; then
        [ -n "$_st_one" ] && pltf_info "[skip] $_st_c is not part of the $(pltf_cluster_distro "$_st_name") distro"
        continue
      fi
      pltf_status_component "$_st_name" "$_st_dir" "$_st_c" "$_st_brief" || _st_rc=1
    done
    [ -n "$_st_one" ] || pltf_status_summary "$_st_dir"
    rm -rf "$_st_dir"
  done
  [ "$_st_found" -eq 1 ] || {
    pltf_info "No pltfctl clusters present; run 'pltfctl up'"
    [ -z "$_st_one" ]; return
  }
  [ -n "$_st_one" ] || return 0
  return "$_st_rc"
}
