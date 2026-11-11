#!/usr/bin/env bash
# traffic — transfer, access logi, skoki. Strumieniowo, bez wczytywania całego logu do tablicy basha.

_hm_cmd_help traffic <<'EOF'
Użycie:
  traffic [day|month]
  traffic sites [--since 24h]
  traffic now
  traffic spikes

Log access: IP domena bajty [cf=IP]. Adres cf= wygrywa z adresem Cloudflare.
EOF

hm_traffic_counters() { printf '%s\n' "${HM_TRAFFIC_COUNTERS:-}"; }
hm_traffic_logs() { printf '%s\n' "${HM_TRAFFIC_LOGS:-}"; }

hm_traffic_day() {
  local which="${1:-day}" file
  file="$(hm_traffic_counters)"
  [[ -n "${file}" && -f "${file}" ]] || { hm_err "Brak liczników transferu."; return 1; }
  awk -F= -v which="${which}" '
    $1 == "rx_" which { rx=$2 }
    $1 == "tx_" which { tx=$2 }
    END { printf "rx: %s\ntx: %s\n", rx+0, tx+0 }
  ' "${file}"
}

hm_traffic_awk='
  {
    ip=$1; dom=$2; bytes=$3+0
    if (match($0, /cf=[0-9A-Fa-f:.]+/)) ip=substr($0, RSTART+3, RLENGTH-3)
    if (dom == "" || ip == "") next
    req[dom]++; sum[dom]+=bytes
    ipn[ip]++
  }
'

hm_traffic_sites() {
  local since="" dir file
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --since) since="${2:-}"; shift 2 || true ;;
      *) shift ;;
    esac
  done
  dir="$(hm_traffic_logs)"
  [[ -n "${dir}" && -d "${dir}" ]] || { hm_err "Brak katalogu logów."; return 1; }
  : > "${dir}/.hm-traffic-sum"
  shopt -s nullglob
  for file in "${dir}"/*.log "${dir}"/*.log.gz; do
    if [[ "${file}" == *.gz ]]; then
      gzip -dc -- "${file}" | awk "${hm_traffic_awk}"' END { for (d in req) printf "%s\t%s\t%s\n", d, req[d], sum[d] }'
    else
      awk "${hm_traffic_awk}"' END { for (d in req) printf "%s\t%s\t%s\n", d, req[d], sum[d] }' "${file}"
    fi
  done >> "${dir}/.hm-traffic-sum"
  shopt -u nullglob
  awk -F '\t' '{ r[$1]+=$2; b[$1]+=$3 } END { for (d in r) printf "%s\t%s\t%s\n", d, r[d], b[d] }' "${dir}/.hm-traffic-sum"
  rm -f "${dir}/.hm-traffic-sum"
  if [[ -n "${since}" ]]; then
    hm_info "Okno: ${since} (logi bez odcinania dat)."
  fi
}

hm_traffic_now() {
  local file="${HM_TRAFFIC_NOW:-}"
  [[ -n "${file}" && -f "${file}" ]] || { hm_err "Brak zrzutu połączeń."; return 1; }
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
}

hm_traffic_spikes() {
  local dir file
  dir="$(hm_traffic_logs)"
  [[ -n "${dir}" && -d "${dir}" ]] || { hm_err "Brak katalogu logów."; return 1; }
  : > "${dir}/.hm-traffic-ip"
  shopt -s nullglob
  for file in "${dir}"/*.log "${dir}"/*.log.gz; do
    if [[ "${file}" == *.gz ]]; then
      gzip -dc -- "${file}" | awk "${hm_traffic_awk}"' END { for (i in ipn) printf "%s\t%s\n", i, ipn[i] }'
    else
      awk "${hm_traffic_awk}"' END { for (i in ipn) printf "%s\t%s\n", i, ipn[i] }' "${file}"
    fi
  done >> "${dir}/.hm-traffic-ip"
  shopt -u nullglob
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
  ' "${dir}/.hm-traffic-ip"
  rm -f "${dir}/.hm-traffic-ip"
}

hm_traffic_summary() {
  local file
  file="$(hm_traffic_counters)"
  [[ -n "${file}" && -f "${file}" ]] || return 0
  hm_traffic_day month
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
