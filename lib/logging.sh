#!/usr/bin/env bash
# Logowanie pracy hmtools do plików

if [[ -n "${HMTOOLS_LOGGING_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_LOGGING_LOADED=1

: "${HMTOOLS_ROOT:=/hm-tools}"

# Domyślne (nadpisywane przez hm_load_config / conf)
LOG_ENABLED="${LOG_ENABLED:-1}"
LOG_DIR="${LOG_DIR:-${HMTOOLS_ROOT}/logs}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"   # DEBUG|INFO|WARN|ERROR
# 1 = kopiuj cały stdout/stderr sesji do logu (odpowiedzi komend, tabele, …)
LOG_CAPTURE_OUTPUT="${LOG_CAPTURE_OUTPUT:-1}"
# max linii stdout/stderr zapisywanych przez hm_run (0 = bez limitu)
LOG_RUN_MAX_LINES="${LOG_RUN_MAX_LINES:-400}"

HM_LOG_TEE_ATTACHED="${HM_LOG_TEE_ATTACHED:-0}"
HM_LOG_TTY_FDS="${HM_LOG_TTY_FDS:-0}"

hm_log_init() {
  [[ "${LOG_ENABLED}" == "1" ]] || return 0
  # 0700 — logi sesji (stdout/stderr) tylko dla root
  mkdir -m 0700 -p "${LOG_DIR}" 2>/dev/null || mkdir -p "${LOG_DIR}" 2>/dev/null || true
  chmod 0700 "${LOG_DIR}" 2>/dev/null || true
  if [[ -d "${LOG_DIR}" ]] && [[ "${LOG_RETENTION_DAYS}" =~ ^[0-9]+$ ]] && [[ "${LOG_RETENTION_DAYS}" -gt 0 ]]; then
    find "${LOG_DIR}" -type f -name 'hmtools-*.log' -mtime "+${LOG_RETENTION_DAYS}" -delete 2>/dev/null || true
  fi
}

hm_log_file_path() {
  printf '%s/hmtools-%s.log' "${LOG_DIR}" "$(date +%Y-%m-%d)"
}

hm_log_level_num() {
  case "$(echo "$1" | tr '[:lower:]' '[:upper:]')" in
    DEBUG) echo 10 ;;
    INFO)  echo 20 ;;
    WARN|WARNING) echo 30 ;;
    ERROR|ERR) echo 40 ;;
    *) echo 20 ;;
  esac
}

hm_log_should_write() {
  local level="$1"
  local want have
  want="$(hm_log_level_num "${LOG_LEVEL}")"
  have="$(hm_log_level_num "${level}")"
  [[ "${have}" -ge "${want}" ]]
}

hm_log_strip_ansi() {
  # usuń sekwencje kolorów / cursor
  sed -u -e $'s/\033\\[[0-9;]*[a-zA-Z]//g' -e $'s/\033\\][^\a]*\a//g' -e $'s/\r//g'
}

# Zapis do pliku (bez kolorów, bez stdout)
hm_file_log() {
  local level="${1:-INFO}"
  shift || true
  local msg="$*"
  [[ "${LOG_ENABLED}" == "1" ]] || return 0
  hm_log_should_write "${level}" || return 0

  mkdir -m 0700 -p "${LOG_DIR}" 2>/dev/null || true
  local ts ctx="" logf
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  if [[ -n "${HM_SITE_DOMAIN:-}" ]]; then
    ctx=" site=${HM_SITE_DOMAIN}"
  fi
  logf="$(hm_log_file_path)"
  # umask 077 → pliki 0600
  (
    umask 077
    printf '%s [%s]%s %s\n' "${ts}" "$(echo "${level}" | tr '[:lower:]' '[:upper:]')" "${ctx}" "${msg}" \
      >> "${logf}" 2>/dev/null || true
  )
  chmod 0600 "${logf}" 2>/dev/null || true
}

# Czy hm_info/ok/warn/err mają dublować do pliku?
# Gdy tee sesji aktywny — treść i tak trafia jako OUT/ERR; pomijamy duplikat.
hm_file_log_ui() {
  if [[ "${HM_LOG_TEE_ATTACHED}" == "1" ]]; then
    return 0
  fi
  hm_file_log "$@"
}

hm_log_stream_to_file() {
  # stdin → linie w logu z prefiksem tag (OUT|ERR|RUN_OUT|…)
  local tag="${1:-OUT}"
  local level="${2:-INFO}"
  local line ts ctx
  while IFS= read -r line || [[ -n "${line}" ]]; do
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    ctx=""
    [[ -n "${HM_SITE_DOMAIN:-}" ]] && ctx=" site=${HM_SITE_DOMAIN}"
    local logf
    logf="$(hm_log_file_path)"
    (
      umask 077
      printf '%s [%s]%s %s %s\n' "${ts}" "${level}" "${ctx}" "${tag}" "${line}" \
        >> "${logf}" 2>/dev/null || true
    )
    chmod 0600 "${logf}" 2>/dev/null || true
  done
}

