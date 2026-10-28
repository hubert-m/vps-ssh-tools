#!/usr/bin/env bash
# OpenLiteSpeed: stats (.rtreport), htaccess, LSCache, reverse proxy, WebAdmin

if [[ -n "${HMTOOLS_OLS_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_OLS_LOADED=1

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_LIB_DIR}/common.sh"
# shellcheck source=detect.sh
source "${_LIB_DIR}/detect.sh"
# shellcheck source=size.sh
source "${_LIB_DIR}/size.sh"
# shellcheck source=sites/vhost.sh
source "${_LIB_DIR}/sites/vhost.sh"

hm_is_valid_port() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && [[ "${1}" -ge 1 && "${1}" -le 65535 ]]
}

hm_ols_rtreport_files() {
  local f
  for f in /tmp/lshttpd/.rtreport /tmp/lshttpd/.rtreport.*; do
    [[ -f "${f}" ]] || continue
    # pomiń .rtreport.bak itd.
    [[ "$(basename "${f}")" =~ ^\.rtreport(\.[0-9]+)?$ ]] || continue
    printf '%s\n' "${f}"
  done
}

hm_ols_parse_kv() {
  # z linii "KEY: val, KEY2: val2" wyciągnij wartość KEY
  local line="$1" key="$2"
  local re
  re="${key}:[[:space:]]*([^,]+)"
  if [[ "${line}" =~ ${re} ]]; then
    printf '%s' "${BASH_REMATCH[1]// /}"
  else
    printf '%s' "0"
  fi
}

