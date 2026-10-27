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

hm_log_init() {
  [[ "${LOG_ENABLED}" == "1" ]] || return 0
  mkdir -p "${LOG_DIR}" 2>/dev/null || true
  # czyszczenie starych logów (raz na sesję)
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

# Zapis do pliku (bez kolorów, bez stdout)
hm_file_log() {
  local level="${1:-INFO}"
  shift || true
  local msg="$*"
  [[ "${LOG_ENABLED}" == "1" ]] || return 0
  hm_log_should_write "${level}" || return 0

  mkdir -p "${LOG_DIR}" 2>/dev/null || true
  local ts ctx=""
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  if [[ -n "${HM_SITE_DOMAIN:-}" ]]; then
    ctx=" site=${HM_SITE_DOMAIN}"
  fi
  # nie przerywaj pracy narzędzi przy błędzie zapisu
  printf '%s [%s]%s %s\n' "${ts}" "$(echo "${level}" | tr '[:lower:]' '[:upper:]')" "${ctx}" "${msg}" \
    >> "$(hm_log_file_path)" 2>/dev/null || true
}

hm_log_session_start() {
  local mode="${1:-interactive}"
  hm_log_init
  hm_file_log INFO "=== sesja start (${mode}) pid=$$ user=$(id -un 2>/dev/null || echo ?) host=$(hostname 2>/dev/null || echo ?) root=${HMTOOLS_ROOT} ==="
}

hm_log_session_end() {
  hm_file_log INFO "=== sesja koniec pid=$$ ==="
}

hm_log_cmd() {
  local line="$*"
  hm_file_log INFO "CMD: ${line}"
}
