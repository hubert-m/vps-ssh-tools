#!/usr/bin/env bash
# users — konta systemowe (admin/deploy), sudoers.d, audyt UID 0


_hm_cmd_help users <<'EOF'
Użycie:
  users [list]                         Lista kont (UID, shell, sudo, klucze)
  users add <login> --key <plik|URL> [--sudo] [--expire YYYY-MM-DD]
  users lock|unlock|expire|del <login> [--force]
  users sudo grant|revoke <login>
  users audit                          UID 0, puste hasła, NOPASSWD, shell

Ochrona: root i użytkownik bieżącej sesji — wymaga --force (+ potwierdzenie).
sudoers zapisywany atomowo z walidacją visudo -c.
EOF

hm_users_passwd_file() { printf '%s' "${HM_USERS_PASSWD:-/etc/passwd}"; }
hm_users_shadow_file() { printf '%s' "${HM_USERS_SHADOW:-/etc/shadow}"; }
hm_users_sudoers_dir() { printf '%s' "${HM_USERS_SUDOERS_D:-/etc/sudoers.d}"; }
hm_users_home_base() { printf '%s' "${HM_USERS_HOME_BASE:-/home}"; }

hm_users_session_login() {
  local u
  u="$(id -un 2>/dev/null || true)"
  [[ -n "${u}" ]] || u="${USER:-}"
  printf '%s' "${u}"
}

hm_users_protected_target() {
  local login="$1" force="${2:-0}"
  local me
  me="$(hm_users_session_login)"
  if [[ "${login}" == "root" || "${login}" == "${me}" ]]; then
    if [[ "${force}" != "1" ]]; then
      hm_err "Odmowa: ${login} (root/sesja) — użyj --force i potwierdź."
      return 1
    fi
  fi
  return 0
}

hm_users_in_sudo_group() {
  local login="$1" g
  for g in $(id -nG "${login}" 2>/dev/null || true); do
    case "${g}" in sudo|wheel|admin) return 0 ;; esac
  done
  [[ -f "$(hm_users_sudoers_dir)/hm-${login}" ]] && return 0
  return 1
}

hm_users_ssh_key_stats() {
  local login="$1" home ak n=0
  home="$(getent passwd "${login}" 2>/dev/null | cut -d: -f6)"
  [[ -z "${home}" && -f "$(hm_users_passwd_file)" ]] && \
    home="$(awk -F: -v u="${login}" '$1==u{print $6; exit}' "$(hm_users_passwd_file)")"
  ak="${home}/.ssh/authorized_keys"
  if [[ -f "${ak}" && ! -L "${ak}" ]]; then
    n="$(grep -cE '^(ssh-|ecdsa-|sk-)' "${ak}" 2>/dev/null || true)"
    [[ "${n}" =~ ^[0-9]+$ ]] || n=0
  fi
  printf '%s' "${n}"
}

cmd_users_list() {
  local pf line login uid shell home groups last keys
  pf="$(hm_users_passwd_file)"
  echo "${C_BOLD}users${C_RESET}"
  printf '%-16s %6s %-18s %-10s %5s %s\n' "LOGIN" "UID" "SHELL" "SUDO" "KEYS" "HOME"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" == \#* || -z "${line}" ]] && continue
    login="${line%%:*}"
    uid="$(printf '%s' "${line}" | cut -d: -f3)"
    home="$(printf '%s' "${line}" | cut -d: -f6)"
    shell="$(printf '%s' "${line}" | cut -d: -f7)"
    # pomiń typowe konta systemowe bez logowania (UID < 1000), pokaż root
    if [[ "${uid}" =~ ^[0-9]+$ && "${uid}" -lt 1000 && "${login}" != "root" ]]; then
      continue
    fi
    if hm_users_in_sudo_group "${login}" 2>/dev/null; then
      groups="yes"
    else
      groups="no"
    fi
    keys="$(hm_users_ssh_key_stats "${login}")"
    printf '%-16s %6s %-18s %-10s %5s %s\n' "${login}" "${uid}" "${shell}" "${groups}" "${keys}" "${home}"
  done < "${pf}"
}

