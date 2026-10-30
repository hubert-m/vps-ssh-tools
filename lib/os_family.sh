#!/usr/bin/env bash
# Publiczne API różnic OS_FAMILY (debian | rhel) — osobna oś od menedżera pakietów.
# Adaptery: lib/os/debian.sh | lib/os/rhel.sh; opcjonalnie lib/os/overrides/${OS_ID}.sh

if [[ -n "${HMTOOLS_OS_FAMILY_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_OS_FAMILY_LOADED=1

HMTOOLS_OS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/os"
HM_OS_BACKEND_KEY=""

hm_os_family_id() {
  case "${OS_FAMILY:-unknown}" in
    debian|rhel) printf '%s' "${OS_FAMILY}" ;;
    *)
      # heurystyka gdy detect jeszcze nie ustawil
      if [[ -d /etc/httpd ]] || hm_have_cmd dnf || hm_have_cmd yum; then
        printf 'rhel'
      else
        printf 'debian'
      fi
      ;;
  esac
}

hm_os_bind() {
  local fam key
  fam="$(hm_os_family_id)"
  key="${fam}:${OS_ID:-}"
  if [[ "${HM_OS_BACKEND_KEY}" == "${key}" ]]; then
    return 0
  fi
  case "${fam}" in
    debian)
      # shellcheck source=os/debian.sh
      source "${HMTOOLS_OS_DIR}/debian.sh"
      ;;
    rhel)
      # shellcheck source=os/rhel.sh
      source "${HMTOOLS_OS_DIR}/rhel.sh"
      ;;
    *)
      # shellcheck source=os/debian.sh
      source "${HMTOOLS_OS_DIR}/debian.sh"
      fam="debian"
      ;;
  esac
  if [[ -n "${OS_ID:-}" && -f "${HMTOOLS_OS_DIR}/overrides/${OS_ID}.sh" ]]; then
    # shellcheck disable=SC1090
    source "${HMTOOLS_OS_DIR}/overrides/${OS_ID}.sh"
  fi
  HM_OS_BACKEND_KEY="${key}"
  return 0
}

_hm_os_do_web_group() { printf 'nogroup'; }
_hm_os_do_apache_unit() { printf 'apache2'; }
_hm_os_do_apache_error_log() { return 1; }
_hm_os_do_firewall_status() { hm_warn "Firewall: brak adaptera OS."; return 1; }
_hm_os_do_firewall_ban() { return 1; }
_hm_os_do_firewall_unban() { return 1; }

# Grupa procesu WWW (OLS preferuje żywą grupę procesu; fallback = rodzina OS)
hm_os_web_group() {
  local g
  g="$(ps -o group= -C lshttpd 2>/dev/null | head -1 | tr -d ' ')"
  if [[ -z "${g}" ]]; then
    g="$(ps -o group= -C openlitespeed 2>/dev/null | head -1 | tr -d ' ')"
  fi
  if [[ -n "${g}" && "${g}" != "root" ]]; then
    printf '%s' "${g}"
    return 0
  fi
  hm_os_bind || true
  _hm_os_do_web_group
}

hm_os_apache_unit() {
  hm_os_bind || return 1
  _hm_os_do_apache_unit
}

hm_os_apache_error_log() {
  hm_os_bind || return 1
  _hm_os_do_apache_error_log
}

hm_os_firewall_status() {
  hm_os_bind || return 1
  # CSF / uniwersalne warstwy — przed adapterem rodziny
  if hm_have_cmd csf; then
    csf -l 2>/dev/null | head -40 || true
    return 0
  fi
  _hm_os_do_firewall_status
}

hm_os_firewall_ban() {
  hm_os_bind || return 1
  _hm_os_do_firewall_ban "$@"
}

hm_os_firewall_unban() {
  hm_os_bind || return 1
  _hm_os_do_firewall_unban "$@"
}
