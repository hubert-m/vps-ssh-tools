#!/usr/bin/env bash
# Moduł: health


_hm_cmd_help health <<'EOF'
Użycie:
  health                         Szybki przegląd: load, RAM, dysk, OLS/MySQL, certy
  health --ram [--count N]       Top procesów wg RAM (RSS) + site/service/cwd
  health --cpu [--count N]       Top procesów wg CPU + site/service/cwd
  health --ram --cpu             Obie sekcje
  health --ram|--cpu --live [--interval N]
                                 Live (min. interval=2 s); q lub Ctrl+C → hmtools>
  health --check [--disk 90] [--ssl-days 14] [--services] [--notify] [--json]
  health watch install|status|disable   Cron co 15 min (hmtools-watch)

Domyślnie --count 15. Mapowanie: /home/<domena>, cgroup *.service, cwd z /proc.
--check: rc≠0 gdy alert; z --notify woła hm_notify (dedup + recovery OK).
EOF

# Skróć cmdline do czytelnej linii (bez NUL).
hm_health_cmdline() {
  local pid="$1" raw
  raw="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
  raw="$(printf '%s' "${raw}" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
  if [[ -z "${raw}" ]]; then
    raw="$(ps -p "${pid}" -o comm= 2>/dev/null || echo '?')"
  fi
  if [[ ${#raw} -gt 72 ]]; then
    printf '%s…' "${raw:0:71}"
  else
    printf '%s' "${raw}"
  fi
}

hm_health_cwd() {
  local pid="$1"
  readlink -f "/proc/${pid}/cwd" 2>/dev/null || true
}

# Jednostka systemd z cgroup (np. php8.2-fpm.service, redis.service, docker-<id>.scope).
hm_health_systemd_unit() {
  local pid="$1" cg unit=""
  [[ -r "/proc/${pid}/cgroup" ]] || return 0
  cg="$(tr '\n' ' ' < "/proc/${pid}/cgroup" 2>/dev/null || true)"
  # Docker / containerd scope przed zwykłym .service
  unit="$(printf '%s\n' "${cg}" | grep -oE 'docker-[0-9a-f]+\.scope' | tail -1 || true)"
  if [[ -z "${unit}" ]]; then
    unit="$(printf '%s\n' "${cg}" | grep -oE 'containerd-[0-9a-f]+\.scope' | tail -1 || true)"
  fi
  if [[ -z "${unit}" ]]; then
    unit="$(printf '%s\n' "${cg}" | grep -oE '[A-Za-z0-9_@.-]+\.service' | tail -1 || true)"
  fi
  printf '%s' "${unit}"
}

# Dopasuj domenę strony: cwd / cmdline → /home/<domena>.
hm_health_site_for_text() {
  local text="$1"
  local d best="" best_len=0
  [[ -n "${text}" ]] || return 0
  for d in "${HM_SITES_LIST[@]:-}"; do
    [[ -n "${d}" ]] || continue
    if [[ "${text}" == *"/home/${d}"* ]]; then
      if [[ "${#d}" -gt "${best_len}" ]]; then
        best="${d}"
        best_len="${#d}"
      fi
    fi
  done
  printf '%s' "${best}"
}

hm_health_hint() {
  # stdout: site|unit|cwd  (puste pola dozwolone)
  local pid="$1"
  local cwd cmd site unit text
  cwd="$(hm_health_cwd "${pid}")"
  cmd="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
  text="${cwd} ${cmd}"
  site="$(hm_health_site_for_text "${text}")"
  unit="$(hm_health_systemd_unit "${pid}")"
  printf '%s|%s|%s' "${site}" "${unit}" "${cwd}"
}

hm_health_mem_summary() {
  local total avail used
  if [[ -r /proc/meminfo ]]; then
    total="$(awk '/^MemTotal:/ {print $2*1024}' /proc/meminfo)"
    avail="$(awk '/^MemAvailable:/ {print $2*1024}' /proc/meminfo)"
    [[ "${total}" =~ ^[0-9]+$ && "${avail}" =~ ^[0-9]+$ ]] || return 0
    used=$((total - avail))
    echo "  Razem: $(hm_human_size "${total}")  |  użyte: $(hm_human_size "${used}")  |  dostępne: $(hm_human_size "${avail}")"
  elif hm_have_cmd free; then
    free -h | sed 's/^/  /'
  fi
}

hm_health_section_ram() {
  local count="${1:-15}"
  echo "${C_BOLD}Top RAM (RSS ↓)${C_RESET} ${C_DIM}— ${count} procesów${C_RESET}"
  hm_health_mem_summary
  echo
  printf '  %s%-12s %5s %7s %-12s %-28s %s%s\n' \
    "${C_DIM}" "RSS" "%MEM" "PID" "USER" "SITE / SERVICE" "COMMAND" "${C_RESET}"
  printf '  %s%s%s\n' "${C_DIM}" "$(printf '%.0s─' {1..96})" "${C_RESET}"

  local pid user pmem rss_kb cmd site unit cwd hint rss_h label
  local n=0
  # RSS w KB (ps); sort malejąco
  while IFS= read -r line || [[ -n "${line:-}" ]]; do
    [[ -n "${line}" ]] || continue
    # pid user %mem rss cmd… — cmd może mieć spacje
    pid="$(printf '%s' "${line}" | awk '{print $1}')"
    user="$(printf '%s' "${line}" | awk '{print $2}')"
    pmem="$(printf '%s' "${line}" | awk '{print $3}')"
    rss_kb="$(printf '%s' "${line}" | awk '{print $4}')"
    [[ "${pid}" =~ ^[0-9]+$ ]] || continue
    [[ "${rss_kb}" =~ ^[0-9]+$ ]] || continue
    [[ "${rss_kb}" -gt 0 ]] || continue
    n=$((n + 1))
    [[ "${n}" -le "${count}" ]] || break

    rss_h="$(hm_human_size "$((rss_kb * 1024))")"
    cmd="$(hm_health_cmdline "${pid}")"
    IFS='|' read -r site unit cwd <<<"$(hm_health_hint "${pid}")"
    label="-"
    if [[ -n "${site}" && -n "${unit}" ]]; then
      label="${site} / ${unit}"
    elif [[ -n "${site}" ]]; then
      label="${site}"
    elif [[ -n "${unit}" ]]; then
      label="${unit}"
    fi
    if [[ ${#label} -gt 28 ]]; then
      label="${label:0:27}…"
    fi
    printf '  %-12s %5s %7s %-12s %-28s %s\n' \
      "${rss_h}" "${pmem}" "${pid}" "${user:0:12}" "${label}" "${cmd}"
    if [[ -n "${cwd}" && "${cwd}" != "/" ]]; then
      echo "  ${C_DIM}             cwd: ${cwd}${C_RESET}"
    fi
  done < <(ps -eo pid=,user=,%mem=,rss=,args= --sort=-rss 2>/dev/null | head -n "$((count + 5))")

  if [[ "${n}" -eq 0 ]]; then
    hm_warn "Brak danych z ps (RSS)."
  fi
}

hm_health_section_cpu() {
  local count="${1:-15}"
  echo "${C_BOLD}Top CPU (%CPU ↓)${C_RESET} ${C_DIM}— ${count} procesów${C_RESET}"
  echo -n "  Load: "
  cat /proc/loadavg 2>/dev/null || uptime
  echo
  printf '  %s%6s %7s %-12s %-28s %s%s\n' \
    "${C_DIM}" "%CPU" "PID" "USER" "SITE / SERVICE" "COMMAND" "${C_RESET}"
  printf '  %s%s%s\n' "${C_DIM}" "$(printf '%.0s─' {1..96})" "${C_RESET}"

  local pid user pcpu cmd site unit cwd label n=0
  while IFS= read -r line || [[ -n "${line:-}" ]]; do
    [[ -n "${line}" ]] || continue
    pid="$(printf '%s' "${line}" | awk '{print $1}')"
    user="$(printf '%s' "${line}" | awk '{print $2}')"
    pcpu="$(printf '%s' "${line}" | awk '{print $3}')"
    [[ "${pid}" =~ ^[0-9]+$ ]] || continue
    # pomiń idle 0.0 na końcu listy — i tak head ogranicza
    n=$((n + 1))
    [[ "${n}" -le "${count}" ]] || break

    cmd="$(hm_health_cmdline "${pid}")"
    IFS='|' read -r site unit cwd <<<"$(hm_health_hint "${pid}")"
    label="-"
    if [[ -n "${site}" && -n "${unit}" ]]; then
      label="${site} / ${unit}"
    elif [[ -n "${site}" ]]; then
      label="${site}"
    elif [[ -n "${unit}" ]]; then
      label="${unit}"
    fi
    if [[ ${#label} -gt 28 ]]; then
      label="${label:0:27}…"
    fi
    printf '  %6s %7s %-12s %-28s %s\n' \
      "${pcpu}" "${pid}" "${user:0:12}" "${label}" "${cmd}"
    if [[ -n "${cwd}" && "${cwd}" != "/" ]]; then
      echo "  ${C_DIM}             cwd: ${cwd}${C_RESET}"
    fi
  done < <(ps -eo pid=,user=,%cpu=,args= --sort=-%cpu 2>/dev/null | head -n "$((count + 5))")

  if [[ "${n}" -eq 0 ]]; then
    hm_warn "Brak danych z ps (CPU)."
  fi
}

# Czekaj interval s; q/Q/Esc → rc=1; HM_HEALTH_LIVE_STOP=1 (Ctrl+C) → rc=1.
hm_health_live_wait() {
  local interval="${1:-2}"
  local end key=""
  end=$((SECONDS + interval))
  while (( SECONDS < end )); do
    [[ "${HM_HEALTH_LIVE_STOP:-0}" -eq 1 ]] && return 1
    key=""
    if read -r -n 1 -t 0.25 key 2>/dev/null; then
      case "${key}" in
        q|Q|$'\033') return 1 ;;
      esac
    fi
  done
  return 0
}

# Live top RAM/CPU — clear + odświeżanie; wyjście: q lub Ctrl+C.
hm_health_live() {
  local do_ram="${1:-0}" do_cpu="${2:-0}" count="${3:-15}" interval="${4:-2}"
  local frame=0 need_sep=0

  [[ "${interval}" =~ ^[0-9]+$ ]] || interval=2
  if [[ "${interval}" -lt 2 ]]; then
    hm_warn "--interval minimum to 2 s (było ${interval}) — ustawiam 2."
    interval=2
  fi

  if [[ ! -t 0 || ! -t 1 ]]; then
    hm_err "health --live wymaga TTY (interaktywny terminal)."
    return 1
  fi

  HM_HEALTH_LIVE_STOP=0
  hm_info "Live co ${interval}s — q lub Ctrl+C wraca do hmtools"
  trap 'HM_HEALTH_LIVE_STOP=1' INT
  while [[ "${HM_HEALTH_LIVE_STOP}" -eq 0 ]]; do
    if [[ "${frame}" -gt 0 ]]; then
      clear 2>/dev/null || printf '\033[H\033[2J'
    fi
    echo "${C_BOLD}health live${C_RESET} ${C_DIM}$(date '+%Y-%m-%d %H:%M:%S')  interval=${interval}s  q/Ctrl+C = wyjście${C_RESET}"
    echo
    need_sep=0
    if [[ "${do_ram}" -eq 1 ]]; then
      hm_health_section_ram "${count}"
      need_sep=1
    fi
    [[ "${HM_HEALTH_LIVE_STOP}" -eq 1 ]] && break
    if [[ "${do_cpu}" -eq 1 ]]; then
      [[ "${need_sep}" -eq 1 ]] && echo
      hm_health_section_cpu "${count}"
    fi
    [[ "${HM_HEALTH_LIVE_STOP}" -eq 1 ]] && break
    echo
    echo "${C_DIM}odświeżenie co ${interval} s — q lub Ctrl+C aby wyjść${C_RESET}"
    frame=$((frame + 1))
    hm_health_live_wait "${interval}" || break
  done
  trap - INT
  unset HM_HEALTH_LIVE_STOP
  echo
  hm_ok "Live zakończone — powrót do hmtools."
  return 0
}

hm_health_overview() {
  echo "${C_BOLD}Health check${C_RESET}"
  echo "Host     : $(hostname -f 2>/dev/null || hostname)"
  echo "Panel    : ${PANEL}"
  echo "Webserver: ${WEBSERVER}"
  echo "DB       : ${DB_ENGINE}"
  echo

  echo -n "Load     : "
  cat /proc/loadavg 2>/dev/null || uptime

  if hm_have_cmd free; then
    echo
    free -h
  fi

  echo
  echo "Dysk     : used $(hm_disk_used_percent /)%  free $(hm_disk_free_percent /)%"
  df -h / 2>/dev/null | tail -1

  echo
  local ols_ok="down" mysql_ok="down"
  local sup_ok="absent" chrome_ok="absent"
  if pgrep -x lshttpd >/dev/null 2>&1 || pgrep -x openlitespeed >/dev/null 2>&1; then
    ols_ok="up"
  elif [[ -x "${OLS_CTRL}" ]] && "${OLS_CTRL}" status 2>/dev/null | grep -qi running; then
    ols_ok="up"
  fi
  if hm_mysql_exec -e "SELECT 1;" >/dev/null 2>&1; then
    mysql_ok="up"
  fi
  if [[ "${SUPERVISOR:-no}" == "yes" ]]; then
    if pgrep -x supervisord >/dev/null 2>&1 \
      || { hm_have_cmd systemctl && systemctl is-active --quiet supervisord 2>/dev/null; } \
      || { hm_have_cmd systemctl && systemctl is-active --quiet supervisor 2>/dev/null; }; then
      sup_ok="up"
    else
      sup_ok="down"
    fi
  fi
  if [[ "${CHROME:-no}" == "yes" && -n "${CHROME_BIN:-}" ]]; then
    chrome_ok="${CHROME_BIN}"
  fi
  echo "OLS      : ${ols_ok}"
  echo "MySQL    : ${mysql_ok}"
  echo "Supervisor: ${sup_ok}"
  echo "Chrome   : ${chrome_ok}"

  echo
  echo "${C_BOLD}Certyfikaty wygasające < 14 dni${C_RESET}"
  hm_discover_sites
  local domain cert status days expiry found=0
  local total="${#HM_SITES_LIST[@]}" i=0
  local -a alerts=()
  for domain in "${HM_SITES_LIST[@]}"; do
    i=$((i + 1))
    hm_progress_bar "${i}" "${total}" "Sprawdzanie certyfikatu SSL: ${domain}"
    cert="$(hm_ssl_paths_for_domain "${domain}" 2>/dev/null || true)"
    [[ -n "${cert}" ]] || continue
    status="$(hm_ssl_status "${cert}" 14)"
    case "${status}" in
      expired|soon)
        found=1
        days="$(hm_ssl_days_left "${cert}" 2>/dev/null || echo "?")"
        expiry="$(hm_ssl_expiry "${cert}")"
        if [[ "${status}" == "expired" ]]; then
          alerts+=("EXPIRED|${domain}|${expiry}|${days}")
        else
          alerts+=("SOON|${domain}|${expiry}|${days}")
        fi
        ;;
    esac
  done
  hm_progress_done
  local a
  for a in "${alerts[@]}"; do
    IFS='|' read -r status domain expiry days <<<"${a}"
    if [[ "${status}" == "EXPIRED" ]]; then
      hm_err "  EXPIRED  ${domain}  (${expiry}, ${days} dni)"
    else
      hm_warn "  SOON     ${domain}  (${expiry}, ${days} dni)"
    fi
  done
  if [[ "${found}" -eq 0 ]]; then
    hm_ok "Brak certyfikatów wygasających w ciągu 14 dni."
  fi

  echo
  # skrócony audyt portów (pełny: security ports)
  if hm_have_cmd ss; then
    echo "${C_BOLD}Publiczne porty wrażliwe${C_RESET} ${C_DIM}(security ports)${C_RESET}"
    local hit=0
    while IFS= read -r line; do
      [[ -n "${line}" ]] || continue
      hit=1
      hm_warn "  ${line}"
    done < <(ss -lntup 2>/dev/null | awk '
      NR==1 { next }
      $4 ~ /^0\.0\.0\.0:|^\[::\]:|^\*:/ {
        n=split($4,a,":"); port=a[n]
        if (port ~ /^(3306|5432|6379|7080|8090|3000|3001|3002|3003)$/)
          print $4, $NF
      }
    ')
    if [[ "${hit}" -eq 0 ]]; then
      hm_ok "Brak typowych wrażliwych portów na 0.0.0.0."
    fi
  fi

  echo
  hm_info "Szczegóły procesów: health --ram  |  health --cpu  (opcjonalnie --count N)"
}

hm_health_failed_services() {
  # wypisz nazwy failed units (jedna na linię)
  if ! hm_have_cmd systemctl; then
    return 0
  fi
  systemctl --failed --no-legend --plain 2>/dev/null \
    | awk 'NF{print $1}' || true
}

# health --check: zbiera alerty; stdout tekst lub JSON; rc=1 gdy coś nie tak.
# hm_health_check [--disk N] [--ssl-days N] [--services] [--notify] [--json]
hm_health_check() {
  hm_load_config 2>/dev/null || true
  local disk_thr="${HEALTH_WATCH_DISK:-90}"
  local ssl_days="${HEALTH_WATCH_SSL_DAYS:-14}"
  local do_svc=1 do_notify=0 do_json=0
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --disk) disk_thr="${2:-90}"; shift 2 || true ;;
      --disk=*) disk_thr="${1#*=}"; shift ;;
      --ssl-days) ssl_days="${2:-14}"; shift 2 || true ;;
      --ssl-days=*) ssl_days="${1#*=}"; shift ;;
      --services) do_svc=1; shift ;;
      --no-services) do_svc=0; shift ;;
      --notify) do_notify=1; shift ;;
      --json) do_json=1; shift ;;
      *) shift ;;
    esac
  done
  [[ "${disk_thr}" =~ ^[0-9]+$ ]] || disk_thr=90
  [[ "${ssl_days}" =~ ^[0-9]+$ ]] || ssl_days=14

  hm_detect_all 2>/dev/null || true
  hm_discover_sites 2>/dev/null || true

  local -a alerts=()
  local used
  used="$(hm_disk_used_percent / 2>/dev/null || echo 0)"
  used="${used%%%}"
  if [[ "${used}" =~ ^[0-9]+$ ]] && [[ "${used}" -ge "${disk_thr}" ]]; then
    alerts+=("disk:used=${used}%>=${disk_thr}%")
  fi

  local domain cert status days
  for domain in "${HM_SITES_LIST[@]:-}"; do
    [[ -n "${domain}" ]] || continue
    cert="$(hm_ssl_paths_for_domain "${domain}" 2>/dev/null || true)"
    [[ -n "${cert}" && -f "${cert}" ]] || continue
    status="$(hm_ssl_status "${cert}" "${ssl_days}" 2>/dev/null || echo unknown)"
    case "${status}" in
      expired|soon)
        days="$(hm_ssl_days_left "${cert}" 2>/dev/null || echo '?')"
        alerts+=("ssl:${domain}:${status}:days=${days}")
        ;;
    esac
  done

  if [[ "${do_svc}" -eq 1 ]]; then
    local u
    while IFS= read -r u; do
      [[ -n "${u}" ]] || continue
      alerts+=("service:failed:${u}")
    done < <(hm_health_failed_services)
  fi

  local rc=0
  if [[ "${#alerts[@]}" -gt 0 ]]; then
    rc=1
  fi

  if [[ "${do_json}" -eq 1 ]]; then
    local aj="[]"
    if [[ "${#alerts[@]}" -gt 0 ]]; then
      aj="$(printf '%s\n' "${alerts[@]}" | awk 'BEGIN{printf "["} {printf sep "\"%s\"", $0; sep=","} END{printf "]"}')"
    fi
    printf '{"ok":%s,"alerts":%s,"disk_used":%s}\n' \
      "$([[ "${rc}" -eq 0 ]] && echo true || echo false)" \
      "${aj}" \
      "${used:-0}"
  else
    if [[ "${rc}" -eq 0 ]]; then
      hm_ok "health check: OK (disk ${used}%, ssl≥${ssl_days}d, services)"
    else
      hm_err "health check: ${#alerts[@]} alert(ów)"
      local a
      for a in "${alerts[@]}"; do
        echo "  - ${a}"
      done
    fi
  fi

  if [[ "${do_notify}" -eq 1 ]] && declare -F hm_notify >/dev/null 2>&1; then
    if [[ "${rc}" -ne 0 ]]; then
      local body
      body="$(printf '%s\n' "${alerts[@]}")"
      # osobne typy dla dysku / ssl / services — dedup per typ
      local has_disk=0 has_ssl=0 has_svc=0
      for a in "${alerts[@]}"; do
        case "${a}" in
          disk:*) has_disk=1 ;;
          ssl:*) has_ssl=1 ;;
          service:*) has_svc=1 ;;
        esac
      done
      [[ "${has_disk}" -eq 1 ]] && hm_notify error "Dysk ≥${disk_thr}%" "host=$(hostname)\n${body}" "health.disk"
      [[ "${has_ssl}" -eq 1 ]] && hm_notify error "SSL wygasa <${ssl_days}d" "host=$(hostname)\n${body}" "health.ssl"
      [[ "${has_svc}" -eq 1 ]] && hm_notify error "Usługi failed" "host=$(hostname)\n${body}" "health.services"
    else
      hm_notify ok "Health OK" "host=$(hostname)\ndisk=${used}%" "health.disk"
      hm_notify ok "SSL OK" "host=$(hostname)" "health.ssl"
      hm_notify ok "Services OK" "host=$(hostname)" "health.services"
    fi
  fi
  return "${rc}"
}

