#!/usr/bin/env bash
# services — status / restart / enable / disable usług stosu (tylko zainstalowane)


_hm_cmd_help services <<'EOF'
Użycie:
  services                         Tabela: usługa, active/failed, enabled, uptime, RAM, porty
  services restart <nazwa>         Plan → restart → is-active + port + journal przy błędzie
  services enable|disable <nazwa>  Z ostrzeżeniem o zależnościach
  services status <nazwa>          Szczegóły jednej usługi

Nazwy: lsws, lscpd, mariadb|mysql, postfix, dovecot, pdns, pure-ftpd,
       opendkim, redis, fail2ban, cron, docker, supervisor, sshd
OLS: preferowany soft-reload (hm_ols_reload_soft); sshd: sshd -t przed restartem.
EOF

# Katalog: alias → możliwe unit-y systemd (pierwszy istniejący wygrywa)
hm_services_catalog() {
  cat <<'EOF'
lsws|lsws lshttpd openlitespeed|80 443|OLS / LiteSpeed
lscpd|lscpd|8090|CyberPanel daemon
mariadb|mariadb mysql mysqld|3306|MariaDB / MySQL
postfix|postfix|25 587|MTA
dovecot|dovecot|110 143 993 995|IMAP/POP
pdns|pdns pdns-recursor|53|PowerDNS
pure-ftpd|pure-ftpd pure-ftpd.service|21|FTP
opendkim|opendkim|8891|DKIM
redis|redis redis-server|6379|Redis
fail2ban|fail2ban|—|Fail2Ban
cron|cron crond|—|Cron
docker|docker docker.service|—|Docker
supervisor|supervisor supervisord|—|Supervisor
sshd|sshd ssh|22|OpenSSH
EOF
}

hm_services_resolve_unit() {
  local alias="$1"
  local line units u
  line="$(hm_services_catalog | awk -F'|' -v a="${alias}" '$1==a {print; exit}')"
  [[ -n "${line}" ]] || return 1
  units="$(echo "${line}" | cut -d'|' -f2)"
  for u in ${units}; do
    u="${u%.service}"
    if hm_services_unit_exists "${u}"; then
      printf '%s' "${u}"
      return 0
    fi
  done
  return 1
}

hm_services_unit_exists() {
  local u="$1"
  [[ -n "${u}" ]] || return 1
  hm_have_cmd systemctl || return 1
  if systemctl cat "${u}.service" >/dev/null 2>&1; then
    return 0
  fi
  systemctl list-unit-files "${u}.service" --no-legend 2>/dev/null \
    | grep -qE "^${u}\\.service"
}

hm_services_alias_for_arg() {
  # normalizacja: mysql→mariadb, ftp→pure-ftpd, …
  local a
  a="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "${a}" in
    mysql|mysqld|mariadb) echo "mariadb" ;;
    ftp|pureftpd|pure-ftp) echo "pure-ftpd" ;;
    ols|litespeed|lshttpd|openlitespeed|lsws) echo "lsws" ;;
    ssh|sshd) echo "sshd" ;;
    crond|cron) echo "cron" ;;
    redis-server|redis) echo "redis" ;;
    supervisord|supervisor) echo "supervisor" ;;
    powerdns|pdns-recursor|pdns) echo "pdns" ;;
    *) echo "${a}" ;;
  esac
}

hm_services_ports_hint() {
  local alias="$1"
  hm_services_catalog | awk -F'|' -v a="${alias}" '$1==a {print $3; exit}'
}

hm_services_desc() {
  local alias="$1"
  hm_services_catalog | awk -F'|' -v a="${alias}" '$1==a {print $4; exit}'
}

hm_services_is_active() {
  local unit="$1"
  systemctl is-active --quiet "${unit}" 2>/dev/null
}

hm_services_active_str() {
  local unit="$1" s
  # systemctl is-active wypisuje stan i rc≠0 dla failed/inactive — NIE doklejać || echo
  s="$(systemctl is-active "${unit}" 2>/dev/null || true)"
  s="$(printf '%s' "${s}" | tr -d '\r' | head -1 | tr -d '[:space:]')"
  [[ -n "${s}" ]] || s="unknown"
  case "${s}" in
    active) printf '%s' "active" ;;
    failed) printf '%s' "failed" ;;
    *) printf '%s' "${s}" ;;
  esac
}

