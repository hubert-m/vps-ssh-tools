#!/usr/bin/env bash
# Komenda: security — audyt VPS (porty, firewall, Fail2Ban, SSH, skan docroot)


_hm_cmd_help security <<'EOF'
Użycie:
  security status          Firewall + Fail2Ban + skrót portów
  security ports           Publiczne 0.0.0.0/[::] + alerty (3306/6379/7080/3xxx)
  security ssh             Audyt sshd_config, authorized_keys, lastb
  security ssh set port <N> | password-auth no|yes | root-login <val>
  security ssh confirm     Potwierdź zmianę SSH (anuluje auto-rollback 120 s)
  security fail2ban        Status jaili i zbanowanych IP
  security ban|unban <IP>  Blokada / odbanowanie
  security scan [domena]   Skan heurystyczny docroot (php w uploads, 777, .sql/.env/.git)
  security malware         Silniki ImunifyAV/ClamAV/maldet; schedule / install-clamav
  (w use) malware scan|report|quarantine|restore
  security waf             ModSecurity: status/log/mode/rules; (w use) waf whitelist
  (w use) waf | waf whitelist <ruleId> [--uri …]
  security events [--since 24h] [--notify]
                           Logowania SSH, sudo/su, UID 0, authorized_keys
  security events watch install|status|disable|run
  security audit [--json] [--only ssh|kernel|fs|services|web|php|updates]
  security audit --fix <id>   sysctl tak; sshd tylko przez security ssh set (rollback)

Zmiana portu SSH: otwarcie w firewall → sshd -t → restart → 120 s na confirm, inaczej rollback.
password-auth no tylko gdy root (lub bieżący user) ma niepusty authorized_keys.
EOF

_HM_SEC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=malware.sh
source "${_HM_SEC_DIR}/malware.sh"
# shellcheck source=waf.sh
source "${_HM_SEC_DIR}/waf.sh"
# shellcheck source=events.sh
source "${_HM_SEC_DIR}/events.sh"
# shellcheck source=audit.sh
source "${_HM_SEC_DIR}/audit.sh"

hm_is_valid_ip() {
  local ip="${1:-}"
  [[ -n "${ip}" ]] || return 1
  # IPv4 — oktety 0–255; odrzuć 0.0.0.0 (bezsensowny ban „wszystkiego”)
  if [[ "${ip}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    local o
    for o in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do
      [[ "${o}" =~ ^[0-9]+$ ]] || return 1
      ((10#${o} <= 255)) || return 1
    done
    [[ "${ip}" != "0.0.0.0" ]] || return 1
    return 0
  fi
  # IPv6 — hex + ':', co najwyżej jedno '::', 2–8 hextetów
  [[ "${ip}" == *:* ]] || return 1
  [[ "${ip}" =~ ^[0-9a-fA-F:]+$ ]] || return 1
  [[ "${ip}" =~ [0-9a-fA-F] ]] || return 1
  [[ "${ip}" != : && "${ip}" != :: ]] || return 1
  # więcej niż jedno '::' (np. 1::2::3)
  local _tmp="${ip//::/}"
  local _ncomp=$(( (${#ip} - ${#_tmp}) / 2 ))
  [[ "${_ncomp}" -le 1 ]] || return 1
  # hextety (puste OK tylko przy kompresji ::)
  local _left _right _g _groups=0
  if [[ "${ip}" == *"::"* ]]; then
    _left="${ip%%::*}"
    _right="${ip#*::}"
    [[ "${_right}" != *"::"* ]] || return 1
    if [[ -n "${_left}" ]]; then
      IFS=':' read -r -a _la <<< "${_left}"
      for _g in "${_la[@]}"; do
        [[ -n "${_g}" ]] || return 1
        [[ "${#_g}" -le 4 && "${_g}" =~ ^[0-9a-fA-F]+$ ]] || return 1
        _groups=$((_groups + 1))
      done
    fi
    if [[ -n "${_right}" ]]; then
      IFS=':' read -r -a _ra <<< "${_right}"
      for _g in "${_ra[@]}"; do
        [[ -n "${_g}" ]] || return 1
        [[ "${#_g}" -le 4 && "${_g}" =~ ^[0-9a-fA-F]+$ ]] || return 1
        _groups=$((_groups + 1))
      done
    fi
    # :: musi „zjadać” ≥1 hextet → max 7 jawnych grup
    [[ "${_groups}" -ge 1 && "${_groups}" -le 7 ]] || return 1
  else
    IFS=':' read -r -a _la <<< "${ip}"
    for _g in "${_la[@]}"; do
      [[ -n "${_g}" ]] || return 1
      [[ "${#_g}" -le 4 && "${_g}" =~ ^[0-9a-fA-F]+$ ]] || return 1
      _groups=$((_groups + 1))
    done
    # bez :: — dokładnie 8 hextetów (odrzuca 1:2)
    [[ "${_groups}" -eq 8 ]] || return 1
  fi
  return 0
}

hm_session_ssh_ip() {
  local tip=""
  if [[ -n "${SSH_CLIENT:-}" ]]; then
    tip="${SSH_CLIENT%% *}"
  elif [[ -n "${SSH_CONNECTION:-}" ]]; then
    tip="${SSH_CONNECTION%% *}"
  fi
  [[ -n "${tip}" ]] || return 1
  printf '%s' "${tip}"
}

hm_security_warn_if_self_ip() {
  local ip="${1:-}" mine
  mine="$(hm_session_ssh_ip 2>/dev/null || true)"
  [[ -n "${mine}" && "${mine}" == "${ip}" ]] || return 0
  hm_warn "To jest IP Twojej bieżącej sesji SSH (${mine}) — możesz się odciąć od serwera."
  if ! hm_confirm "Na pewno zablokować własne IP ${ip}?"; then
    return 1
  fi
  return 0
}

cmd_security() {
  local sub="${1:-status}"
  shift || true
  hm_detect_all

  case "${sub}" in
    status|stat)
      cmd_security_status
      ;;
    ports|port)
      cmd_security_ports
      ;;
    ssh)
      cmd_security_ssh "$@"
      ;;
    fail2ban|f2b|banlist)
      cmd_security_fail2ban "$@"
      ;;
    unban)
      cmd_security_unban "$@"
      ;;
    ban)
      cmd_security_ban "$@"
      ;;
    scan)
      cmd_security_scan "$@"
      ;;
    malware|av|clam)
      cmd_security_malware "$@"
      ;;
    waf|modsec|modsecurity)
      cmd_security_waf "$@"
      ;;
    events)
      cmd_security_events "$@"
      ;;
    audit)
      cmd_security_audit "$@"
      ;;
    help|-h|--help)
      hm_help_topic security
      ;;
    *)
      hm_err "Nieznane: security ${sub}. security help"
      return 1
      ;;
  esac
}