hm_health_watch_cron_path() {
  printf '%s' /etc/cron.d/hmtools-watch
}

hm_health_watch_install() {
  hm_load_config
  local disk_thr="${HEALTH_WATCH_DISK:-90}" ssl_days="${HEALTH_WATCH_SSL_DAYS:-14}" do_svc=1
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --disk) disk_thr="${2:-90}"; shift 2 || true ;;
      --disk=*) disk_thr="${1#*=}"; shift ;;
      --ssl-days) ssl_days="${2:-14}"; shift 2 || true ;;
      --ssl-days=*) ssl_days="${1#*=}"; shift ;;
      --services) do_svc=1; shift ;;
      --no-services) do_svc=0; shift ;;
      *) shift ;;
    esac
  done
  local f bin logf svc_flag=""
  f="$(hm_health_watch_cron_path)"
  bin="$(command -v hmtools 2>/dev/null || echo "${HMTOOLS_ROOT}/bin/hmtools")"
  logf="${LOG_DIR:-/hm-tools/logs}/health-watch.log"
  mkdir -p "$(dirname "${logf}")" 2>/dev/null || true
  [[ "${do_svc}" -eq 1 ]] && svc_flag=" --services"

  if [[ ! -w "$(dirname "${f}")" ]] && [[ "$(id -u)" -ne 0 ]]; then
    hm_err "Potrzebujesz root, aby zapisać ${f}"
    return 1
  fi
  if ! hm_confirm_plan "health watch install" \
    "Cron co 15 min: health --check --notify." \
    "Zapis ${f}" \
    "Progi: disk>=${disk_thr}% ssl<${ssl_days}d services=$([[ ${do_svc} -eq 1 ]] && echo on || echo off)" \
    "Log: ${logf}"; then
    return 0
  fi
  cat > "${f}" <<EOF
