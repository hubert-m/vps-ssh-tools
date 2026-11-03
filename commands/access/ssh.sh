#!/usr/bin/env bash
# access — SSH: status, passwd, shell, authorized_keys (HM_SITE_USER)

hm_access_user_is_protected() {
  local u="${1:-}"
  if declare -F hm_del_user_is_protected >/dev/null 2>&1; then
    hm_del_user_is_protected "${u}"
    return $?
  fi
  case "${u}" in
    root|nobody|nogroup|www-data|lsadm|cyberpanel|mysql|mariadb|postfix|dovecot|sshd|ubuntu|debian|centos|almalinux|rocky|apache|nginx)
      return 0
      ;;
  esac
  return 1
}

# Ustaw kontekst strony (HM_SITE_*). NIE wołać w $(…) — subshell gubi kontekst.
# Po sukcesie: HM_SITE_DOMAIN / HM_SITE_USER / … są ustawione w bieżącej powłoce.
hm_access_resolve_site() {
  local arg="${1:-}"
  local domain=""
  if [[ -n "${arg}" ]]; then
    domain="$(hm_find_site_by_arg "${arg}")" || return 1
    hm_set_site_context "${domain}"
  elif [[ -n "${HM_SITE_DOMAIN:-}" ]]; then
    domain="${HM_SITE_DOMAIN}"
  else
    hm_err "Podaj domenę lub wejdź w kontekst: use <domena>"
    return 1
  fi
  [[ -n "${HM_SITE_DOMAIN:-}" ]] || return 1
  return 0
}

hm_access_require_site_user() {
  local domain="$1"
  local user="${HM_SITE_USER:-}"
  [[ -n "${user}" ]] || {
    hm_err "Brak użytkownika Unix dla ${domain} (HM_SITE_USER puste)."
    return 1
  }
  if hm_access_user_is_protected "${user}"; then
    hm_err "Użytkownik chroniony — odmowa: ${user}"
    return 1
  fi
  if ! id "${user}" >/dev/null 2>&1; then
    hm_err "Użytkownik nie istnieje w systemie: ${user}"
    return 1
  fi
  printf '%s' "${user}"
}

hm_access_unix_home() {
  local user="$1"
  getent passwd "${user}" 2>/dev/null | cut -d: -f6
}

hm_access_unix_shell() {
  local user="$1"
  getent passwd "${user}" 2>/dev/null | cut -d: -f7
}

hm_access_ssh_keys_file() {
  local user="$1"
  local home
  home="$(hm_access_unix_home "${user}")"
  [[ -n "${home}" && -d "${home}" ]] || return 1
  printf '%s' "${home}/.ssh/authorized_keys"
}

