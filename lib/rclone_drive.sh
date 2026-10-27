#!/usr/bin/env bash
# Wrapper rclone / Google Drive

if [[ -n "${HMTOOLS_RCLONE_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_RCLONE_LOADED=1

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_LIB_DIR}/common.sh"

hm_rclone_check() {
  if ! hm_have_cmd rclone; then
    hm_err "Brak rclone. Zainstaluj: curl https://rclone.org/install.sh | bash"
    hm_err "Lub uruchom: hmtools → backup setup"
    return 1
  fi
  return 0
}

hm_rclone_remote_name() {
  # z RCLONE_REMOTE=gdrive:path → gdrive
  echo "${RCLONE_REMOTE%%:*}"
}

hm_rclone_remote_path() {
  # gdrive:vps-backups → vps-backups  (lub pusty)
  local rest="${RCLONE_REMOTE#*:}"
  if [[ "${rest}" == "${RCLONE_REMOTE}" ]]; then
    echo ""
  else
    echo "${rest}"
  fi
}

hm_rclone_dest() {
  # hm_rclone_dest relative/path → full remote:path (względem RCLONE_REMOTE = root backupów)
  local rel="${1#/}"
  local base
  base="$(hm_rclone_remote_path)"
  if [[ -n "${base}" ]]; then
    echo "${RCLONE_REMOTE%%:*}:${base}/${rel}"
  else
    echo "${RCLONE_REMOTE%%:*}:${rel}"
  fi
}

# Struktura na Drive (root = RCLONE_REMOTE):
#   full/<stamp>/              — pełny backup serwera
#   <domena>/<stamp>/          — backup jednej strony
#   db-dumps/                  — jednorazowe zrzuty mysql dump
hm_backup_dest_full() {
  local stamp="$1"
  hm_rclone_dest "full/${stamp}"
}

hm_backup_dest_site() {
  local domain="$1"
  local stamp="$2"
  hm_rclone_dest "${domain}/${stamp}"
}

hm_backup_dest_dbdump() {
  local db="$1"
  local stamp="$2"
  hm_rclone_dest "db-dumps/${db}-${stamp}.sql.gz"
}

hm_rclone_save_remote_conf() {
  # zapis RCLONE_REMOTE do hmtools.conf
  local value="$1"
  local conf="${HMTOOLS_CONF:-${HMTOOLS_ROOT}/config/hmtools.conf}"
  mkdir -p "$(dirname "${conf}")"
  if [[ -f "${conf}" ]] && grep -q '^RCLONE_REMOTE=' "${conf}" 2>/dev/null; then
    sed -i.bak "s|^RCLONE_REMOTE=.*|RCLONE_REMOTE=\"${value}\"|" "${conf}"
  elif [[ -f "${conf}" ]]; then
    echo "RCLONE_REMOTE=\"${value}\"" >> "${conf}"
  elif [[ -f "${HMTOOLS_ROOT}/config/hmtools.conf.example" ]]; then
    cp "${HMTOOLS_ROOT}/config/hmtools.conf.example" "${conf}"
    sed -i.bak "s|^RCLONE_REMOTE=.*|RCLONE_REMOTE=\"${value}\"|" "${conf}"
  else
    echo "RCLONE_REMOTE=\"${value}\"" > "${conf}"
  fi
  RCLONE_REMOTE="${value}"
  export RCLONE_REMOTE
}

hm_rclone_ensure_backup_layout() {
  # utwórz root + full/ na Drive
  hm_rclone_check || return 1
  hm_rclone_mkdir "${RCLONE_REMOTE}"
  hm_rclone_mkdir "$(hm_rclone_dest "full")"
}

hm_rclone_test() {
  hm_rclone_check || return 1
  local remote
  remote="$(hm_rclone_remote_name)"
  hm_info "Test rclone remote '${remote}'..."
  if rclone lsd "${remote}:" >/dev/null 2>&1; then
    hm_ok "Połączenie OK."
    echo
    echo "Root backupów (RCLONE_REMOTE): ${RCLONE_REMOTE}"
    echo "Struktura:"
    echo "  ${RCLONE_REMOTE}/full/<stamp>/     — pełne kopie"
    echo "  ${RCLONE_REMOTE}/<domena>/<stamp>/ — kopie stron"
    echo
    hm_info "Zawartość katalogu root:"
    rclone lsd "${RCLONE_REMOTE}" 2>/dev/null | head -30 || true
    return 0
  else
    hm_err "Nie udało się wypisać katalogów remote '${remote}:'."
    hm_err "Uruchom: rclone config  lub  backup setup"
    return 1
  fi
}

hm_backup_config_root() {
  # jednorazowa konfiguracja katalogu root na Google Drive
  hm_load_config
  hm_rclone_check || return 1

  local remote cur_path
  remote="$(hm_rclone_remote_name)"
  cur_path="$(hm_rclone_remote_path)"
  [[ -n "${remote}" ]] || remote="gdrive"

  echo "${C_BOLD}Konfiguracja katalogu root backupów (Google Drive)${C_RESET}"
  echo
  echo "  Obecnie: ${RCLONE_REMOTE:-brak}"
  echo
  echo "  Wewnątrz wybranego katalogu hmtools utworzy:"
  echo "    full/           — pełne kopie serwera"
  echo "    <domena>/       — kopie poszczególnych stron"
  echo "    db-dumps/       — jednorazowe zrzuty baz"
  echo

  if rclone listremotes 2>/dev/null | grep -q .; then
    echo "  Dostępne remote rclone:"
    rclone listremotes 2>/dev/null | sed 's/^/    /'
    echo
  fi

  local new_remote new_path
  read -r -p "Nazwa remote rclone [${remote}]: " new_remote
  new_remote="${new_remote:-${remote}}"

  echo
  hm_info "Katalogi w ${new_remote}: (pierwsze poziomy)"
  rclone lsd "${new_remote}:" 2>/dev/null | head -25 | sed 's/^/  /' || hm_warn "Nie udało się listować (sprawdź rclone config)."
  echo

  read -r -p "Ścieżka katalogu root na Drive [${cur_path:-vps-backups}]: " new_path
  new_path="${new_path:-${cur_path:-vps-backups}}"
  # bez wiodącego/końcowego slash
  new_path="${new_path#/}"
  new_path="${new_path%/}"

  local value="${new_remote}:${new_path}"
  echo
  echo "  Ustawić root na: ${value} ?"
  if ! hm_confirm "Zapisać w hmtools.conf"; then
    hm_info "Anulowano."
    return 0
  fi

  hm_rclone_save_remote_conf "${value}"
  hm_ok "Zapisano RCLONE_REMOTE=\"${value}\""

  hm_info "Tworzenie katalogów root/ i full/ …"
  hm_rclone_ensure_backup_layout
  hm_ok "Layout gotowy."
  echo
  rclone lsd "${RCLONE_REMOTE}" 2>/dev/null | sed 's/^/  /' || true
}

hm_rclone_rcat() {
  # stdin → remote path (pełny remote:path)
  local dest="$1"
  hm_rclone_check || return 1
  rclone rcat "${dest}" --quiet
}

hm_rclone_copyto() {
  local src="$1"
  local dest="$2"
  hm_rclone_check || return 1
  rclone copyto "${src}" "${dest}" --quiet
}

hm_rclone_mkdir() {
  local dest="$1"
  hm_rclone_check || return 1
  rclone mkdir "${dest}" >/dev/null 2>&1 || true
}
