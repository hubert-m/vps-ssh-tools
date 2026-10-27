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
  # hm_rclone_dest relative/path → full remote:path
  local rel="${1#/}"
  local base
  base="$(hm_rclone_remote_path)"
  if [[ -n "${base}" ]]; then
    echo "${RCLONE_REMOTE%%:*}:${base}/${rel}"
  else
    echo "${RCLONE_REMOTE%%:*}:${rel}"
  fi
}

hm_rclone_test() {
  hm_rclone_check || return 1
  local remote
  remote="$(hm_rclone_remote_name)"
  hm_info "Test rclone remote '${remote}'..."
  if rclone lsd "${remote}:" >/dev/null 2>&1; then
    hm_ok "Połączenie OK."
    rclone lsd "${remote}:" 2>/dev/null | head -20
    return 0
  else
    hm_err "Nie udało się wypisać katalogów remote '${remote}:'."
    hm_err "Uruchom: rclone config  lub  backup setup"
    return 1
  fi
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
