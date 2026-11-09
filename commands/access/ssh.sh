#!/usr/bin/env bash
# access — SSH: status, passwd, shell, authorized_keys (HM_SITE_USER)

hm_access_user_is_protected() {
  local u="${1:-}"
  local uid umin
  if declare -F hm_del_user_is_protected >/dev/null 2>&1; then
    hm_del_user_is_protected "${u}"
    return $?
  fi
  case "${u}" in
    root|nobody|nogroup|www-data|lsadm|cyberpanel|mysql|mariadb|postfix|dovecot|sshd|ubuntu|debian|centos|almalinux|rocky|apache|nginx|daemon|messagebus|bin|sys)
      return 0
      ;;
  esac
  if id "${u}" >/dev/null 2>&1; then
    uid="$(id -u "${u}" 2>/dev/null || echo "")"
    if declare -F hm_unix_uid_min >/dev/null 2>&1; then
      umin="$(hm_unix_uid_min)"
    else
      umin=1000
    fi
    if [[ "${uid}" =~ ^[0-9]+$ && "${uid}" -lt "${umin}" ]]; then
      return 0
    fi
  fi
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
  local uid umin
  [[ -n "${user}" ]] || {
    hm_err "Brak użytkownika Unix dla ${domain} (HM_SITE_USER puste)."
    return 1
  }
  if ! id "${user}" >/dev/null 2>&1; then
    hm_err "Użytkownik nie istnieje w systemie: ${user}"
    return 1
  fi
  # System UID < UID_MIN — jawny komunikat (daemon/messagebus itd.)
  uid="$(id -u "${user}" 2>/dev/null || echo "")"
  if declare -F hm_unix_uid_min >/dev/null 2>&1; then
    umin="$(hm_unix_uid_min)"
  else
    umin=1000
  fi
  if [[ "${uid}" =~ ^[0-9]+$ && "${uid}" -lt "${umin}" ]]; then
    hm_err "Użytkownik systemowy (UID ${uid} < ${umin}) — odmowa: ${user}"
    return 1
  fi
  if hm_access_user_is_protected "${user}"; then
    hm_err "Użytkownik chroniony — odmowa: ${user}"
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