hm_ols_stats_print() {
  hm_detect_all
  local -a files=()
  local f
  while IFS= read -r f; do
    [[ -n "${f}" ]] && files+=("${f}")
  done < <(hm_ols_rtreport_files)

  if [[ "${#files[@]}" -eq 0 ]]; then
    hm_err "Brak /tmp/lshttpd/.rtreport* — OLS nie działa lub brak uprawnień."
    return 1
  fi

  local bps_in=0 bps_out=0 ssl_in=0 ssl_out=0
  local plain=0 sslc=0 idle=0 maxconn=""
  local uptime="" version=""
  local line vh rps proc etype evh ename ekey wq
  # vhost → rps|proc (sumowane między workerami)
  local -A vh_rps=() vh_proc=()
  # extapp key → waitq|inuse|idle|pool|cmax|rps
  local -A ea_wait=() ea_inuse=() ea_idle=() ea_pool=() ea_cmax=() ea_rps=() ea_label=()

  for f in "${files[@]}"; do
    while IFS= read -r line || [[ -n "${line}" ]]; do
      line="${line//$'\r'/}"
      [[ -n "${line}" ]] || continue
      case "${line}" in
        VERSION:*)
          version="${line#VERSION: }"
          ;;
        UPTIME:*)
          uptime="${line#UPTIME: }"
          ;;
        BPS_IN:*)
          bps_in="$(awk -v a="${bps_in}" -v b="$(hm_ols_parse_kv "${line}" BPS_IN)" 'BEGIN{printf "%d", a+b}')"
          bps_out="$(awk -v a="${bps_out}" -v b="$(hm_ols_parse_kv "${line}" BPS_OUT)" 'BEGIN{printf "%d", a+b}')"
          ssl_in="$(awk -v a="${ssl_in}" -v b="$(hm_ols_parse_kv "${line}" SSL_BPS_IN)" 'BEGIN{printf "%d", a+b}')"
          ssl_out="$(awk -v a="${ssl_out}" -v b="$(hm_ols_parse_kv "${line}" SSL_BPS_OUT)" 'BEGIN{printf "%d", a+b}')"
          ;;
        PLAINCONN:*|MAXCONN:*)
          plain="$(awk -v a="${plain}" -v b="$(hm_ols_parse_kv "${line}" PLAINCONN)" 'BEGIN{printf "%d", a+b}')"
          sslc="$(awk -v a="${sslc}" -v b="$(hm_ols_parse_kv "${line}" SSLCONN)" 'BEGIN{printf "%d", a+b}')"
          idle="$(awk -v a="${idle}" -v b="$(hm_ols_parse_kv "${line}" IDLECONN)" 'BEGIN{printf "%d", a+b}')"
          if [[ "${line}" == *MAXCONN:* ]]; then
            maxconn="$(hm_ols_parse_kv "${line}" MAXCONN)"
          fi
          ;;
        REQ_RATE*)
          if [[ "${line}" =~ REQ_RATE[[:space:]]*\[([^\]]*)\] ]]; then
            vh="${BASH_REMATCH[1]}"
          else
            vh=""
          fi
          [[ -n "${vh}" ]] || continue  # pomiń agregat []
          rps="$(hm_ols_parse_kv "${line}" REQ_PER_SEC)"
          proc="$(hm_ols_parse_kv "${line}" REQ_PROCESSING)"
          vh_rps["${vh}"]="$(awk -v a="${vh_rps[${vh}]:-0}" -v b="${rps}" 'BEGIN{printf "%.1f", a+b}')"
          vh_proc["${vh}"]="$(( ${vh_proc[${vh}]:-0} + ${proc%.*} ))"
          ;;
        EXTAPP*)
          if [[ "${line}" =~ EXTAPP[[:space:]]*\[([^\]]*)\][[:space:]]*\[([^\]]*)\][[:space:]]*\[([^\]]*)\] ]]; then
            etype="${BASH_REMATCH[1]}"
            evh="${BASH_REMATCH[2]}"
            ename="${BASH_REMATCH[3]}"
          else
            continue
          fi
          ekey="${etype}|${evh}|${ename}"
          if [[ -n "${evh}" ]]; then
            ea_label["${ekey}"]="${etype} [${evh}] ${ename}"
          else
            ea_label["${ekey}"]="${etype} ${ename}"
          fi
          wq="$(hm_ols_parse_kv "${line}" WAITQUE_DEPTH)"
          if [[ "${wq}" == "0" && "${line}" == *WAITQ_DEPTH* ]]; then
            wq="$(hm_ols_parse_kv "${line}" WAITQ_DEPTH)"
          fi
          wq="${wq%.*}"
          [[ "${wq}" =~ ^[0-9]+$ ]] || wq=0
          ea_wait["${ekey}"]="$(( ${ea_wait[${ekey}]:-0} + wq ))"
          ea_inuse["${ekey}"]="$(( ${ea_inuse[${ekey}]:-0} + $(hm_ols_parse_kv "${line}" INUSE_CONN) ))"
          ea_idle["${ekey}"]="$(( ${ea_idle[${ekey}]:-0} + $(hm_ols_parse_kv "${line}" IDLE_CONN) ))"
          ea_pool["${ekey}"]="$(( ${ea_pool[${ekey}]:-0} + $(hm_ols_parse_kv "${line}" POOL_SIZE) ))"
          ea_cmax["${ekey}"]="$(hm_ols_parse_kv "${line}" CMAXCONN)"
          rps="$(hm_ols_parse_kv "${line}" REQ_PER_SEC)"
          ea_rps["${ekey}"]="$(awk -v a="${ea_rps[${ekey}]:-0}" -v b="${rps}" 'BEGIN{printf "%.1f", a+b}')"
          ;;
      esac
    done < "${f}"
  done

  echo "${C_BOLD}OLS live — .rtreport (${#files[@]} worker)${C_RESET}"
  [[ -n "${version}" ]] && echo "  VERSION : ${version}"
  [[ -n "${uptime}" ]] && echo "  UPTIME  : ${uptime}"
  echo "  HTTP    : in ${bps_in} B/s  out ${bps_out} B/s"
  echo "  HTTPS   : in ${ssl_in} B/s  out ${ssl_out} B/s"
  echo -n "  CONN    : plain=${plain} ssl=${sslc} idle=${idle}"
  [[ -n "${maxconn}" && "${maxconn}" != "0" ]] && echo -n "  max=${maxconn}"
  echo
  echo

  echo "${C_BOLD}VHost (REQ_RATE) — top REQ_PER_SEC${C_RESET}"
  if [[ "${#vh_rps[@]}" -eq 0 ]]; then
    echo "  (brak danych per-vhost)"
  else
    local sorted
    sorted="$(for k in "${!vh_rps[@]}"; do printf '%s\t%s\t%s\n' "${vh_rps[$k]}" "${vh_proc[$k]}" "$k"; done | sort -t$'\t' -k1,1nr)"
    printf '  %-40s %10s %8s\n' "VHOST" "REQ/s" "PROC"
    while IFS=$'\t' read -r rps proc vh; do
      [[ -n "${vh}" ]] || continue
      printf '  %-40s %10s %8s\n' "${vh}" "${rps}" "${proc}"
    done <<< "${sorted}"
  fi
  echo

  echo "${C_BOLD}EXTAPP / LSAPI — kolejka WAITQUE${C_RESET}"
  if [[ "${#ea_wait[@]}" -eq 0 ]]; then
    echo "  (brak EXTAPP w raporcie)"
  else
    printf '  %-48s %6s %6s %6s %6s %8s\n' "APP" "WAITQ" "INUSE" "IDLE" "POOL" "REQ/s"
    sorted="$(for k in "${!ea_wait[@]}"; do
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${ea_wait[$k]}" "${ea_inuse[$k]}" "${ea_idle[$k]}" "${ea_pool[$k]}" "${ea_rps[$k]}" "${ea_label[$k]}" "$k"
    done | sort -t$'\t' -k1,1nr)"
    while IFS=$'\t' read -r wq inu idl pool rps lab _; do
      [[ -n "${lab}" ]] || continue
      if [[ "${wq:-0}" -gt 0 ]]; then
        printf '  %s%-48s%s %s%6s%s %6s %6s %6s %8s\n' \
          "${C_RED}" "${lab}" "${C_RESET}" "${C_RED}" "${wq}" "${C_RESET}" "${inu}" "${idl}" "${pool}" "${rps}"
      else
        printf '  %-48s %6s %6s %6s %6s %8s\n' "${lab}" "${wq}" "${inu}" "${idl}" "${pool}" "${rps}"
      fi
    done <<< "${sorted}"
  fi
}