# Zachowaj oryginalne deskryptory TTY (przed pierwszym tee)
hm_log_save_tty_fds() {
  [[ "${HM_LOG_TTY_FDS}" == "1" ]] && return 0
  # tylko gdy stdout nadal jest terminalem
  if [[ -t 1 ]]; then
    exec 3>&1 4>&2
    HM_LOG_TTY_FDS=1
    export HM_LOG_TTY_FDS
  fi
}

# Podłącz tee: wyświetlanie na zapisanym TTY (fd 3/4), kopia (bez ANSI) → log
hm_log_attach_output_capture() {
  [[ "${LOG_ENABLED}" == "1" ]] || return 0
  [[ "${LOG_CAPTURE_OUTPUT}" == "1" ]] || return 0
  [[ "${HM_LOG_TEE_ATTACHED}" == "1" ]] && return 0

  hm_log_save_tty_fds
  # bez zapisanych TTY nie podpinamy (np. stdout już przekierowany z zewnątrz)
  if [[ "${HM_LOG_TTY_FDS}" != "1" ]]; then
    [[ -t 1 ]] || return 0
    hm_log_save_tty_fds
    [[ "${HM_LOG_TTY_FDS}" == "1" ]] || return 0
  fi

  hm_log_init
  local logf
  logf="$(hm_log_file_path)"

  # tee → prawdziwy TTY (3/4); druga gałąź bez ANSI → plik
  # stdbuf -oL zmniejsza wyścig z promptem REPL
  if command -v stdbuf >/dev/null 2>&1; then
    exec > >(stdbuf -oL -eL tee >(hm_log_strip_ansi | hm_log_stream_to_file OUT INFO) >&3)
    exec 2> >(stdbuf -oL -eL tee >(hm_log_strip_ansi | hm_log_stream_to_file ERR WARN) >&4)
  else
    exec > >(tee >(hm_log_strip_ansi | hm_log_stream_to_file OUT INFO) >&3)
    exec 2> >(tee >(hm_log_strip_ansi | hm_log_stream_to_file ERR WARN) >&4)
  fi

  HM_LOG_TEE_ATTACHED=1
  export HM_LOG_TEE_ATTACHED
  hm_file_log INFO "LOG: podłączono przechwyt stdout/stderr → ${logf}"
}

# Przywróć TTY (domyka potoki tee → flush logu)
hm_log_detach_output_capture() {
  [[ "${HM_LOG_TEE_ATTACHED}" == "1" ]] || return 0
  [[ "${HM_LOG_TTY_FDS}" == "1" ]] || return 0
  exec 1>&3 2>&4
  HM_LOG_TEE_ATTACHED=0
  export HM_LOG_TEE_ATTACHED
  # daj process substitution czas na domknięcie i zapis
  sleep 0.05 2>/dev/null || true
}

hm_log_flush_capture() {
  [[ "${HM_LOG_TEE_ATTACHED}" == "1" ]] || return 0
  sleep 0.05 2>/dev/null || true
}

# Komendy TUI (crontab -e, rclone config, nano/vi): prawdziwe TTY, bez śmieci w logu
hm_run_on_tty() {
  local -a cmd=("$@")
  [[ "${#cmd[@]}" -gt 0 ]] || return 1
  hm_file_log INFO "RUN_TTY: ${cmd[*]}"

  hm_log_save_tty_fds
  local rc=0
  set +e
  if [[ "${HM_LOG_TTY_FDS}" == "1" ]] && [[ -e /dev/tty ]]; then
    "${cmd[@]}" >&3 2>&4 </dev/tty
    rc=$?
  elif [[ -e /dev/tty ]]; then
    "${cmd[@]}" </dev/tty
    rc=$?
  else
    "${cmd[@]}"
    rc=$?
  fi
  set -e
  hm_file_log INFO "RUN_TTY_END: rc=${rc} cmd=${cmd[*]}"
  return "${rc}"
}

hm_log_session_start() {
  local mode="${1:-interactive}"
  hm_log_init
  local ver=""
  [[ -f "${HMTOOLS_ROOT}/VERSION" ]] && ver="$(tr -d '[:space:]' < "${HMTOOLS_ROOT}/VERSION")"
  hm_file_log INFO "=== sesja start (${mode}) pid=$$ user=$(id -un 2>/dev/null || echo ?) host=$(hostname 2>/dev/null || echo ?) version=${ver:-?} root=${HMTOOLS_ROOT} log_level=${LOG_LEVEL} capture=${LOG_CAPTURE_OUTPUT} ==="
  if [[ "${mode}" == "interactive" || "${mode}" == "oneshot" ]]; then
    hm_log_attach_output_capture
  fi
}

hm_log_session_end() {
  hm_log_detach_output_capture
  hm_file_log INFO "=== sesja koniec pid=$$ ==="
}

hm_log_cmd() {
  local line="$*"
  hm_file_log INFO "CMD: ${line}"
}

hm_log_cmd_end() {
  local rc="${1:-0}"
  local dur="${2:-}"
  if [[ -n "${dur}" ]]; then
    hm_file_log INFO "CMD_END: rc=${rc} duration=${dur}s"
  else
    hm_file_log INFO "CMD_END: rc=${rc}"
  fi
}