# hmtools — health watch (zarządzane przez: health watch)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""

*/15 * * * * root ${bin} -c "health --check --disk ${disk_thr} --ssl-days ${ssl_days}${svc_flag} --notify" >> ${logf} 2>&1
EOF
  chmod 644 "${f}"
  hm_ok "Włączono health watch → ${f}"
}

hm_health_watch_disable() {
  local f
  f="$(hm_health_watch_cron_path)"
  [[ -f "${f}" ]] || { hm_info "health watch już wyłączony."; return 0; }
  if ! hm_confirm_plan "health watch disable" "" "Usunięcie ${f}"; then
    return 0
  fi
  rm -f "${f}"
  hm_ok "Wyłączono health watch."
}

hm_health_watch_status() {
  local f
  f="$(hm_health_watch_cron_path)"
  echo "${C_BOLD}health watch${C_RESET}"
  if [[ -f "${f}" ]]; then
    echo "  Status: włączony (${f})"
    sed 's/^/  /' "${f}"
  else
    echo "  Status: wyłączony"
  fi
  echo "  HEALTH_WATCH_DISK=${HEALTH_WATCH_DISK:-90}"
  echo "  HEALTH_WATCH_SSL_DAYS=${HEALTH_WATCH_SSL_DAYS:-14}"
}

