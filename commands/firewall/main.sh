#!/usr/bin/env bash
# Komenda: firewall — porty/reguły (ufw/firewalld/CSF) przez hm_os_*


_hm_cmd_help firewall <<'EOF'
Użycie:
  firewall | status            Backend + reguły
  firewall allow <port[/proto]> [--from IP] [--comment "…"]
  firewall deny  <port[/proto]> [--from IP] [--comment "…"]
  firewall remove <nr|port/proto|from:IP>
  firewall whitelist <IP>      Trwałe allow from IP (+ Fail2Ban ignoreip)

Ochrona: nie zablokujesz portu SSH ani IP sesji bez --force + drugiego potwierdzenia.
Porty CyberPanel (8090, 7080, 21, 40110-40210): ostrzeżenie przy deny/remove.
EOF

# Porty krytyczne CP / FTP passive (ostrzeżenie)
HM_FIREWALL_CP_PORTS="8090 7080 21 40110 40210"

hm_firewall_parse_port_spec() {
  # stdin nic; $1=8443/tcp|8443 → ustawia HM_FW_PORT / HM_FW_PROTO
  local spec="${1:-}"
  HM_FW_PORT=""
  HM_FW_PROTO="tcp"
  [[ -n "${spec}" ]] || return 1
  if [[ "${spec}" == */* ]]; then
    HM_FW_PORT="${spec%%/*}"
    HM_FW_PROTO="${spec##*/}"
  else
    HM_FW_PORT="${spec}"
  fi
  [[ "${HM_FW_PORT}" =~ ^[0-9]+$ ]] || return 1
  ((10#${HM_FW_PORT} >= 1 && 10#${HM_FW_PORT} <= 65535)) || return 1
  case "${HM_FW_PROTO}" in
    tcp|udp|any) ;;
    *) return 1 ;;
  esac
  return 0
}

hm_firewall_sshd_port() {
  local conf="/etc/ssh/sshd_config" p
  p="$(awk 'tolower($1)=="port"{v=$2} END{print v}' "${conf}" 2>/dev/null || true)"
  printf '%s' "${p:-22}"
}

hm_firewall_is_ssh_port() {
  local port="$1" sshp
  sshp="$(hm_firewall_sshd_port)"
  [[ "${port}" == "${sshp}" ]]
}

hm_firewall_is_cp_port() {
  local port="$1" p
  for p in ${HM_FIREWALL_CP_PORTS}; do
    [[ "${port}" == "${p}" ]] && return 0
  done
  # zakres FTP passive 40110-40210
  if [[ "${port}" =~ ^[0-9]+$ ]] && ((10#${port} >= 40110 && 10#${port} <= 40210)); then
    return 0
  fi
  return 1
}

hm_firewall_protect_ssh_deny() {
  # blokada deny/remove portu SSH lub IP sesji bez --force
  local port="${1:-}" from="${2:-}" force="${3:-0}"
  local mine
  mine="$(hm_session_ssh_ip 2>/dev/null || true)"

  if [[ -n "${port}" ]] && hm_firewall_is_ssh_port "${port}"; then
    hm_err "Port ${port} to port SSH — odmowa bez --force."
    if [[ "${force}" -ne 1 ]]; then
      return 1
    fi
    if ! hm_confirm_plan_critical "SSH" "firewall deny SSH port ${port}" \
      "Możesz odciąć WSZYSTKIE sesje SSH." \
      "Zmiana reguły firewall dla portu SSH ${port}"; then
      return 1
    fi
  fi

  if [[ -n "${from}" && -n "${mine}" && "${from}" == "${mine}" ]]; then
    hm_err "IP ${from} to IP bieżącej sesji SSH."
    if [[ "${force}" -ne 1 ]]; then
      hm_info "Użyj --force i potwierdź domenę-marker SSH."
      return 1
    fi
    if ! hm_confirm_plan_critical "SSH" "firewall deny własnego IP ${from}" \
      "Możesz odciąć bieżącą sesję." \
      "Deny/remove dla IP sesji ${from}"; then
      return 1
    fi
  fi
  return 0
}

hm_firewall_fail2ban_ignore() {
  local ip="$1"
  hm_have_cmd fail2ban-client || return 0
  # best-effort: setignoreip append — wiele instalacji czyta jail.local
  local jlocal="/etc/fail2ban/jail.local"
  if [[ -f "${jlocal}" ]] || [[ -d /etc/fail2ban ]]; then
    if ! grep -qE "^[[:space:]]*ignoreip[[:space:]]*=.*[[:space:]]${ip}([[:space:]]|$)" "${jlocal}" 2>/dev/null; then
      if [[ -f "${jlocal}" ]]; then
        if grep -qE '^[[:space:]]*ignoreip[[:space:]]*=' "${jlocal}" 2>/dev/null; then
          # dopisz IP do istniejącej linii ignoreip (pierwsza)
          local tmp
          tmp="$(hm_mktemp .f2b)"
          awk -v ip="${ip}" '
            BEGIN{done=0}
            /^[[:space:]]*ignoreip[[:space:]]*=/ && !done {
              if ($0 ~ "(^|[[:space:]])" ip "([[:space:]]|$)") { print; done=1; next }
              print $0 " " ip
              done=1; next
            }
            { print }
            END { if (!done) print "ignoreip = 127.0.0.1/8 ::1 " ip }
          ' "${jlocal}" > "${tmp}"
          cat "${tmp}" > "${jlocal}"
          rm -f "${tmp}"
        else
          printf '\n[DEFAULT]\nignoreip = 127.0.0.1/8 ::1 %s\n' "${ip}" >> "${jlocal}"
        fi
      else
        mkdir -p /etc/fail2ban
        printf '[DEFAULT]\nignoreip = 127.0.0.1/8 ::1 %s\n' "${ip}" > "${jlocal}"
      fi
      fail2ban-client reload >/dev/null 2>&1 || true
    fi
  fi
  return 0
}

cmd_firewall() {
  local sub="${1:-status}"
  shift || true
  hm_detect_all 2>/dev/null || true

  case "${sub}" in
    ""|status|stat|list|ls)
      echo "${C_BOLD}Firewall${C_RESET}  backend=$(hm_os_firewall_backend)"
      echo "  SSH port: $(hm_firewall_sshd_port)  session IP: $(hm_session_ssh_ip 2>/dev/null || echo '-')"
      echo
      hm_os_firewall_list || hm_os_firewall_status || true
      ;;
    allow|open)
      hm_firewall_cmd_allow "$@"
      ;;
    deny|block|reject)
      hm_firewall_cmd_deny "$@"
      ;;
    remove|delete|del|rm)
      hm_firewall_cmd_remove "$@"
      ;;
    whitelist|wl|allow-ip)
      hm_firewall_cmd_whitelist "$@"
      ;;
    help|-h|--help)
      hm_help_topic firewall
      ;;
    *)
      hm_err "Nieznane: firewall ${sub}. firewall help"
      return 1
      ;;
  esac
}

