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

# Wyświetla ustandaryzowany plan krok po kroku i wymaga wpisania dokładnie 'yes'.
# Opcjonalnie po ostrzeżeniu: "--yes" jako pierwszy krok → wypisz plan, pomiń pytanie.
# Użycie:
#   hm_confirm_plan "TYTUŁ" "OSTRZEŻENIE (opcjonalne)" "Krok 1..." "Krok 2..."
#   hm_confirm_plan "TYTUŁ" "" --yes "Krok 1..." "Krok 2..."
hm_confirm_plan() {
  local title="${1:-Operacja}"
  local warning="${2:-}"
  shift 2 || true
  local auto_yes=0
  if [[ "${1:-}" == "--yes" ]]; then
    auto_yes=1
    shift || true
  fi
  local -a steps=("$@")

  echo
  echo "${C_BOLD}══════════════════════════════════════════════════════════════════════${C_RESET}"
  echo "  ${C_BOLD}${title}${C_RESET}"
  echo "${C_BOLD}══════════════════════════════════════════════════════════════════════${C_RESET}"
  echo "  ${C_CYAN}Po potwierdzeniu zostaną wykonane kolejno następujące kroki:${C_RESET}"
  echo
  local i=0 step
  for step in "${steps[@]}"; do
    [[ -n "${step}" ]] || continue
    i=$((i + 1))
    printf '    %s%d.%s %s\n' "${C_BOLD}" "${i}" "${C_RESET}" "${step}"
  done
  echo
  if [[ -n "${warning}" ]]; then
    hm_warn "  UWAGA: ${warning}"
    echo
  fi

  if [[ "${auto_yes}" -eq 1 ]]; then
    hm_file_log INFO "CONFIRM_PLAN: ${title} -> yes (--yes, ${i} steps)"
    echo "  ${C_DIM}(--yes: pomijam interaktywne potwierdzenie)${C_RESET}"
    echo
    return 0
  fi

  local reply
  printf '  Wpisz %syes%s, aby wykonać powyższy plan (cokolwiek innego = anuluj): ' \
    "${C_BOLD}${C_YELLOW}" "${C_RESET}"
  read -r reply || {
    echo
    hm_file_log WARN "CONFIRM_PLAN: ${title} -> (EOF/abort)"
    return 1
  }
  if [[ "${reply}" == "yes" ]]; then
    hm_file_log INFO "CONFIRM_PLAN: ${title} -> yes (${i} steps)"
    echo
    return 0
  fi
  hm_file_log INFO "CONFIRM_PLAN: ${title} -> aborted (reply=${reply:-empty})"
  hm_info "Anulowano — żaden krok nie został wykonany."
  return 1
}

# Wariant o podwyższonym rygorze: po 'yes' wymaga wpisania dokładnej nazwy domeny.
# Wspiera --yes jako 4. argument (po domain/title/warning) — pomija obie interakcje.
hm_confirm_plan_critical() {
  local domain="$1"
  local title="$2"
  local warning="$3"
  shift 3 || true
  local auto_yes=0
  if [[ "${1:-}" == "--yes" ]]; then
    auto_yes=1
    shift || true
  fi
  if [[ "${auto_yes}" -eq 1 ]]; then
    if ! hm_confirm_plan "${title}" "${warning}" --yes "$@"; then
      return 1
    fi
    hm_file_log INFO "CONFIRM_CRITICAL: confirmed domain=${domain} (--yes)"
    return 0
  fi
  if ! hm_confirm_plan "${title}" "${warning}" "$@"; then
    return 1
  fi
  local confirm_dom
  printf '  Potwierdź docelową domenę, wpisując dokładnie %s%s%s: ' \
    "${C_BOLD}${C_RED}" "${domain}" "${C_RESET}"
  read -r confirm_dom || return 1
  if [[ "${confirm_dom}" != "${domain}" ]]; then
    hm_file_log WARN "CONFIRM_CRITICAL: mismatch expected=${domain} got=${confirm_dom:-empty}"
    hm_err "Nazwa domeny nie zgadza się (${confirm_dom:-pusto} != ${domain}). Operacja przerwana."
    return 1
  fi
  hm_file_log INFO "CONFIRM_CRITICAL: confirmed domain=${domain}"
  echo
  return 0
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

# --- postęp / status na prawdziwym TTY (bez śmieci w logach sesji) ------------

hm_ui_tty_fd() {
  # fd 3 przy aktywnym tee logów; inaczej 1 gdy stdout to TTY
  if [[ "${HM_LOG_TTY_FDS:-0}" == "1" ]]; then
    if { true >&3; } 2>/dev/null; then
      echo 3
      return 0
    fi
  fi
  if [[ -t 1 ]]; then
    echo 1
    return 0
  fi
  return 1
}

hm_status_clear() {
  local fd
  fd="$(hm_ui_tty_fd)" || return 0
  # shellcheck disable=SC2086
  printf '\r\033[K' >&"${fd}"
}

hm_status_line() {
  # tymczasowa linia statusu (operacje bez znanej liczby kroków)
  local msg="$*"
  local fd
  fd="$(hm_ui_tty_fd)" || return 0
  if [[ ${#msg} -gt 72 ]]; then
    msg="${msg:0:69}..."
  fi
  # shellcheck disable=SC2086
  printf '\r\033[K  %s… %s%s' "${C_CYAN}" "${msg}" "${C_RESET}" >&"${fd}"
}

hm_progress_bar() {
  # hm_progress_bar <current> <total> [opis]
  local cur="${1:-0}" total="${2:-1}" label="${3:-}"
  local fd pct width filled empty bar i
  fd="$(hm_ui_tty_fd)" || return 0
  [[ "${total}" =~ ^[0-9]+$ && "${total}" -gt 0 ]] || total=1
  [[ "${cur}" =~ ^[0-9]+$ ]] || cur=0
  [[ "${cur}" -gt "${total}" ]] && cur="${total}"

  pct=$((cur * 100 / total))
  width=20
  filled=$((pct * width / 100))
  empty=$((width - filled))
  bar=""
  for ((i = 0; i < filled; i++)); do bar+=$'\u2588'; done
  for ((i = 0; i < empty; i++)); do bar+=$'\u2591'; done

  if [[ ${#label} -gt 48 ]]; then
    label="${label:0:45}..."
  fi

  # shellcheck disable=SC2086
  printf '\r\033[K  %s[%s] %3d%% (%d/%d)%s %s' \
    "${C_CYAN}" "${bar}" "${pct}" "${cur}" "${total}" "${C_RESET}" "${label}" >&"${fd}"
}

hm_progress_done() {
  hm_status_clear
  if [[ $# -gt 0 && -n "$*" ]]; then
    hm_info "$*"
  fi
}