hm_access_is_valid_ssh_key_line() {
  local line="${1:-}"
  [[ -n "${line}" ]] || return 1
  [[ "${line}" =~ ^[[:space:]]*# ]] && return 1
  [[ "${line}" =~ ^[[:space:]]*(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]+ ]]
}

hm_access_ssh_status() {
  local domain user home shell keysf nkeys=0
  hm_access_resolve_site "${1:-}" || return 1
  domain="${HM_SITE_DOMAIN}"
  user="$(hm_access_require_site_user "${domain}")" || return 1
  home="$(hm_access_unix_home "${user}")"
  shell="$(hm_access_unix_shell "${user}")"
  keysf="$(hm_access_ssh_keys_file "${user}" 2>/dev/null || true)"

  echo "${C_BOLD}SSH / Unix — ${domain}${C_RESET}"
  echo "  User     : ${user}"
  echo "  Home     : ${home:--}"
  echo "  Shell    : ${shell:--}"
  if [[ -n "${shell}" && "${shell}" != */nologin && "${shell}" != */false ]]; then
    echo "  Logowanie: ${C_GREEN}włączone${C_RESET} (shell interaktywny)"
  else
    echo "  Logowanie: ${C_YELLOW}wyłączone${C_RESET} (nologin/false)"
  fi
  if [[ -n "${keysf}" && -f "${keysf}" ]]; then
    nkeys="$(grep -cE '^[[:space:]]*(ssh-|ecdsa-|sk-)' "${keysf}" 2>/dev/null || echo 0)"
    echo "  Klucze   : ${nkeys} w ${keysf}"
  else
    echo "  Klucze   : 0 (brak authorized_keys)"
  fi
}

hm_access_ssh_passwd() {
  local domain user pass
  hm_access_resolve_site "${1:-}" || return 1
  domain="${HM_SITE_DOMAIN}"
  user="$(hm_access_require_site_user "${domain}")" || return 1

  if ! hm_confirm_plan "access ssh passwd — ${domain}" \
    "Hasło użytkownika Unix ${user} zostanie zmienione i wypisane na ekranie." \
    "Wygenerowanie nowego hasła (openssl/urandom)" \
    "Ustawienie hasła przez chpasswd dla ${user}"; then
    return 1
  fi

  pass="$(hm_gen_password)"
  [[ -n "${pass}" && ${#pass} -ge 12 ]] || { hm_err "Nie udało się wygenerować hasła."; return 1; }

  if ! printf '%s:%s\n' "${user}" "${pass}" | chpasswd; then
    hm_err "chpasswd nieudany dla ${user}."
    return 1
  fi
  hm_ok "Hasło Unix ustawione dla ${user}."
  echo
  echo "  ${C_BOLD}Użytkownik:${C_RESET} ${user}"
  echo "  ${C_BOLD}Hasło:${C_RESET}      ${pass}"
  echo "  ${C_DIM}Zapisz hasło — nie będzie ponownie pokazane.${C_RESET}"
}

hm_access_ssh_shell() {
  local action="${1:-}"
  local domain_arg="${2:-}"
  local domain user cur target
  case "${action}" in
    enable|on|bash)
      target="/bin/bash"
      [[ -x "${target}" ]] || target="/bin/sh"
      ;;
    disable|off|nologin)
      if [[ -x /usr/sbin/nologin ]]; then
        target="/usr/sbin/nologin"
      elif [[ -x /sbin/nologin ]]; then
        target="/sbin/nologin"
      else
        target="/bin/false"
      fi
      ;;
    *)
      hm_err "Użycie: access ssh shell enable|disable [domena]"
      return 1
      ;;
  esac

  hm_access_resolve_site "${domain_arg}" || return 1
  domain="${HM_SITE_DOMAIN}"
  user="$(hm_access_require_site_user "${domain}")" || return 1
  cur="$(hm_access_unix_shell "${user}")"

  if ! hm_confirm_plan "access ssh shell ${action} — ${domain}" \
    "Zmiana shella wpływa na możliwość logowania SSH/SFTP jako ${user}." \
    "usermod -s ${target} ${user} (obecnie: ${cur:--})"; then
    return 1
  fi

  if ! usermod -s "${target}" "${user}"; then
    hm_err "usermod nieudany."
    return 1
  fi
  hm_ok "Shell ${user}: ${cur:--} → ${target}"
}

hm_access_ssh_keys_list() {
  local domain user keysf line i=0
  hm_access_resolve_site "${1:-}" || return 1
  domain="${HM_SITE_DOMAIN}"
  user="$(hm_access_require_site_user "${domain}")" || return 1
  keysf="$(hm_access_ssh_keys_file "${user}" 2>/dev/null || true)"

  echo "${C_BOLD}authorized_keys — ${user} (${domain})${C_RESET}"
  if [[ -z "${keysf}" || ! -f "${keysf}" ]]; then
    echo "  (brak pliku)"
    return 0
  fi
  echo "  Plik: ${keysf}"
  echo
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    hm_access_is_valid_ssh_key_line "${line}" || continue
    i=$((i + 1))
    local typ comment
    typ="$(printf '%s' "${line}" | awk '{print $1}')"
    comment="$(printf '%s' "${line}" | awk '{print $3}')"
    printf '  %2d  %-20s %s\n' "${i}" "${typ}" "${comment:-(brak komentarza)}"
  done < "${keysf}"
  if [[ "${i}" -eq 0 ]]; then
    echo "  (brak kluczy)"
  fi
}

hm_access_ssh_keys_ensure_dir() {
  local user="$1"
  local home sshdir
  home="$(hm_access_unix_home "${user}")"
  [[ -n "${home}" && -d "${home}" ]] || {
    hm_err "Brak katalogu home: ${home:--}"
    return 1
  }
  sshdir="${home}/.ssh"
  mkdir -p "${sshdir}"
  chmod 700 "${sshdir}"
  chown "${user}:${user}" "${sshdir}" 2>/dev/null || chown "${user}" "${sshdir}"
  touch "${sshdir}/authorized_keys"
  chmod 600 "${sshdir}/authorized_keys"
  chown "${user}:${user}" "${sshdir}/authorized_keys" 2>/dev/null || chown "${user}" "${sshdir}/authorized_keys"
  printf '%s' "${sshdir}/authorized_keys"
}

hm_access_ssh_keys_add() {
  local domain_arg="" key_line=""
  # access ssh keys add [domena] ssh-ed25519 AAAA… [comment]
  if [[ -n "${1:-}" && -n "${2:-}" ]] && [[ "${2}" =~ ^(ssh-|ecdsa-|sk-) ]]; then
    domain_arg="${1}"
    shift
    key_line="$*"
  else
    key_line="$*"
  fi

  local domain user keysf
  hm_access_resolve_site "${domain_arg}" || return 1
  domain="${HM_SITE_DOMAIN}"
  user="$(hm_access_require_site_user "${domain}")" || return 1

  if [[ -z "${key_line}" ]]; then
    hm_err "Użycie: access ssh keys add [domena] <linia-klucza-ssh>"
    hm_info "Przykład: access ssh keys add example.com ssh-ed25519 AAAA… comment"
    return 1
  fi
  if ! hm_access_is_valid_ssh_key_line "${key_line}"; then
    hm_err "Nieprawidłowa linia klucza (oczekiwano ssh-ed25519|ssh-rsa|ecdsa-… + base64)."
    return 1
  fi

  if ! hm_confirm_plan "access ssh keys add — ${domain}" \
    "Klucz zostanie dopisany do authorized_keys użytkownika ${user}." \
    "Utworzenie ~/.ssh (700) i authorized_keys (600) jeśli brak" \
    "Dopisanie linii klucza (${key_line%% *} …)"; then
    return 1
  fi

  keysf="$(hm_access_ssh_keys_ensure_dir "${user}")" || return 1
  if grep -Fqx "${key_line}" "${keysf}" 2>/dev/null; then
    hm_ok "Klucz już jest w ${keysf}."
    return 0
  fi
  printf '%s\n' "${key_line}" >> "${keysf}"
  chmod 600 "${keysf}"
  chown "${user}:${user}" "${keysf}" 2>/dev/null || chown "${user}" "${keysf}"
  hm_ok "Dodano klucz do ${keysf}"
}

hm_access_ssh_keys_remove() {
  local idx_or_domain="${1:-}"
  local maybe_idx="${2:-}"
  local domain_arg="" idx="" domain user keysf
  local tmp n=0 line

  if [[ "${idx_or_domain}" =~ ^[0-9]+$ ]]; then
    idx="${idx_or_domain}"
    domain_arg=""
  else
    domain_arg="${idx_or_domain}"
    idx="${maybe_idx}"
  fi
  [[ -n "${idx}" && "${idx}" =~ ^[0-9]+$ ]] || {
    hm_err "Użycie: access ssh keys remove [domena] <numer>"
    hm_info "Numer z: access ssh keys list"
    return 1
  }

  hm_access_resolve_site "${domain_arg}" || return 1
  domain="${HM_SITE_DOMAIN}"
  user="$(hm_access_require_site_user "${domain}")" || return 1
  keysf="$(hm_access_ssh_keys_file "${user}" 2>/dev/null || true)"
  [[ -n "${keysf}" && -f "${keysf}" ]] || {
    hm_err "Brak authorized_keys."
    return 1
  }

  if ! hm_confirm_plan "access ssh keys remove #${idx} — ${domain}" \
    "Usunięcie klucza uniemożliwi logowanie tym kluczem." \
    "Usunięcie pozycji #${idx} z ${keysf}"; then
    return 1
  fi

  tmp="$(mktemp "${TMP_DIR:-/tmp}/hmtools-ak.XXXXXX")"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if hm_access_is_valid_ssh_key_line "${line}"; then
      n=$((n + 1))
      if [[ "${n}" -eq "${idx}" ]]; then
        continue
      fi
    fi
    printf '%s\n' "${line}" >> "${tmp}"
  done < "${keysf}"

  if [[ "${n}" -lt "${idx}" ]]; then
    rm -f "${tmp}"
    hm_err "Brak klucza o numerze ${idx} (jest ${n})."
    return 1
  fi
  mv "${tmp}" "${keysf}"
  chmod 600 "${keysf}"
  chown "${user}:${user}" "${keysf}" 2>/dev/null || chown "${user}" "${keysf}"
  hm_ok "Usunięto klucz #${idx}."
}

hm_access_ssh_dispatch() {
  local sub="${1:-status}"
  shift || true
  case "${sub}" in
    status|stat|info|"")
      hm_access_ssh_status "$@"
      ;;
    passwd|password|pass)
      hm_access_ssh_passwd "$@"
      ;;
    shell)
      hm_access_ssh_shell "$@"
      ;;
    keys|key)
      local ksub="${1:-list}"
      shift || true
      case "${ksub}" in
        list|ls|"") hm_access_ssh_keys_list "$@" ;;
        add|append) hm_access_ssh_keys_add "$@" ;;
        remove|rm|del|delete) hm_access_ssh_keys_remove "$@" ;;
        *)
          hm_err "Użycie: access ssh keys list|add|remove …"
          return 1
          ;;
      esac
      ;;
    help|-h|--help)
      hm_help_topic access
      ;;
    *)
      hm_err "Nieznane: access ssh ${sub}. access help"
      return 1
      ;;
  esac
}
