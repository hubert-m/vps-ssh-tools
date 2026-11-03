#!/usr/bin/env bash
# Moduł: health


_hm_cmd_help health <<'EOF'
Użycie:
  health                         Szybki przegląd: load, RAM, dysk, OLS/MySQL, certy
  health --ram [--count N]       Top procesów wg RAM (RSS) + site/service/cwd
  health --cpu [--count N]       Top procesów wg CPU + site/service/cwd
  health --ram --cpu             Obie sekcje

Domyślnie --count 15. Mapowanie: /home/<domena>, cgroup *.service, cwd z /proc.
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

# Jednostka systemd z cgroup (np. php8.2-fpm.service, redis.service).
hm_health_systemd_unit() {
  local pid="$1" cg unit=""
  [[ -r "/proc/${pid}/cgroup" ]] || return 0
  cg="$(tr '\n' ' ' < "/proc/${pid}/cgroup" 2>/dev/null || true)"
  unit="$(printf '%s\n' "${cg}" | grep -oE '[A-Za-z0-9_@.-]+\.service' | tail -1 || true)"
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

cmd_health() {
  local do_ram=0 do_cpu=0
  local count="" arg

  while [[ $# -gt 0 ]]; do
    arg="${1}"
    case "${arg}" in
      --ram|-r)
        do_ram=1
        shift
        ;;
      --cpu|-c)
        do_cpu=1
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

  if [[ -n "${count}" ]] && [[ "${do_ram}" -eq 0 && "${do_cpu}" -eq 0 ]]; then
    hm_err "--count wymaga --ram i/lub --cpu."
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
