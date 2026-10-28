#!/usr/bin/env bash
# Common: kolory, log UI, confirm, rozmiary, CLI

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

hm_log()   { printf '%s\n' "$*"; hm_file_log_ui INFO "$*"; }
hm_info()  { printf '%s%s%s\n' "${C_CYAN}" "$*" "${C_RESET}"; hm_file_log_ui INFO "$*"; }
hm_ok()    { printf '%s%s%s\n' "${C_GREEN}" "$*" "${C_RESET}"; hm_file_log_ui INFO "$*"; }
hm_warn()  { printf '%s%s%s\n' "${C_YELLOW}" "$*" "${C_RESET}" >&2; hm_file_log_ui WARN "$*"; }
hm_err()   { printf '%s%s%s\n' "${C_RED}" "$*" "${C_RESET}" >&2; hm_file_log_ui ERROR "$*"; }
hm_die()   { hm_err "$*"; exit 1; }

hm_require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    hm_die "Uruchom jako root (sudo)."
  fi
}

# --- walidacja niezaufanych danych (pliki strony / input użytkownika) ----------

hm_is_valid_db_name() {
  # MySQL identifier — biała lista (bez apostrofów, spacji, średników)
  [[ "${1:-}" =~ ^[a-zA-Z0-9_\$\-]{1,64}$ ]]
}

hm_is_valid_domain() {
  [[ "${1:-}" =~ ^[a-zA-Z0-9._-]{1,253}$ ]]
}

hm_is_valid_unix_user() {
  [[ "${1:-}" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]
}

hm_is_valid_rclone_remote() {
  # remote:path — bez $() ` | ; " ' itd.
  [[ "${1:-}" =~ ^[a-zA-Z0-9_.:/-]+$ ]]
}

hm_sql_quote() {
  # escapowanie literału SQL (apostrof → '')
  local s="${1:-}"
  s="${s//\'/\'\'}"
  printf "'%s'" "${s}"
}

hm_confirm() {
  local prompt="${1:-Kontynuować?}"
  local reply
  printf '%s [t/N]: ' "${prompt}"
  read -r reply || {
    hm_file_log WARN "CONFIRM: ${prompt} → (EOF/abort)"
    return 1
  }
  case "${reply}" in
    t|T|tak|Tak|TAK|y|Y|yes|Yes)
      hm_file_log INFO "CONFIRM: ${prompt} → yes (${reply})"
      return 0
      ;;
    *)
      hm_file_log INFO "CONFIRM: ${prompt} → no (${reply:-empty})"
      return 1
      ;;
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