hm_users_install_key() {
  local login="$1" keysrc="$2" home ak tmp
  home="$(awk -F: -v u="${login}" '$1==u{print $6; exit}' "$(hm_users_passwd_file)")"
  [[ -n "${home}" ]] || home="$(hm_users_home_base)/${login}"
  mkdir -p "${home}/.ssh"
  chmod 700 "${home}/.ssh"
  ak="${home}/.ssh/authorized_keys"
  tmp="$(mktemp)"
  chmod 0600 "${tmp}"
  case "${keysrc}" in
    https://github.com/*)
      if [[ "${HMTOOLS_TEST:-}" == "1" ]]; then
        printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyFromGithub fixture\n' > "${tmp}"
      else
        curl -fsSL "${keysrc%/}.keys" > "${tmp}" || curl -fsSL "${keysrc}" > "${tmp}" || {
          rm -f "${tmp}"; hm_err "Nie pobrano klucza z ${keysrc}"; return 1
        }
      fi
      ;;
    http://*|https://*)
      [[ "${HMTOOLS_TEST:-}" == "1" ]] && { printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyUrl fixture\n' > "${tmp}"; } || {
        curl -fsSL "${keysrc}" > "${tmp}" || { rm -f "${tmp}"; return 1; }
      }
      ;;
    *)
      [[ -f "${keysrc}" && ! -L "${keysrc}" ]] || { hm_err "Brak pliku klucza: ${keysrc}"; rm -f "${tmp}"; return 1; }
      cat "${keysrc}" > "${tmp}"
      ;;
  esac
  if ! grep -qE '^(ssh-|ecdsa-|sk-)' "${tmp}"; then
    hm_err "Plik nie wygląda na klucz publiczny SSH."
    rm -f "${tmp}"
    return 1
  fi
  cat "${tmp}" >> "${ak}"
  chmod 600 "${ak}"
  rm -f "${tmp}"
  if declare -F hm_have_cmd >/dev/null 2>&1 && hm_have_cmd chown; then
    chown -R "${login}:${login}" "${home}/.ssh" 2>/dev/null || true
  fi
  return 0
}

cmd_users_add() {
  local login="${1:-}" key="" sudo=0 expire="" force=0 a
  shift || true
  while [[ $# -gt 0 ]]; do
    a="$1"; shift || true
    case "${a}" in
      --key) key="${1:-}"; shift || true ;;
      --key=*) key="${a#--key=}" ;;
      --sudo) sudo=1 ;;
      --expire) expire="${1:-}"; shift || true ;;
      --expire=*) expire="${a#--expire=}" ;;
      --force) force=1 ;;
      *) hm_err "Nieznane: ${a}"; return 1 ;;
    esac
  done
  [[ -n "${login}" && -n "${key}" ]] || {
    hm_err "Użycie: users add <login> --key <plik|URL> [--sudo] [--expire YYYY-MM-DD]"
    return 1
  }
  [[ "${login}" =~ ^[a-z_][a-z0-9_-]*$ ]] || { hm_err "Zły login."; return 1; }
  if [[ "${HMTOOLS_TEST:-}" == "1" ]]; then
    local pf
    pf="$(hm_users_passwd_file)"
    if ! grep -q "^${login}:" "${pf}" 2>/dev/null; then
      printf '%s:x:1500:1500::%s/%s:/bin/bash\n' "${login}" "$(hm_users_home_base)" "${login}" >> "${pf}"
    fi
    mkdir -p "$(hm_users_home_base)/${login}"
    hm_users_install_key "${login}" "${key}" || return 1
    [[ "${sudo}" -eq 1 ]] && cmd_users_sudo grant "${login}"
    [[ -n "${expire}" ]] && printf 'expire %s %s\n' "${login}" "${expire}" >> "${HM_USERS_EXPIRE_LOG:-/dev/null}"
    hm_ok "Dodano ${login} (test fixture)"
    return 0
  fi
  if id "${login}" >/dev/null 2>&1; then
    hm_err "Użytkownik ${login} już istnieje."
    return 1
  fi
  useradd -m -s /bin/bash "${login}" || return 1
  hm_users_install_key "${login}" "${key}" || return 1
  if [[ "${sudo}" -eq 1 ]]; then
    cmd_users_sudo grant "${login}" || return 1
  fi
  if [[ -n "${expire}" ]]; then
    chage -E "${expire}" "${login}" 2>/dev/null || true
  fi
  hm_ok "Dodano ${login}"
}

