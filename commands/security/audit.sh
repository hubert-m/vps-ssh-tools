#!/usr/bin/env bash
# security audit — lista kontrolna ze scoringiem. SSH nie jest zapisywane tutaj.

hm_sec_audit_add() {
  local id="$1" group="$2" weight="$3" status="$4" desc="$5" fix="$6"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${id}" "${group}" "${weight}" "${status}" "${desc}" "${fix}" >> "${HM_SEC_AUDIT_ROWS}"
}

hm_sec_audit_sshd() {
  local file="${HM_SEC_AUDIT_SSHD:-/etc/ssh/sshd_config}" key="$1" val="" line re
  [[ -f "${file}" ]] || return 0
  re="^[[:space:]]*${key}[[:space:]]+([^[:space:]#]+)"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ "${line}" =~ ${re} ]] || continue
    val="${BASH_REMATCH[1]:-}"
  done < "${file}"
  printf '%s' "${val}"
}

hm_sec_audit_sysctl_get() {
  local key="$1" file="${HM_SEC_AUDIT_SYSCTL:-}" line k v re
  re='^[[:space:]]*([^=[:space:]]+)[[:space:]]*=[[:space:]]*([^[:space:]]+)'
  if [[ -n "${file}" && -f "${file}" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ "${line}" =~ ^[[:space:]]*# ]] && continue
      [[ "${line}" =~ ${re} ]] || continue
      k="${BASH_REMATCH[1]:-}"
      v="${BASH_REMATCH[2]:-}"
      [[ "${k}" == "${key}" ]] || continue
      printf '%s' "${v}"
      return 0
    done < "${file}"
    return 1
  fi
  if hm_have_cmd sysctl; then
    sysctl -n "${key}" 2>/dev/null || return 1
    return 0
  fi
  return 1
}

hm_sec_audit_checks() {
  local v st fix
  v="$(hm_sec_audit_sshd PermitRootLogin)"
  case "${v}" in
    no|prohibit-password) st="PASS" ;;
    yes|"") st="WARN" ;;
    *) st="WARN" ;;
  esac
  hm_sec_audit_add ssh-root ssh 8 "${st}" "PermitRootLogin=${v:-brak}" "security ssh set root-login prohibit-password"
  v="$(hm_sec_audit_sshd PasswordAuthentication)"
  case "${v}" in
    no) st="PASS" ;;
    *) st="WARN" ;;
  esac
  hm_sec_audit_add ssh-pass ssh 6 "${st}" "PasswordAuthentication=${v:-brak}" "security ssh set password-auth no"
  v="$(hm_sec_audit_sshd MaxAuthTries)"
  if [[ "${v}" =~ ^[0-9]+$ && "${v}" -le 6 ]]; then
    st="PASS"
  elif [[ -z "${v}" ]]; then
    st="WARN"
  else
    st="WARN"
  fi
  hm_sec_audit_add ssh-tries ssh 4 "${st}" "MaxAuthTries=${v:-brak}" "ustaw MaxAuthTries 4 w sshd (przez security ssh set, z rollbackiem)"

  hm_sec_audit_sysctl kernel-aslr kernel 8 kernel.randomize_va_space 2 "ASLR wyłączone"
  hm_sec_audit_sysctl kernel-symlinks kernel 6 fs.protected_symlinks 1 "symlinki w world-writable nie są chronione"
  hm_sec_audit_sysctl kernel-hardlinks kernel 4 fs.protected_hardlinks 1 "hardlinki nie są chronione"
  hm_sec_audit_sysctl kernel-rpfilter kernel 6 net.ipv4.conf.all.rp_filter 1 "rp_filter wyłączony"
  hm_sec_audit_sysctl kernel-syncookies kernel 6 net.ipv4.tcp_syncookies 1 "brak SYN cookies"

  hm_sec_audit_shadow
  hm_sec_audit_suid
  hm_sec_audit_ww
  hm_sec_audit_listen
  hm_sec_audit_updates
  hm_sec_audit_php
  hm_sec_audit_svc
}

