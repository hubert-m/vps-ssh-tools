#!/usr/bin/env bash
# traffic — transfer, access logi, skoki. Strumieniowo, bez wczytywania całego logu do tablicy basha.

_hm_cmd_help traffic <<'EOF'
Użycie:
  traffic [day|month]
  traffic sites [--since 24h]
  traffic now
  traffic spikes [--since 24h]

Źródła (gdy brak HM_TRAFFIC_*): vnstat lub /proc/net/dev, logi /home/*/logs i OLS,
połączenia z `ss`. Format: „IP domena bajty [cf=…]” albo combined (CLF/OLS).
Adres cf= / CF-Connecting-IP wygrywa z brzegowym. Domena z nazwy pliku / $host, nie z IP.
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

hm_traffic_since_epoch() {
  local since="${1:-}" now n u sec=0
  now="$(date +%s)"
  [[ -n "${since}" ]] || { printf '%s' 0; return 0; }
  if [[ "${since}" =~ ^([0-9]+)([smhd])$ ]]; then
    n="${BASH_REMATCH[1]}"
    u="${BASH_REMATCH[2]}"
    case "${u}" in
      s) sec="${n}" ;;
      m) sec=$((n * 60)) ;;
      h) sec=$((n * 3600)) ;;
      d) sec=$((n * 86400)) ;;
    esac
    printf '%s' "$((now - sec))"
    return 0
  fi
  if date -d "${since}" +%s >/dev/null 2>&1; then
    date -d "${since}" +%s
    return 0
  fi
  printf '%s' 0
}

hm_traffic_epoch_cmp() {
  local ep="${1:-0}"
  [[ "${ep}" =~ ^[0-9]+$ && "${ep}" -gt 0 ]] || { printf '%s' 0; return 0; }
  if date -d "@${ep}" +%Y%m%d%H%M%S >/dev/null 2>&1; then
    date -d "@${ep}" +%Y%m%d%H%M%S
    return 0
  fi
  if date -r "${ep}" +%Y%m%d%H%M%S >/dev/null 2>&1; then
    date -r "${ep}" +%Y%m%d%H%M%S
    return 0
  fi
  printf '%s' 0
}

hm_traffic_fmt_bytes() {
  local n="${1:-0}"
  [[ "${n}" =~ ^-?[0-9]+$ ]] || n=0
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec --suffix=B "${n}" 2>/dev/null && return 0
  fi
  printf '%sB\n' "${n}"
}

hm_traffic_print_rx_tx() {
  local rx="${1:-0}" tx="${2:-0}"
  printf 'rx: %s\ntx: %s\n' "$(hm_traffic_fmt_bytes "${rx}")" "$(hm_traffic_fmt_bytes "${tx}")"
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
        if (rx >= 0 && tx >= 0) { printf "%s %s\n", rx, tx; found=1; exit }
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
    printf '%s %s\n' "$((rx - month_rx0))" "$((tx - month_tx0))"
  else
    printf '%s %s\n' "$((rx - day_rx0))" "$((tx - day_tx0))"
  fi
}

# Suma body_bytes z access logów w oknie (TX przybliżony; RX=0).
hm_traffic_logs_bytes() {
  local since_cmp="$1" file total=0 list=0 tmp
  tmp="$(hm_traffic_tmp)" || return 1
  : > "${tmp}"
  while IFS= read -r file; do
    [[ -n "${file}" && -f "${file}" ]] || continue
    list=1
    export HM_TRAFFIC_DOM
    HM_TRAFFIC_DOM="$(hm_traffic_domain_from_path "${file}")"
    if [[ "${file}" == *.gz ]]; then
      gzip -dc -- "${file}" | awk -v since_cmp="${since_cmp}" "${hm_traffic_awk}"' END { t=0; for (d in sum) t+=sum[d]; print t+0 }'
    else
      awk -v since_cmp="${since_cmp}" "${hm_traffic_awk}"' END { t=0; for (d in sum) t+=sum[d]; print t+0 }' "${file}"
    fi
  done < <(hm_traffic_iter_logs) >> "${tmp}"
  if [[ "${list}" -eq 0 ]]; then
    rm -f "${tmp}"
    return 1
  fi
  total="$(awk '{ s+=$1 } END { print s+0 }' "${tmp}")"
  rm -f "${tmp}"
  printf '0 %s\n' "${total}"
}

hm_traffic_day() {
  local which="${1:-day}" pair rx tx since_cmp
  if [[ -n "${HM_TRAFFIC_COUNTERS:-}" && -f "${HM_TRAFFIC_COUNTERS}" ]]; then
    pair="$(awk -F= -v which="${which}" '
      $1 == "rx_" which { rx=$2 }
      $1 == "tx_" which { tx=$2 }
      END { printf "%s %s\n", rx+0, tx+0 }
    ' "${HM_TRAFFIC_COUNTERS}")"
    rx="${pair%% *}"
    tx="${pair##* }"
    hm_traffic_print_rx_tx "${rx}" "${tx}"
    return 0
  fi
  if pair="$(hm_traffic_vnstat "${which}")"; then
    rx="${pair%% *}"
    tx="${pair##* }"
    hm_traffic_print_rx_tx "${rx}" "${tx}"
    return 0
  fi
  # Logi: day=24h, month=30d — różne okna (w odróżnieniu od surowego /proc).
  if [[ "${which}" == "month" ]]; then
    since_cmp="$(hm_traffic_epoch_cmp "$(hm_traffic_since_epoch 30d)")"
  else
    since_cmp="$(hm_traffic_epoch_cmp "$(hm_traffic_since_epoch 24h)")"
  fi
  if pair="$(hm_traffic_logs_bytes "${since_cmp}")"; then
    rx="${pair%% *}"
    tx="${pair##* }"
    hm_traffic_print_rx_tx "${rx}" "${tx}"
    return 0
  fi
  if pair="$(hm_traffic_proc_delta "${which}")"; then
    rx="${pair%% *}"
    tx="${pair##* }"
    hm_traffic_print_rx_tx "${rx}" "${tx}"
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
# -v since_cmp=YYYYMMDDHHMMSS|0 — filtr czasu linii CLF.
hm_traffic_awk='
  BEGIN {
    split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", _m, " ")
    for (i = 1; i <= 12; i++) mon[_m[i]] = sprintf("%02d", i)
  }
  function real_ip(line,   m) {
    if (match(line, /cf=[0-9A-Fa-f:.]+/)) return substr(line, RSTART+3, RLENGTH-3)
    if (match(line, /CF-Connecting-IP[:[:space:]"]*[0-9A-Fa-f:.]+/)) {
      m = substr(line, RSTART, RLENGTH)
      sub(/.*[^0-9A-Fa-f:.]/, "", m)
      return m
    }
    return ""
  }
  function is_ip(s) {
    return (s ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ || s ~ /^[0-9A-Fa-f:]+$/)
  }
  function is_host(s) {
    if (s == "" || is_ip(s)) return 0
    return (s ~ /^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$/ && s ~ /[.]/)
  }
  function clf_cmp(s,   m, dd, mo, yy, hh, mi, ss) {
    if (!match(s, /\[[0-9][0-9]\/[A-Za-z][A-Za-z][A-Za-z]\/[0-9][0-9][0-9][0-9]:[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) return ""
    m = substr(s, RSTART + 1, RLENGTH - 1)
    dd = substr(m, 1, 2); mo = substr(m, 4, 3); yy = substr(m, 8, 4)
    hh = substr(m, 13, 2); mi = substr(m, 16, 2); ss = substr(m, 19, 2)
    if (!(mo in mon)) return ""
    return yy mon[mo] dd hh mi ss
  }
  function within_since(s,   ts) {
    if (since_cmp == "" || since_cmp == "0") return 1
    ts = clf_cmp(s)
    if (ts == "") return 1
    return (ts >= since_cmp)
  }
  {
    line = $0
    if (!within_since(line)) next
    rip = real_ip(line)
    if (line ~ /\[[0-9][0-9]\/[A-Za-z][A-Za-z][A-Za-z]\/[0-9][0-9][0-9][0-9]:/ || (NF >= 7 && $2 == "-" && $3 == "-")) {
      ip = $1
      if (rip != "") ip = rip
      bytes = 0
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
      if (dom == "" || is_ip(dom) || ip == "") next
      req[dom]++; sum[dom]+=bytes
      ipn[ip]++
      next
    }
    ip = $1; dom = $2; bytes = $3 + 0
    if (rip != "") ip = rip
    # CF IP w $2 / ostatnie pole — nie traktuj jako domeny
    if (!is_host(dom)) {
      dom = ENVIRON["HM_TRAFFIC_DOM"]
      if (NF >= 4 && is_host($2)) dom = $2
      else if (NF >= 3 && $3 ~ /^[0-9]+$/ && is_host($2)) { dom = $2; bytes = $3 + 0 }
      else if (!is_host(dom)) {
        # IP CF_IP bytes → domena ze ścieżki
        if (NF >= 3 && is_ip($2) && $3 ~ /^[0-9]+$/) {
          dom = ENVIRON["HM_TRAFFIC_DOM"]
          bytes = $3 + 0
        }
      }
    }
    if (dom == "" || is_ip(dom) || ip == "") next
    if (dom ~ /^[0-9]+$/ ) next
    req[dom]++; sum[dom]+=bytes
    ipn[ip]++
  }
'

hm_traffic_sites() {
  local since="" file tmp list=0 since_cmp=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --since) since="${2:-}"; shift 2 || true ;;
      *) shift ;;
    esac
  done
  since_cmp="$(hm_traffic_epoch_cmp "$(hm_traffic_since_epoch "${since}")")"
  tmp="$(hm_traffic_tmp)" || { hm_err "Brak katalogu logów."; return 1; }
  : > "${tmp}"
  while IFS= read -r file; do
    [[ -n "${file}" && -f "${file}" ]] || continue
    list=1
    export HM_TRAFFIC_DOM
    HM_TRAFFIC_DOM="$(hm_traffic_domain_from_path "${file}")"
    if [[ "${file}" == *.gz ]]; then
      gzip -dc -- "${file}" | awk -v since_cmp="${since_cmp}" "${hm_traffic_awk}"' END { for (d in req) printf "%s\t%s\t%s\n", d, req[d], sum[d] }'
    else
      awk -v since_cmp="${since_cmp}" "${hm_traffic_awk}"' END { for (d in req) printf "%s\t%s\t%s\n", d, req[d], sum[d] }' "${file}"
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
    hm_info "Okno: ${since}"
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
  local file tmp list=0 since="" since_cmp=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --since) since="${2:-}"; shift 2 || true ;;
      *) shift ;;
    esac
  done
  # Filtr czasu tylko przy jawnym --since (inaczej cały dostępny log)
  since_cmp=0
  if [[ -n "${since}" ]]; then
    since_cmp="$(hm_traffic_epoch_cmp "$(hm_traffic_since_epoch "${since}")")"
  fi
  tmp="$(hm_traffic_tmp)" || { hm_err "Brak katalogu logów."; return 1; }
  : > "${tmp}"
  while IFS= read -r file; do
    [[ -n "${file}" && -f "${file}" ]] || continue
    list=1
    export HM_TRAFFIC_DOM
    HM_TRAFFIC_DOM="$(hm_traffic_domain_from_path "${file}")"
    if [[ "${file}" == *.gz ]]; then
      gzip -dc -- "${file}" | awk -v since_cmp="${since_cmp}" "${hm_traffic_awk}"' END { for (i in ipn) printf "%s\t%s\n", i, ipn[i] }'
    else
      awk -v since_cmp="${since_cmp}" "${hm_traffic_awk}"' END { for (i in ipn) printf "%s\t%s\n", i, ipn[i] }' "${file}"
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
      if (c == 0) { print "brak skoków"; exit }
      avg=total/c
      for (i in n) {
        if ((n[i] >= 4 && n[i] > avg * 3) || (n[i] >= 10 && n[i] > avg * 2)) {
          printf "spike\t%s\t%d\n", i, n[i]
          printf "hint\tsecurity ban %s\n", i
          hits++
        }
      }
      if (!hits) print "brak skoków"
    }
  ' "${tmp}"
  rm -f "${tmp}"
  if [[ -n "${since}" ]]; then
    hm_info "Okno: ${since}"
  fi
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
