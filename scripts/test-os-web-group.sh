#!/usr/bin/env bash
# hm_os_web_group: nginx/apache → www-data (Debian) / nginx|apache (RHEL), nie nogroup.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

# shellcheck disable=SC1091
source lib/os_family.sh

# Stub ps: bez OLS; opcjonalnie nginx worker
_HM_PS_NGINX_GROUP=""
ps() {
  # ps -o group= -C NAME
  local proc="" arg
  for arg in "$@"; do
    case "${arg}" in
      lshttpd|openlitespeed|litespeed|apache2|httpd) return 0 ;;
      nginx)
        if [[ -n "${_HM_PS_NGINX_GROUP}" ]]; then
          printf '%s\n' "root" "${_HM_PS_NGINX_GROUP}"
        fi
        return 0
        ;;
    esac
  done
  return 0
}

# Debian adapter
hm_os_bind() {
  OS_FAMILY=debian
  # shellcheck disable=SC1091
  source lib/os/debian.sh
  return 0
}
getent() {
  case "${2:-}" in
    www-data|nogroup|nobody) return 0 ;;
    *) return 1 ;;
  esac
}

# --- (a) WEBSERVER=nginx, brak żywego procesu → www-data ---
_HM_PS_NGINX_GROUP=""
export WEBSERVER=nginx
unset HM_SITE_WEBSERVER
got="$(hm_os_web_group)"
[[ "${got}" == "www-data" ]] && pass "(a) WEBSERVER=nginx → www-data" || fail "(a) got=${got}"

# --- (b) żywy nginx worker → grupa z ps ---
_HM_PS_NGINX_GROUP="www-data"
unset WEBSERVER HM_SITE_WEBSERVER
got="$(hm_os_web_group)"
[[ "${got}" == "www-data" ]] && pass "(b) ps nginx worker → www-data" || fail "(b) got=${got}"

# --- (c) apache ---
_HM_PS_NGINX_GROUP=""
export WEBSERVER=apache
got="$(hm_os_web_group)"
[[ "${got}" == "www-data" ]] && pass "(c) WEBSERVER=apache → www-data" || fail "(c) got=${got}"

# --- (d) RHEL nginx ---
hm_os_bind() {
  OS_FAMILY=rhel
  # shellcheck disable=SC1091
  source lib/os/rhel.sh
  return 0
}
getent() {
  case "${2:-}" in
    nginx|apache|nobody|nogroup) return 0 ;;
    *) return 1 ;;
  esac
}
export WEBSERVER=nginx
got="$(hm_os_web_group)"
[[ "${got}" == "nginx" ]] && pass "(d) RHEL nginx → nginx" || fail "(d) got=${got}"
export WEBSERVER=apache
got="$(hm_os_web_group)"
[[ "${got}" == "apache" ]] && pass "(e) RHEL apache → apache" || fail "(e) got=${got}"

# --- (f) restore ownership używa www-data ---
hm_os_bind() {
  OS_FAMILY=debian
  source lib/os/debian.sh
  return 0
}
getent() {
  case "${2:-}" in
    www-data|nogroup|nobody) return 0 ;;
    *) return 1 ;;
  esac
}
hm_info() { :; }
hm_ok() { :; }
export WEBSERVER=nginx
_HM_PS_NGINX_GROUP=""
CHOWN_LOG="$(mktemp)"
chown() {
  printf '%s\n' "$*" >> "${CHOWN_LOG}"
  return 0
}
id() { return 0; }
# shellcheck disable=SC1091
source commands/backup/restore.sh
tmp="$(mktemp -d)"
mkdir -p "${tmp}/site/public_html"
hm_backup_restore_fix_ownership "${tmp}/site" "siteuser" "${tmp}/site/public_html" || true
if grep -q 'siteuser:www-data' "${CHOWN_LOG}"; then
  pass "(f) restore docroot → user:www-data"
else
  fail "(f) brak siteuser:www-data w chown: $(cat "${CHOWN_LOG}")"
fi
rm -rf "${tmp}" "${CHOWN_LOG}"

if [[ "${FAIL}" -eq 0 ]]; then
  echo "ALL PASSED (${PASS})"
else
  echo "FAILED (${FAIL} fail, ${PASS} pass)" >&2
  exit 1
fi