hm_services_enabled_str() {
  local unit="$1" s
  s="$(systemctl is-enabled "${unit}" 2>/dev/null || true)"
  s="$(printf '%s' "${s}" | tr -d '\r' | head -1 | tr -d '[:space:]')"
  [[ -n "${s}" ]] || s="-"
  printf '%s' "${s}"
}

hm_services_uptime_str() {
  local unit="$1" ts epoch now
  ts="$(systemctl show -p ActiveEnterTimestamp --value "${unit}" 2>/dev/null || true)"
  [[ -n "${ts}" && "${ts}" != "n/a" && "${ts}" != "0" ]] || { echo "-"; return 0; }
  epoch="$(date -d "${ts}" +%s 2>/dev/null || true)"
  [[ -n "${epoch}" ]] || { echo "-"; return 0; }
  now="$(date +%s)"
  local d=$((now - epoch))
  if [[ "${d}" -lt 60 ]]; then
    echo "${d}s"
  elif [[ "${d}" -lt 3600 ]]; then
    echo "$((d / 60))m"
  elif [[ "${d}" -lt 86400 ]]; then
    echo "$((d / 3600))h"
  else
    echo "$((d / 86400))d"
  fi
}

hm_services_memory_str() {
  local unit="$1" mem
  mem="$(systemctl show -p MemoryCurrent --value "${unit}" 2>/dev/null || true)"
  if [[ -n "${mem}" && "${mem}" =~ ^[0-9]+$ && "${mem}" -gt 0 && "${mem}" != "18446744073709551615" ]]; then
    hm_human_size "${mem}" 2>/dev/null || echo "${mem}"
    return 0
  fi
  # fallback: suma RSS MainPID + ControlGroup (przybliżenie)
  local pid
  pid="$(systemctl show -p MainPID --value "${unit}" 2>/dev/null || true)"
  if [[ -n "${pid}" && "${pid}" =~ ^[0-9]+$ && "${pid}" -gt 0 ]]; then
    local rss
    rss="$(ps -o rss= -p "${pid}" 2>/dev/null | tr -d ' ' || true)"
    if [[ -n "${rss}" && "${rss}" =~ ^[0-9]+$ ]]; then
      hm_human_size "$((rss * 1024))" 2>/dev/null || echo "${rss}k"
      return 0
    fi
  fi
  echo "-"
}

# Porty nasłuchu powiązane z MainPID (lub dziećmi) jednostki
hm_services_listen_ports() {
  local unit="$1"
  local pid
  pid="$(systemctl show -p MainPID --value "${unit}" 2>/dev/null || true)"
  [[ -n "${pid}" && "${pid}" =~ ^[0-9]+$ && "${pid}" -gt 1 ]] || { echo "-"; return 0; }
  if ! hm_have_cmd ss; then
    echo "-"
    return 0
  fi
  local ports
  ports="$(ss -ltnp 2>/dev/null | awk -v p="${pid}" '
    index($0, "pid=" p ",") || index($0, "pid=" p ")") {
      split($4, a, ":");
      port=a[length(a)];
      gsub(/\]/, "", port);
      if (port ~ /^[0-9]+$/) print port;
    }
  ' | sort -n | uniq | tr '\n' ',' | sed 's/,$//')"
  [[ -n "${ports}" ]] && echo "${ports}" || echo "-"
}

hm_services_list_installed() {
  # wypisz aliasy zainstalowanych usług
  local line alias
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    alias="${line%%|*}"
    if hm_services_resolve_unit "${alias}" >/dev/null 2>&1; then
      printf '%s\n' "${alias}"
    fi
  done < <(hm_services_catalog)
}

hm_services_color_state() {
  local st="$1"
  case "${st}" in
    active) printf '%s%s%s' "${C_GREEN:-}" "${st}" "${C_RESET:-}" ;;
    failed|inactive|deactivating)
      printf '%s%s%s' "${C_RED:-}" "${st}" "${C_RESET:-}"
      ;;
    *) printf '%s' "${st}" ;;
  esac
}

