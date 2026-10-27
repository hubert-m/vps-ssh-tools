#!/usr/bin/env bash
# Wspólne helpery hmtools

if [[ -n "${HMTOOLS_COMMON_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_COMMON_LOADED=1

# Katalog instalacji (nadpisywany przez entrypoint)
: "${HMTOOLS_ROOT:=/hm-tools}"
: "${HMTOOLS_CONF:=${HMTOOLS_ROOT}/config/hmtools.conf}"

# shellcheck source=logging.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logging.sh"

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

hm_log()   { printf '%s\n' "$*"; hm_file_log INFO "$*"; }
hm_info()  { printf '%s%s%s\n' "${C_CYAN}" "$*" "${C_RESET}"; hm_file_log INFO "$*"; }
hm_ok()    { printf '%s%s%s\n' "${C_GREEN}" "$*" "${C_RESET}"; hm_file_log INFO "$*"; }
hm_warn()  { printf '%s%s%s\n' "${C_YELLOW}" "$*" "${C_RESET}" >&2; hm_file_log WARN "$*"; }
hm_err()   { printf '%s%s%s\n' "${C_RED}" "$*" "${C_RESET}" >&2; hm_file_log ERROR "$*"; }
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
  LOG_ENABLED="${LOG_ENABLED:-1}"
  LOG_DIR="${LOG_DIR:-${HMTOOLS_ROOT}/logs}"
  LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
  LOG_LEVEL="${LOG_LEVEL:-INFO}"

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
  # zwykły wypis (bez znaczników readline)
  if [[ -n "${HM_SITE_DOMAIN}" ]]; then
    printf '%s[%s]%s> ' "${C_BOLD}${C_BLUE}" "${HM_SITE_DOMAIN}" "${C_RESET}"
  else
    printf '%shmtools%s> ' "${C_BOLD}${C_CYAN}" "${C_RESET}"
  fi
}

hm_prompt_for_read() {
  # Prompt dla `read -e -p` — kolory w \001...\002, żeby readline
  # poprawnie przerysował linię po Tab (bind -x).
  local si=$'\001' ei=$'\002'
  if [[ -n "${HM_SITE_DOMAIN}" ]]; then
    printf '%s%s%s[%s]%s%s%s> ' \
      "${si}" "${C_BOLD}${C_BLUE}" "${ei}" \
      "${HM_SITE_DOMAIN}" \
      "${si}" "${C_RESET}" "${ei}"
  else
    printf '%s%s%shmtools%s%s%s> ' \
      "${si}" "${C_BOLD}${C_CYAN}" "${ei}" \
      "${si}" "${C_RESET}" "${ei}"
  fi
}

hm_help_global() {
  cat <<'EOF'
Komendy globalne:
  webs [--quick]     Lista usług webowych
  use <n|domena>     Wejście w kontekst strony (Tab = podpowiedź domen)
  backup setup       Konfiguracja rclone / Google Drive
  backup config      Ustaw katalog root backupów na Drive
  backup full        Pełna kopia → Drive/full/  |  site → Drive/<domena>/
  applog [N]         Ostatnie N linii logu hmtools (domyślnie 50)
  disk               Zużycie dysku
  ols [status|reload|restart|log]
  ssl                Certyfikaty SSL stron (status / dni)
  renew-ssl [domena] Odnów Let's Encrypt (z potwierdzeniem)
  mysql / dbs        Bazy danych (globalnie)
  cron [list|edit…]  Crony systemowe / użytkowników / strony
  pm2|node|apps      Procesy PM2/Node (porty, status, proxy OLS)
  php                LSPHP na serwerze + najnowsze z php.net
  update-php <ver>   Aktualizacja LSPHP (np. update-php 8.4) — z potwierdzeniem
  health             Szybki przegląd zdrowia serwera
  detect             Pokaż wykryty panel / webserver
  help [polecenie]   Lista komend lub pomoc do konkretnej (np. help use)
  version            Wersja + changelog zainstalowanej wersji
  update-hmtools     Aktualizacja z GitHuba (+ co nowego)
  uninstall-hmtools  Usuń hmtools z serwera (--yes bez pytania)
  exit / quit        Wyjście z hmtools

W kontekście strony (po 'use'):
  info, size, dbs, ssl, renew-ssl, php, logs, cron, pm2, backup, clean, exit

Szczegóły: help <polecenie>
EOF
}

cmd_uninstall_hmtools() {
  local yes=0
  local a
  for a in "$@"; do
    case "${a}" in
      --yes|-y) yes=1 ;;
      --help|-h)
        cat <<'EOF'
