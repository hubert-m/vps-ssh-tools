#!/usr/bin/env bash
# Common: ładowanie hmtools.conf

hm_load_config() {
  # Domyślne wartości
  RCLONE_REMOTE="${RCLONE_REMOTE:-gdrive:vps-backups}"
  MIN_FREE_PERCENT="${MIN_FREE_PERCENT:-5}"
  CHUNK_SIZE_MB="${CHUNK_SIZE_MB:-512}"
  CHUNK_THRESHOLD_MB="${CHUNK_THRESHOLD_MB:-2048}"
  TMP_DIR="${TMP_DIR:-/tmp/hmtools-backup}"
  BACKUP_EXCLUDES="${BACKUP_EXCLUDES:-cache node_modules .git *.log tmp temp wp-content/cache}"
  BACKUP_HOST_LABEL="${BACKUP_HOST_LABEL:-}"
  BACKUP_KEEP_DAYS="${BACKUP_KEEP_DAYS:-14}"
  BACKUP_KEEP_MIN="${BACKUP_KEEP_MIN:-3}"
  BACKUP_SCHEDULE_HOUR="${BACKUP_SCHEDULE_HOUR:-3}"
  BACKUP_SCHEDULE_PRUNE="${BACKUP_SCHEDULE_PRUNE:-1}"
  LOG_ENABLED="${LOG_ENABLED:-1}"
  LOG_DIR="${LOG_DIR:-${HMTOOLS_ROOT}/logs}"
  LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
  LOG_LEVEL="${LOG_LEVEL:-INFO}"
  LOG_CAPTURE_OUTPUT="${LOG_CAPTURE_OUTPUT:-1}"
  LOG_RUN_MAX_LINES="${LOG_RUN_MAX_LINES:-400}"

  if [[ -f "${HMTOOLS_CONF}" ]]; then
    # shellcheck disable=SC1090
    source "${HMTOOLS_CONF}"
  fi

  if [[ -z "${BACKUP_HOST_LABEL}" ]]; then
    BACKUP_HOST_LABEL="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo server)"
  fi

  # normalizacja ścieżki logów względem HMTOOLS_ROOT
  if [[ "${LOG_DIR}" != /* ]]; then
    LOG_DIR="${HMTOOLS_ROOT}/${LOG_DIR}"
  fi
}
