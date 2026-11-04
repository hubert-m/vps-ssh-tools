#!/usr/bin/env bash
# Common: ładowanie hmtools.conf

hm_load_config() {
  # Domyślne wartości
  RCLONE_REMOTE="${RCLONE_REMOTE:-gdrive:vps-backups}"
  MIN_FREE_PERCENT="${MIN_FREE_PERCENT:-5}"
  CHUNK_SIZE_MB="${CHUNK_SIZE_MB:-512}"
  CHUNK_THRESHOLD_MB="${CHUNK_THRESHOLD_MB:-2048}"
  # Domyślnie poza world-writable /tmp (unikamy symlink/TOCTOU eskalacji)
  TMP_DIR="${TMP_DIR:-/var/lib/hmtools/tmp}"
  # Site/full backup — wzorce kotwiczone do korzenia archiwum (./…); bez „tmp” na dowolnej głębokości
  BACKUP_EXCLUDES="${BACKUP_EXCLUDES:-./node_modules ./.git ./tmp ./temp ./cache ./public_html/wp-content/cache ./public_html/wp-content/uploads/cache *.log}"
  # Archive (destrukcyjne) — domyślnie PEŁNY dump bez excludes; ewentualnie jawne ARCHIVE_EXCLUDES
  ARCHIVE_EXCLUDES="${ARCHIVE_EXCLUDES:-}"
  BACKUP_HOST_LABEL="${BACKUP_HOST_LABEL:-}"
  BACKUP_KEEP_DAYS="${BACKUP_KEEP_DAYS:-14}"
  BACKUP_KEEP_MIN="${BACKUP_KEEP_MIN:-3}"
  # Niepełne snapshoty (bez manifestu) młodsze niż N godzin — NIE kasuj (prune vs trwający backup)
  BACKUP_ORPHAN_GRACE_HOURS="${BACKUP_ORPHAN_GRACE_HOURS:-24}"
  # Opcjonalnie: passphrase openssl (AES-256-CBC) dla db-accounts.sql / unix-account.meta / system-configs
  # BACKUP_ENCRYPT_PASSPHRASE=""
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

  hm_ensure_secure_tmpdir
  mkdir -m 0700 -p "${LOG_DIR}" 2>/dev/null || true
  chmod 0700 "${LOG_DIR}" 2>/dev/null || true
}

# Katalogi izolowane (mktemp) do usunięcia przy EXIT — nie zostawiać śmieci w /var/lib/hmtools.
declare -a HM_SECURE_TMP_CLEANUP_DIRS=()
HM_SECURE_TMP_ISOLATED="${HM_SECURE_TMP_ISOLATED:-}"
HM_SECURE_TMP_TRAP_SET="${HM_SECURE_TMP_TRAP_SET:-0}"

# Other-writable? (ostatnia cyfra mode: 2/3/6/7) — np. 1777 /tmp, 0777.
hm_fs_mode_other_writable() {
  local mode="${1:-0}" last
  last="${mode: -1}"
  case "${last}" in
    2|3|6|7) return 0 ;;
    *) return 1 ;;
  esac
}

hm_secure_tmpdir_cleanup() {
  local d
  for d in "${HM_SECURE_TMP_CLEANUP_DIRS[@]:-}"; do
    [[ -n "${d}" && -d "${d}" ]] || continue
    # tylko nasze izolowane mktemp — nigdy stały /var/lib/hmtools/tmp
    case "${d}" in
      /var/lib/hmtools/tmp.*|*/hmtools-safe.*)
        rm -rf -- "${d}" 2>/dev/null || true
        ;;
    esac
  done
  HM_SECURE_TMP_CLEANUP_DIRS=()
  HM_SECURE_TMP_ISOLATED=""
}

hm_secure_tmpdir_register_cleanup() {
  local d="${1:-}"
  [[ -n "${d}" ]] || return 0
  HM_SECURE_TMP_CLEANUP_DIRS+=("${d}")
  HM_SECURE_TMP_ISOLATED="${d}"
  if [[ "${HM_SECURE_TMP_TRAP_SET}" != "1" ]]; then
    HM_SECURE_TMP_TRAP_SET=1
    # shellcheck disable=SC2064
    trap 'hm_secure_tmpdir_cleanup' EXIT
  fi
}

