#!/usr/bin/env bash
# Regresja: access ssh — UID < UID_MIN (daemon/messagebus) = chroniony
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"

fail=0
assert_eq() {
  local name="$1" got="$2" want="$3"
  if [[ "${got}" != "${want}" ]]; then
    echo "FAIL ${name}: got=[${got}] want=[${want}]"
    fail=1
    return
  fi
  echo "OK   ${name}"
}

# stubi UI
hm_err() { echo "ERR:$*" >&2; }
hm_ok() { :; }
hm_info() { :; }
hm_warn() { :; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }

# shellcheck disable=SC1091
source commands/delete-site/delete.sh
# shellcheck disable=SC1091
source commands/access/ssh.sh

# --- hm_unix_uid_min ---
umin="$(hm_unix_uid_min)"
[[ "${umin}" =~ ^[0-9]+$ ]] && echo "OK   uid-min-numeric (${umin})" || { echo "FAIL uid-min"; fail=1; }

# --- protected: sztywna lista ---
hm_del_user_is_protected "www-data" && echo "OK   www-data-protected" || { echo "FAIL www-data"; fail=1; }
hm_del_user_is_protected "root" && echo "OK   root-protected" || { echo "FAIL root"; fail=1; }

# --- UID < UID_MIN: symulacja id ---
_real_id="$(command -v id)"
id() {
  case "${1:-}" in
    -u)
      case "${2:-}" in
        fakedaemon) echo 1; return 0 ;;
        fakemsg) echo 102; return 0 ;;
        normalsite) echo 1001; return 0 ;;
        *) "${_real_id}" "$@" ;;
      esac
      ;;
    fakedaemon|fakemsg|normalsite) return 0 ;;
    *) "${_real_id}" "$@" ;;
  esac
}

hm_del_user_is_protected "fakedaemon" && echo "OK   uid1-protected" || { echo "FAIL uid1"; fail=1; }
hm_del_user_is_protected "fakemsg" && echo "OK   uid102-protected" || { echo "FAIL uid102"; fail=1; }
hm_del_user_is_protected "normalsite" && { echo "FAIL normalsite-should-not-be-protected"; fail=1; } || echo "OK   uid1001-not-protected"

# --- require_site_user odmowa dla system UID ---
HM_SITE_USER="fakedaemon"
if out="$(hm_access_require_site_user "sys.pl" 2>&1)"; then
  echo "FAIL require-should-deny-daemon"
  fail=1
else
  echo "OK   require-denies-daemon"
fi

HM_SITE_USER="normalsite"
# normalsite nie jest chroniony nazwą; id stub zwraca 1001 — powinno przejść
if got="$(hm_access_require_site_user "blog.pl" 2>/dev/null)"; then
  assert_eq "require-allows-normal" "${got}" "normalsite"
else
  echo "FAIL require-should-allow-normalsite"
  fail=1
fi

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL OK"
exit 0