hm_ols_top() {
  # odświeżanie co 3 s (Ctrl+C)
  local n=0
  while true; do
    [[ "${n}" -gt 0 ]] && clear 2>/dev/null || true
    hm_ols_stats_print || return 1
    echo
    echo "${C_DIM}odświeżenie co 3 s — Ctrl+C aby wyjść${C_RESET}"
    n=$((n + 1))
    sleep 3 || return 0
  done
}

# --- .htaccess ---------------------------------------------------------------

hm_ols_lshttpd_start_epoch() {
  # czas startu głównego procesu lshttpd (sekundy unix)
  local pid
  pid="$(pgrep -o lshttpd 2>/dev/null || pgrep -o openlitespeed 2>/dev/null || true)"
  if [[ -n "${pid}" && -r "/proc/${pid}" ]]; then
    stat -c %Y "/proc/${pid}" 2>/dev/null && return 0
  fi
  # fallback: mtime binarki / brak
  printf '%s' "0"
}

hm_ols_htaccess_check() {
  local domain="${1:-${HM_SITE_DOMAIN:-}}"
  local docroot="${2:-${HM_SITE_DOCROOT:-}}"
  local vhost="${3:-${HM_SITE_VHOST:-}}"

  [[ -n "${domain}" ]] || { hm_err "Podaj domenę lub wejdź w kontekst (use)."; return 1; }
  if [[ -z "${docroot}" || -z "${vhost}" ]]; then
    hm_set_site_context "${domain}" 2>/dev/null || true
    docroot="${HM_SITE_DOCROOT:-${docroot}}"
    vhost="${HM_SITE_VHOST:-${vhost}}"
  fi

  local ht="${docroot}/.htaccess"
  echo "${C_BOLD}.htaccess — ${domain}${C_RESET}"
  echo "  Docroot : ${docroot:--}"
  echo "  Vhost   : ${vhost:--}"

  if [[ -f "${ht}" ]]; then
    local mtime size
    mtime="$(stat -c %Y "${ht}" 2>/dev/null || echo 0)"
    size="$(stat -c %s "${ht}" 2>/dev/null || echo 0)"
    echo "  Plik    : ${ht} ($(hm_human_size "${size}"), mtime $(date -d "@${mtime}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "${mtime}"))"
  else
    hm_warn "Brak pliku ${ht}"
  fi

  local auto="" rewrite_en=""
  if [[ -n "${vhost}" && -f "${vhost}" ]]; then
    auto="$(awk 'tolower($1)=="autoloadhtaccess" { print $2; exit }' "${vhost}" 2>/dev/null || true)"
    rewrite_en="$(awk '
      BEGIN { inrw=0 }
      tolower($1)=="rewrite" { inrw=1; next }
      inrw && tolower($1)=="enable" { print $2; exit }
      inrw && $0 ~ /^[[:space:]]*\}/ { inrw=0 }
    ' "${vhost}" 2>/dev/null || true)"
  fi

  if [[ "${auto}" == "1" ]]; then
    echo "  autoLoadHtaccess : ${C_GREEN}1${C_RESET}"
  else
    echo "  autoLoadHtaccess : ${C_YELLOW}${auto:-brak}${C_RESET}  → ols htaccess enable"
  fi
  if [[ "${rewrite_en}" == "1" ]]; then
    echo "  rewrite enable   : ${C_GREEN}1${C_RESET}"
  else
    echo "  rewrite enable   : ${C_YELLOW}${rewrite_en:-brak}${C_RESET}"
  fi

  if [[ -f "${ht}" ]]; then
    local start_epoch ht_mtime
    start_epoch="$(hm_ols_lshttpd_start_epoch)"
    ht_mtime="$(stat -c %Y "${ht}" 2>/dev/null || echo 0)"
    if [[ "${start_epoch}" =~ ^[0-9]+$ && "${start_epoch}" -gt 0 && "${ht_mtime}" -gt "${start_epoch}" ]]; then
      hm_warn "Plik .htaccess był modyfikowany po ostatnim starcie/reloadzie OLS — uruchom ols reload!"
    else
      hm_ok ".htaccess nie wygląda na nowszy niż proces OLS."
    fi
  fi
}