hm_firewall_cmd_allow() {
  local spec="" from="" comment="" force=0 auto_yes=0
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --from) from="${2:-}"; shift 2 || true ;;
      --from=*) from="${1#*=}"; shift ;;
      --comment|-m) comment="${2:-}"; shift 2 || true ;;
      --comment=*) comment="${1#*=}"; shift ;;
      --force|-f) force=1; shift ;;
      --yes|-y) auto_yes=1; shift ;;
      -*)
        hm_err "Nieznana flaga: ${1}"; return 1 ;;
      *)
        [[ -z "${spec}" ]] && spec="${1}" || { hm_err "Niespodziewany: ${1}"; return 1; }
        shift
        ;;
    esac
  done
  hm_firewall_parse_port_spec "${spec}" || { hm_err "Użycie: firewall allow <port[/tcp|udp]> [--from IP]"; return 1; }
  if [[ -n "${from}" ]] && ! hm_is_valid_ip "${from}"; then
    hm_err "Nieprawidłowe IP: ${from}"; return 1
  fi
  local -a steps=(
    "Backend: $(hm_os_firewall_backend)"
    "ALLOW ${HM_FW_PORT}/${HM_FW_PROTO}${from:+ from ${from}}"
  )
  [[ -n "${comment}" ]] && steps+=("Komentarz: ${comment}")
  if [[ "${auto_yes}" -eq 1 ]]; then
    hm_confirm_plan "firewall allow ${HM_FW_PORT}" "" --yes "${steps[@]}" || return 1
  else
    hm_confirm_plan "firewall allow ${HM_FW_PORT}" "" "${steps[@]}" || return 0
  fi
  if hm_os_firewall_allow "${HM_FW_PORT}" "${HM_FW_PROTO}" "${from}" "${comment}"; then
    hm_ok "ALLOW ${HM_FW_PORT}/${HM_FW_PROTO}${from:+ from ${from}}"
  else
    hm_err "Nie udało się dodać reguły ALLOW."
    return 1
  fi
}

