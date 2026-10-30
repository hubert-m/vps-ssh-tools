#!/usr/bin/env bash
# Komenda: security — audyt VPS (porty, firewall, Fail2Ban, SSH, skan docroot)

hm_is_valid_ip() {
  local ip="${1:-}"
  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || [[ "${ip}" =~ ^[0-9a-fA-F:]+$ ]]
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
      cmd_security_ssh
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
  echo "${C_DIM}Więcej: security ssh | security scan (w use <domena>)${C_RESET}"
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

  printf '  %-6s %-22s %s\n' "PORT" "ADRES" "PROCES / ALERT"
  printf '  %s\n' "$(printf '%.0s─' {1..64})"

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

    printf '  %-6s %-22s %s' "${port}" "${addr}" "${proc:--}"
    [[ -n "${alert}" ]] && printf '  %s' "${alert}"
    echo
  done < "${tmp}"

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
    "Usunięcie reguły firewall (ufw / firewalld / iptables) dla ${ip}"; then
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
    hm_warn "Firewall: brak reguły do usunięcia (lub brak ufw/firewalld/iptables)."
  fi
}

cmd_security_ban() {
  local ip="${1:-}"
  [[ -n "${ip}" ]] || { hm_err "Użycie: security ban <IP>"; return 1; }
  hm_is_valid_ip "${ip}" || { hm_err "Nieprawidłowe IP: ${ip}"; return 1; }
  if ! hm_confirm_plan "security ban — ${ip}" \
    "Blokada adresu IP na firewallu i w Fail2Ban." \
    "Dodanie blokady adresu IP ${ip} we wszystkich aktywnych jailach Fail2Ban" \
    "Dodanie reguły firewall (ufw / firewalld / iptables) dla ${ip}"; then
    return 0
  fi

  local ok=0
  if hm_have_cmd fail2ban-client; then
    local jails jail
    jails="$(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/{print $2}' | tr ',' ' ')"
    for jail in ${jails}; do
      jail="$(echo "${jail}" | tr -d ' ')"
      [[ -n "${jail}" ]] || continue
      if fail2ban-client set "${jail}" banip "${ip}" 2>/dev/null; then
        hm_ok "Ban ${ip} w jail ${jail}"
        ok=1
        break
      fi
    done
  fi
  if hm_os_firewall_ban "${ip}"; then
    hm_ok "Firewall: zablokowano ${ip}"
    ok=1
  fi
  [[ "${ok}" -eq 1 ]] || hm_err "Nie udało się zablokować (brak fail2ban / firewall OS)."
}

cmd_security_ssh() {
  local conf="/etc/ssh/sshd_config"
  echo "${C_BOLD}SSH — audyt${C_RESET}"
  if [[ ! -f "${conf}" ]]; then
    hm_err "Brak ${conf}"
    return 1
  fi

  local getv
  getv() {
    # ostatnia niezakomentowana dyrektywa
    awk -v k="$(echo "$1" | tr '[:upper:]' '[:lower:]')" '
      tolower($1)==k { v=$2 }
      END { print v }
    ' "${conf}" 2>/dev/null
  }

  local port pass rootlogin
  port="$(getv Port)"; port="${port:-22}"
  pass="$(getv PasswordAuthentication)"; pass="${pass:-yes}"
  rootlogin="$(getv PermitRootLogin)"; rootlogin="${rootlogin:-yes}"

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

  echo
  echo "${C_BOLD}authorized_keys (root)${C_RESET}"
  local ak="/root/.ssh/authorized_keys"
  if [[ -f "${ak}" ]]; then
    local n
    n="$(grep -cE '^(ssh-|ecdsa-|sk-)' "${ak}" 2>/dev/null || echo 0)"
    echo "  Liczba kluczy: ${n}"
    awk '/^(ssh-|ecdsa-|sk-)/ {
      comment=$NF
      if ($0 ~ / /) {
        # ostatnie pole to komentarz gdy nie wygląda na key material
      }
      type=$1
      # komentarz = wszystko po 3. polu
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
    hm_set_site_context "${domain}" || true
  fi
  local doc="${HM_SITE_DOCROOT:-}"
  local root="${HM_SITE_ROOT:-}"
  [[ -n "${doc}" && -d "${doc}" ]] || { hm_err "Brak docroot dla ${domain}."; return 1; }

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
}
