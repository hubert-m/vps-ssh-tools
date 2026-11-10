#!/usr/bin/env bash
# security events — logi auth i stan systemu. Alerty bez sekretów, każde zdarzenie raz.

hm_sec_events_state() {
  printf '%s' "${HM_SEC_EVENTS_STATE:-/var/lib/hmtools/security-events}"
}

hm_sec_events_host() {
  if [[ -n "${HM_SEC_EVENTS_HOST:-}" ]]; then
    printf '%s' "${HM_SEC_EVENTS_HOST}"
    return 0
  fi
  hostname 2>/dev/null || printf 'localhost'
}

hm_sec_events_now() {
  if [[ -n "${HM_SEC_EVENTS_NOW:-}" ]]; then
    date -d "${HM_SEC_EVENTS_NOW}" +%s 2>/dev/null || date +%s
  else
    date +%s
  fi
}

hm_sec_events_cutoff() {
  local spec="${1:-24h}" n=24 mult=3600 now
  now="$(hm_sec_events_now)"
  if [[ "${spec}" =~ ^([0-9]+)([mhd])$ ]]; then
    n="${BASH_REMATCH[1]}"
    case "${BASH_REMATCH[2]}" in
      m) mult=60 ;;
      h) mult=3600 ;;
      d) mult=86400 ;;
    esac
  fi
  printf '%s' "$((now - n * mult))"
}

hm_sec_events_epoch() {
  local when="$1" now year
  now="$(hm_sec_events_now)"
  year="$(date -d "@${now}" +%Y 2>/dev/null || date +%Y)"
  date -d "${when} ${year}" +%s 2>/dev/null || printf '0'
}

hm_sec_events_log() {
  local f
  if [[ -n "${HM_SEC_EVENTS_LOG:-}" ]]; then
    printf '%s' "${HM_SEC_EVENTS_LOG}"
    return 0
  fi
  for f in /var/log/auth.log /var/log/secure; do
    if [[ -f "${f}" ]]; then
      printf '%s' "${f}"
      return 0
    fi
  done
  return 1
}