# Izolowany katalog gdy skonfigurowany TMP_DIR jest niebezpieczny.
# Reużywa jeden katalog na proces; sprzątany przez EXIT trap.
# Ustawia TMP_DIR (bez echo / command substitution — inaczej gubi się rejestr w rodzicu).
hm_secure_tmpdir_fallback() {
  local euid d=""
  if [[ -n "${HM_SECURE_TMP_ISOLATED}" && -d "${HM_SECURE_TMP_ISOLATED}" && ! -L "${HM_SECURE_TMP_ISOLATED}" ]]; then
    TMP_DIR="${HM_SECURE_TMP_ISOLATED}"
    return 0
  fi
  euid="$(id -u 2>/dev/null || echo 0)"
  if [[ "${euid}" -eq 0 ]]; then
    mkdir -m 0700 -p /var/lib/hmtools 2>/dev/null || true
    d="$(mktemp -d /var/lib/hmtools/tmp.XXXXXX 2>/dev/null || true)"
  fi
  if [[ -z "${d}" ]]; then
    d="$(mktemp -d "${TMPDIR:-/tmp}/hmtools-safe.XXXXXX" 2>/dev/null || mktemp -d)"
  fi
  chmod 0700 "${d}" 2>/dev/null || true
  hm_secure_tmpdir_register_cleanup "${d}"
  TMP_DIR="${d}"
}

# Bezpieczny TMP_DIR: nie symlink, właściciel = euid, NIE other-writable.
# World-writable (np. 1777) → fallback BEZ chmod (nie psuć /tmp gdy TMP_DIR=/tmp).
# Stary /tmp/hmtools-backup → /var/lib/hmtools/tmp.
hm_ensure_secure_tmpdir() {
  local euid configured base owner mode
  euid="$(id -u 2>/dev/null || echo 0)"
  configured="${TMP_DIR:-}"

  # legacy /tmp/hmtools-backup — nie używaj world-writable bez twardej walidacji
  if [[ -z "${configured}" || "${configured}" == "/tmp/hmtools-backup" ]]; then
    if [[ "${euid}" -eq 0 ]]; then
      base="/var/lib/hmtools/tmp"
    else
      base="${TMPDIR:-/tmp}/hmtools-${euid}"
    fi
  else
    base="${configured}"
  fi

  if [[ -L "${base}" ]]; then
    if declare -F hm_warn >/dev/null 2>&1; then
      hm_warn "TMP_DIR jest symlinkiem (${base}) — używam izolowanego katalogu."
    fi
    hm_secure_tmpdir_fallback
    return 0
  fi

  if [[ ! -e "${base}" ]]; then
    if ! mkdir -m 0700 -p "${base}" 2>/dev/null; then
      hm_secure_tmpdir_fallback
      return 0
    fi
  fi

  if [[ -L "${base}" || ! -d "${base}" ]]; then
    hm_secure_tmpdir_fallback
    return 0
  fi

  owner="$(stat -c '%u' "${base}" 2>/dev/null || echo x)"
  mode="$(stat -c '%a' "${base}" 2>/dev/null || echo 0)"
  if [[ "${owner}" != "${euid}" ]]; then
    if declare -F hm_warn >/dev/null 2>&1; then
      hm_warn "TMP_DIR ${base} należy do uid=${owner} (oczekiwano ${euid}) — izolowany katalog."
    fi
    hm_secure_tmpdir_fallback
    return 0
  fi

  # NAJPIERW other-writable (1777/0777) — NIGDY chmod na takim katalogu (psuje /tmp)
  if hm_fs_mode_other_writable "${mode}"; then
    if declare -F hm_warn >/dev/null 2>&1; then
      hm_warn "TMP_DIR ${base} jest world/other-writable (${mode}) — izolowany katalog (bez chmod)."
    fi
    hm_secure_tmpdir_fallback
    return 0
  fi

  # zacieśnij tylko prywatne katalogi bez sticky (np. 755 → 700); sticky 1xxx bez other-write zostaw
  if [[ "${#mode}" -le 3 ]]; then
    chmod 0700 "${base}" 2>/dev/null || true
    mode="$(stat -c '%a' "${base}" 2>/dev/null || echo 0)"
    if hm_fs_mode_other_writable "${mode}"; then
      hm_secure_tmpdir_fallback
      return 0
    fi
  fi

  # ponowny check symlink (TOCTOU)
  if [[ -L "${base}" ]]; then
    hm_secure_tmpdir_fallback
    return 0
  fi

  TMP_DIR="${base}"
}

# Plik tymczasowy w bezpiecznym TMP_DIR (mktemp — nigdy stała nazwa).
# Użycie: path="$(hm_mktemp [.suffix])"
hm_mktemp() {
  local suffix="${1:-}"
  local dir="${TMP_DIR:-}"
  if [[ -z "${dir}" || -L "${dir}" || ! -d "${dir}" ]]; then
    hm_ensure_secure_tmpdir
    dir="${TMP_DIR}"
  fi
  mktemp "${dir}/hm.XXXXXX${suffix}"
}