hm_ols_htaccess_enable() {
  local domain="${1:-${HM_SITE_DOMAIN:-}}"
  local vhost="${2:-${HM_SITE_VHOST:-}}"
  [[ -n "${domain}" ]] || { hm_err "Podaj domenę lub use <domena>."; return 1; }
  if [[ -z "${vhost}" || ! -f "${vhost}" ]]; then
    vhost="$(hm_vhost_conf_path "${domain}" 2>/dev/null || true)"
  fi
  [[ -n "${vhost}" && -f "${vhost}" ]] || { hm_err "Brak vhconf dla ${domain}."; return 1; }

  echo "  Vhost: ${vhost}"
  if ! hm_confirm "Włączyć autoLoadHtaccess 1 + rewrite enable 1 i przeładować OLS"; then
    hm_info "Anulowano."
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  awk '
    BEGIN { has_auto=0; inrw=0; rw_enable=0; saw_rw=0 }
    tolower($1)=="autoloadhtaccess" {
      print "autoLoadHtaccess 1"
      has_auto=1
      next
    }
    tolower($1)=="rewrite" {
      print
      inrw=1; saw_rw=1
      next
    }
    inrw && tolower($1)=="enable" {
      print "  enable                  1"
      rw_enable=1
      next
    }
    inrw && $0 ~ /^[[:space:]]*\}/ {
      if (!rw_enable) print "  enable                  1"
      print
      inrw=0
      next
    }
    { print }
    END {
      if (!has_auto) print "autoLoadHtaccess 1"
      if (!saw_rw) {
        print "rewrite  {"
        print "  enable                  1"
        print "}"
      }
    }
  ' "${vhost}" > "${tmp}"

  if ! cp -a "${vhost}" "${vhost}.hmtools.bak" 2>/dev/null; then
    hm_warn "Nie udało się zrobić .bak — kontynuuję."
  fi
  if ! cat "${tmp}" > "${vhost}"; then
    hm_err "Zapis vhconf nieudany."
    rm -f "${tmp}"
    return 1
  fi
  rm -f "${tmp}"
  hm_ok "Zapisano autoLoadHtaccess / rewrite enable."
  hm_ols_reload_soft && hm_ok "OLS reload OK." || hm_warn "ols reload nieudany"
}