Użycie: uninstall-hmtools [--yes]

Usuwa hmtools z serwera:
  - katalog instalacji (domyślnie /hm-tools) — w tym conf i logi
  - symlinki /usr/bin/hmtools oraz /usr/local/bin/hmtools

Nie usuwa rclone ani backupów na Google Drive.
EOF
        return 0
        ;;
    esac
  done

  local dest="${HMTOOLS_ROOT:-/hm-tools}"
  local links=("/usr/bin/hmtools" "/usr/local/bin/hmtools")
  if [[ -n "${HMTOOLS_BIN_LINK:-}" ]]; then
    links+=("${HMTOOLS_BIN_LINK}")
  fi

  echo "Zostanie usunięte:"
  echo "  - ${dest}/"
  local link
  for link in "${links[@]}"; do
    if [[ -L "${link}" ]] || [[ -e "${link}" ]]; then
      echo "  - ${link}"
    fi
  done
  echo
  hm_warn "Konfiguracja, logi i pliki narzędzi zostaną skasowane."
  hm_info "Backupy na Google Drive i konfiguracja rclone pozostaną nietknięte."

  if [[ "${yes}" -ne 1 ]]; then
    if ! hm_confirm "Na pewno odinstalować hmtools?"; then
      hm_info "Anulowano."
      return 0
    fi
  fi

  hm_file_log INFO "uninstall-hmtools start dest=${dest}"

  for link in "${links[@]}"; do
    if [[ -L "${link}" ]]; then
      local target
      target="$(readlink -f "${link}" 2>/dev/null || readlink "${link}" 2>/dev/null || true)"
      if [[ "${target}" == "${dest}/bin/hmtools" || "${target}" == */hm-tools/bin/hmtools ]]; then
        rm -f "${link}"
        hm_ok "Usunięto symlink ${link}"
      else
        hm_warn "Pominięto ${link} (cel: ${target:-?})."
      fi
    elif [[ -e "${link}" ]]; then
      hm_warn "Pominięto ${link} (nie jest symlinkiem)."
    fi
  done

  if [[ -d "${dest}" ]]; then
    # bezpieczeństwo: nie kasuj / ani /
    case "${dest}" in
      /|/usr|/usr/local|/bin|/etc|/home|/var|/root)
        hm_err "Odmowa usunięcia niebezpiecznej ścieżki: ${dest}"
        return 1
        ;;
    esac
    rm -rf "${dest}"
    echo "Usunięto katalog ${dest}"
  else
    hm_warn "Katalog ${dest} już nie istnieje."
  fi

  echo
  echo "hmtools zostało odinstalowane."
  # kod specjalny — REPL powinien się zakończyć (katalog źródłowy mógł zniknąć)
  return 98
}

cmd_applog() {
  local n="${1:-50}"
  local f
  hm_log_init
  f="$(hm_log_file_path)"
  if [[ ! -f "${f}" ]]; then
    # pokaż najnowszy istniejący plik
    f="$(ls -1t "${LOG_DIR}"/hmtools-*.log 2>/dev/null | head -1 || true)"
  fi
  if [[ -z "${f}" || ! -f "${f}" ]]; then
    hm_warn "Brak plików logów w ${LOG_DIR}"
    return 0
  fi
  echo "Log: ${f} (ostatnie ${n} linii)"
  echo "----"
  tail -n "${n}" "${f}"
}