hm_sec_audit_sysctl() {
  local id="$1" group="$2" weight="$3" key="$4" want="$5" desc="$6" got=""
  got="$(hm_sec_audit_sysctl_get "${key}" 2>/dev/null || true)"
  if [[ "${got}" == "${want}" ]]; then
    hm_sec_audit_add "${id}" "${group}" "${weight}" PASS "${key}=${got}" "sysctl ${key}=${want}"
  elif [[ -z "${got}" ]]; then
    hm_sec_audit_add "${id}" "${group}" "${weight}" WARN "${key} nieodczytane" "sysctl ${key}=${want}"
  else
    hm_sec_audit_add "${id}" "${group}" "${weight}" FAIL "${desc} (${key}=${got})" "security audit --fix ${id}"
  fi
}

hm_sec_audit_shadow() {
  local mode="${HM_SEC_AUDIT_SHADOW_MODE:-}"
  if [[ -z "${mode}" && -e /etc/shadow ]]; then
    mode="$(stat -c '%a' -- /etc/shadow 2>/dev/null || true)"
  fi
  case "${mode}" in
    600|640|400|440|000) hm_sec_audit_add fs-shadow fs 8 PASS "/etc/shadow ${mode}" "chmod 640 /etc/shadow" ;;
    "") hm_sec_audit_add fs-shadow fs 8 WARN "brak odczytu /etc/shadow" "chmod 640 /etc/shadow" ;;
    *) hm_sec_audit_add fs-shadow fs 8 FAIL "/etc/shadow mode ${mode}" "chmod 640 /etc/shadow" ;;
  esac
}

hm_sec_audit_suid_allowed() {
  case "$1" in
    /usr/bin/sudo|/usr/bin/passwd|/usr/bin/su|/usr/bin/mount|/usr/bin/umount|/usr/bin/chsh|/usr/bin/chfn|/usr/bin/chage|/usr/bin/gpasswd|/usr/bin/newgrp|/usr/lib/openssh/ssh-keysign|/usr/bin/fusermount|/usr/bin/fusermount3) return 0 ;;
    *) return 1 ;;
  esac
}

hm_sec_audit_suid() {
  local file="${HM_SEC_AUDIT_SUID:-}" path extra=0
  if [[ -z "${file}" ]]; then
    hm_sec_audit_add fs-suid fs 4 WARN "brak listy SUID (ustaw skan albo fixture)" "przejrzyj find / -perm -4000"
    return 0
  fi
  while IFS= read -r path || [[ -n "${path}" ]]; do
    [[ -n "${path}" ]] || continue
    hm_sec_audit_suid_allowed "${path}" || extra=$((extra + 1))
  done < "${file}"
  if [[ "${extra}" -eq 0 ]]; then
    hm_sec_audit_add fs-suid fs 4 PASS "SUID tylko z listy dozwolonych" "usuń zbędny SUID"
  else
    hm_sec_audit_add fs-suid fs 4 WARN "SUID spoza listy: ${extra}" "usuń zbędny SUID"
  fi
}