cmd_security_status() {
  echo "${C_BOLD}Security — status${C_RESET}"
  echo

  # Firewall (adapter OS_FAMILY: ufw vs firewalld)
  echo "${C_BOLD}Firewall${C_RESET}"
  hm_os_firewall_status || true
  echo

  # Fail2Ban skrót
  echo "${C_BOLD}Fail2Ban${C_RESET}"
  if hm_have_cmd fail2ban-client; then
    fail2ban-client status 2>/dev/null || hm_warn "fail2ban-client status nieudany"
    echo "  Szczegóły jaili: security fail2ban"
  else
    hm_warn "Fail2Ban nie zainstalowany (brak fail2ban-client)."
  fi
  echo

  cmd_security_ports
  echo
  echo "${C_DIM}Więcej: security ssh | security events | security scan | security malware | security waf${C_RESET}"
}

cmd_security_ports() {
  echo "${C_BOLD}Porty publiczne (0.0.0.0 / [::])${C_RESET}"
  if ! hm_have_cmd ss; then
    hm_err "Brak ss (iproute2)."
    return 1
  fi

  # linie: proto local process
  local tmp
  tmp="$(mktemp "${TMP_DIR:-/tmp}/hmtools-ports.XXXXXX")"
  ss -lntup 2>/dev/null | awk 'NR>1 { print }' > "${tmp}" || true

  hm_table_begin RLLL
  hm_table_row PORT ADRES PROCES ALERT

  local line addr port pub=0
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    # Local Address:Port zwykle kolumna 4
    addr="$(echo "${line}" | awk '{print $4}')"
    case "${addr}" in
      0.0.0.0:*|\[::\]:*|\*:*)
        pub=1
        port="${addr##*:}"
        port="${port%\]}"
        ;;
      *)
        continue
        ;;
    esac
    [[ "${port}" =~ ^[0-9]+$ ]] || continue

    local alert="" proc=""
    # ss: users:(("mysqld",pid=…,fd=…))
    if [[ "${line}" =~ users:\(\(\"([^\"]+)\" ]]; then
      proc="${BASH_REMATCH[1]}"
    else
      proc="$(echo "${line}" | awk '{print $NF}')"
    fi

    case "${port}" in
      3306|5432|6379|27017|11211)
        alert="${C_RED}ERR — baza/cache na zewnątrz!${C_RESET}"
        ;;
      7080|8090)
        alert="${C_YELLOW}WARN — panel WebAdmin/CyberPanel publicznie${C_RESET}"
        ;;
      3000|3001|3002|3003|3004|3005|4000|5000|8000|8080|8081)
        alert="${C_YELLOW}WARN — backend app (powinien być localhost + OLS proxy)${C_RESET}"
        ;;
      22|2222)
        alert="${C_DIM}SSH${C_RESET}"
        ;;
      80|443)
        alert="${C_DIM}HTTP(S)${C_RESET}"
        ;;
      *)
        # inne wysokie porty Node
        if [[ "${port}" -ge 3000 && "${port}" -le 3999 ]]; then
          alert="${C_YELLOW}WARN — możliwy backend PM2/Node${C_RESET}"
        fi
        ;;
    esac

    hm_table_row "${port}" "${addr}" "${proc:--}" "${alert:--}"
  done < "${tmp}"
  hm_table_print

  if [[ "${pub}" -eq 0 ]]; then
    hm_ok "Brak oczywistych nasłuchów na 0.0.0.0 / [::] (lub ss pusty)."
  fi
  rm -f "${tmp}"
}