cmd_health() {
  local do_ram=0 do_cpu=0 do_check=0 do_live=0 saw_interval=0
  local count="" interval=2 arg
  local -a check_args=()

  # health watch …
  if [[ "${1:-}" == "watch" ]]; then
    shift || true
    case "${1:-status}" in
      install|enable) shift || true; hm_health_watch_install "$@" ;;
      disable|off) hm_health_watch_disable ;;
      status|"") hm_health_watch_status ;;
      help|-h|--help) echo "Użycie: health watch install|status|disable [--disk N] [--ssl-days N]" ;;
      *) hm_err "Nieznane: health watch ${1}"; return 1 ;;
    esac
    return $?
  fi

  while [[ $# -gt 0 ]]; do
    arg="${1}"
    case "${arg}" in
      --check|check)
        do_check=1
        shift
        ;;
      --disk|--ssl-days|--services|--no-services|--notify|--json)
        check_args+=("${arg}")
        if [[ "${arg}" == --disk || "${arg}" == --ssl-days ]]; then
          shift
          check_args+=("${1:-}")
        fi
        shift
        ;;
      --disk=*|--ssl-days=*)
        check_args+=("${arg}")
        shift
        ;;
      --ram|-r)
        do_ram=1
        shift
        ;;
      --cpu|-c)
        do_cpu=1
        shift
        ;;
      --live|-f|live)
        do_live=1
        shift
        ;;
      --interval)
        shift
        [[ -n "${1:-}" && "${1}" =~ ^[0-9]+$ ]] || {
          hm_err "Użycie: health --live --interval <N>  (N ≥ 2)"
          return 1
        }
        interval="${1}"
        saw_interval=1
        shift
        ;;
      --interval=*)
        interval="${arg#--interval=}"
        [[ "${interval}" =~ ^[0-9]+$ ]] || {
          hm_err "Użycie: health --live --interval <N>  (N ≥ 2)"
          return 1
        }
        saw_interval=1
        shift
        ;;
      --count)
        shift
        [[ -n "${1:-}" && "${1}" =~ ^[1-9][0-9]*$ ]] || {
          hm_err "Użycie: health --ram|--cpu --count <N>  (N ≥ 1)"
          return 1
        }
        count="${1}"
        shift
        ;;
      --count=*)
        count="${arg#--count=}"
        [[ "${count}" =~ ^[1-9][0-9]*$ ]] || {
          hm_err "Użycie: health --ram|--cpu --count <N>  (N ≥ 1)"
          return 1
        }
        shift
        ;;
      help|-h|--help)
        hm_help_topic health
        return 0
        ;;
      *)
        hm_err "Nieznane: ${arg}. health help"
        return 1
        ;;
    esac
  done

  if [[ "${do_check}" -eq 1 ]]; then
    hm_health_check "${check_args[@]}"
    return $?
  fi

  if [[ -n "${count}" ]] && [[ "${do_ram}" -eq 0 && "${do_cpu}" -eq 0 ]]; then
    hm_err "--count wymaga --ram i/lub --cpu."
    return 1
  fi
  if [[ "${do_live}" -eq 1 ]] && [[ "${do_ram}" -eq 0 && "${do_cpu}" -eq 0 ]]; then
    hm_err "--live wymaga --ram i/lub --cpu."
    return 1
  fi
  if [[ "${saw_interval}" -eq 1 && "${do_live}" -eq 0 ]]; then
    hm_err "--interval wymaga --live."
    return 1
  fi

  hm_detect_all

  # bez flag = klasyczny overview
  if [[ "${do_ram}" -eq 0 && "${do_cpu}" -eq 0 ]]; then
    hm_health_overview
    return 0
  fi

  # mapa domen do kolumny SITE
  hm_discover_sites 2>/dev/null || true

  if [[ "${do_live}" -eq 1 ]]; then
    hm_health_live "${do_ram}" "${do_cpu}" "${count:-15}" "${interval}"
    return $?
  fi

  local need_sep=0
  if [[ "${do_ram}" -eq 1 ]]; then
    hm_health_section_ram "${count:-15}"
    need_sep=1
  fi
  if [[ "${do_cpu}" -eq 1 ]]; then
    [[ "${need_sep}" -eq 1 ]] && echo
    hm_health_section_cpu "${count:-15}"
  fi
}

_hm_cmd_register health cmd_health 0 status