hm_sec_events_sha() {
  local path="$1" sum=""
  [[ -f "${path}" && ! -L "${path}" ]] || return 1
  if hm_have_cmd sha256sum; then
    sum="$(sha256sum -- "${path}" 2>/dev/null | awk '{print $1}' || true)"
    sum="${sum#\\}"
  elif hm_have_cmd openssl; then
    sum="$(openssl dgst -sha256 "${path}" 2>/dev/null | awk '{print $NF}' || true)"
  else
    return 1
  fi
  [[ "${sum}" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
  printf '%s' "${sum}"
}

hm_sec_events_ensure() {
  local dir
  dir="$(hm_sec_events_state)"
  mkdir -p "${dir}"
  chmod 0700 "${dir}" 2>/dev/null || true
}

hm_sec_events_seen() {
  local fp="$1" file
  file="$(hm_sec_events_state)/seen"
  [[ -f "${file}" ]] || return 1
  grep -qxF "${fp}" "${file}"
}

hm_sec_events_mark() {
  local fp="$1" file
  hm_sec_events_ensure
  file="$(hm_sec_events_state)/seen"
  printf '%s\n' "${fp}" >> "${file}"
  chmod 0600 "${file}" 2>/dev/null || true
}

hm_sec_events_fp() {
  local kind="$1" user="$2" ip="$3" when="$4" detail="$5" raw
  raw="$(printf '%s|%s|%s|%s|%s' "${kind}" "${user}" "${ip}" "${when}" "${detail}" | sha256sum 2>/dev/null | awk '{print $1}')"
  raw="${raw#\\}"
  printf '%s' "${raw}"
}

hm_sec_events_ip_known() {
  local ip="$1" f
  for f in "${HM_SEC_EVENTS_KNOWN:-}" "${HM_SEC_EVENTS_WHITELIST:-}"; do
    [[ -n "${f}" && -f "${f}" ]] || continue
    grep -qxF "${ip}" "${f}" && return 0
  done
  f="$(hm_sec_events_state)/known-ips"
  [[ -f "${f}" ]] && grep -qxF "${ip}" "${f}" && return 0
  return 1
}

hm_sec_events_learn_ip() {
  local ip="$1" f
  [[ -n "${ip}" ]] || return 0
  hm_sec_events_ensure
  f="$(hm_sec_events_state)/known-ips"
  grep -qxF "${ip}" "${f}" 2>/dev/null && return 0
  printf '%s\n' "${ip}" >> "${f}"
  chmod 0600 "${f}" 2>/dev/null || true
}

hm_sec_events_geo() {
  local ip="$1" map="${HM_SEC_EVENTS_GEOIP:-}" a b
  [[ -n "${map}" && -f "${map}" ]] || return 1
  while read -r a b _; do
    [[ "${a}" == "${ip}" ]] || continue
    printf '%s' "${b}"
    return 0
  done < "${map}"
  return 1
}

# Jedna linia logu → zdarzenia na stdout: when<TAB>kind<TAB>user<TAB>ip<TAB>detail
# Wzorce w zmiennych: nawias w [[ =~ ]] inaczej ucina wyrażenie.
hm_sec_events_parse_line() {
  local line="$1" when="" user="" ip="" country=""
  local re_when='^([A-Z][a-z]{2}[[:space:]]+[0-9]{1,2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2})'
  local re_acc='Accepted[[:space:]]+[A-Za-z0-9-]+[[:space:]]+for[[:space:]]+([^[:space:]]+)[[:space:]]+from[[:space:]]+([0-9A-Fa-f:.]+)'
  local re_sudo='sudo:[[:space:]]+([^[:space:]]+)[[:space:]]+:'
  local re_pam='session[[:space:]]+opened[[:space:]]+for[[:space:]]+user[[:space:]]+[^[:space:]]+[[:space:]]+by[[:space:]]+([^[:space:]]+)'
  local re_su='\(to[[:space:]]+[^)]+\)[[:space:]]+([^[:space:]]+)'
  local re_add='new[[:space:]]+user:[[:space:]]+name=([^,[:space:]]+)'
  [[ "${line}" =~ ${re_when} ]] || return 0
  when="${BASH_REMATCH[1]:-}"
  [[ -n "${when}" ]] || return 0
  if [[ "${line}" =~ ${re_acc} ]]; then
    user="${BASH_REMATCH[1]:-}"
    ip="${BASH_REMATCH[2]:-}"
    [[ -n "${user}" && -n "${ip}" ]] || return 0
    country="$(hm_sec_events_geo "${ip}" 2>/dev/null || true)"
    if [[ "${user}" == "root" ]]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "${when}" "ssh-root" "${user}" "${ip}" "${country}"
    fi
    if ! hm_sec_events_ip_known "${ip}"; then
      printf '%s\t%s\t%s\t%s\t%s\n' "${when}" "ssh-new-ip" "${user}" "${ip}" "${country}"
      hm_sec_events_learn_ip "${ip}"
    fi
    return 0
  fi
  if [[ "${line}" =~ ${re_sudo} ]]; then
    user="${BASH_REMATCH[1]:-}"
    if [[ -n "${user}" && "${user}" != pam_unix* ]]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "${when}" "sudo" "${user}" "" "sudo"
      return 0
    fi
  fi
  if [[ "${line}" =~ ${re_pam} ]]; then
    user="${BASH_REMATCH[1]:-}"
    user="${user%%\(*}"
    [[ -n "${user}" ]] || return 0
    printf '%s\t%s\t%s\t%s\t%s\n' "${when}" "sudo" "${user}" "" "sudo"
    return 0
  fi
  if [[ "${line}" =~ ${re_su} ]]; then
    user="${BASH_REMATCH[1]:-}"
    [[ -n "${user}" ]] || return 0
    printf '%s\t%s\t%s\t%s\t%s\n' "${when}" "su" "${user}" "" "su"
    return 0
  fi
  if [[ "${line}" =~ ${re_add} ]]; then
    user="${BASH_REMATCH[1]:-}"
    [[ -n "${user}" ]] || return 0
    printf '%s\t%s\t%s\t%s\t%s\n' "${when}" "user-add" "${user}" "" "nowy user"
  fi
}

hm_sec_events_read_log() {
  local log="$1" from="${2:-0}" size=0
  [[ -f "${log}" ]] || return 0
  size="$(wc -c < "${log}" | tr -d '[:space:]')"
  [[ "${size}" =~ ^[0-9]+$ ]] || size=0
  if [[ "${from}" -gt "${size}" ]]; then
    from=0
  fi
  tail -c +"$((from + 1))" "${log}" 2>/dev/null || true
}

hm_sec_events_collect_log() {
  local log="$1" from="${2:-0}" line
  log="$(hm_sec_events_log)" || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    hm_sec_events_parse_line "${line}"
  done < <(hm_sec_events_read_log "${log}" "${from}")
}

hm_sec_events_uid0() {
  local file="${HM_SEC_EVENTS_PASSWD:-/etc/passwd}" name uid
  [[ -f "${file}" ]] || return 0
  while IFS=: read -r name _ uid _; do
    [[ "${uid}" == "0" ]] || continue
    printf '%s\n' "${name}"
  done < "${file}"
}

hm_sec_events_scan_files() {
  local when dir prev cur name home keys hash old snap
  when="$(date -d "@$(hm_sec_events_now)" '+%b %e %H:%M:%S' 2>/dev/null || date '+%b %e %H:%M:%S')"
  dir="$(hm_sec_events_state)"
  hm_sec_events_ensure

  snap="${dir}/uid0"
  cur="$(hm_sec_events_uid0 | sort)"
  if [[ -f "${snap}" ]]; then
    while IFS= read -r name; do
      [[ -n "${name}" ]] || continue
      grep -qxF "${name}" "${snap}" && continue
      printf '%s\t%s\t%s\t%s\t%s\n' "${when}" "uid0" "${name}" "" "drugi uid 0"
    done <<< "${cur}"
  fi
  printf '%s\n' "${cur}" > "${snap}"

  if [[ -n "${HM_SEC_EVENTS_PASSWD:-}" && -f "${HM_SEC_EVENTS_PASSWD}" ]]; then
    hm_sec_events_file_diff "passwd" "${HM_SEC_EVENTS_PASSWD}" "${when}"
  fi
  if [[ -n "${HM_SEC_EVENTS_SHADOW:-}" ]]; then
    hm_sec_events_file_diff "shadow" "${HM_SEC_EVENTS_SHADOW}" "${when}"
  fi
  if [[ -n "${HM_SEC_EVENTS_SUDOERS:-}" ]]; then
    hm_sec_events_file_diff "sudoers" "${HM_SEC_EVENTS_SUDOERS}" "${when}"
  fi

  local passwd="${HM_SEC_EVENTS_PASSWD:-/etc/passwd}"
  [[ -f "${passwd}" ]] || return 0
  while IFS=: read -r name _ _ _ _ home _; do
    [[ -n "${home}" && "${home}" != "/" ]] || continue
    keys="${home}/.ssh/authorized_keys"
    [[ -f "${keys}" && ! -L "${keys}" ]] || continue
    hash="$(hm_sec_events_sha "${keys}" 2>/dev/null || true)"
    [[ -n "${hash}" ]] || continue
    old="${dir}/keys.${name}"
    if [[ -f "${old}" ]]; then
      prev="$(cat "${old}")"
      if [[ "${prev}" != "${hash}" ]]; then
        printf '%s\t%s\t%s\t%s\t%s\n' "${when}" "keys" "${name}" "" "authorized_keys"
      fi
    fi
    printf '%s\n' "${hash}" > "${old}"
    chmod 0600 "${old}" 2>/dev/null || true
  done < "${passwd}"

  hm_sec_events_ports "${when}"
  hm_sec_events_bans "${when}"
}

hm_sec_events_file_diff() {
  local kind="$1" path="$2" when="$3" hash="" old="" prev="" slot
  [[ -f "${path}" && ! -L "${path}" ]] || return 0
  hash="$(hm_sec_events_sha "${path}" 2>/dev/null || true)"
  [[ -n "${hash}" ]] || return 0
  slot="$(hm_sec_events_state)/file.${kind}"
  if [[ -f "${slot}" ]]; then
    prev="$(cat "${slot}")"
    if [[ "${prev}" != "${hash}" ]]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "${when}" "file" "" "" "${path}"
    fi
  fi
  printf '%s\n' "${hash}" > "${slot}"
}

hm_sec_events_ports() {
  local when="$1" file="${HM_SEC_EVENTS_PORTS:-}" snap cur p
  [[ -n "${file}" && -f "${file}" ]] || return 0
  snap="$(hm_sec_events_state)/ports"
  cur="$(sort "${file}")"
  if [[ -f "${snap}" ]]; then
    while IFS= read -r p; do
      [[ -n "${p}" ]] || continue
      grep -qxF "${p}" "${snap}" && continue
      printf '%s\t%s\t%s\t%s\t%s\n' "${when}" "port" "" "" "port ${p}"
    done <<< "${cur}"
  fi
  printf '%s\n' "${cur}" > "${snap}"
}

hm_sec_events_bans() {
  local when="$1" file="${HM_SEC_EVENTS_BANS:-}" snap n=0 prev=0 pt=0 now dt
  [[ -n "${file}" && -f "${file}" ]] || return 0
  n="$(tr -d '[:space:]' < "${file}")"
  [[ "${n}" =~ ^[0-9]+$ ]] || return 0
  snap="$(hm_sec_events_state)/bans"
  now="$(hm_sec_events_now)"
  if [[ -f "${snap}" ]]; then
    read -r prev pt < "${snap}" || true
    [[ "${prev}" =~ ^[0-9]+$ ]] || prev=0
    [[ "${pt}" =~ ^[0-9]+$ ]] || pt=0
    dt=$((now - pt))
    if [[ "${dt}" -ge 0 && "${dt}" -le 3600 && $((n - prev)) -gt 50 ]]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "${when}" "bans" "" "" "skok banów"
    fi
  fi
  printf '%s %s\n' "${n}" "${now}" > "${snap}"
}

hm_sec_events_emit() {
  local when="$1" kind="$2" user="$3" ip="$4" detail="$5" host fp epoch cut
  host="$(hm_sec_events_host)"
  fp="$(hm_sec_events_fp "${kind}" "${user}" "${ip}" "${when}" "${detail}")"
  if hm_sec_events_seen "${fp}"; then
    return 0
  fi
  if [[ -n "${HM_SEC_EVENTS_CUTOFF:-}" && "${kind}" != "keys" && "${kind}" != "uid0" && "${kind}" != "file" && "${kind}" != "port" && "${kind}" != "bans" ]]; then
    epoch="$(hm_sec_events_epoch "${when}")"
    cut="${HM_SEC_EVENTS_CUTOFF}"
    [[ "${epoch}" =~ ^[0-9]+$ && "${epoch}" -ge "${cut}" ]] || return 0
  fi
  hm_sec_events_mark "${fp}"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${when}" "${kind}" "${user}" "${ip}" "${detail}" "${host}"
  if [[ "${HM_SEC_EVENTS_NOTIFY:-0}" -eq 1 ]] && declare -F hm_notify >/dev/null 2>&1; then
    hm_notify warning "Zdarzenie bezpieczeństwa" \
      "host=${host} czas=${when} zdarzenie=${kind} user=${user:--} ip=${ip:--} ${detail}" \
      "security.events.${fp}"
  fi
}

hm_sec_events_run() {
  local from=0 log size line when kind user ip detail
  HM_SEC_EVENTS_NOTIFY="${1:-0}"
  if [[ -z "${HM_SEC_EVENTS_CUTOFF:-}" ]]; then
    HM_SEC_EVENTS_CUTOFF="$(hm_sec_events_cutoff 24h)"
  fi
  hm_sec_events_ensure
  log="$(hm_sec_events_log 2>/dev/null || true)"
  if [[ -n "${log}" && -f "${log}" ]]; then
    if [[ -f "$(hm_sec_events_state)/offset" ]]; then
      read -r from _ < "$(hm_sec_events_state)/offset" || from=0
      [[ "${from}" =~ ^[0-9]+$ ]] || from=0
    fi
    while IFS=$'\t' read -r when kind user ip detail; do
      [[ -n "${kind}" ]] || continue
      hm_sec_events_emit "${when}" "${kind}" "${user}" "${ip}" "${detail}"
    done < <(hm_sec_events_collect_log "${log}" "${from}")
    size="$(wc -c < "${log}" | tr -d '[:space:]')"
    printf '%s %s\n' "${size}" "${log}" > "$(hm_sec_events_state)/offset"
  fi
  while IFS=$'\t' read -r when kind user ip detail; do
    [[ -n "${kind}" ]] || continue
    hm_sec_events_emit "${when}" "${kind}" "${user}" "${ip}" "${detail}"
  done < <(hm_sec_events_scan_files)
}

hm_sec_events_watch() {
  local action="${1:-status}" file
  file="${HM_SEC_EVENTS_CRON:-/etc/cron.d/hmtools-security-events}"
  case "${action}" in
    install|enable)
      mkdir -p "$(dirname "${file}")"
      printf '%s\n' '# hmtools-security-events' '*/5 * * * * root hmtools security events watch run' > "${file}"
      hm_ok "Cron zdarzeń (co 5 min): ${file}"
      ;;
    disable)
      if [[ -f "${file}" ]] && grep -q 'hmtools-security-events' "${file}"; then
        rm -f "${file}"
        hm_ok "Usunięto ${file}"
      else
        hm_warn "To nie jest plik hmtools-security-events."
        return 1
      fi
      ;;
    status)
      if [[ -f "${file}" ]]; then
        hm_ok "Cron zdarzeń: ${file}"
      else
        hm_warn "Brak crona zdarzeń."
        return 1
      fi
      ;;
    run)
      hm_sec_events_run 1
      ;;
    *)
      hm_err "Użycie: security events watch install|status|disable|run"
      return 1
      ;;
  esac
}