cmd_security_fail2ban() {
  if ! hm_have_cmd fail2ban-client; then
    hm_err "Brak fail2ban-client."
    return 1
  fi
  echo "${C_BOLD}Fail2Ban — jaile${C_RESET}"
  local jails jail
  jails="$(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/{print $2}' | tr ',' ' ')"
  if [[ -z "${jails// /}" ]]; then
    fail2ban-client status 2>/dev/null || true
    return 0
  fi
  for jail in ${jails}; do
    jail="$(echo "${jail}" | tr -d ' ')"
    [[ -n "${jail}" ]] || continue
    echo
    echo "---- ${jail} ----"
    fail2ban-client status "${jail}" 2>/dev/null || true
  done
}

cmd_security_unban() {
  local ip="${1:-}"
  [[ -n "${ip}" ]] || { hm_err "Użycie: security unban <IP>"; return 1; }
  hm_is_valid_ip "${ip}" || { hm_err "Nieprawidłowe IP: ${ip}"; return 1; }

  if ! hm_confirm_plan "security unban — ${ip}" \
    "Odblokowanie adresu IP." \
    "Usunięcie blokady adresu IP ${ip} we wszystkich aktywnych jailach Fail2Ban" \
    "Usunięcie reguły firewall (ufw / firewalld / iptables|ip6tables) dla ${ip}"; then
    return 0
  fi

  if hm_have_cmd fail2ban-client; then
    local jails jail
    jails="$(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/{print $2}' | tr ',' ' ')"
    local any=0
    for jail in ${jails}; do
      jail="$(echo "${jail}" | tr -d ' ')"
      [[ -n "${jail}" ]] || continue
      if fail2ban-client set "${jail}" unbanip "${ip}" 2>/dev/null; then
        hm_ok "Unban ${ip} w jail ${jail}"
        any=1
      fi
    done
    [[ "${any}" -eq 1 ]] || hm_warn "Fail2Ban: IP nie było na liście (lub brak jaili)."
  fi

  if hm_os_firewall_unban "${ip}"; then
    hm_ok "Firewall: usunięto blokadę ${ip}"
  else
    hm_warn "Firewall: brak reguły do usunięcia (lub błąd usuwania / brak ufw/firewalld/iptables)."
  fi
}