# Uruchom komendę zewnętrzną: pokaż output + zapisz do logu (RUN / RUN_OUT / RUN_ERR / RUN_END)
hm_run() {
  local -a cmd=("$@")
  [[ "${#cmd[@]}" -gt 0 ]] || return 1

  local tmp_out tmp_err rc=0 max="${LOG_RUN_MAX_LINES:-400}"
  tmp_out="$(mktemp "${TMP_DIR:-/tmp}/hmtools-run.XXXXXX.out" 2>/dev/null || mktemp /tmp/hmtools-run.XXXXXX.out)"
  tmp_err="$(mktemp "${TMP_DIR:-/tmp}/hmtools-run.XXXXXX.err" 2>/dev/null || mktemp /tmp/hmtools-run.XXXXXX.err)"

  hm_file_log INFO "RUN: ${cmd[*]}"

  local cmd_pid fd start_ts elapsed last_line spin_idx=0
  local -a frames=('|' '/' '-' '\\')
  start_ts="$(date +%s)"

  set +e
  "${cmd[@]}" >"${tmp_out}" 2>"${tmp_err}" &
  cmd_pid=$!

  if fd="$(hm_ui_tty_fd 2>/dev/null)"; then
    while kill -0 "${cmd_pid}" 2>/dev/null; do
      elapsed=$(( $(date +%s) - start_ts ))
      last_line="$(
        { tail -n 3 "${tmp_out}" 2>/dev/null; tail -n 3 "${tmp_err}" 2>/dev/null; } \
          | grep -v '^==>' | awk 'NF { line=$0 } END { print line }' | tr -d '\r'
      )"
      [[ ${#last_line} -gt 42 ]] && last_line="${last_line:0:39}..."
      # shellcheck disable=SC2086
      printf '\r\033[K  %s%s [%02ds] %s%s%s' \
        "${C_CYAN}" "${frames[$spin_idx]}" "${elapsed}" \
        "${cmd[0]}${cmd[1]:+ ${cmd[1]}}" \
        "${C_DIM}${last_line:+ — ${last_line}}" "${C_RESET}" >&"${fd}"
      spin_idx=$(( (spin_idx + 1) % ${#frames[@]} ))
      sleep 0.25 2>/dev/null || sleep 1
    done
    # shellcheck disable=SC2086
    printf '\r\033[K' >&"${fd}"
  fi
  wait "${cmd_pid}"
  rc=$?
  set -e

  # pokaż użytkownikowi
  if [[ -s "${tmp_out}" ]]; then
    cat "${tmp_out}"
  fi
  if [[ -s "${tmp_err}" ]]; then
    cat "${tmp_err}" >&2
  fi

  # do logu (z limitem linii)
  if [[ -s "${tmp_out}" ]]; then
    if [[ "${max}" -gt 0 ]]; then
      local n
      n="$(wc -l < "${tmp_out}" | tr -d ' ')"
      head -n "${max}" "${tmp_out}" | hm_log_stream_to_file RUN_OUT INFO
      if [[ "${n}" -gt "${max}" ]]; then
        hm_file_log INFO "RUN_OUT: … (ucięto, łącznie ${n} linii; limit ${max})"
      fi
    else
      hm_log_stream_to_file RUN_OUT INFO < "${tmp_out}"
    fi
  fi
  if [[ -s "${tmp_err}" ]]; then
    if [[ "${max}" -gt 0 ]]; then
      local n
      n="$(wc -l < "${tmp_err}" | tr -d ' ')"
      head -n "${max}" "${tmp_err}" | hm_log_stream_to_file RUN_ERR WARN
      if [[ "${n}" -gt "${max}" ]]; then
        hm_file_log WARN "RUN_ERR: … (ucięto, łącznie ${n} linii; limit ${max})"
      fi
    else
      hm_log_stream_to_file RUN_ERR WARN < "${tmp_err}"
    fi
  fi

  hm_file_log INFO "RUN_END: rc=${rc} cmd=${cmd[*]}"
  rm -f "${tmp_out}" "${tmp_err}" 2>/dev/null || true
  return "${rc}"
}

# Jak hm_run, ale bez wypisywania na terminal (tylko log) — rzadkie przypadki
hm_run_quiet() {
  local -a cmd=("$@")
  local tmp_out tmp_err rc=0
  tmp_out="$(mktemp /tmp/hmtools-run.XXXXXX.out)"
  tmp_err="$(mktemp /tmp/hmtools-run.XXXXXX.err)"
  hm_file_log INFO "RUN_QUIET: ${cmd[*]}"
  set +e
  "${cmd[@]}" >"${tmp_out}" 2>"${tmp_err}"
  rc=$?
  set -e
  [[ -s "${tmp_out}" ]] && hm_log_stream_to_file RUN_OUT INFO < "${tmp_out}"
  [[ -s "${tmp_err}" ]] && hm_log_stream_to_file RUN_ERR WARN < "${tmp_err}"
  hm_file_log INFO "RUN_END: rc=${rc} cmd=${cmd[*]}"
  rm -f "${tmp_out}" "${tmp_err}" 2>/dev/null || true
  return "${rc}"
}