cmd_security_events() {
  local since="24h" notify=0 a
  if [[ "${1:-}" == "watch" ]]; then
    shift || true
    hm_sec_events_watch "$@"
    return $?
  fi
  while [[ $# -gt 0 ]]; do
    a="$1"
    shift
    case "${a}" in
      --notify) notify=1 ;;
      --since)
        since="${1:-24h}"
        shift || true
        ;;
      --since=*) since="${a#--since=}" ;;
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
  HM_SEC_EVENTS_CUTOFF="$(hm_sec_events_cutoff "${since}")"
  # lista od początku logu (okno --since), bez przesuwania offsetu watchera
  local saved="" log
  log="$(hm_sec_events_log 2>/dev/null || true)"
  if [[ -n "${log}" ]]; then
    saved="$(hm_sec_events_state)/offset"
  fi
  local off_copy=""
  if [[ -f "$(hm_sec_events_state)/offset" ]]; then
    off_copy="$(mktemp "${TMPDIR:-/tmp}/hm-sec-off.XXXXXX")"
    cp "$(hm_sec_events_state)/offset" "${off_copy}"
  fi
  rm -f "$(hm_sec_events_state)/offset"
  hm_sec_events_run "${notify}"
  if [[ -n "${off_copy}" && -f "${off_copy}" ]]; then
    mv -f "${off_copy}" "$(hm_sec_events_state)/offset"
  elif [[ -z "${off_copy}" ]]; then
    rm -f "$(hm_sec_events_state)/offset"
  fi
}