cmd_services_table() {
  hm_detect_all 2>/dev/null || true
  if ! hm_have_cmd systemctl; then
    hm_err "Brak systemctl — services niedostępne."
    return 1
  fi
  echo "${C_BOLD}Usługi stosu (tylko zainstalowane)${C_RESET}"
  printf '  %-12s %-10s %-10s %-8s %-10s %s\n' "SERVICE" "ACTIVE" "ENABLED" "UPTIME" "RAM" "PORTS"
  printf '  %-12s %-10s %-10s %-8s %-10s %s\n' "-------" "------" "-------" "------" "---" "-----"
  local alias unit st en up mem ports any=0
  while IFS= read -r alias; do
    [[ -n "${alias}" ]] || continue
    unit="$(hm_services_resolve_unit "${alias}")" || continue
    any=1
    st="$(hm_services_active_str "${unit}")"
    en="$(hm_services_enabled_str "${unit}")"
    up="$(hm_services_uptime_str "${unit}")"
    mem="$(hm_services_memory_str "${unit}")"
    ports="$(hm_services_listen_ports "${unit}")"
    printf '  %-12s ' "${alias}"
    # kolor tylko dla active kolumny — szerokość ANSI
    if [[ "${st}" == "failed" ]]; then
      printf '%s%-10s%s' "${C_RED:-}" "${st}" "${C_RESET:-}"
    elif [[ "${st}" == "active" ]]; then
      printf '%s%-10s%s' "${C_GREEN:-}" "${st}" "${C_RESET:-}"
    else
      printf '%-10s' "${st}"
    fi
    printf ' %-10s %-8s %-10s %s\n' "${en}" "${up}" "${mem}" "${ports}"
  done < <(hm_services_list_installed)
  if [[ "${any}" -eq 0 ]]; then
    hm_warn "Nie wykryto żadnej znanej usługi."
  fi
}

hm_services_journal_tail() {
  local unit="$1" n="${2:-20}"
  echo "${C_BOLD}journalctl -u ${unit} -n ${n}${C_RESET}"
  journalctl -u "${unit}" -n "${n}" --no-pager 2>/dev/null | sed 's/^/  /' || true
}

hm_services_check_ports_after() {
  local alias="$1" unit="$2"
  local hint p
  hint="$(hm_services_ports_hint "${alias}")"
  [[ -n "${hint}" && "${hint}" != "—" ]] || return 0
  local ok=0
  for p in ${hint}; do
    [[ "${p}" =~ ^[0-9]+$ ]] || continue
    if ss -ltn 2>/dev/null | grep -qE ":${p}\\s"; then
      ok=1
      hm_ok "Port ${p} nasłuchuje."
    else
      hm_warn "Port ${p} nie nasłuchuje po restarcie."
    fi
  done
  [[ "${ok}" -eq 1 || "${hint}" == *"—"* ]] && return 0
  return 1
}

cmd_services_restart() {
  local raw="${1:-}"
  [[ -n "${raw}" ]] || { hm_err "Użycie: services restart <nazwa>"; return 1; }
  local alias unit
  alias="$(hm_services_alias_for_arg "${raw}")"
  unit="$(hm_services_resolve_unit "${alias}")" || {
    hm_err "Usługa nieznana lub niezainstalowana: ${raw}"
    return 1
  }

  local hint
  hint="$(hm_services_ports_hint "${alias}")"
  local -a steps=(
    "Restart ${alias} (unit=${unit})"
    "Weryfikacja is-active + porty (${hint})"
  )

  if [[ "${alias}" == "sshd" ]]; then
    steps+=("sshd -t (test konfiguracji) PRZED restartem")
    steps+=("UWAGA: błąd SSH może odciąć sesję — nie restartuj bez konsoli/IPMI")
  fi
  if [[ "${alias}" == "lsws" ]]; then
    steps+=("Preferowany soft-reload (hm_ols_reload_soft); fallback systemctl restart")
  fi

  if ! hm_confirm_plan "services restart — ${alias}" \
    "Restart wpływa tylko na tę usługę (nie na cały serwer)." \
    "${steps[@]}"; then
    return 0
  fi

  if [[ "${alias}" == "sshd" ]]; then
    if hm_have_cmd sshd; then
      if ! sshd -t 2>/dev/null; then
        hm_err "sshd -t nieudany — odmowa restartu."
        sshd -t 2>&1 | sed 's/^/  /' || true
        return 1
      fi
      hm_ok "sshd -t OK."
    fi
  fi

  local rc=0
  if [[ "${alias}" == "lsws" ]]; then
    if hm_ols_reload_soft; then
      hm_ok "OLS soft-reload OK."
    else
      hm_warn "soft-reload nieudany — systemctl restart ${unit}"
      hm_run systemctl restart "${unit}" || rc=$?
    fi
  else
    hm_run systemctl restart "${unit}" || rc=$?
  fi

  sleep 0.5 2>/dev/null || true
  local st
  st="$(hm_services_active_str "${unit}")"
  if [[ "${st}" != "active" ]]; then
    hm_err "Po restarcie: ${unit} → ${st}"
    hm_services_journal_tail "${unit}" 20
    return 1
  fi
  hm_ok "${alias} active."
  hm_services_check_ports_after "${alias}" "${unit}" || true
  return "${rc}"
}