hm_installed_version() {
  if [[ -f "${HMTOOLS_ROOT}/VERSION" ]]; then
    tr -d '[:space:]' < "${HMTOOLS_ROOT}/VERSION"
    return 0
  fi
  echo ""
}

hm_latest_remote_version() {
  # najnowszy tag (fallback: plik VERSION z brancha); cicho przy braku sieci
  local repo="${HMTOOLS_REPO:-hubert-m/vps-ssh-tools}"
  local branch="${HMTOOLS_BRANCH:-develop}"
  local latest=""
  latest="$(curl -fsSL --connect-timeout 2 --max-time 5 --retry 0 \
    -H 'Accept: application/vnd.github+json' -H 'User-Agent: hmtools' \
    "https://api.github.com/repos/${repo}/tags?per_page=100" 2>/dev/null \
    | grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]+"' \
    | sed -E 's/.*"([^"]+)"$/\1/' \
    | sort -V | tail -1 || true)"
  if [[ -z "${latest}" ]]; then
    latest="$(curl -fsSL --connect-timeout 2 --max-time 5 --retry 0 \
      "https://raw.githubusercontent.com/${repo}/${branch}/VERSION" 2>/dev/null \
      | tr -d '[:space:]' || true)"
  fi
  printf '%s' "${latest}"
}

hm_version_is_newer() {
  # 0 = remote ($2) nowsze niż local ($1)
  local cur="$1" remote="$2" top
  [[ -n "${cur}" && -n "${remote}" ]] || return 1
  [[ "${cur}" == "${remote}" ]] && return 1
  top="$(printf '%s\n%s\n' "${cur}" "${remote}" | sort -V | tail -1)"
  [[ "${top}" == "${remote}" ]]
}

hm_welcome_update_notice() {
  local cur remote repo branch
  cur="$(hm_installed_version)"
  [[ -n "${cur}" ]] || return 0
  remote="$(hm_latest_remote_version)"
  [[ -n "${remote}" ]] || return 0
  hm_version_is_newer "${cur}" "${remote}" || return 0

  repo="${HMTOOLS_REPO:-hubert-m/vps-ssh-tools}"
  branch="${HMTOOLS_BRANCH:-develop}"
  hm_warn "Dostępna nowsza wersja: masz ${cur}, najnowsza ${remote}"
  hm_warn "Aktualizacja: curl -fsSL https://raw.githubusercontent.com/${repo}/${branch}/install.sh | bash"
  hm_warn "Albo w REPL: update-hmtools"
}

hm_changelog_path() {
  local ver="${1:-}"
  local f
  if [[ -n "${ver}" ]]; then
    f="${HMTOOLS_ROOT}/changelogs/${ver}.txt"
    if [[ -f "${f}" ]]; then
      echo "${f}"
      return 0
    fi
    if [[ "${ver}" == v* ]]; then
      f="${HMTOOLS_ROOT}/changelogs/${ver#v}.txt"
    else
      f="${HMTOOLS_ROOT}/changelogs/v${ver}.txt"
    fi
    if [[ -f "${f}" ]]; then
      echo "${f}"
      return 0
    fi
  fi
  # fallback: najnowszy plik w changelogs/
  f="$(ls -1 "${HMTOOLS_ROOT}/changelogs"/v*.txt 2>/dev/null | sort -V | tail -1 || true)"
  [[ -n "${f}" && -f "${f}" ]] || return 1
  echo "${f}"
}

hm_print_changelog() {
  local ver="${1:-}"
  local title="${2:-}"
  local f
  if ! f="$(hm_changelog_path "${ver}")"; then
    hm_warn "Brak pliku changelog dla wersji ${ver}."
    return 0
  fi
  if [[ -n "${title}" ]]; then
    echo
    echo "${C_BOLD}${title}${C_RESET}"
    echo
  fi
  cat "${f}"
  echo
}