cmd_security_ban() {
  local ip="${1:-}"
  [[ -n "${ip}" ]] || { hm_err "Użycie: security ban <IP>"; return 1; }
  hm_is_valid_ip "${ip}" || { hm_err "Nieprawidłowe IP: ${ip}"; return 1; }
  hm_security_warn_if_self_ip "${ip}" || { hm_info "Anulowano ban."; return 0; }

  if ! hm_confirm_plan "security ban — ${ip}" \
    "Blokada adresu IP na firewallu i w Fail2Ban." \
    "Dodanie blokady adresu IP ${ip} we wszystkich aktywnych jailach Fail2Ban" \
    "Dodanie reguły firewall (ufw prepend DENY przed ALLOW — trwałe)" \
    "Nieskuteczny DENY za ALLOW zostanie usunięty przed prepend"; then
    return 1
  fi

  local ok=0 f2b_ok=0 fw_ok=0
  if hm_have_cmd fail2ban-client; then
    local jails jail f2b_any=0
    jails="$(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/{print $2}' | tr ',' ' ')"
    for jail in ${jails}; do
      jail="$(echo "${jail}" | tr -d ' ')"
      [[ -n "${jail}" ]] || continue
      if fail2ban-client set "${jail}" banip "${ip}" 2>/dev/null; then
        hm_ok "Ban ${ip} w jail ${jail}"
        f2b_any=1
        f2b_ok=1
        ok=1
      fi
    done
    [[ "${f2b_any}" -eq 1 ]] || hm_warn "Fail2Ban: nie udało się dodać bana w żadnym jailu (lub brak jaili)."
  fi
  if hm_os_firewall_ban "${ip}"; then
    hm_ok "Firewall: zablokowano ${ip}"
    fw_ok=1
    ok=1
  else
    if [[ "${f2b_ok}" -eq 1 ]]; then
      hm_warn "Fail2Ban OK, ale firewall (ufw/firewalld/iptables) nie zablokował ${ip} — sprawdź reguły (DENY musi być przed ALLOW)."
    fi
  fi
  if [[ "${ok}" -eq 0 ]]; then
    hm_err "Nie udało się zablokować (brak fail2ban / firewall OS)."
    return 1
  fi
  # częściowy sukces (tylko f2b) — rc≠0, żeby nie wyglądało na pełny ban
  if [[ "${f2b_ok}" -eq 1 && "${fw_ok}" -eq 0 ]]; then
    return 1
  fi
  return 0
}

hm_security_sshd_get() {
  local key="$1" conf="${2:-/etc/ssh/sshd_config}"
  awk -v k="$(printf '%s' "${key}" | tr '[:upper:]' '[:lower:]')" '
    tolower($1)==k { v=$2 }
    END { print v }
  ' "${conf}" 2>/dev/null
}

