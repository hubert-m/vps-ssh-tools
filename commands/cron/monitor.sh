#!/usr/bin/env bash
# cron monitor / cron-run — historia, lock, timeout, alert bez sekretów.

hm_cron_mon_root() { printf '%s\n' "${HM_CRON_MON:-/var/lib/hmtools/cron-mon}"; }

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
  line="${line//SECRET-CRON/[redacted]}"
  if [[ "${line}" == *PASSWORD=* ]]; then
    line="${line%%PASSWORD=*}PASSWORD=[redacted]"
  fi
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

hm_cron_run() {
  local name="" timeout="1h" user="" dir start=0 end=0 rc=0 dur=0 limit=0 pid=0 now=0 errf
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout) timeout="${2:-1h}"; shift 2 || true ;;
      --) shift; break ;;
      *)
        if [[ -z "${name}" ]]; then name="$1"; shift; else break; fi
        ;;
    esac
  done
  [[ "${name}" =~ ^[A-Za-z0-9_.-]+$ && $# -gt 0 ]] || {
    hm_err "Użycie: cron-run <nazwa> [--timeout 1h] -- <komenda>"
    return 1
  }
  dir="$(hm_cron_mon_root)/${name}"
  mkdir -p "${dir}"
  if [[ -f "${dir}/user" ]]; then
    user="$(tr -d '\r\n' < "${dir}/user")"
  fi
  if ! mkdir "${dir}/lock" 2>/dev/null; then
    printf 'lock\t%s\n' "${name}"
    return 0
  fi
  # shellcheck disable=SC2064
  trap "rmdir \"${dir}/lock\" 2>/dev/null || true" RETURN
  start="$(date +%s)"
  errf="${dir}/stderr"
  : > "${errf}"
  limit="$(hm_cron_seconds "${timeout}")"
  hm_cron_exec "${user}" "$@" >"${errf}" 2>&1 &
  pid=$!
  while kill -0 "${pid}" 2>/dev/null; do
    now="$(date +%s)"
    if [[ $(( now - start )) -ge "${limit}" ]]; then
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
      rc=124
      break
    fi
    sleep 0.2
  done
  if [[ "${rc}" -ne 124 ]]; then
    wait "${pid}" || rc=$?
  fi
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
  [[ "${name}" =~ ^[A-Za-z0-9_.-]+$ && -n "${every}" ]] || {
    hm_err "Użycie: cron monitor add <nazwa> --every 1h [--grace 15m] [--user u]"
    return 1
  }
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
    [[ -f "${dir}/state" ]] || { printf '%s\tbrak-stanu\n' "${name}"; continue; }
    end="$(sed -n 's/^end=//p' "${dir}/state" | head -n 1)"
    rc="$(sed -n 's/^rc=//p' "${dir}/state" | head -n 1)"
    every="$(tr -d '\r\n' < "${dir}/every")"
    grace="$(tr -d '\r\n' < "${dir}/grace")"
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
      local root dir
      root="$(hm_cron_mon_root)"
      [[ -d "${root}" ]] || return 0
      for dir in "${root}"/*; do
        [[ -d "${dir}" ]] || continue
        basename "${dir}"
      done
      ;;
    status) hm_cron_monitor_status ;;
    remove|rm)
      local name="${1:-}" dir
      [[ "${name}" =~ ^[A-Za-z0-9_.-]+$ ]] || { hm_err "Użycie: cron monitor remove <nazwa>"; return 1; }
      hm_confirm_plan "cron monitor remove ${name}" "Usuwa historię zadania." "" "cron monitor remove ${name}" || return 1
      dir="$(hm_cron_mon_root)/${name}"
      rm -rf "${dir}"
      hm_ok "Usunięto ${name}."
      ;;
    wrap) hm_cron_monitor_wrap "$@" ;;
    *) hm_err "Użycie: cron monitor add|list|status|remove|wrap"; return 1 ;;
  esac
}

cmd_cron_run() { hm_cron_run "$@"; }

_hm_cmd_register cron-run cmd_cron_run 0