cmd_services_enable_disable() {
  local action="$1" raw="${2:-}"
  [[ -n "${raw}" ]] || { hm_err "Użycie: services ${action} <nazwa>"; return 1; }
  local alias unit
  alias="$(hm_services_alias_for_arg "${raw}")"
  unit="$(hm_services_resolve_unit "${alias}")" || {
    hm_err "Usługa nieznana/niezainstalowana: ${raw}"
    return 1
  }
  local warn=""
  case "${alias}" in
    pdns) warn="Wyłączenie DNS może zerwać resolve dla domen na tym VPS." ;;
    postfix|dovecot) warn="Wpływ na pocztę (SMTP/IMAP)." ;;
    mariadb) warn="Bazy WWW przestaną działać." ;;
    lsws) warn="Cały WWW (OLS) przestanie serwować." ;;
    sshd) warn="Ryzyko utraty dostępu SSH." ;;
    docker) warn="Kontenery nie startują po reboot." ;;
  esac
  local -a steps=("systemctl ${action} ${unit}")
  [[ -n "${warn}" ]] && steps+=("UWAGA: ${warn}")
  if ! hm_confirm_plan "services ${action} — ${alias}" \
    "${warn}" \
    "${steps[@]}"; then
    return 0
  fi
  hm_run systemctl "${action}" "${unit}"
}

cmd_services_one() {
  local raw="${1:-}" alias unit
  alias="$(hm_services_alias_for_arg "${raw}")"
  unit="$(hm_services_resolve_unit "${alias}")" || {
    hm_err "Brak: ${raw}"
    return 1
  }
  echo "${C_BOLD}${alias}${C_RESET}  unit=${unit}  $(hm_services_desc "${alias}")"
  echo "  active : $(hm_services_active_str "${unit}")"
  echo "  enabled: $(hm_services_enabled_str "${unit}")"
  echo "  uptime : $(hm_services_uptime_str "${unit}")"
  echo "  memory : $(hm_services_memory_str "${unit}")"
  echo "  ports  : $(hm_services_listen_ports "${unit}") (hint: $(hm_services_ports_hint "${alias}"))"
  systemctl status "${unit}" --no-pager -l 2>/dev/null | head -25 | sed 's/^/  /' || true
}

cmd_services() {
  local sub="${1:-}"
  shift || true
  case "${sub}" in
    ""|list|ls|status)
      if [[ -n "${1:-}" && "${sub}" == "status" ]]; then
        cmd_services_one "$1"
      elif [[ -n "${1:-}" && "${sub}" != "list" && "${sub}" != "ls" && "${sub}" != "" ]]; then
        cmd_services_one "${sub}"
      else
        cmd_services_table
      fi
      ;;
    restart|reload)
      cmd_services_restart "$@"
      ;;
    enable|disable)
      cmd_services_enable_disable "${sub}" "$@"
      ;;
    help|-h|--help)
      hm_help_topic services
      ;;
    *)
      # services postfix → status one
      if hm_services_resolve_unit "$(hm_services_alias_for_arg "${sub}")" >/dev/null 2>&1; then
        cmd_services_one "${sub}"
      else
        hm_err "Nieznane: services ${sub}. services help"
        return 1
      fi
      ;;
  esac
}

_hm_cmd_register services cmd_services 0