hm_security_sshd_set_directive() {
  # ustaw dyrektywę w conf (cat > zachowuje mode); $1=Key $2=value $3=conf
  local key="$1" val="$2" conf="${3:-/etc/ssh/sshd_config}"
  local tmp
  tmp="$(hm_mktemp .sshd)"
  awk -v k="${key}" -v v="${val}" '
    BEGIN { kl=tolower(k); done=0 }
    {
      if ($0 ~ /^[[:space:]]*#/) { print; next }
      if (tolower($1)==kl) {
        if (!done) { print k " " v; done=1 }
        next
      }
      print
    }
    END { if (!done) print k " " v }
  ' "${conf}" > "${tmp}"
  cat "${tmp}" > "${conf}"
  rm -f "${tmp}"
}

hm_security_has_authorized_keys() {
  local u="${1:-root}" home ak n
  if [[ "${u}" == "root" ]]; then
    home="/root"
  else
    home="$(getent passwd "${u}" 2>/dev/null | cut -d: -f6)"
  fi
  ak="${home}/.ssh/authorized_keys"
  [[ -f "${ak}" ]] || return 1
  n="$(grep -cE '^(ssh-|ecdsa-|sk-)' "${ak}" 2>/dev/null || echo 0)"
  [[ "${n}" =~ ^[0-9]+$ && "${n}" -gt 0 ]]
}

hm_security_sshd_restart() {
  if hm_have_cmd systemctl; then
    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null \
      || systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null \
      || return 1
    return 0
  fi
  service ssh reload 2>/dev/null || service sshd reload 2>/dev/null || return 1
}

hm_security_ssh_rollback_state() {
  printf '%s' "${TMP_DIR:-/tmp}/hmtools-ssh-pending"
}

hm_security_ssh_cancel_rollback_timer() {
  # Anuluj transient timer/service (systemd-run) — odporne na brak jednostki.
  if hm_have_cmd systemctl; then
    systemctl stop hmtools-ssh-rollback.timer 2>/dev/null || true
    systemctl stop hmtools-ssh-rollback.service 2>/dev/null || true
    systemctl reset-failed hmtools-ssh-rollback.service 2>/dev/null || true
    systemctl reset-failed hmtools-ssh-rollback.timer 2>/dev/null || true
  fi
}

cmd_security_ssh_confirm() {
  local st
  st="$(hm_security_ssh_rollback_state)"
  if [[ ! -f "${st}.bak" && ! -f "${st}.meta" ]]; then
    hm_info "Brak oczekującej zmiany SSH do potwierdzenia."
    return 0
  fi
  touch "${st}.confirmed"
  hm_security_ssh_cancel_rollback_timer
  # skrypt setsid/nohup i tak wyjdzie po sleep gdy zobaczy .confirmed
  hm_ok "Potwierdzono zmianę SSH — auto-rollback anulowany."
  return 0
}

# Skrypt rollbacka (standalone) — systemd-run / setsid (przeżywa SIGHUP sesji SSH).
hm_security_ssh_write_rollback_script() {
  local script="$1" st="$2" conf="$3" old_port="$4" new_port="$5" opened_fw="$6" do_sleep="${7:-0}"
  # shellcheck disable=SC2086
  cat > "${script}" <<EOF
#!/usr/bin/env bash
# hmtools: auto-rollback SSH — detached (SIGHUP-safe)
set +e
trap '' HUP PIPE
st=$(printf '%q' "${st}")
conf=$(printf '%q' "${conf}")
old_port=$(printf '%q' "${old_port}")
new_port=$(printf '%q' "${new_port}")
opened_fw=$(printf '%q' "${opened_fw}")
[[ "${do_sleep}" == "1" ]] && sleep 120
if [[ -f "\${st}.confirmed" ]]; then
  rm -f "\${st}".{bak,meta,confirmed,method,sh} 2>/dev/null
  exit 0
fi
if [[ -f "\${st}.bak" && -f "\${conf}" ]]; then
  echo "hmtools: brak potwierdzenia SSH w 120s — rollback…" >&2
  cat "\${st}.bak" > "\${conf}"
  if [[ "\${opened_fw}" == "1" && -n "\${new_port}" && "\${new_port}" != "\${old_port}" ]]; then
    if command -v ufw >/dev/null 2>&1; then
      ufw --force delete allow "\${new_port}/tcp" >/dev/null 2>&1 || true
    fi
    if command -v firewall-cmd >/dev/null 2>&1; then
      firewall-cmd --permanent --remove-port="\${new_port}/tcp" >/dev/null 2>&1 || true
      firewall-cmd --reload >/dev/null 2>&1 || true
    fi
    # CSF: best-effort — zostaw port otwarty jeśli sed niepewnie; krytyczne jest Port w sshd
  fi
  command -v sshd >/dev/null 2>&1 && sshd -t 2>/dev/null || true
  systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null \\
    || systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
fi
rm -f "\${st}".{bak,meta,confirmed,method,sh} 2>/dev/null
exit 0
EOF
  chmod 700 "${script}"
}

hm_security_ssh_schedule_rollback() {
  local bak="$1" conf="$2" old_port="$3" new_port="$4" opened_fw="${5:-0}"
  local st script method="setsid"
  st="$(hm_security_ssh_rollback_state)"
  script="${st}.sh"
  cp -a "${bak}" "${st}.bak" 2>/dev/null || cp "${bak}" "${st}.bak"
  rm -f "${st}.confirmed"
  printf '%s\n' "${conf}" "${old_port}" "${new_port}" "${opened_fw}" > "${st}.meta"

  hm_security_ssh_cancel_rollback_timer

  # 1) Preferuj systemd-run — timer przeżywa zerwanie sesji SSH
  if hm_have_cmd systemd-run && hm_have_cmd systemctl; then
    hm_security_ssh_write_rollback_script "${script}" "${st}" "${conf}" "${old_port}" "${new_port}" "${opened_fw}" 0
    if systemd-run --collect \
      --unit=hmtools-ssh-rollback \
      --description="hmtools SSH port auto-rollback" \
      --on-active=120s \
      /bin/bash "${script}" >/dev/null 2>&1; then
      printf '%s\n' "systemd-run" > "${st}.method"
      hm_warn "Masz 120 s na: security ssh confirm — inaczej automatyczny rollback (systemd-run)."
      return 0
    fi
    hm_warn "systemd-run niedostępny/nieudany — fallback setsid/nohup."
  fi

  # 2) Fallback: nowa sesja + nohup, stdin=/dev/null (nie ginie z pty/SIGHUP)
  hm_security_ssh_write_rollback_script "${script}" "${st}" "${conf}" "${old_port}" "${new_port}" "${opened_fw}" 1
  if hm_have_cmd setsid; then
    setsid -f nohup /bin/bash "${script}" </dev/null >/dev/null 2>&1 \
      || setsid nohup /bin/bash "${script}" </dev/null >/dev/null 2>&1 &
  elif hm_have_cmd nohup; then
    nohup /bin/bash "${script}" </dev/null >/dev/null 2>&1 &
  else
    ( trap '' HUP; /bin/bash "${script}" ) </dev/null >/dev/null 2>&1 &
  fi
  printf '%s\n' "setsid" > "${st}.method"
  hm_warn "Masz 120 s na: security ssh confirm — inaczej automatyczny rollback (setsid/nohup)."
}

cmd_security_ssh_set() {
  local what="${1:-}" val="${2:-}"
  shift 2 || true
  local conf="/etc/ssh/sshd_config"
  [[ -f "${conf}" ]] || { hm_err "Brak ${conf}"; return 1; }

  case "${what}" in
    port)
      [[ "${val}" =~ ^[0-9]+$ ]] && ((10#${val} >= 1 && 10#${val} <= 65535)) || {
        hm_err "Użycie: security ssh set port <1-65535>"; return 1
      }
      local old_port
      old_port="$(hm_security_sshd_get Port "${conf}")"; old_port="${old_port:-22}"
      if [[ "${old_port}" == "${val}" ]]; then
        hm_ok "Port SSH już wynosi ${val}."
        return 0
      fi
      if ! hm_confirm_plan "security ssh set port ${val}" \
        "Bez security ssh confirm w 120 s wróci stary port ${old_port}." \
        "Otwarcie ${val}/tcp w firewall (hm_os_firewall_allow)" \
        "Backup ${conf}.hmtools.bak + Port ${val}" \
        "sshd -t + restart/reload sshd" \
        "Test listen ${val} (ss -ltn)" \
        "Timer rollback 120 s (security ssh confirm)"; then
        return 0
      fi
      # 1) otwórz nowy port ZANIM zmienisz sshd
      local opened=0
      if hm_os_firewall_allow "${val}" "tcp" "" "hmtools-ssh-port"; then
        opened=1
        hm_ok "Firewall ALLOW ${val}/tcp"
      else
        hm_warn "Nie otwarto portu ${val} w firewall — kontynuuję (możesz być odcięty)."
      fi
      local bak="${conf}.hmtools.bak"
      cp -a "${conf}" "${bak}" || { hm_err "Backup nieudany"; return 1; }
      hm_security_sshd_set_directive "Port" "${val}" "${conf}"
      if ! sshd -t 2>/dev/null; then
        hm_err "sshd -t nieudany — rollback pliku."
        cat "${bak}" > "${conf}"
        [[ "${opened}" -eq 1 ]] && hm_os_firewall_remove "${val}/tcp" 2>/dev/null || true
        return 1
      fi
      if ! hm_security_sshd_restart; then
        hm_err "Restart sshd nieudany — rollback."
        cat "${bak}" > "${conf}"
        hm_security_sshd_restart || true
        [[ "${opened}" -eq 1 ]] && hm_os_firewall_remove "${val}/tcp" 2>/dev/null || true
        return 1
      fi
      sleep 0.5
      if ! ss -ltn 2>/dev/null | grep -qE ":${val}\\s"; then
        hm_warn "Brak listen :${val} w ss — sprawdź ręcznie; rollback timer i tak aktywny."
      else
        hm_ok "sshd nasłuchuje na :${val}"
      fi
      hm_security_ssh_schedule_rollback "${bak}" "${conf}" "${old_port}" "${val}" "${opened}"
      hm_ok "Port SSH ustawiony na ${val}. Potwierdź: security ssh confirm"
      ;;
    password-auth|PasswordAuthentication)
      case "${val}" in
        no|No|NO|yes|Yes|YES) ;;
        *) hm_err "Użycie: security ssh set password-auth no|yes"; return 1 ;;
      esac
      local norm
      norm="$(printf '%s' "${val}" | tr '[:upper:]' '[:lower:]')"
      if [[ "${norm}" == "no" ]]; then
        if ! hm_security_has_authorized_keys root \
          && ! hm_security_has_authorized_keys "$(id -un 2>/dev/null || echo root)"; then
          hm_err "password-auth no zabronione: brak niepustego authorized_keys (root/bieżący user)."
          return 1
        fi
      fi
      if ! hm_confirm_plan "security ssh set password-auth ${norm}" \
        "" \
        "Backup ${conf}" \
        "PasswordAuthentication ${norm}" \
        "sshd -t + reload"; then
        return 0
      fi
      cp -a "${conf}" "${conf}.hmtools.bak" || return 1
      hm_security_sshd_set_directive "PasswordAuthentication" "${norm}" "${conf}"
      if ! sshd -t 2>/dev/null; then
        cat "${conf}.hmtools.bak" > "${conf}"
        hm_err "sshd -t fail — rollback"
        return 1
      fi
      hm_security_sshd_restart || hm_warn "reload sshd nieudany"
      hm_ok "PasswordAuthentication=${norm}"
      ;;
    root-login|PermitRootLogin)
      case "${val}" in
        yes|no|prohibit-password|without-password|forced-commands-only) ;;
        *)
          hm_err "Użycie: security ssh set root-login yes|no|prohibit-password|…"
          return 1
          ;;
      esac
      if ! hm_confirm_plan "security ssh set root-login ${val}" \
        "" \
        "Backup ${conf}" \
        "PermitRootLogin ${val}" \
        "sshd -t + reload"; then
        return 0
      fi
      cp -a "${conf}" "${conf}.hmtools.bak" || return 1
      hm_security_sshd_set_directive "PermitRootLogin" "${val}" "${conf}"
      if ! sshd -t 2>/dev/null; then
        cat "${conf}.hmtools.bak" > "${conf}"
        hm_err "sshd -t fail — rollback"
        return 1
      fi
      hm_security_sshd_restart || hm_warn "reload sshd nieudany"
      hm_ok "PermitRootLogin=${val}"
      ;;
    help|-h|--help|"")
      echo "Użycie: security ssh set port <N> | password-auth no|yes | root-login <val>"
      echo "        security ssh confirm"
      ;;
    *)
      hm_err "Nieznane: security ssh set ${what}"
      return 1
      ;;
  esac
}