cmd_users_lock() {
  local login="${1:-}" force=0
  shift || true
  [[ "${1:-}" == "--force" ]] && force=1
  [[ -n "${login}" ]] || { hm_err "Użycie: users lock <login> [--force]"; return 1; }
  hm_users_protected_target "${login}" "${force}" || return 1
  if [[ "${force}" -eq 1 ]]; then
    hm_confirm_plan_critical "users lock ${login}" "Blokada konta chronionego." "passwd -l ${login}" || return 0
  else
    hm_confirm_plan "users lock ${login}" "Blokuje logowanie hasłem." "passwd -l ${login}" || return 0
  fi
  if [[ "${HMTOOLS_TEST:-}" == "1" ]]; then
    printf 'locked %s\n' "${login}" >> "${HM_USERS_ACTION_LOG:-/dev/null}"
    hm_ok "Zablokowano ${login} (test)"
    return 0
  fi
  passwd -l "${login}" && hm_ok "Zablokowano ${login}"
}

cmd_users_unlock() {
  local login="${1:-}"
  [[ -n "${login}" ]] || { hm_err "Użycie: users unlock <login>"; return 1; }
  hm_confirm_plan "users unlock ${login}" "Odblokowuje konto." "passwd -u ${login}" || return 0
  if [[ "${HMTOOLS_TEST:-}" == "1" ]]; then
    printf 'unlocked %s\n' "${login}" >> "${HM_USERS_ACTION_LOG:-/dev/null}"
    hm_ok "Odblokowano ${login} (test)"
    return 0
  fi
  passwd -u "${login}" && hm_ok "Odblokowano ${login}"
}

cmd_users_expire() {
  local login="${1:-}" day="${2:-}" force=0
  shift || true
  [[ "${1:-}" == "--force" ]] && force=1 && shift || true
  day="${1:-$(date -u +%Y-%m-%d)}"
  [[ -n "${login}" ]] || { hm_err "Użycie: users expire <login> [YYYY-MM-DD] [--force]"; return 1; }
  hm_users_protected_target "${login}" "${force}" || return 1
  hm_confirm_plan "users expire ${login}" "Ustawia datę wygaśnięcia ${day}." "chage -E ${day}" || return 0
  if [[ "${HMTOOLS_TEST:-}" == "1" ]]; then
    printf 'expire %s %s\n' "${login}" "${day}" >> "${HM_USERS_ACTION_LOG:-/dev/null}"
    hm_ok "Wygaśnięcie ${login} → ${day} (test)"
    return 0
  fi
  chage -E "${day}" "${login}" && hm_ok "Wygaśnięcie ${login} → ${day}"
}

cmd_users_del() {
  local login="${1:-}" force=0
  shift || true
  [[ "${1:-}" == "--force" ]] && force=1
  [[ -n "${login}" ]] || { hm_err "Użycie: users del <login> [--force]"; return 1; }
  hm_users_protected_target "${login}" "${force}" || return 1
  if [[ "${force}" -eq 1 ]]; then
    hm_confirm_plan_critical "users del ${login}" "Usunięcie konta chronionego." "userdel -r ${login}" || return 0
  else
    hm_confirm_plan "users del ${login}" "Usuwa konto i home." "userdel -r ${login}" || return 0
  fi
  cmd_users_sudo revoke "${login}" 2>/dev/null || true
  if [[ "${HMTOOLS_TEST:-}" == "1" ]]; then
    local pf
    pf="$(hm_users_passwd_file)"
    grep -v "^${login}:" "${pf}" > "${pf}.tmp" && mv -f "${pf}.tmp" "${pf}"
    printf 'deleted %s\n' "${login}" >> "${HM_USERS_ACTION_LOG:-/dev/null}"
    hm_ok "Usunięto ${login} (test)"
    return 0
  fi
  userdel -r "${login}" && hm_ok "Usunięto ${login}"
}

