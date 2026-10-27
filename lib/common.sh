#!/usr/bin/env bash
# Wspólne helpery hmtools

if [[ -n "${HMTOOLS_COMMON_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_COMMON_LOADED=1

# Katalog instalacji (nadpisywany przez entrypoint)
: "${HMTOOLS_ROOT:=/hm-tools}"
: "${HMTOOLS_CONF:=${HMTOOLS_ROOT}/config/hmtools.conf}"

# Kolory (wyłączane gdy nie-TTY)
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_CYAN=$'\033[36m'
else
  C_RESET= C_BOLD= C_DIM= C_RED= C_GREEN= C_YELLOW= C_BLUE= C_CYAN=
fi

hm_log()   { printf '%s\n' "$*"; }
hm_info()  { printf '%s%s%s\n' "${C_CYAN}" "$*" "${C_RESET}"; }
hm_ok()    { printf '%s%s%s\n' "${C_GREEN}" "$*" "${C_RESET}"; }
hm_warn()  { printf '%s%s%s\n' "${C_YELLOW}" "$*" "${C_RESET}" >&2; }
hm_err()   { printf '%s%s%s\n' "${C_RED}" "$*" "${C_RESET}" >&2; }
hm_die()   { hm_err "$*"; exit 1; }

hm_require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    hm_die "Uruchom jako root (sudo)."
  fi
}

hm_load_config() {
  # Domyślne wartości
  RCLONE_REMOTE="${RCLONE_REMOTE:-gdrive:vps-backups}"
  MIN_FREE_PERCENT="${MIN_FREE_PERCENT:-5}"
  CHUNK_SIZE_MB="${CHUNK_SIZE_MB:-512}"
  CHUNK_THRESHOLD_MB="${CHUNK_THRESHOLD_MB:-2048}"
  TMP_DIR="${TMP_DIR:-/tmp/hmtools-backup}"
  BACKUP_EXCLUDES="${BACKUP_EXCLUDES:-cache node_modules .git *.log tmp temp wp-content/cache}"
  BACKUP_HOST_LABEL="${BACKUP_HOST_LABEL:-}"

  if [[ -f "${HMTOOLS_CONF}" ]]; then
    # shellcheck disable=SC1090
    source "${HMTOOLS_CONF}"
  fi

  if [[ -z "${BACKUP_HOST_LABEL}" ]]; then
    BACKUP_HOST_LABEL="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo server)"
  fi
}

hm_confirm() {
  local prompt="${1:-Kontynuować?}"
  local reply
  printf '%s [t/N]: ' "${prompt}"
  read -r reply || return 1
  case "${reply}" in
    t|T|tak|Tak|TAK|y|Y|yes|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

hm_human_size() {
  # Wejście: bajty (liczba całkowita)
  local bytes="${1:-0}"
  if ! [[ "${bytes}" =~ ^[0-9]+$ ]]; then
    printf '%s' "?"
    return
  fi
  awk -v b="${bytes}" 'BEGIN {
    split("B KB MB GB TB PB", u, " ");
    i=1;
    while (b >= 1024 && i < 6) { b/=1024; i++ }
    if (i==1) printf "%d %s", b, u[i];
    else printf "%.2f %s", b, u[i];
  }'
}

hm_disk_free_percent() {
  # Procent wolnego miejsca na partycji zawierającej ścieżkę ($1, domyślnie /)
  local path="${1:-/}"
  df -P "${path}" 2>/dev/null | awk 'NR==2 {
    if ($2+0==0) { print 0; exit }
    printf "%.0f", ($4/$2)*100
  }'
}

hm_disk_used_percent() {
  local path="${1:-/}"
  df -P "${path}" 2>/dev/null | awk 'NR==2 { gsub(/%/,"",$5); print $5+0 }'
}

hm_have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

hm_mysql_cli() {
  if hm_have_cmd mariadb; then
    echo mariadb
  elif hm_have_cmd mysql; then
    echo mysql
  else
    return 1
  fi
}

hm_mysqldump_cli() {
  if hm_have_cmd mariadb-dump; then
    echo mariadb-dump
  elif hm_have_cmd mysqldump; then
    echo mysqldump
  else
    return 1
  fi
}

# Globalny stan kontekstu strony
HM_SITE_DOMAIN=""
HM_SITE_ROOT=""
HM_SITE_DOCROOT=""
HM_SITE_LOGS=""
HM_SITE_VHOST=""
HM_SITE_PHP=""
HM_SITE_USER=""
HM_SITE_STATUS=""

hm_clear_site_context() {
  HM_SITE_DOMAIN=""
  HM_SITE_ROOT=""
  HM_SITE_DOCROOT=""
  HM_SITE_LOGS=""
  HM_SITE_VHOST=""
  HM_SITE_PHP=""
  HM_SITE_USER=""
  HM_SITE_STATUS=""
}

hm_prompt_string() {
  if [[ -n "${HM_SITE_DOMAIN}" ]]; then
    printf '%s[%s]%s> ' "${C_BOLD}${C_BLUE}" "${HM_SITE_DOMAIN}" "${C_RESET}"
  else
    printf '%shmtools%s> ' "${C_BOLD}${C_CYAN}" "${C_RESET}"
  fi
}

hm_help_global() {
  cat <<'EOF'
Komendy globalne:
  webs [--quick]     Lista usług webowych
  use <n|domena>     Wejście w kontekst strony
  backup setup       Konfiguracja rclone / Google Drive
  backup full        Pełna kopia serwera → Drive
  disk               Zużycie dysku
  ols [status|reload|restart|log]
  ssl                Certyfikaty SSL stron
  mysql / dbs        Bazy danych (globalnie)
  php                Dostępne wersje LSPHP
  health             Szybki przegląd zdrowia serwera
  detect             Pokaż wykryty panel / webserver
  help               Ta pomoc
  exit / quit        Wyjście z hmtools

W kontekście strony (po 'use'):
  info, size, dbs, ssl, php, logs, backup, clean, exit
EOF
}