cmd_security_ssh() {
  local sub="${1:-}"
  case "${sub}" in
    set)
      shift || true
      cmd_security_ssh_set "$@"
      return $?
      ;;
    confirm|ack)
      cmd_security_ssh_confirm
      return $?
      ;;
    ""|status|audit|show)
      ;;
    help|-h|--help)
      echo "Użycie: security ssh | security ssh set … | security ssh confirm"
      return 0
      ;;
    *)
      # nieznane — pokaż audyt
      ;;
  esac

  local conf="/etc/ssh/sshd_config"
  echo "${C_BOLD}SSH — audyt${C_RESET}"
  if [[ ! -f "${conf}" ]]; then
    hm_err "Brak ${conf}"
    return 1
  fi

  local port pass rootlogin
  port="$(hm_security_sshd_get Port "${conf}")"; port="${port:-22}"
  pass="$(hm_security_sshd_get PasswordAuthentication "${conf}")"; pass="${pass:-yes}"
  rootlogin="$(hm_security_sshd_get PermitRootLogin "${conf}")"; rootlogin="${rootlogin:-yes}"

  echo "  Port                 : ${port}"
  if [[ "${pass}" =~ ^[Nn][Oo]$ ]]; then
    echo "  PasswordAuthentication: ${C_GREEN}${pass}${C_RESET}"
  else
    hm_warn "PasswordAuthentication=${pass} — rozważ wyłączenie (tylko klucze)."
  fi
  case "${rootlogin}" in
    no|prohibit-password|without-password)
      echo "  PermitRootLogin     : ${C_GREEN}${rootlogin}${C_RESET}"
      ;;
    *)
      hm_warn "PermitRootLogin=${rootlogin}"
      ;;
  esac

  local st
  st="$(hm_security_ssh_rollback_state)"
  if [[ -f "${st}.bak" && ! -f "${st}.confirmed" ]]; then
    hm_warn "Oczekuje potwierdzenia zmiany SSH — security ssh confirm (inaczej rollback)."
  fi

  echo
  echo "${C_BOLD}authorized_keys (root)${C_RESET}"
  local ak="/root/.ssh/authorized_keys"
  if [[ -f "${ak}" ]]; then
    local n
    n="$(grep -cE '^(ssh-|ecdsa-|sk-)' "${ak}" 2>/dev/null || echo 0)"
    echo "  Liczba kluczy: ${n}"
    awk '/^(ssh-|ecdsa-|sk-)/ {
      type=$1
      c=""; for(i=3;i<=NF;i++) c=c (i>3?" ":"") $i
      if (c=="") c="(brak komentarza)"
      printf "  · %s  %s\n", type, c
    }' "${ak}" 2>/dev/null | head -30
  else
    hm_warn "Brak ${ak}"
  fi

  echo
  echo "${C_BOLD}Ostatnie nieudane logowania SSH${C_RESET}"
  if hm_have_cmd lastb; then
    lastb -n 15 2>/dev/null || lastb 2>/dev/null | head -15 || hm_warn "lastb wymaga root / wtmp"
  elif hm_have_cmd journalctl; then
    journalctl -u ssh -u sshd --no-pager -n 30 2>/dev/null \
      | grep -iE 'failed|invalid|authentication failure' | tail -15 \
      || journalctl -u ssh -u sshd --no-pager -n 15 2>/dev/null || true
  else
    hm_warn "Brak lastb / journalctl"
  fi
}