hm_users_sudoers_write() {
  local login="$1" dest tmp
  dest="$(hm_users_sudoers_dir)/hm-${login}"
  tmp="$(mktemp)"
  printf '%s ALL=(ALL) ALL\n' "${login}" > "${tmp}"
  chmod 0440 "${tmp}"
  if hm_have_cmd visudo; then
    if ! visudo -c -f "${tmp}" >/dev/null 2>&1; then
      hm_err "visudo -c nie przeszedł — nie zapisuję."
      rm -f "${tmp}"
      return 1
    fi
  fi
  mkdir -p "$(hm_users_sudoers_dir)"
  mv -f "${tmp}" "${dest}"
  chmod 0440 "${dest}"
  hm_ok "sudoers: ${dest}"
}

cmd_users_sudo() {
  local action="${1:-}" login="${2:-}"
  [[ -n "${action}" && -n "${login}" ]] || {
    hm_err "Użycie: users sudo grant|revoke <login>"; return 1
  }
  case "${action}" in
    grant)
      hm_confirm_plan "users sudo grant ${login}" "Nadaje sudo przez /etc/sudoers.d/hm-${login}." \
        "visudo -c + zapis" || return 0
      hm_users_sudoers_write "${login}"
      ;;
    revoke)
      hm_confirm_plan "users sudo revoke ${login}" "Usuwa /etc/sudoers.d/hm-${login}." \
        "rm sudoers.d/hm-${login}" || return 0
      rm -f -- "$(hm_users_sudoers_dir)/hm-${login}"
      hm_ok "Usunięto sudo dla ${login}"
      ;;
    *) hm_err "Użycie: users sudo grant|revoke <login>"; return 1 ;;
  esac
}

cmd_users_audit() {
  local pf sf line login uid shell home nuid0=0
  pf="$(hm_users_passwd_file)"
  sf="$(hm_users_shadow_file)"
  echo "${C_BOLD}users audit${C_RESET}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" == \#* || -z "${line}" ]] && continue
    login="${line%%:*}"
    uid="$(printf '%s' "${line}" | cut -d: -f3)"
    shell="$(printf '%s' "${line}" | cut -d: -f7)"
    if [[ "${uid}" == "0" ]]; then
      nuid0=$((nuid0 + 1))
      [[ "${login}" != "root" ]] && echo "  ALERT drugi UID 0: ${login}"
    fi
    if [[ "${uid}" =~ ^[0-9]+$ && "${uid}" -lt 1000 ]]; then
      case "${shell}" in
        */bash|*/sh)
          case "${login}" in
            root|sync|shutdown|halt) ;;
            *) echo "  WARN shell logowania u konta systemowego: ${login} (${shell})" ;;
          esac
          ;;
      esac
    fi
  done < "${pf}"
  [[ "${nuid0}" -gt 1 ]] && echo "  ALERT liczba UID 0: ${nuid0}" || echo "  OK   jeden UID 0 (root)"
  if [[ -f "${sf}" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      login="${line%%:*}"
      local hash
      hash="$(printf '%s' "${line}" | cut -d: -f2)"
      if [[ -z "${hash}" ]]; then
        echo "  ALERT puste hasło: ${login}"
      fi
    done < "${sf}"
  fi
  local sd f
  sd="$(hm_users_sudoers_dir)"
  if [[ -d "${sd}" ]]; then
    while IFS= read -r f; do
      [[ -f "${f}" ]] || continue
      if grep -Eq 'NOPASSWD' "${f}" 2>/dev/null; then
        echo "  WARN NOPASSWD w $(basename "${f}")"
      fi
    done < <(find "${sd}" -type f 2>/dev/null || true)
  fi
}

cmd_users() {
  local sub="${1:-list}"
  shift || true
  case "${sub}" in
    list|ls|"") cmd_users_list "$@" ;;
    add) cmd_users_add "$@" ;;
    lock) cmd_users_lock "$@" ;;
    unlock) cmd_users_unlock "$@" ;;
    expire) cmd_users_expire "$@" ;;
    del|delete|rm) cmd_users_del "$@" ;;
    sudo) cmd_users_sudo "$@" ;;
    audit) cmd_users_audit "$@" ;;
    help|-h|--help) hm_help_topic users ;;
    *) hm_err "Nieznane: ${sub}. users help"; return 1 ;;
  esac
}

_hm_cmd_register users cmd_users 0 user