# --- LSCache -----------------------------------------------------------------

hm_ols_cache_paths_for_domain() {
  local domain="$1"
  local root="${2:-}"
  local p
  for p in \
    "/home/${domain}/lscache" \
    "${root}/lscache" \
    "${OLS_ROOT}/cachedata/${domain}" \
    "${OLS_ROOT}/cachedata"
  do
    [[ -n "${p}" && -d "${p}" ]] || continue
    # unikaj duplikatów
    printf '%s\n' "${p}"
  done | awk '!seen[$0]++'
}

hm_ols_cache_status() {
  local domain="${1:-}"
  hm_detect_all
  local conf="${OLS_CONF:-}"
  echo "${C_BOLD}LSCache / module cache${C_RESET}"

  if [[ -n "${conf}" && -f "${conf}" ]]; then
    if grep -Eqi 'module[[:space:]]+cache|cache[[:space:]]*\{' "${conf}" 2>/dev/null; then
      hm_ok "Globalnie: wpis cache w ${conf}"
      grep -Ein 'module[[:space:]]+cache|enableCache|checkPublicCache|checkPrivateCache|storagePath' "${conf}" 2>/dev/null \
        | head -20 | sed 's/^/  /' || true
    else
      hm_warn "Brak oczywistego bloku module cache w httpd_config.conf"
    fi
  else
    hm_warn "Brak OLS_CONF"
  fi

  if [[ -z "${domain}" && -n "${HM_SITE_DOMAIN:-}" ]]; then
    domain="${HM_SITE_DOMAIN}"
  fi

  if [[ -n "${domain}" ]]; then
    local vhost root
    vhost="$(hm_vhost_conf_path "${domain}" 2>/dev/null || true)"
    root="$(hm_ols_vhroot_for_domain "${domain}" 2>/dev/null || true)"
    echo
    echo "${C_BOLD}VHost ${domain}${C_RESET}"
    if [[ -n "${vhost}" && -f "${vhost}" ]]; then
      echo "  Conf: ${vhost}"
      grep -Ein 'enableCache|checkPublicCache|checkPrivateCache|storagePath|cache' "${vhost}" 2>/dev/null \
        | head -25 | sed 's/^/  /' || echo "  (brak dyrektyw cache w vhconf)"
    else
      hm_warn "Brak vhconf"
    fi
    echo "  Katalogi cache:"
    local p bytes
    while IFS= read -r p; do
      [[ -n "${p}" ]] || continue
      bytes="$(hm_dir_size_bytes "${p}" 2>/dev/null || echo 0)"
      echo "    ${p}  ($(hm_human_size "${bytes}"))"
    done < <(hm_ols_cache_paths_for_domain "${domain}" "${root}")
  fi
}

