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

# Escapowanie wartości string do JSON (dla heredoców manifestów backup).
hm_json_escape_str() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "${s}"
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
  if declare -F hm_config_after >/dev/null 2>&1; then
    hm_config_after || true
  fi
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
    if declare -F hm_config_before >/dev/null 2>&1; then
      hm_config_before "${title}" || true
    fi
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
    if declare -F hm_config_before >/dev/null 2>&1; then
      hm_config_before "${title}" || true
    fi
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

# Uruchom z limitem czasu (sekundy). Bez `timeout` w PATH — wywołanie bezpośrednie.
hm_run_timeout() {
  local secs="${1:-3}"
  shift || true
  if hm_have_cmd timeout; then
    timeout "${secs}s" "$@"
  else
    "$@"
  fi
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

# Sekret na prawdziwym TTY (fd 3) albo w pliku 0600 (HM_SECRET_FILE / --secret-file).
# Bez TTY i bez pliku: rc≠0, nic nie zmieniamy w wołającym kodzie — wołający ma sprawdzić wcześniej.
hm_secret_tty_ok() {
  if [[ "${HMTOOLS_TEST:-0}" == "1" && "${HMTOOLS_TEST_NO_TTY:-0}" == "1" ]]; then
    return 1
  fi
  if [[ "${HM_LOG_TTY_FDS:-0}" == "1" ]] && { true >&3; } 2>/dev/null; then
    return 0
  fi
  if [[ -t 1 ]]; then
    return 0
  fi
  if [[ -e /dev/tty ]] && { true >/dev/tty; } 2>/dev/null; then
    return 0
  fi
  return 1
}

hm_secret_can_deliver() {
  if [[ -n "${HM_SECRET_FILE:-}" ]]; then
    mkdir -p "$(dirname "${HM_SECRET_FILE}")" 2>/dev/null || true
    if : >> "${HM_SECRET_FILE}" 2>/dev/null; then
      chmod 0600 "${HM_SECRET_FILE}" 2>/dev/null || true
      return 0
    fi
    return 1
  fi
  hm_secret_tty_ok
}

hm_secret_require_delivery() {
  if hm_secret_can_deliver; then
    return 0
  fi
  hm_err "Brak TTY — sekret nie zostałby pokazany. Operacja przerwana przed zmianą hasła. Podaj --secret-file."
  return 1
}

hm_secret_register() {
  local s="${1:-}" existing
  [[ ${#s} -ge 8 ]] || return 0
  [[ -n "${HM_LOG_SECRETS+x}" ]] || HM_LOG_SECRETS=()
  for existing in "${HM_LOG_SECRETS[@]:-}"; do
    [[ "${existing}" == "${s}" ]] && return 0
  done
  HM_LOG_SECRETS+=("${s}")
}

hm_secret_note_line() {
  local line="$1" low val
  low="$(printf '%s' "${line}" | tr '[:upper:]' '[:lower:]')"
  case "${low}" in
    *hasło:*|*haslo:*|*password:*)
      val="${line##*:}"
      val="${val#"${val%%[![:space:]]*}"}"
      val="${val%"${val##*[![:space:]]}"}"
      hm_secret_register "${val}"
      ;;
  esac
}

hm_secret_write_file() {
  local f="${HM_SECRET_FILE:-}" line
  [[ -n "${f}" ]] || return 1
  (
    umask 077
    for line in "$@"; do
      [[ -n "${line}" ]] || continue
      printf '%s\n' "${line}" >> "${f}"
    done
  )
  chmod 0600 "${f}" 2>/dev/null || true
}

hm_secret_write_tty() {
  local line fd=""
  if [[ "${HM_LOG_TTY_FDS:-0}" == "1" ]] && { true >&3; } 2>/dev/null; then
    fd=3
  elif [[ -t 1 ]]; then
    fd=1
  fi
  if [[ -n "${fd}" ]]; then
    for line in "$@"; do
      printf '%s\n' "${line}" >&"${fd}"
    done
    return 0
  fi
  if [[ -e /dev/tty ]] && { true >/dev/tty; } 2>/dev/null; then
    for line in "$@"; do
      printf '%s\n' "${line}" >/dev/tty
    done
    return 0
  fi
  return 1
}

hm_print_secret() {
  local line
  for line in "$@"; do
    hm_secret_note_line "${line}"
  done
  if [[ -n "${HM_SECRET_FILE:-}" ]]; then
    hm_secret_write_file "$@" || return 1
    if hm_secret_tty_ok; then
      hm_secret_write_tty "$@" || true
    fi
    return 0
  fi
  if hm_secret_tty_ok; then
    hm_secret_write_tty "$@"
    return $?
  fi
  hm_err "Brak TTY — sekret nie został wypisany. Podaj --secret-file."
  return 1
}

# --- tabele kolumnowe -------------------------------------------------------
# Szerokość z treści (nie ze stałego %-Ns), więc długie domeny nie rozjeżdżają
# kolejnych kolumn. Kolory ANSI nie wchodzą do szerokości.
#   hm_table_begin [LRRL]     # L lewo, R prawo; domyślnie same L
#   hm_table_row  "a" "b"
#   hm_table_print [wcięcie]  # domyślnie 2 spacje; pierwszy wiersz = nagłówek

hm_visible_len() {
  local s="${1:-}" out=""
  while [[ "${s}" == *$'\033'* ]]; do
    out+="${s%%$'\033'*}"
    s="${s#*$'\033'}"
    if [[ "${s:0:1}" == "[" ]]; then
      s="${s:1}"
      while [[ -n "${s}" && "${s:0:1}" == [0-9\;?] ]]; do
        s="${s:1}"
      done
      [[ -n "${s}" ]] && s="${s:1}"
    fi
  done
  out+="${s}"
  local LC_ALL=C.UTF-8
  printf '%s' "${#out}"
}

hm_table_dashes() {
  local n="${1:-0}" i s=""
  for ((i = 0; i < n; i++)); do
    s+=-
  done
  printf '%s' "${s}"
}

hm_table_indent() {
  local n="${1:-0}" i
  for ((i = 0; i < n; i++)); do
    printf ' '
  done
}

hm_table_pad() {
  local text="${1:-}" width="${2:-0}" align="${3:-L}" vis pad
  vis="$(hm_visible_len "${text}")"
  [[ "${vis}" =~ ^[0-9]+$ ]] || vis=0
  [[ "${width}" =~ ^[0-9]+$ ]] || width=0
  if [[ "${vis}" -ge "${width}" ]]; then
    printf '%s' "${text}"
    return 0
  fi
  pad=$((width - vis))
  case "${align}" in
    R|r) printf '%*s%s' "${pad}" "" "${text}" ;;
    *) printf '%s%*s' "${text}" "${pad}" "" ;;
  esac
}

hm_table_begin() {
  HM_TABLE_ROWS=()
  HM_TABLE_ALIGN="${1:-}"
}

hm_table_row() {
  local -a cells=()
  local c n joined
  for c in "$@"; do
    c="${c//$'\n'/ }"
    c="${c//$'\r'/ }"
    c="${c//$'\t'/ }"
    c="${c//$'\x1e'/ }"
    cells+=("${c}")
  done
  n="${#cells[@]}"
  [[ "${n}" -gt 0 ]] || return 0
  joined="${n}"
  for c in "${cells[@]}"; do
    joined+=$'\x1e'"${c}"
  done
  HM_TABLE_ROWS+=("${joined}")
}

hm_table_split_row() {
  local stored="${1:-}" rest count i part
  HM_TABLE_CELLS=()
  count="${stored%%$'\x1e'*}"
  [[ "${count}" =~ ^[0-9]+$ ]] || return 0
  rest="${stored#*$'\x1e'}"
  for ((i = 0; i < count; i++)); do
    if [[ "${i}" -eq $((count - 1)) ]]; then
      HM_TABLE_CELLS+=("${rest}")
      break
    fi
    part="${rest%%$'\x1e'*}"
    rest="${rest#*$'\x1e'}"
    HM_TABLE_CELLS+=("${part}")
  done
}

hm_table_print() {
  local indent="${1:-2}"
  [[ "${#HM_TABLE_ROWS[@]}" -gt 0 ]] || return 0
  local -a widths=()
  local stored i vis w cell align n idx=0
  for stored in "${HM_TABLE_ROWS[@]}"; do
    hm_table_split_row "${stored}"
    for i in "${!HM_TABLE_CELLS[@]}"; do
      vis="$(hm_visible_len "${HM_TABLE_CELLS[$i]}")"
      w="${widths[$i]:-0}"
      if [[ "${vis}" -gt "${w}" ]]; then
        widths[$i]="${vis}"
      fi
    done
  done
  n="${#widths[@]}"
  [[ "${n}" -gt 0 ]] || return 0
  for stored in "${HM_TABLE_ROWS[@]}"; do
    hm_table_split_row "${stored}"
    hm_table_indent "${indent}"
    if [[ "${idx}" -eq 0 ]]; then
      printf '%s' "${C_BOLD:-}"
    fi
    for ((i = 0; i < n; i++)); do
      cell="${HM_TABLE_CELLS[$i]:-}"
      align="L"
      if [[ -n "${HM_TABLE_ALIGN:-}" && "${i}" -lt "${#HM_TABLE_ALIGN}" ]]; then
        align="${HM_TABLE_ALIGN:i:1}"
      fi
      [[ -n "${widths[$i]:-}" ]] || widths[$i]=0
      hm_table_pad "${cell}" "${widths[$i]}" "${align}"
      if [[ "${i}" -lt $((n - 1)) ]]; then
        printf '  '
      fi
    done
    if [[ "${idx}" -eq 0 ]]; then
      printf '%s\n' "${C_RESET:-}"
      hm_table_indent "${indent}"
      printf '%s' "${C_DIM:-}"
      for ((i = 0; i < n; i++)); do
        hm_table_dashes "${widths[$i]}"
        if [[ "${i}" -lt $((n - 1)) ]]; then
          printf '  '
        fi
      done
      printf '%s\n' "${C_RESET:-}"
    else
      printf '\n'
    fi
    idx=$((idx + 1))
  done
  return 0
}

_hm_json_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/json.sh"
if [[ -f "${_hm_json_lib}" ]]; then
  # shellcheck source=json.sh
  source "${_hm_json_lib}"
fi
unset _hm_json_lib
