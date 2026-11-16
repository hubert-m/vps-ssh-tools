#!/usr/bin/env bash
# cron monitor / cron-run — historia, lock, timeout, alert bez sekretów.

hm_cron_mon_root() { printf '%s\n' "${HM_CRON_MON:-/var/lib/hmtools/cron-mon}"; }

hm_cron_name_ok() {
  # bez kropek / „.” / „..” — ochrona przed wyjściem poza spool
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]]
}

hm_cron_seconds() {
  local spec="$1" n
  case "${spec}" in
    *h) n="${spec%h}"; printf '%s\n' "$(( n * 3600 ))" ;;
    *m) n="${spec%m}"; printf '%s\n' "$(( n * 60 ))" ;;
    *s) printf '%s\n' "${spec%s}" ;;
    *) printf '%s\n' "${spec}" ;;
  esac
}

hm_cron_redact_line() {
  local line="$1"
  # wartości sekretów — nie całe linie; typowe argv i nagłówki (bez \1 — portable sed)
  line="$(printf '%s' "${line}" | sed -E \
    -e 's/[Aa]uthorization:[[:space:]]*.*/Authorization=[redacted]/g' \
    -e 's/[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]=[^[:space:]]+/PASSWORD=[redacted]/g' \
    -e 's/[Tt][Oo][Kk][Ee][Nn]=[^[:space:]]+/token=[redacted]/g' \
    -e 's/[Aa][Pp][Ii][_-]?[Kk][Ee][Yy]=[^[:space:]]+/api_key=[redacted]/g' \
    -e 's/[Ss][Ee][Cc][Rr][Ee][Tt]=[^[:space:]]+/secret=[redacted]/g' \
    -e 's/--password[= ][^[:space:]]+/--password [redacted]/g' \
    -e 's/ -p[^[:space:]-]+/ -p[redacted]/g' \
    -e 's/SECRET-[A-Za-z0-9_-]+/[redacted]/g')"
  printf '%s\n' "${line}"
}

hm_cron_redact_file() {
  local file="$1" tmp line
  [[ -f "${file}" ]] || return 0
  tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    hm_cron_redact_line "${line}"
  done < "${file}" > "${tmp}"
  cat "${tmp}" > "${file}"
  rm -f "${tmp}"
}

hm_cron_alert() {
  local name="$1" why="$2" seen="${HM_CRON_ALERTS:-}"
  if [[ -n "${seen}" && -f "${seen}" ]] && grep -qxF "${name} ${why}" "${seen}"; then
    return 0
  fi
  if declare -F hm_notify >/dev/null 2>&1; then
    hm_notify error "cron ${name}" "${why}" "cron.${name}"
  fi
  if [[ -n "${seen}" ]]; then
    mkdir -p "$(dirname "${seen}")"
    printf '%s %s\n' "${name}" "${why}" >> "${seen}"
  fi
  printf 'alert\t%s\t%s\n' "${name}" "${why}"
}

hm_cron_exec() {
  local user="$1"
  shift
  if [[ -n "${user}" && "${user}" != "root" ]]; then
    printf 'runuser -u %s\n' "${user}" >> "${HM_CRON_EXEC_LOG:-/dev/null}"
    if [[ "${HMTOOLS_TEST:-}" == "1" ]]; then
      "$@"
      return $?
    fi
    if command -v runuser >/dev/null 2>&1; then
      runuser -u "${user}" -- "$@"
      return $?
    fi
    hm_err "Brak runuser. Nie uruchamiam ${user} jako root."
    return 1
  fi
  "$@"
}

# Lock: PID + kill -0 (stary lock znika); opcjonalnie flock; mkdir jako znacznik.
# Ustawia HM_CRON_LOCK_FD gdy flock; zwraca 1 gdy zajęty przez żywy proces.
hm_cron_lock_acquire() {
  local dir="$1" old
  mkdir -p "${dir}"
  if [[ -f "${dir}/lock.pid" ]]; then
    old="$(tr -d '\r\n' < "${dir}/lock.pid" 2>/dev/null || true)"
    if [[ -n "${old}" && "${old}" =~ ^[0-9]+$ ]] && kill -0 "${old}" 2>/dev/null; then
      return 1
    fi
    rm -f "${dir}/lock.pid"
    rmdir "${dir}/lock" 2>/dev/null || true
  fi
  if ! mkdir "${dir}/lock" 2>/dev/null; then
    old="$(tr -d '\r\n' < "${dir}/lock.pid" 2>/dev/null || true)"
    if [[ -n "${old}" && "${old}" =~ ^[0-9]+$ ]] && kill -0 "${old}" 2>/dev/null; then
      return 1
    fi
    rmdir "${dir}/lock" 2>/dev/null || rm -rf "${dir}/lock"
    mkdir "${dir}/lock" 2>/dev/null || return 1
  fi
  printf '%s\n' "$$" > "${dir}/lock.pid"
  if command -v flock >/dev/null 2>&1 && [[ "${HM_CRON_NO_FLOCK:-}" != "1" ]]; then
    exec {HM_CRON_LOCK_FD}>"${dir}/lock.flock"
    if ! flock -n "${HM_CRON_LOCK_FD}"; then
      eval "exec ${HM_CRON_LOCK_FD}>&-" 2>/dev/null || true
      unset HM_CRON_LOCK_FD
      rm -f "${dir}/lock.pid"
      rmdir "${dir}/lock" 2>/dev/null || true
      return 1
    fi
  fi
  return 0
}