hm_firewall_cmd_deny() {
  local spec="" from="" comment="" force=0 auto_yes=0
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --from) from="${2:-}"; shift 2 || true ;;
      --from=*) from="${1#*=}"; shift ;;
      --comment|-m) comment="${2:-}"; shift 2 || true ;;
      --comment=*) comment="${1#*=}"; shift ;;
      --force|-f) force=1; shift ;;
      --yes|-y) auto_yes=1; shift ;;
      -*) hm_err "Nieznana flaga: ${1}"; return 1 ;;
      *)
        [[ -z "${spec}" ]] && spec="${1}" || { hm_err "Niespodziewany: ${1}"; return 1; }
        shift
        ;;
    esac
  done
  hm_firewall_parse_port_spec "${spec}" || { hm_err "Użycie: firewall deny <port[/proto]> [--from IP]"; return 1; }
  if [[ -n "${from}" ]] && ! hm_is_valid_ip "${from}"; then
    hm_err "Nieprawidłowe IP: ${from}"; return 1
  fi
  hm_firewall_protect_ssh_deny "${HM_FW_PORT}" "${from}" "${force}" || return 1
  if hm_firewall_is_cp_port "${HM_FW_PORT}"; then
    hm_warn "Port ${HM_FW_PORT} jest używany przez CyberPanel/FTP — zamknięcie może zepsuć panel/FTP."
  fi
  local -a steps=(
    "Backend: $(hm_os_firewall_backend)"
    "DENY ${HM_FW_PORT}/${HM_FW_PROTO}${from:+ from ${from}}"
  )
  if [[ "${auto_yes}" -eq 1 ]]; then
    hm_confirm_plan "firewall deny ${HM_FW_PORT}" "Możliwe odcięcie usług." --yes "${steps[@]}" || return 1
  else
    hm_confirm_plan "firewall deny ${HM_FW_PORT}" "Możliwe odcięcie usług." "${steps[@]}" || return 0
  fi
  if hm_os_firewall_deny "${HM_FW_PORT}" "${HM_FW_PROTO}" "${from}" "${comment}"; then
    hm_ok "DENY ${HM_FW_PORT}/${HM_FW_PROTO}${from:+ from ${from}}"
  else
    hm_err "Nie udało się dodać reguły DENY."
    return 1
  fi
}

hm_firewall_cmd_remove() {
  local spec="${1:-}" force=0
  shift || true
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --force|-f) force=1; shift ;;
      *) shift ;;
    esac
  done
  [[ -n "${spec}" ]] || { hm_err "Użycie: firewall remove <nr|port/proto|from:IP>"; return 1; }

  local port_check=""
  if [[ "${spec}" =~ ^[0-9]+/(tcp|udp)$ || "${spec}" =~ ^[0-9]+$ ]]; then
    port_check="${spec%%/*}"
    hm_firewall_protect_ssh_deny "${port_check}" "" "${force}" || return 1
    if hm_firewall_is_cp_port "${port_check}"; then
      hm_warn "Port ${port_check} wygląda na CyberPanel/FTP."
    fi
  fi
  if [[ "${spec}" == from:* ]]; then
    hm_firewall_protect_ssh_deny "" "${spec#from:}" "${force}" || return 1
  fi

  if ! hm_confirm_plan "firewall remove ${spec}" "" \
    "Backend: $(hm_os_firewall_backend)" \
    "Usunięcie reguły: ${spec}"; then
    return 0
  fi
  if hm_os_firewall_remove "${spec}"; then
    hm_ok "Usunięto: ${spec}"
  else
    hm_err "Nie udało się usunąć: ${spec}"
    return 1
  fi
}

hm_firewall_cmd_whitelist() {
  local ip="${1:-}"
  [[ -n "${ip}" ]] || { hm_err "Użycie: firewall whitelist <IP>"; return 1; }
  hm_is_valid_ip "${ip}" || { hm_err "Nieprawidłowe IP: ${ip}"; return 1; }
  if ! hm_confirm_plan "firewall whitelist ${ip}" "" \
    "ALLOW from ${ip} (wszystkie porty) — przed DENY jeśli możliwe" \
    "Dopisanie do Fail2Ban ignoreip (best-effort)"; then
    return 0
  fi
  if hm_os_firewall_whitelist "${ip}"; then
    hm_firewall_fail2ban_ignore "${ip}" || true
    hm_ok "Whitelist: ${ip}"
  else
    hm_err "Whitelist nieudany dla ${ip}"
    return 1
  fi
}

_hm_cmd_register firewall cmd_firewall 0 fw