# Ścieżka nie jest symlinkiem, realpath ⊆ home, owner=user (gdy plik istnieje).
hm_access_ssh_path_ok() {
  local user="$1" home="$2" path="$3"
  local rp hr owner
  [[ -n "${user}" && -n "${home}" && -n "${path}" ]] || return 1
  if [[ -L "${path}" ]]; then
    hm_err "Odmowa: ${path} jest symlinkiem (ryzyko zapisu poza home)."
    return 1
  fi
  hr="$(realpath -m "${home}" 2>/dev/null || echo "${home}")"
  hr="${hr%/}"
  if [[ -e "${path}" ]]; then
    rp="$(realpath "${path}" 2>/dev/null || realpath -m "${path}" 2>/dev/null || echo "${path}")"
  else
    rp="$(realpath -m "${path}" 2>/dev/null || echo "${path}")"
  fi
  rp="${rp%/}"
  if [[ "${rp}" != "${hr}" && "${rp}" != "${hr}"/* ]]; then
    hm_err "Odmowa: ${path} poza home ${hr} (→ ${rp})."
    return 1
  fi
  if [[ -e "${path}" ]]; then
    owner="$(stat -c '%U' "${path}" 2>/dev/null || stat -f '%Su' "${path}" 2>/dev/null || true)"
    if [[ -n "${owner}" && "${owner}" != "${user}" ]]; then
      hm_err "Odmowa: ${path} należy do „${owner}”, nie „${user}”."
      return 1
    fi
  fi
  return 0
}

# ~/.ssh + authorized_keys: bez symlinku katalogu/pliku, path_ok (anti-TOCTOU przed I/O).
hm_access_ssh_recheck_keys_paths() {
  local user="$1" home="$2" keysf="$3"
  local sshdir="${home}/.ssh"
  if [[ -L "${sshdir}" ]]; then
    hm_err "Odmowa: ${sshdir} jest symlinkiem (ryzyko eskalacji / TOCTOU)."
    return 1
  fi
  if [[ -L "${keysf}" ]]; then
    hm_err "Odmowa: ${keysf} jest symlinkiem (ryzyko eskalacji / TOCTOU)."
    return 1
  fi
  # katalog .ssh musi istnieć i należeć do usera
  if [[ -d "${sshdir}" ]]; then
    hm_access_ssh_path_ok "${user}" "${home}" "${sshdir}" || return 1
  fi
  hm_access_ssh_path_ok "${user}" "${home}" "${keysf}" || return 1
  return 0
}

# Odczyt authorized_keys — preferuj runuser (symlink → /root = permission denied).
hm_access_ssh_read_keys_file() {
  local user="$1" keysf="$2" dest="$3"
  if hm_have_cmd runuser; then
    runuser -u "${user}" -- cat "${keysf}" > "${dest}" 2>/dev/null || return 1
    return 0
  fi
  cat "${keysf}" > "${dest}" || return 1
  return 0
}

# Zapis treści (stdin) do authorized_keys — preferuj runuser (bez chown roota).
hm_access_ssh_write_keys_file() {
  local user="$1" keysf="$2"
  if hm_have_cmd runuser; then
    runuser -u "${user}" -- tee "${keysf}" >/dev/null || return 1
    runuser -u "${user}" -- chmod 600 "${keysf}" 2>/dev/null || true
    return 0
  fi
  # bez runuser: jeszcze raz path_ok tuż przed zapisem jako root
  cat > "${keysf}" || return 1
  chmod 600 "${keysf}"
  chown -h "${user}:${user}" "${keysf}" 2>/dev/null || chown -h "${user}" "${keysf}"
  return 0
}

hm_access_is_valid_ssh_key_line() {
  local line="${1:-}"
  [[ -n "${line}" ]] || return 1
  [[ "${line}" =~ ^[[:space:]]*# ]] && return 1
  [[ "${line}" =~ ^[[:space:]]*(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]+ ]]
}

# Typ + blob (bez komentarza) — duplikat klucza mimo innego comment.
hm_access_ssh_key_type_blob() {
  local line="${1:-}" t b
  read -r t b _ <<<"${line}" || true
  [[ -n "${t}" && -n "${b}" ]] || return 1
  printf '%s %s\n' "${t}" "${b}"
}

# Czy authorized_keys (stdin lub plik $2) już ma ten sam typ+blob co $1?
hm_access_ssh_key_blob_exists() {
  local key_line="${1:-}" keys_file="${2:-}"
  local want have line
  want="$(hm_access_ssh_key_type_blob "${key_line}")" || return 1
  if [[ -n "${keys_file}" ]]; then
    [[ -f "${keys_file}" ]] || return 1
    while IFS= read -r line || [[ -n "${line}" ]]; do
      hm_access_is_valid_ssh_key_line "${line}" || continue
      have="$(hm_access_ssh_key_type_blob "${line}")" || continue
      [[ "${have}" == "${want}" ]] && return 0
    done < "${keys_file}"
    return 1
  fi
  return 1
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
  if [[ -n "${keysf}" ]]; then
    if [[ -L "${home}/.ssh" || -L "${keysf}" ]]; then
      hm_warn "Klucze   : odmowa odczytu — ~/.ssh lub authorized_keys jest symlinkiem"
    elif [[ -f "${keysf}" ]] && hm_access_ssh_path_ok "${user}" "${home}" "${keysf}" 2>/dev/null; then
      # grep -c przy 0 trafieniach: stdout „0” + rc=1 — NIE używać `|| echo 0` (dałoby „0\n0”)
      nkeys="$(grep -cE '^[[:space:]]*(ssh-|ecdsa-|sk-)' "${keysf}" 2>/dev/null || true)"
      [[ "${nkeys}" =~ ^[0-9]+$ ]] || nkeys=0
      echo "  Klucze   : ${nkeys} w ${keysf}"
    elif [[ -f "${keysf}" ]]; then
      hm_warn "Klucze   : plik istnieje, ale ścieżka/właściciel niebezpieczne — pomijam odczyt"
    else
      echo "  Klucze   : 0 (brak authorized_keys)"
    fi
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
  hm_print_secret "" \
    "  ${C_BOLD}Użytkownik:${C_RESET} ${user}" \
    "  ${C_BOLD}Hasło:${C_RESET}      ${pass}" \
    "  ${C_DIM}Zapisz hasło — nie będzie ponownie pokazane.${C_RESET}"
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

  if [[ "${cur}" == "${target}" ]]; then
    case "${action}" in
      enable|on|bash) hm_ok "Shell ${user}: już włączony (${cur})." ;;
      *) hm_ok "Shell ${user}: już wyłączony (${cur})." ;;
    esac
    return 0
  fi

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
  local domain user home keysf line i=0
  hm_access_resolve_site "${1:-}" || return 1
  domain="${HM_SITE_DOMAIN}"
  user="$(hm_access_require_site_user "${domain}")" || return 1
  home="$(hm_access_unix_home "${user}")"
  keysf="$(hm_access_ssh_keys_file "${user}" 2>/dev/null || true)"

  echo "${C_BOLD}authorized_keys — ${user} (${domain})${C_RESET}"
  if [[ -z "${keysf}" || ! -e "${keysf}" ]]; then
    echo "  (brak pliku)"
    return 0
  fi
  if [[ -L "${home}/.ssh" || -L "${keysf}" ]]; then
    hm_err "Odmowa: ~/.ssh lub authorized_keys jest symlinkiem."
    return 1
  fi
  hm_access_ssh_path_ok "${user}" "${home}" "${keysf}" || return 1
  echo "  Plik: ${keysf}"
  echo
  hm_table_begin RLL
  hm_table_row "#" TYP KOMENTARZ
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    hm_access_is_valid_ssh_key_line "${line}" || continue
    i=$((i + 1))
    local typ comment
    typ="$(printf '%s' "${line}" | awk '{print $1}')"
    comment="$(printf '%s' "${line}" | awk '{print $3}')"
    hm_table_row "${i}" "${typ}" "${comment:-(brak komentarza)}"
  done < "${keysf}"
  if [[ "${i}" -eq 0 ]]; then
    echo "  (brak kluczy)"
  else
    hm_table_print
  fi
}

hm_access_ssh_keys_ensure_dir() {
  local user="$1"
  local home sshdir keysf
  home="$(hm_access_unix_home "${user}")"
  [[ -n "${home}" && -d "${home}" ]] || {
    hm_err "Brak katalogu home: ${home:--}"
    return 1
  }
  home="$(realpath -m "${home}" 2>/dev/null || echo "${home}")"
  sshdir="${home}/.ssh"
  keysf="${sshdir}/authorized_keys"

  if [[ -L "${sshdir}" ]]; then
    hm_err "Odmowa: ${sshdir} jest symlinkiem (ryzyko eskalacji)."
    return 1
  fi
  if [[ -e "${sshdir}" && ! -d "${sshdir}" ]]; then
    hm_err "Odmowa: ${sshdir} nie jest katalogiem."
    return 1
  fi

  if [[ ! -d "${sshdir}" ]]; then
    if hm_have_cmd install; then
      install -d -o "${user}" -g "${user}" -m 700 "${sshdir}" || {
        hm_err "Nie utworzono ${sshdir}."
        return 1
      }
    else
      mkdir -m 700 "${sshdir}" || return 1
      chown -h "${user}:${user}" "${sshdir}" 2>/dev/null || chown -h "${user}" "${sshdir}"
    fi
  else
    hm_access_ssh_path_ok "${user}" "${home}" "${sshdir}" || return 1
    chmod 700 "${sshdir}"
  fi

  if [[ -L "${keysf}" ]]; then
    hm_err "Odmowa: ${keysf} jest symlinkiem (ryzyko eskalacji)."
    return 1
  fi
  if [[ -e "${keysf}" ]]; then
    hm_access_ssh_path_ok "${user}" "${home}" "${keysf}" || return 1
  else
    # nowy plik — bez podążania za linkiem (nie istnieje)
    if hm_have_cmd install; then
      install -o "${user}" -g "${user}" -m 600 /dev/null "${keysf}" || {
        hm_err "Nie utworzono ${keysf}."
        return 1
      }
    elif hm_have_cmd runuser; then
      runuser -u "${user}" -- touch "${keysf}" || return 1
      chmod 600 "${keysf}"
    else
      (umask 077; : > "${keysf}") || return 1
      chown -h "${user}:${user}" "${keysf}" 2>/dev/null || chown -h "${user}" "${keysf}"
      chmod 600 "${keysf}"
    fi
  fi
  # ponowna weryfikacja po utworzeniu
  if [[ -L "${keysf}" ]]; then
    hm_err "Odmowa: ${keysf} stał się symlinkiem."
    return 1
  fi
  hm_access_ssh_path_ok "${user}" "${home}" "${keysf}" || return 1
  chmod 600 "${keysf}"
  printf '%s' "${keysf}"
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

  # Duplikat po typ+blob (nie cała linia — ten sam klucz z innym comment = duplikat)
  local home keys_existing
  home="$(hm_access_unix_home "${user}")"
  keys_existing="$(hm_access_ssh_keys_file "${user}" 2>/dev/null || true)"
  if [[ -n "${keys_existing}" && -f "${keys_existing}" ]] \
    && [[ ! -L "${home}/.ssh" && ! -L "${keys_existing}" ]] \
    && hm_access_ssh_path_ok "${user}" "${home}" "${keys_existing}" 2>/dev/null \
    && hm_access_ssh_key_blob_exists "${key_line}" "${keys_existing}"; then
    hm_ok "Klucz (typ+blob) już jest w ${keys_existing}."
    return 0
  fi

  if ! hm_confirm_plan "access ssh keys add — ${domain}" \
    "Klucz zostanie dopisany do authorized_keys użytkownika ${user}." \
    "Utworzenie ~/.ssh (700) i authorized_keys (600) jeśli brak" \
    "Dopisanie linii klucza (${key_line%% *} …)"; then
    return 1
  fi

  # Anti-TOCTOU: ponowna weryfikacja po confirm (user mógł podmienić ~/.ssh)
  if [[ -e "${home}/.ssh" || -L "${home}/.ssh" ]]; then
    if [[ -L "${home}/.ssh" ]]; then
      hm_err "Odmowa: ${home}/.ssh jest symlinkiem (ryzyko eskalacji / TOCTOU)."
      return 1
    fi
    hm_access_ssh_path_ok "${user}" "${home}" "${home}/.ssh" || return 1
  fi

  keysf="$(hm_access_ssh_keys_ensure_dir "${user}")" || return 1
  hm_access_ssh_recheck_keys_paths "${user}" "${home}" "${keysf}" || return 1
  if hm_access_ssh_key_blob_exists "${key_line}" "${keysf}"; then
    hm_ok "Klucz (typ+blob) już jest w ${keysf}."
    return 0
  fi
  if hm_have_cmd runuser; then
    printf '%s\n' "${key_line}" | runuser -u "${user}" -- tee -a "${keysf}" >/dev/null || {
      hm_err "Zapis klucza (runuser) nieudany."
      return 1
    }
    runuser -u "${user}" -- chmod 600 "${keysf}" 2>/dev/null || true
  else
    hm_access_ssh_recheck_keys_paths "${user}" "${home}" "${keysf}" || return 1
    printf '%s\n' "${key_line}" >> "${keysf}" || return 1
    hm_access_ssh_recheck_keys_paths "${user}" "${home}" "${keysf}" || return 1
    chmod 600 "${keysf}"
    chown -h "${user}:${user}" "${keysf}" 2>/dev/null || chown -h "${user}" "${keysf}"
  fi
  hm_access_ssh_recheck_keys_paths "${user}" "${home}" "${keysf}" || return 1
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
  # list numeruje od 1 — #0 nigdy nie wskazuje klucza, ale wcześniej fałszywie „Usunięto”
  if [[ "${idx}" -lt 1 ]]; then
    hm_err "Numer klucza musi być ≥ 1 (patrz: access ssh keys list)."
    return 1
  fi

  hm_access_resolve_site "${domain_arg}" || return 1
  domain="${HM_SITE_DOMAIN}"
  user="$(hm_access_require_site_user "${domain}")" || return 1
  local home
  home="$(hm_access_unix_home "${user}")"
  keysf="$(hm_access_ssh_keys_file "${user}" 2>/dev/null || true)"
  [[ -n "${keysf}" && -f "${keysf}" ]] || {
    hm_err "Brak authorized_keys."
    return 1
  }
  hm_access_ssh_recheck_keys_paths "${user}" "${home}" "${keysf}" || return 1

  # Zakres numeru — przed confirm (nie pytaj o nieistniejący #N)
  local n_avail=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if hm_access_is_valid_ssh_key_line "${line}"; then
      n_avail=$((n_avail + 1))
    fi
  done < "${keysf}"
  if [[ "${idx}" -gt "${n_avail}" ]]; then
    hm_err "Brak klucza o numerze ${idx} (jest ${n_avail})."
    return 1
  fi

  if ! hm_confirm_plan "access ssh keys remove #${idx} — ${domain}" \
    "Usunięcie klucza uniemożliwi logowanie tym kluczem." \
    "Usunięcie pozycji #${idx} z ${keysf}"; then
    return 1
  fi

  # Anti-TOCTOU: po „yes” user mógł podmienić ~/.ssh → /root/.ssh
  hm_access_ssh_recheck_keys_paths "${user}" "${home}" "${keysf}" || return 1

  local src tmp
  src="$(mktemp "${TMP_DIR:-/tmp}/hmtools-ak-src.XXXXXX")"
  tmp="$(mktemp "${TMP_DIR:-/tmp}/hmtools-ak.XXXXXX")"
  if ! hm_access_ssh_read_keys_file "${user}" "${keysf}" "${src}"; then
    rm -f "${src}" "${tmp}"
    hm_err "Odczyt authorized_keys nieudany (odmowa / TOCTOU?)."
    return 1
  fi
  # ścieżki mogły się zmienić w trakcie odczytu
  hm_access_ssh_recheck_keys_paths "${user}" "${home}" "${keysf}" || {
    rm -f "${src}" "${tmp}"
    return 1
  }

  local removed=0
  n=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if hm_access_is_valid_ssh_key_line "${line}"; then
      n=$((n + 1))
      if [[ "${n}" -eq "${idx}" ]]; then
        removed=1
        continue
      fi
    fi
    printf '%s\n' "${line}" >> "${tmp}"
  done < "${src}"
  rm -f "${src}"

  if [[ "${removed}" -ne 1 ]]; then
    rm -f "${tmp}"
    hm_err "Brak klucza o numerze ${idx} (jest ${n})."
    return 1
  fi

  hm_access_ssh_recheck_keys_paths "${user}" "${home}" "${keysf}" || {
    rm -f "${tmp}"
    return 1
  }
  if ! hm_access_ssh_write_keys_file "${user}" "${keysf}" < "${tmp}"; then
    rm -f "${tmp}"
    hm_err "Zapis authorized_keys nieudany."
    return 1
  fi
  rm -f "${tmp}"
  hm_access_ssh_recheck_keys_paths "${user}" "${home}" "${keysf}" || return 1
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