hm_cron_lock_release() {
  local dir="$1"
  if [[ -n "${HM_CRON_LOCK_FD:-}" ]]; then
    flock -u "${HM_CRON_LOCK_FD}" 2>/dev/null || true
    eval "exec ${HM_CRON_LOCK_FD}>&-" 2>/dev/null || true
    unset HM_CRON_LOCK_FD
  fi
  rm -f "${dir}/lock.pid" "${dir}/lock.flock" 2>/dev/null || true
  rmdir "${dir}/lock" 2>/dev/null || true
}

hm_cron_pgid_of() {
  local pid="$1" pg
  pg="$(ps -o pgid= -p "${pid}" 2>/dev/null | tr -d ' ' || true)"
  if [[ -n "${pg}" && "${pg}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "${pg}"
  else
    printf '%s\n' "${pid}"
  fi
}

hm_cron_kill_tree() {
  local pid="$1" pgid
  pgid="$(hm_cron_pgid_of "${pid}")"
  # cała grupa procesów (setsid)
  kill -TERM -- "-${pgid}" 2>/dev/null || kill -TERM "${pid}" 2>/dev/null || true
  local i=0
  while kill -0 "${pid}" 2>/dev/null && [[ "${i}" -lt 10 ]]; do
    sleep 1
    i=$((i + 1))
  done
  if kill -0 "${pid}" 2>/dev/null; then
    kill -KILL -- "-${pgid}" 2>/dev/null || kill -KILL "${pid}" 2>/dev/null || true
  fi
  # dobij sieroty sleep z tej grupy
  if command -v pkill >/dev/null 2>&1; then
    pkill -KILL -g "${pgid}" 2>/dev/null || true
  fi
  wait "${pid}" 2>/dev/null || true
}

hm_cron_run() {
  local name="" timeout="1h" user="" dir start=0 end=0 rc=0 dur=0 limit=0 pid=0 now=0 errf
  unset HM_CRON_LOCK_FD 2>/dev/null || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout) timeout="${2:-1h}"; shift 2 || true ;;
      --) shift; break ;;
      *)
        if [[ -z "${name}" ]]; then name="$1"; shift; else break; fi
        ;;
    esac
  done
  if ! hm_cron_name_ok "${name}" || [[ $# -eq 0 ]]; then
    hm_err "Użycie: cron-run <nazwa> [--timeout 1h] -- <komenda>"
    return 1
  fi
  dir="$(hm_cron_mon_root)/${name}"
  mkdir -p "${dir}"
  if [[ -f "${dir}/user" ]]; then
    user="$(tr -d '\r\n' < "${dir}/user")"
  fi
  if ! hm_cron_lock_acquire "${dir}"; then
    printf 'lock\t%s\n' "${name}"
    hm_cron_alert "${name}" "lock" >/dev/null || true
    return 1
  fi

  start="$(date +%s)"
  errf="${dir}/stderr"
  : > "${errf}"
  limit="$(hm_cron_seconds "${timeout}")"

  # nowa grupa procesów — timeout zabija całą grupę, nie tylko subshell
  if command -v setsid >/dev/null 2>&1 && [[ "${HM_CRON_NO_SETSID:-}" != "1" ]]; then
    if [[ -n "${user}" && "${user}" != "root" && "${HMTOOLS_TEST:-}" != "1" ]]; then
      if command -v runuser >/dev/null 2>&1; then
        printf 'runuser -u %s\n' "${user}" >> "${HM_CRON_EXEC_LOG:-/dev/null}"
        setsid runuser -u "${user}" -- "$@" >"${errf}" 2>&1 &
      else
        hm_cron_lock_release "${dir}"
        hm_err "Brak runuser. Nie uruchamiam ${user} jako root."
        return 1
      fi
    else
      if [[ -n "${user}" && "${user}" != "root" ]]; then
        printf 'runuser -u %s\n' "${user}" >> "${HM_CRON_EXEC_LOG:-/dev/null}"
      fi
      setsid "$@" >"${errf}" 2>&1 &
    fi
    pid=$!
  else
    hm_cron_exec "${user}" "$@" >"${errf}" 2>&1 &
    pid=$!
  fi

  while kill -0 "${pid}" 2>/dev/null; do
    now="$(date +%s)"
    if [[ $(( now - start )) -ge "${limit}" ]]; then
      hm_cron_kill_tree "${pid}"
      rc=124
      break
    fi
    sleep 0.2
  done
  if [[ "${rc}" -ne 124 ]]; then
    wait "${pid}" || rc=$?
  fi
  # lock dopiero po śmierci procesu / grupy
  hm_cron_lock_release "${dir}"

  end="$(date +%s)"
  dur="$(( end - start ))"
  hm_cron_redact_file "${errf}"
  {
    printf 'start=%s\n' "${start}"
    printf 'end=%s\n' "${end}"
    printf 'rc=%s\n' "${rc}"
    printf 'dur=%s\n' "${dur}"
  } > "${dir}/state"
  if [[ "${rc}" -ne 0 ]]; then
    hm_cron_alert "${name}" "rc=${rc}" >/dev/null
    return "${rc}"
  fi
  return 0
}

hm_cron_monitor_add() {
  local name="" every="" grace="15m" user=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --every) every="${2:-}"; shift 2 || true ;;
      --grace) grace="${2:-15m}"; shift 2 || true ;;
      --user) user="${2:-}"; shift 2 || true ;;
      *)
        if [[ -z "${name}" ]]; then name="$1"; shift; else shift; fi
        ;;
    esac
  done
  if ! hm_cron_name_ok "${name}" || [[ -z "${every}" ]]; then
    hm_err "Użycie: cron monitor add <nazwa> --every 1h [--grace 15m] [--user u]"
    return 1
  fi
  local dir
  dir="$(hm_cron_mon_root)/${name}"
  mkdir -p "${dir}"
  hm_cron_seconds "${every}" > "${dir}/every"
  hm_cron_seconds "${grace}" > "${dir}/grace"
  if [[ -n "${user}" ]]; then
    printf '%s\n' "${user}" > "${dir}/user"
  fi
  hm_ok "Monitor ${name}."
}

