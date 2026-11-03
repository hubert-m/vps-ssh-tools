#!/usr/bin/env bash
# Test: hm_access_resolve_site ustawia HM_SITE_* w bieżącej powłoce (nie w subshellu)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

hm_err() { echo "ERR: $*" >&2; }
hm_ok() { :; }
hm_info() { :; }
hm_warn() { :; }

HM_SITE_DOMAIN=""
HM_SITE_USER=""
HM_SITE_ROOT=""

hm_find_site_by_arg() {
  case "${1:-}" in
    shop.pl|shop) printf 'shop.pl' ;;
    blog.pl|blog) printf 'blog.pl' ;;
    *) return 1 ;;
  esac
}

hm_set_site_context() {
  local d="$1"
  HM_SITE_DOMAIN="${d}"
  case "${d}" in
    shop.pl) HM_SITE_USER="shop"; HM_SITE_ROOT="/home/shop.pl" ;;
    blog.pl) HM_SITE_USER="blog"; HM_SITE_ROOT="/home/blog.pl" ;;
  esac
}

# shellcheck disable=SC1091
source "${ROOT}/commands/access/ssh.sh"

fail=0
assert_eq() {
  local label="$1" got="$2" want="$3"
  if [[ "${got}" == "${want}" ]]; then
    echo "OK   ${label}"
  else
    echo "FAIL ${label}: got='${got}' want='${want}'"
    fail=1
  fi
}

# bez subshella — kontekst zostaje
hm_access_resolve_site "shop.pl" || { echo "FAIL resolve shop"; fail=1; }
assert_eq "domain after resolve" "${HM_SITE_DOMAIN}" "shop.pl"
assert_eq "user after resolve" "${HM_SITE_USER}" "shop"

# przełączenie z blog → shop (jawny arg nadpisuje use)
hm_set_site_context "blog.pl"
hm_access_resolve_site "shop.pl" || fail=1
assert_eq "switch domain" "${HM_SITE_DOMAIN}" "shop.pl"
assert_eq "switch user" "${HM_SITE_USER}" "shop"

# subshell — kontekst NIE powinien wyciec (dokumentacja błędu)
HM_SITE_DOMAIN=""; HM_SITE_USER=""
_out="$(hm_access_resolve_site "shop.pl" && printf '%s' "${HM_SITE_USER}")"
assert_eq "inside subshell user visible" "${_out}" "shop"
assert_eq "outside subshell user empty" "${HM_SITE_USER}" ""

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
