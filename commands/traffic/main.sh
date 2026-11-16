#!/usr/bin/env bash
# traffic — transfer, access logi, skoki. Strumieniowo, bez wczytywania całego logu do tablicy basha.

_hm_cmd_help traffic <<'EOF'
Użycie:
  traffic [day|month]
  traffic sites [--since 24h]
  traffic now
  traffic spikes

Źródła (gdy brak HM_TRAFFIC_*): vnstat lub /proc/net/dev, logi /home/*/logs i OLS,
połączenia z `ss`. Format: „IP domena bajty [cf=…]” albo combined (CLF/OLS).
Adres cf= / CF-Connecting-IP wygrywa z brzegowym.
EOF

hm_traffic_tmp() {
  if declare -F hm_mktemp >/dev/null 2>&1; then
    hm_mktemp .traffic
  else
    mktemp "${TMP_DIR:-${TMPDIR:-/tmp}}/hm-traffic.XXXXXX"
  fi
}

hm_traffic_state_dir() {
  printf '%s\n' "${HM_TRAFFIC_DIR:-/var/lib/hmtools/traffic}"
}

# vnstat --json → rx/tx dla dnia lub miesiąca (pierwszy interfejs, najnowszy wpis).
hm_traffic_vnstat() {
  local which="$1" json
  command -v vnstat >/dev/null 2>&1 || return 1
  json="$(vnstat --json 2>/dev/null)" || return 1
  [[ -n "${json}" ]] || return 1
  printf '%s\n' "${json}" | awk -v which="${which}" '
    function dig(n,   t) { t=n; gsub(/[^0-9]/, "", t); return t+0 }
    BEGIN { mode=""; depth=0; rx=-1; tx=-1 }
    {
      if (which == "day" && $0 ~ /"days"/) { mode="want"; next }
      if (which == "month" && $0 ~ /"months"/) { mode="want"; next }
      if (mode == "" ) next
      if ($0 ~ /\[/) depth++
      if (mode == "want" && $0 ~ /\{/) { mode="in"; rx=-1; tx=-1 }
      if (mode == "in" && $0 ~ /"rx"/) rx = dig($0)
      if (mode == "in" && $0 ~ /"tx"/) tx = dig($0)
      if (mode == "in" && $0 ~ /\}/) {
        if (rx >= 0 && tx >= 0) { printf "rx: %s\ntx: %s\n", rx, tx; found=1; exit }
        mode="want"
      }
    }
    END { exit found ? 0 : 1 }
  '
}

hm_traffic_proc_delta() {
  local which="$1" iface snap dir now rx tx
  local day_key="" day_rx0=0 day_tx0=0 month_key="" month_rx0=0 month_tx0=0 last_rx=0 last_tx=0
  local dkey mkey
  iface="${HM_TRAFFIC_NET_FILE:-/proc/net/dev}"
  [[ -f "${iface}" ]] || return 1
  now="$(awk '
    NR > 2 && $1 !~ /^lo:/ {
      gsub(/:/, "", $1)
      rx += $2; tx += $10
    }
    END { printf "%s %s\n", rx+0, tx+0 }
  ' "${iface}")"
  rx="${now%% *}"
  tx="${now##* }"
  dir="$(hm_traffic_state_dir)"
  mkdir -p "${dir}" 2>/dev/null || true
  snap="${dir}/net.state"
  dkey="$(date +%Y-%m-%d 2>/dev/null || echo unknown)"
  mkey="$(date +%Y-%m 2>/dev/null || echo unknown)"
  if [[ -f "${snap}" ]]; then
    read -r day_key day_rx0 day_tx0 month_key month_rx0 month_tx0 last_rx last_tx < "${snap}" || true
  fi
  if [[ "${day_key}" != "${dkey}" ]]; then
    day_key="${dkey}"; day_rx0="${rx}"; day_tx0="${tx}"
  fi
  if [[ "${month_key}" != "${mkey}" ]]; then
    month_key="${mkey}"; month_rx0="${rx}"; month_tx0="${tx}"
  fi
  printf '%s %s %s %s %s %s %s %s\n' \
    "${day_key}" "${day_rx0}" "${day_tx0}" \
    "${month_key}" "${month_rx0}" "${month_tx0}" \
    "${rx}" "${tx}" > "${snap}" 2>/dev/null || true
  if [[ "${which}" == "month" ]]; then
    printf 'rx: %s\ntx: %s\n' "$((rx - month_rx0))" "$((tx - month_tx0))"
  else
    printf 'rx: %s\ntx: %s\n' "$((rx - day_rx0))" "$((tx - day_tx0))"
  fi
}

hm_traffic_day() {
  local which="${1:-day}"
  if [[ -n "${HM_TRAFFIC_COUNTERS:-}" && -f "${HM_TRAFFIC_COUNTERS}" ]]; then
    awk -F= -v which="${which}" '
      $1 == "rx_" which { rx=$2 }
      $1 == "tx_" which { tx=$2 }
      END { printf "rx: %s\ntx: %s\n", rx+0, tx+0 }
    ' "${HM_TRAFFIC_COUNTERS}"
    return 0
  fi
  if hm_traffic_vnstat "${which}"; then
    return 0
  fi
  if hm_traffic_proc_delta "${which}"; then
    return 0
  fi
  hm_err "Brak liczników transferu."
  return 1
}

# Katalogi logów: HM_TRAFFIC_LOGS albo /home/*/logs + OLS.
hm_traffic_iter_logs() {
  local dir f ols
  if [[ -n "${HM_TRAFFIC_LOGS:-}" ]]; then
    dir="${HM_TRAFFIC_LOGS}"
    [[ -d "${dir}" ]] || return 1
    shopt -s nullglob
    for f in "${dir}"/*.log "${dir}"/*.log.gz "${dir}"/*.access_log "${dir}"/*.access_log.gz; do
      [[ -f "${f}" ]] || continue
      printf '%s\n' "${f}"
    done
    shopt -u nullglob
    return 0
  fi
  shopt -s nullglob
  for dir in /home/*/logs; do
    [[ -d "${dir}" ]] || continue
    for f in "${dir}"/access.log "${dir}"/access.log.[0-9]* "${dir}"/access.log.gz \
             "${dir}"/*.access.log "${dir}"/*.access.log.gz; do
      [[ -f "${f}" ]] || continue
      printf '%s\n' "${f}"
    done
  done
  ols="${OLS_ROOT:-/usr/local/lsws}"
  if [[ -d "${ols}/logs" ]]; then
    for f in "${ols}/logs"/*.access_log "${ols}/logs"/*.access_log.gz \
             "${ols}/logs/access.log" "${ols}/logs/access.log.gz"; do
      [[ -f "${f}" ]] || continue
      printf '%s\n' "${f}"
    done
  fi
  shopt -u nullglob
}

hm_traffic_domain_from_path() {
  local file="$1" base dir parent
  base="$(basename "${file}")"
  base="${base%.gz}"
  case "${base}" in
    *.access_log) printf '%s\n' "${base%.access_log}"; return 0 ;;
    *.access.log) printf '%s\n' "${base%.access.log}"; return 0 ;;
  esac
  dir="$(dirname "${file}")"
  parent="$(basename "$(dirname "${dir}")")"
  if [[ "$(basename "${dir}")" == "logs" && "${parent}" != "/" && "${parent}" != "home" ]]; then
    printf '%s\n' "${parent}"
    return 0
  fi
  printf '\n'
}

# Prosty „IP domena bajty [cf=]” oraz combined/CLF OLS.
# ENV: HM_TRAFFIC_DOM — fallback domeny z ścieżki pliku.
hm_traffic_awk='
  function real_ip(line,   m) {
    if (match(line, /cf=[0-9A-Fa-f:.]+/)) return substr(line, RSTART+3, RLENGTH-3)
    if (match(line, /CF-Connecting-IP[:[:space:]"]*[0-9A-Fa-f:.]+/)) {
      m = substr(line, RSTART, RLENGTH)
      sub(/.*[^0-9A-Fa-f:.]/, "", m)
      return m
    }
    return ""
  }
  function is_host(s) {
    return (s ~ /^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$/ && s ~ /[.]/)
  }
  {
    line = $0
    rip = real_ip(line)
    if (line ~ /\[[0-9]{2}\/[A-Za-z]{3}\/[0-9]{4}:/ || (NF >= 7 && $2 == "-" && $3 == "-")) {
      ip = $1
      if (rip != "") ip = rip
      bytes = 0
      # "METHOD …" STATUS BYTES — cudzysłów jako \042
      if (match(line, /\042[A-Z]+[^\042]*\042[[:space:]]+[0-9]+[[:space:]]+([0-9]+|-)/)) {
        rest = substr(line, RSTART, RLENGTH)
        n = split(rest, a, /[[:space:]]+/)
        if (a[n] == "-") bytes = 0
        else bytes = a[n] + 0
      }
      dom = ENVIRON["HM_TRAFFIC_DOM"]
      s = line
      while (match(s, /\042[^\042]+\042/)) {
        q = substr(s, RSTART+1, RLENGTH-2)
        s = substr(s, RSTART+RLENGTH)
        if (is_host(q)) dom = q
      }
      if (dom == "" || ip == "") next
      req[dom]++; sum[dom]+=bytes
      ipn[ip]++
      next
    }
    ip = $1; dom = $2; bytes = $3 + 0
    if (rip != "") ip = rip
    if (dom == "" || ip == "") next
    if (dom ~ /^[0-9]+$/ ) next
    req[dom]++; sum[dom]+=bytes
    ipn[ip]++
  }
'

hm_traffic_sites() {
  local since="" file tmp list=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --since) since="${2:-}"; shift 2 || true ;;
      *) shift ;;
    esac
  done
  tmp="$(hm_traffic_tmp)" || { hm_err "Brak katalogu logów."; return 1; }
  : > "${tmp}"
  while IFS= read -r file; do
    [[ -n "${file}" && -f "${file}" ]] || continue
    list=1
    export HM_TRAFFIC_DOM
    HM_TRAFFIC_DOM="$(hm_traffic_domain_from_path "${file}")"
    if [[ "${file}" == *.gz ]]; then
      gzip -dc -- "${file}" | awk "${hm_traffic_awk}"' END { for (d in req) printf "%s\t%s\t%s\n", d, req[d], sum[d] }'
    else
      awk "${hm_traffic_awk}"' END { for (d in req) printf "%s\t%s\t%s\n", d, req[d], sum[d] }' "${file}"
    fi
  done < <(hm_traffic_iter_logs) >> "${tmp}"
  if [[ "${list}" -eq 0 ]]; then
    rm -f "${tmp}"
    hm_err "Brak katalogu logów."
    return 1
  fi
  awk -F '\t' '{ r[$1]+=$2; b[$1]+=$3 } END { for (d in r) printf "%s\t%s\t%s\n", d, r[d], b[d] }' "${tmp}"
  rm -f "${tmp}"
  if [[ -n "${since}" ]]; then
    hm_info "Okno: ${since} (logi bez odcinania dat)."
  fi
}

hm_traffic_now() {
  local file="${HM_TRAFFIC_NOW:-}" dump
  if [[ -n "${file}" && -f "${file}" ]]; then
    awk '
      NF {
        n++
        ip[$1]++
      }
      END {
        printf "polaczenia: %d\n", n+0
        top=""; best=0
        for (i in ip) if (ip[i] > best) { best=ip[i]; top=i }
        if (top != "") printf "top: %s\t%d\n", top, best
      }
    ' "${file}"
    return 0
  fi
  if ! command -v ss >/dev/null 2>&1; then
    hm_err "Brak zrzutu połączeń."
    return 1
  fi
  dump="$(ss -tnH state established 2>/dev/null || ss -tn state established 2>/dev/null || true)"
  [[ -n "${dump}" ]] || { hm_err "Brak zrzutu połączeń."; return 1; }
  printf '%s\n' "${dump}" | awk '
    {
      peer = $NF
      gsub(/^\[/, "", peer)
      sub(/\]:[0-9]+$/, "", peer)
      sub(/:[0-9]+$/, "", peer)
      if (peer == "" || peer == "*") next
      n++
      ip[peer]++
    }
    END {
      printf "polaczenia: %d\n", n+0
      top=""; best=0
      for (i in ip) if (ip[i] > best) { best=ip[i]; top=i }
      if (top != "") printf "top: %s\t%d\n", top, best
    }
  '
}

hm_traffic_spikes() {
  local file tmp list=0
  tmp="$(hm_traffic_tmp)" || { hm_err "Brak katalogu logów."; return 1; }
  : > "${tmp}"
  while IFS= read -r file; do
    [[ -n "${file}" && -f "${file}" ]] || continue
    list=1
    export HM_TRAFFIC_DOM
    HM_TRAFFIC_DOM="$(hm_traffic_domain_from_path "${file}")"
    if [[ "${file}" == *.gz ]]; then
      gzip -dc -- "${file}" | awk "${hm_traffic_awk}"' END { for (i in ipn) printf "%s\t%s\n", i, ipn[i] }'
    else
      awk "${hm_traffic_awk}"' END { for (i in ipn) printf "%s\t%s\n", i, ipn[i] }' "${file}"
    fi
  done < <(hm_traffic_iter_logs) >> "${tmp}"
  if [[ "${list}" -eq 0 ]]; then
    rm -f "${tmp}"
    hm_err "Brak katalogu logów."
    return 1
  fi
  awk -F '\t' '
    { n[$1]+=$2; total+=$2; u[$1]=1 }
    END {
      c=0; for (i in u) c++
      if (c == 0) exit
      avg=total/c
      for (i in n) if (n[i] >= 4 && n[i] > avg * 3) {
        printf "spike\t%s\t%d\n", i, n[i]
        printf "hint\tsecurity ban %s\n", i
      }
    }
  ' "${tmp}"
  rm -f "${tmp}"
}

hm_traffic_summary() {
  hm_traffic_day month 2>/dev/null || true
}

cmd_traffic() {
  local sub="${1:-day}"
  shift || true
  case "${sub}" in
    day|month) hm_traffic_day "${sub}" ;;
    sites) hm_traffic_sites "$@" ;;
    now) hm_traffic_now "$@" ;;
    spikes) hm_traffic_spikes "$@" ;;
    help|-h|--help) hm_help_topic traffic ;;
    *) hm_err "Nieznane: traffic ${sub}"; return 1 ;;
  esac
}

_hm_cmd_register traffic cmd_traffic 0