hm_ols_cache_flush() {
  local scope="${1:-}"  # domena | all | ""
  hm_detect_all
  local -a targets=()
  local domain p root

  if [[ "${scope}" == "all" || "${scope}" == "--all" || "${scope}" == "global" ]]; then
    for p in "${OLS_ROOT}/cachedata" /tmp/lshttpd/cachedata; do
      [[ -d "${p}" ]] && targets+=("${p}")
    done
    hm_discover_sites 2>/dev/null || true
    for domain in "${HM_SITES_LIST[@]:-}"; do
      root="$(hm_ols_vhroot_for_domain "${domain}" 2>/dev/null || true)"
      while IFS= read -r p; do
        [[ -n "${p}" ]] && targets+=("${p}")
      done < <(hm_ols_cache_paths_for_domain "${domain}" "${root}")
    done
  else
    domain="${scope:-${HM_SITE_DOMAIN:-}}"
    [[ -n "${domain}" ]] || { hm_err "Użycie: ols cache flush [domena|all] (lub use <domena>)."; return 1; }
    root="$(hm_ols_vhroot_for_domain "${domain}" 2>/dev/null || true)"
    while IFS= read -r p; do
      [[ -n "${p}" ]] && targets+=("${p}")
    done < <(hm_ols_cache_paths_for_domain "${domain}" "${root}")
  fi

  # unikalne, istniejące, nie symlinki
  local -a uniq=()
  local t real
  for t in "${targets[@]}"; do
    [[ -d "${t}" ]] || continue
    [[ -L "${t}" ]] && continue
    real="$(realpath -m "${t}" 2>/dev/null || echo "${t}")"
    case "${real}" in
      /home/*|/usr/local/lsws/*|/usr/local/litespeed/*|/tmp/lshttpd/*) ;;
      *) hm_warn "Pominięto niebezpieczną ścieżkę: ${t}"; continue ;;
    esac
    uniq+=("${real}")
  done
  # dedupe
  mapfile -t uniq < <(printf '%s\n' "${uniq[@]}" | awk '!seen[$0]++')

  if [[ "${#uniq[@]}" -eq 0 ]]; then
    hm_info "Brak katalogów LSCache do wyczyszczenia."
    return 0
  fi

  echo "${C_BOLD}LSCache flush — podgląd${C_RESET}"
  local bytes total=0
  for t in "${uniq[@]}"; do
    bytes="$(hm_dir_size_bytes "${t}" 2>/dev/null || echo 0)"
    total=$((total + bytes))
    echo "  ${t}  ($(hm_human_size "${bytes}"))"
  done
  echo "  Razem: $(hm_human_size "${total}")"
  if ! hm_confirm "Wyczyścić zawartość powyższych katalogów LSCache"; then
    hm_info "Anulowano."
    return 0
  fi
  local ent
  for t in "${uniq[@]}"; do
    while IFS= read -r -d '' ent; do
      [[ -L "${ent}" ]] && continue
      rm -rf -- "${ent}" 2>/dev/null || true
    done < <(find -P "${t}" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
    hm_ok "Wyczyszczono: ${t}"
  done
}

# --- Reverse proxy -----------------------------------------------------------

hm_ols_proxy_blocks_for_domain() {
  # wypisz: name|address|port
  local domain="$1"
  local conf
  conf="$(hm_vhost_conf_path "${domain}" 2>/dev/null || true)"
  [[ -n "${conf}" && -f "${conf}" ]] || return 0
  awk '
    BEGIN { inext=0; isproxy=0; name=""; addr="" }
    tolower($1)=="extprocessor" {
      inext=1; isproxy=0; name=$2; addr=""; next
    }
    inext && tolower($1)=="type" && tolower($2)=="proxy" { isproxy=1 }
    inext && tolower($1)=="address" { addr=$2 }
    inext && $0 ~ /^[[:space:]]*\}/ {
      if (isproxy && name != "" && addr != "") {
        n = split(addr, a, ":");
        port = (n > 0 && a[n] ~ /^[0-9]+$/) ? a[n] : "";
        print name "|" addr "|" port
      }
      inext=0; isproxy=0; name=""; addr=""
    }
  ' "${conf}" 2>/dev/null
}

hm_ols_port_listening() {
  local port="$1"
  if hm_have_cmd ss; then
    ss -lnt 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" { found=1 } END { exit !found }'
    return $?
  fi
  if hm_have_cmd netstat; then
    netstat -lnt 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" { found=1 } END { exit !found }'
    return $?
  fi
  return 1
}

hm_ols_proxy_health_one() {
  local port="$1"
  local listen=0 http=0
  if hm_ols_port_listening "${port}"; then
    listen=1
  fi
  if hm_have_cmd curl; then
    if curl -sI --max-time 2 "http://127.0.0.1:${port}/" >/dev/null 2>&1; then
      http=1
    fi
  fi
  printf '%s %s' "${listen}" "${http}"
}

hm_ols_proxy_status() {
  local domain="${1:-}"
  hm_detect_all

  if [[ -n "${domain}" ]]; then
    hm_ols_proxy_status_domain "${domain}"
    return $?
  fi

  echo "${C_BOLD}Reverse proxy (extprocessor type proxy)${C_RESET}"
  hm_discover_sites 2>/dev/null || true
  local d any=0
  for d in "${HM_SITES_LIST[@]:-}"; do
    if hm_ols_proxy_blocks_for_domain "${d}" | grep -q .; then
      any=1
      hm_ols_proxy_status_domain "${d}"
      echo
    fi
  done
  if [[ "${any}" -eq 0 ]]; then
    echo "  (brak bloków proxy w vhostach)"
  fi
}

hm_ols_proxy_status_domain() {
  local domain="$1"
  local line name addr port listen http st
  echo "${C_BOLD}Proxy — ${domain}${C_RESET}"
  local found=0
  while IFS='|' read -r name addr port; do
    [[ -n "${port}" ]] || continue
    found=1
    read -r listen http <<< "$(hm_ols_proxy_health_one "${port}")"
    if [[ "${listen}" -eq 1 ]]; then
      st="${C_GREEN}LISTEN${C_RESET}"
    else
      st="${C_RED}MARTWE (503?)${C_RESET}"
    fi
    printf '  %-20s %s → :%s  [%s]' "${name}" "${addr}" "${port}" "${st}"
    if [[ "${listen}" -eq 1 && "${http}" -eq 1 ]]; then
      printf '  curl=OK'
    elif [[ "${listen}" -eq 1 ]]; then
      printf '  curl=brak odpowiedzi'
    fi
    echo
  done < <(hm_ols_proxy_blocks_for_domain "${domain}")
  if [[ "${found}" -eq 0 ]]; then
    echo "  (brak extprocessor type proxy)"
  fi
}

hm_ols_proxy_set_port() {
  local domain="${1:-${HM_SITE_DOMAIN:-}}"
  local newport="$2"
  local name_filter="${3:-}"

  [[ -n "${domain}" ]] || { hm_err "Podaj domenę lub use <domena>."; return 1; }
  hm_is_valid_port "${newport}" || { hm_err "Nieprawidłowy port: ${newport}"; return 1; }

  local conf
  conf="$(hm_vhost_conf_path "${domain}" 2>/dev/null || true)"
  [[ -n "${conf}" && -f "${conf}" ]] || { hm_err "Brak vhconf dla ${domain}."; return 1; }

  local blocks
  blocks="$(hm_ols_proxy_blocks_for_domain "${domain}")"
  [[ -n "${blocks}" ]] || { hm_err "Brak bloków proxy w ${conf}."; return 1; }

  if [[ -z "${name_filter}" ]]; then
    local cnt
    cnt="$(printf '%s\n' "${blocks}" | grep -c . || true)"
    if [[ "${cnt}" -gt 1 ]]; then
      echo "Dostępne proxy:"
      printf '%s\n' "${blocks}" | while IFS='|' read -r n a p; do echo "  ${n}  ${a}"; done
      hm_err "Wiele proxy — podaj nazwę: proxy set-port ${newport} <nazwa>"
      return 1
    fi
    name_filter="$(printf '%s\n' "${blocks}" | head -1 | cut -d'|' -f1)"
  fi

  echo "  Vhost : ${conf}"
  echo "  Proxy : ${name_filter} → port ${newport}"
  if ! hm_confirm "Zmienić address w extprocessor i przeładować OLS"; then
    hm_info "Anulowano."
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  awk -v want="${name_filter}" -v newport="${newport}" '
    BEGIN { inext=0; isproxy=0; name=""; changed=0 }
    tolower($1)=="extprocessor" {
      inext=1; isproxy=0; name=$2; print; next
    }
    inext && tolower($1)=="type" && tolower($2)=="proxy" { isproxy=1; print; next }
    inext && isproxy && name==want && tolower($1)=="address" {
      # zachowaj host, zmień port
      host=$2
      sub(/:[0-9]+$/, "", host)
      if (host == $2) host="127.0.0.1"
      print "  address                 " host ":" newport
      changed=1
      next
    }
    inext && $0 ~ /^[[:space:]]*\}/ { inext=0; isproxy=0; name=""; print; next }
    { print }
    END { if (!changed) exit 2 }
  ' "${conf}" > "${tmp}"
  local awk_rc=$?
  if [[ "${awk_rc}" -ne 0 ]]; then
    hm_err "Nie znaleziono bloku proxy „${name_filter}”."
    rm -f "${tmp}"
    return 1
  fi
  cp -a "${conf}" "${conf}.hmtools.bak" 2>/dev/null || true
  cat "${tmp}" > "${conf}"
  rm -f "${tmp}"
  hm_ok "Ustawiono port ${newport} dla ${name_filter}."
  hm_ols_reload_soft && hm_ok "OLS reload OK." || hm_warn "ols reload nieudany"
}

# --- WebAdmin ----------------------------------------------------------------

hm_ols_admin_conf() {
  hm_detect_all
  local c
  for c in \
    "${OLS_ROOT}/admin/conf/admin_config.conf" \
    "${OLS_ROOT}/admin/conf/admin_config.xml"
  do
    [[ -f "${c}" ]] && { printf '%s' "${c}"; return 0; }
  done
  return 1
}

hm_ols_admin_port() {
  local conf port=""
  conf="$(hm_ols_admin_conf 2>/dev/null || true)"
  [[ -n "${conf}" && -f "${conf}" ]] || { echo 7080; return 0; }
  port="$(awk '
    tolower($1)=="address" || tolower($1)=="<address>" {
      gsub(/[<>\/]/,"",$0)
      n=split($0,a,":");
      for(i=1;i<=n;i++) if (a[i] ~ /^[0-9]+$/) { print a[i]; exit }
    }
    /listener/ { next }
  ' "${conf}" 2>/dev/null | head -1)"
  # też: address *:7080 lub 7080
  if [[ -z "${port}" ]]; then
    port="$(grep -Eo ':[0-9]{2,5}' "${conf}" 2>/dev/null | head -1 | tr -d ':')"
  fi
  printf '%s' "${port:-7080}"
}

hm_ols_admin_status() {
  hm_detect_all
  local conf port host listen_pub=0 listen_loc=0
  conf="$(hm_ols_admin_conf 2>/dev/null || true)"
  port="$(hm_ols_admin_port)"
  host="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo SERWER)"

  echo "${C_BOLD}OLS WebAdmin${C_RESET}"
  echo "  OLS_ROOT : ${OLS_ROOT:--}"
  echo "  Conf     : ${conf:--}"
  echo "  Port     : ${port}"

  if hm_have_cmd ss; then
    if ss -lnt 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" { print; found=1 } END { exit !found }'; then
      listen_loc=1
      # publiczne jeśli 0.0.0.0 lub * 
      if ss -lnt 2>/dev/null | awk -v p=":${port}" '
        $4 ~ p"$" && ($4 ~ /^0\.0\.0\.0:/ || $4 ~ /^\*:/ || $4 ~ /^\[::\]:/) { exit 0 }
        END { exit 1 }
      '; then
        listen_pub=1
      fi
    fi
  fi

  if [[ "${listen_loc}" -eq 1 ]]; then
    if [[ "${listen_pub}" -eq 1 ]]; then
      hm_warn "Port ${port} nasłuchuje publicznie (0.0.0.0) — rozważ firewall / tylko localhost."
    else
      hm_ok "Port ${port} nasłuchuje (wygląda na lokalny)."
    fi
  else
    hm_warn "Port ${port} nie wygląda na otwarty (ss)."
  fi

  echo
  echo "  Bezpieczny dostęp przez tunel SSH:"
  echo "    ssh -L ${port}:127.0.0.1:${port} root@${host}"
  echo "  Potem w przeglądarce: https://127.0.0.1:${port}/"
}

hm_ols_admin_pass() {
  hm_detect_all
  local script="${OLS_ROOT}/admin/misc/admpass.sh"
  [[ -n "${OLS_ROOT}" && -x "${script}" ]] || {
    hm_err "Brak ${script}"
    return 1
  }
  hm_info "Uruchamiam admpass.sh (interaktywna zmiana loginu/hasła WebAdmin)…"
  "${script}"
}