cmd_security_scan() {
  local domain="${1:-${HM_SITE_DOMAIN:-}}"
  [[ -n "${domain}" ]] || { hm_err "Użycie: security scan (w use <domena>) lub security scan <domena>"; return 1; }
  if [[ -z "${HM_SITE_DOMAIN}" || "${HM_SITE_DOMAIN}" != "${domain}" ]]; then
    domain="$(hm_find_site_by_arg "${domain}" 2>/dev/null || echo "${domain}")"
  fi
  hm_site_context_push "${domain}" || return 1
  local doc="${HM_SITE_DOCROOT:-}"
  local root="${HM_SITE_ROOT:-}"
  if [[ -z "${doc}" || ! -d "${doc}" ]]; then
    hm_err "Brak docroot dla ${domain}."
    hm_site_context_pop
    return 1
  fi

  echo "${C_BOLD}Skan bezpieczeństwa — ${domain}${C_RESET}"
  echo "  Docroot: ${doc}"
  echo
  local issues=0

  hm_progress_bar 1 3 "Skan uploads (.php/.phar)"
  echo "${C_BOLD}.php w katalogach upload${C_RESET}"
  local -a updirs=()
  [[ -d "${doc}/wp-content/uploads" ]] && updirs+=("${doc}/wp-content/uploads")
  [[ -d "${doc}/uploads" ]] && updirs+=("${doc}/uploads")
  [[ -d "${doc}/upload" ]] && updirs+=("${doc}/upload")
  local uphit="" ud
  for ud in "${updirs[@]}"; do
    uphit+=$'\n'"$(find -P "${ud}" -xdev \( -name '*.php' -o -name '*.phtml' -o -name '*.phar' \) 2>/dev/null | head -30)"
  done
  uphit="$(printf '%s\n' "${uphit}" | awk 'NF && !seen[$0]++')"
  hm_status_clear
  if [[ -n "${uphit}" ]]; then
    hm_warn "Znaleziono skrypty PHP w uploads:"
    printf '%s\n' "${uphit}" | sed 's/^/    /'
    issues=$((issues + 1))
  else
    hm_ok "Brak .php/.phtml/.phar w typowych uploads."
  fi

  echo
  hm_progress_bar 2 3 "Skan uprawnień (777)"
  echo "${C_BOLD}World-writable (777 / +o+w)${C_RESET}"
  local ww
  ww="$(find -P "${doc}" -xdev -perm -0002 2>/dev/null | head -25)"
  hm_status_clear
  if [[ -n "${ww}" ]]; then
    hm_warn "World-writable (max 25):"
    printf '%s\n' "${ww}" | sed 's/^/    /'
    issues=$((issues + 1))
  else
    hm_ok "Brak world-writable w docroot."
  fi

  echo
  hm_progress_bar 3 3 "Skan wrażliwych plików (.env/.sql/.git)"
  echo "${C_BOLD}Podejrzane pliki publiczne${C_RESET}"
  local -a suspects=()
  local s
  for s in \
    "${doc}/.env" \
    "${doc}/.git/config" \
    "${doc}/phpinfo.php" \
    "${doc}/info.php" \
    "${doc}/test.php"
  do
    [[ -e "${s}" ]] && suspects+=("${s}")
  done
  while IFS= read -r s; do
    [[ -n "${s}" ]] && suspects+=("${s}")
  done < <(find -P "${doc}" -xdev -maxdepth 3 \( \
      -name '*.sql' -o -name '*.sql.gz' -o -name '*.tar.gz' -o -name '*.zip' -o -name '*.bak' \
    \) 2>/dev/null | head -40)
  hm_progress_done

  if [[ "${#suspects[@]}" -gt 0 ]]; then
    hm_warn "Publicznie dostępne wrażliwe/artefakty:"
    printf '%s\n' "${suspects[@]}" | awk 'NF && !seen[$0]++' | sed 's/^/    /'
    issues=$((issues + 1))
  else
    hm_ok "Brak typowych dumpów/.env/.git/phpinfo w docroot (płytki skan)."
  fi

  echo
  if [[ "${issues}" -eq 0 ]]; then
    hm_ok "Skan: brak znalezionych problemów."
  else
    hm_warn "Skan: ${issues} kategori(e) z alertami."
  fi
  hm_site_context_pop
}

_hm_cmd_register security cmd_security 0 sec