hm_cron_monitor_status() {
  local root name dir end="" rc="" every=0 grace=0 now=0
  root="$(hm_cron_mon_root)"
  [[ -d "${root}" ]] || { hm_info "Brak monitorowanych zadań."; return 0; }
  now="${HM_CRON_NOW:-$(date +%s)}"
  for dir in "${root}"/*; do
    [[ -d "${dir}" ]] || continue
    name="$(basename "${dir}")"
    hm_cron_name_ok "${name}" || continue
    [[ -f "${dir}/state" ]] || { printf '%s\tbrak-stanu\n' "${name}"; continue; }
    end="$(sed -n 's/^end=//p' "${dir}/state" | head -n 1)"
    rc="$(sed -n 's/^rc=//p' "${dir}/state" | head -n 1)"
    every="$(tr -d '\r\n' < "${dir}/every" 2>/dev/null || echo 0)"
    grace="$(tr -d '\r\n' < "${dir}/grace" 2>/dev/null || echo 0)"
    printf '%s\trc=%s\n' "${name}" "${rc}"
    if [[ "${rc}" != "0" ]]; then
      hm_cron_alert "${name}" "rc=${rc}"
    fi
    if [[ -n "${end}" && $(( now - end )) -gt $(( every + grace )) ]]; then
      hm_cron_alert "${name}" "brak"
    fi
  done
}

hm_cron_monitor_wrap() {
  local user="${1:-}" line="${2:-}" shown
  [[ -n "${user}" && -n "${line}" ]] || { hm_err "Użycie: cron monitor wrap <user> <linia>"; return 1; }
  hm_confirm_plan "cron monitor wrap" "Propozycja linii z cron-run." "" "cron monitor wrap ${user}" || return 1
  shown="$(hm_cron_redact_line "${line}")"
  printf '%s hmtools cron-run job --timeout 1h -- %s\n' "${shown%% *}" "${shown#* }"
  printf 'user\t%s\n' "${user}"
}

hm_cron_monitor() {
  local sub="${1:-list}"
  shift || true
  case "${sub}" in
    add) hm_cron_monitor_add "$@" ;;
    list|ls)
      local root dir name
      root="$(hm_cron_mon_root)"
      [[ -d "${root}" ]] || return 0
      for dir in "${root}"/*; do
        [[ -d "${dir}" ]] || continue
        name="$(basename "${dir}")"
        hm_cron_name_ok "${name}" || continue
        printf '%s\n' "${name}"
      done
      ;;
    status) hm_cron_monitor_status ;;
    remove|rm)
      local name="${1:-}" dir
      if ! hm_cron_name_ok "${name}"; then
        hm_err "Użycie: cron monitor remove <nazwa>"
        return 1
      fi
      hm_confirm_plan "cron monitor remove ${name}" "Usuwa historię zadania." "" "cron monitor remove ${name}" || return 1
      dir="$(hm_cron_mon_root)/${name}"
      if [[ -e "${dir}" ]]; then
        rm -rf "${dir}" || { hm_err "Nie usunięto ${name}."; return 1; }
      fi
      hm_ok "Usunięto ${name}."
      ;;
    wrap) hm_cron_monitor_wrap "$@" ;;
    *) hm_err "Użycie: cron monitor add|list|status|remove|wrap"; return 1 ;;
  esac
}

cmd_cron_run() { hm_cron_run "$@"; }

_hm_cmd_register cron-run cmd_cron_run 0