hm_sec_audit_ww() {
  local file="${HM_SEC_AUDIT_WW:-}" path etc=0 doc=0
  if [[ -z "${file}" ]]; then
    hm_sec_audit_add fs-ww fs 8 WARN "brak listy world-writable" "find /etc -perm -0002"
    return 0
  fi
  while IFS= read -r path || [[ -n "${path}" ]]; do
    [[ -n "${path}" ]] || continue
    case "${path}" in
      /etc|/etc/*) etc=$((etc + 1)) ;;
      *) doc=$((doc + 1)) ;;
    esac
  done < "${file}"
  if [[ "${etc}" -gt 0 ]]; then
    hm_sec_audit_add fs-ww fs 8 FAIL "world-writable w /etc: ${etc}" "chmod o-w na plikach /etc"
  elif [[ "${doc}" -gt 0 ]]; then
    hm_sec_audit_add fs-ww fs 8 WARN "world-writable poza /etc: ${doc}" "chmod o-w w docrootach"
  else
    hm_sec_audit_add fs-ww fs 8 PASS "brak world-writable" "chmod o-w"
  fi
}

hm_sec_audit_listen_bad() {
  case "$1" in
    3306|6379|7080|11211|9200|27017) return 0 ;;
    *) return 1 ;;
  esac
}

hm_sec_audit_listen() {
  local file="${HM_SEC_AUDIT_LISTEN:-}" line ip port bad=0
  if [[ -z "${file}" ]]; then
    hm_sec_audit_add svc-listen services 8 WARN "brak listy nasłuchu" "security ports"
    return 0
  fi
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" =~ ^([^:]+):([0-9]+)$ ]] || continue
    ip="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
    [[ "${ip}" == "0.0.0.0" || "${ip}" == "*" || "${ip}" == "[::]" ]] || continue
    if hm_sec_audit_listen_bad "${port}"; then
      bad=$((bad + 1))
    fi
  done < "${file}"
  if [[ "${bad}" -eq 0 ]]; then
    hm_sec_audit_add svc-listen services 8 PASS "brak baz na 0.0.0.0" "security ports"
  else
    hm_sec_audit_add svc-listen services 8 FAIL "usługa danych na 0.0.0.0 (${bad})" "security ports — zwiąż 127.0.0.1"
  fi
}

hm_sec_audit_updates() {
  local n="${HM_SEC_AUDIT_SEC_UPDATES:-}" reb="${HM_SEC_AUDIT_REBOOT:-}"
  if [[ -z "${n}" ]] && declare -F hm_pkg_list_security >/dev/null 2>&1; then
    n="$(hm_pkg_list_security 2>/dev/null | grep -c . || true)"
  fi
  if [[ -z "${n}" ]]; then
    hm_sec_audit_add upd-security updates 8 WARN "brak liczby poprawek security" "update security"
  elif [[ "${n}" == "0" ]]; then
    hm_sec_audit_add upd-security updates 8 PASS "brak oczekujących poprawek security" "update security"
  else
    hm_sec_audit_add upd-security updates 8 FAIL "poprawki security: ${n}" "update security"
  fi
  case "${reb}" in
    no|"") hm_sec_audit_add upd-reboot updates 4 PASS "reboot nie jest wymagany" "reboot" ;;
    yes) hm_sec_audit_add upd-reboot updates 4 WARN "wymagany restart" "reboot" ;;
    *) hm_sec_audit_add upd-reboot updates 4 WARN "reboot: ${reb}" "reboot" ;;
  esac
}

hm_sec_audit_php() {
  local file="${HM_SEC_AUDIT_PHP:-}" ver="" disp="" base="" expose="" st="" pair=""
  if [[ ! -f "${file}" ]]; then
    hm_sec_audit_add php-eol php 8 WARN "brak danych PHP" "update-php"
    hm_sec_audit_add php-display php 6 WARN "brak display_errors" "display_errors=Off"
    hm_sec_audit_add php-basedir php 4 WARN "brak open_basedir" "ustaw open_basedir"
    hm_sec_audit_add php-expose php 4 WARN "brak expose_php" "expose_php=Off"
    return 0
  fi
  IFS=$'\t' read -r ver disp base expose < "${file}" || true
  if declare -F hm_site_php_support_of >/dev/null 2>&1 && [[ "${ver}" =~ ^[0-9]+\.[0-9]+ ]]; then
    pair="$(hm_site_php_support_of "${ver}" 2>/dev/null || true)"
    st="${pair%%$'\t'*}"
  else
    case "${ver}" in
      8.4|8.5) st="active" ;;
      8.3|8.2) st="security" ;;
      *) st="eol" ;;
    esac
  fi
  case "${st}" in
    active) hm_sec_audit_add php-eol php 8 PASS "PHP ${ver} active" "update-php" ;;
    security) hm_sec_audit_add php-eol php 8 WARN "PHP ${ver} tylko security" "update-php" ;;
    *) hm_sec_audit_add php-eol php 8 FAIL "PHP ${ver:-?} EOL" "update-php" ;;
  esac
  case "$(printf '%s' "${disp}" | tr '[:upper:]' '[:lower:]')" in
    off|0) hm_sec_audit_add php-display php 6 PASS "display_errors Off" "display_errors=Off" ;;
    "") hm_sec_audit_add php-display php 6 WARN "display_errors nieznane" "display_errors=Off" ;;
    *) hm_sec_audit_add php-display php 6 FAIL "display_errors włączone" "display_errors=Off" ;;
  esac
  if [[ -n "${base}" && "${base}" != "-" ]]; then
    hm_sec_audit_add php-basedir php 4 PASS "open_basedir ustawione" "ustaw open_basedir"
  else
    hm_sec_audit_add php-basedir php 4 WARN "brak open_basedir" "ustaw open_basedir"
  fi
  case "$(printf '%s' "${expose}" | tr '[:upper:]' '[:lower:]')" in
    off|0) hm_sec_audit_add php-expose php 4 PASS "expose_php Off" "expose_php=Off" ;;
    "") hm_sec_audit_add php-expose php 4 WARN "expose_php nieznane" "expose_php=Off" ;;
    *) hm_sec_audit_add php-expose php 4 WARN "expose_php On" "expose_php=Off" ;;
  esac
}

hm_sec_audit_svc() {
  local f2b="${HM_SEC_AUDIT_F2B:-}" fw="${HM_SEC_AUDIT_FW:-}"
  case "${f2b}" in
    active|yes) hm_sec_audit_add svc-f2b services 6 PASS "fail2ban aktywny" "security fail2ban" ;;
    "") hm_sec_audit_add svc-f2b services 6 WARN "fail2ban nieznany" "security fail2ban" ;;
    *) hm_sec_audit_add svc-f2b services 6 WARN "fail2ban nieaktywny" "security fail2ban" ;;
  esac
  case "${fw}" in
    active|yes) hm_sec_audit_add svc-fw services 8 PASS "firewall aktywny" "hm_os_firewall_status" ;;
    "") hm_sec_audit_add svc-fw services 8 WARN "firewall nieznany" "włącz ufw/firewalld/csf" ;;
    *) hm_sec_audit_add svc-fw services 8 FAIL "firewall wyłączony" "włącz ufw/firewalld/csf" ;;
  esac
}

hm_sec_audit_score() {
  local id group weight status desc fix earned=0 total=0
  while IFS=$'\t' read -r id group weight status desc fix; do
    [[ "${status}" == "PASS" || "${status}" == "WARN" || "${status}" == "FAIL" ]] || continue
    total=$((total + weight))
    case "${status}" in
      PASS) earned=$((earned + weight)) ;;
      WARN) earned=$((earned + weight / 2)) ;;
    esac
  done < "${HM_SEC_AUDIT_ROWS}"
  if [[ "${total}" -eq 0 ]]; then
    printf '0'
    return 0
  fi
  printf '%s' "$((earned * 100 / total))"
}

hm_sec_audit_json_escape() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "${s}"
}

hm_sec_audit_print() {
  local json="$1" only="$2" id group weight status desc fix first=1 score
  score="$(hm_sec_audit_score)"
  if [[ "${json}" -eq 1 ]]; then
    printf '{"score":%s,"checks":[' "${score}"
  else
    echo "${C_BOLD}security audit${C_RESET}  wynik ${score}/100"
    hm_table_begin
    hm_table_row "id" "wynik" "waga" "naprawa"
  fi
  while IFS=$'\t' read -r id group weight status desc fix; do
    [[ -n "${id}" ]] || continue
    [[ -z "${only}" || "${group}" == "${only}" ]] || continue
    if [[ "${json}" -eq 1 ]]; then
      [[ "${first}" -eq 1 ]] || printf ','
      first=0
      printf '{"id":"%s","group":"%s","weight":%s,"status":"%s","desc":"%s","fix":"%s"}' \
        "$(hm_sec_audit_json_escape "${id}")" \
        "$(hm_sec_audit_json_escape "${group}")" \
        "${weight}" \
        "$(hm_sec_audit_json_escape "${status}")" \
        "$(hm_sec_audit_json_escape "${desc}")" \
        "$(hm_sec_audit_json_escape "${fix}")"
    else
      hm_table_row "${id}" "${status}" "${weight}" "${fix}"
    fi
  done < "${HM_SEC_AUDIT_ROWS}"
  if [[ "${json}" -eq 1 ]]; then
    printf ']}\n'
  else
    hm_table_print 2
  fi
}

hm_sec_audit_fix() {
  local id="$1" yes="$2" dest line
  case "${id}" in
    ssh-root|ssh-pass|ssh-tries)
      hm_err "Audyt nie zapisuje sshd. Naprawa: komenda z listy (security ssh set ma rollback 120 s)."
      return 1
      ;;
    kernel-aslr) line="kernel.randomize_va_space = 2" ;;
    kernel-symlinks) line="fs.protected_symlinks = 1" ;;
    kernel-hardlinks) line="fs.protected_hardlinks = 1" ;;
    kernel-rpfilter) line="net.ipv4.conf.all.rp_filter = 1" ;;
    kernel-syncookies) line="net.ipv4.tcp_syncookies = 1" ;;
    *)
      hm_err "Brak automatycznej naprawy dla ${id}. Użyj komendy z kolumny naprawa."
      return 1
      ;;
  esac
  dest="${HM_SEC_AUDIT_SYSCTL_OUT:-/etc/sysctl.d/99-hmtools-audit.conf}"
  if declare -F hm_confirm_plan >/dev/null 2>&1; then
    if [[ "${yes}" -eq 1 ]]; then
      hm_confirm_plan "security audit --fix ${id}" "Tryb --yes." --yes \
        "Dopisanie ${line} do ${dest}" || return 1
    else
      hm_confirm_plan "security audit --fix ${id}" \
        "Plik można usunąć, żeby cofnąć zmianę. sshd nie jest ruszane." \
        "Dopisanie ${line} do ${dest}" || return 1
    fi
  fi
  mkdir -p "$(dirname "${dest}")"
  printf '%s\n' "${line}" >> "${dest}"
  hm_ok "Zapisano ${dest}. Cofnięcie: usuń tę linię."
}

cmd_security_audit() {
  local json=0 only="" fix="" yes=0 a
  while [[ $# -gt 0 ]]; do
    a="$1"
    shift
    case "${a}" in
      --json) json=1 ;;
      --yes|-y) yes=1 ;;
      --only)
        only="${1:-}"
        shift || true
        ;;
      --only=*) only="${a#--only=}" ;;
      --fix)
        fix="${1:-}"
        shift || true
        ;;
      --fix=*) fix="${a#--fix=}" ;;
      help|-h|--help)
        hm_help_topic security
        return 0
        ;;
      *)
        hm_err "Nieznany argument: ${a}"
        return 1
        ;;
    esac
  done
  case "${only}" in
    ""|ssh|kernel|fs|services|web|php|updates) ;;
    *)
      hm_err "Nieznana grupa: ${only}"
      return 1
      ;;
  esac
  if [[ -n "${fix}" ]]; then
    hm_sec_audit_fix "${fix}" "${yes}"
    return $?
  fi
  HM_SEC_AUDIT_ROWS="$(mktemp "${TMPDIR:-/tmp}/hm-audit.XXXXXX")"
  hm_sec_audit_checks
  hm_sec_audit_print "${json}" "${only}"
  rm -f "${HM_SEC_AUDIT_ROWS}"
}
