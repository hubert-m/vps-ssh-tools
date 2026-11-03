#!/usr/bin/env bash
# Test: resolve chroot + pure-pw show parse (Directory/UID) — bez żywego pure-pw
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

hm_err() { echo "ERR: $*" >&2; }
hm_ok() { :; }
hm_info() { :; }
hm_warn() { :; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }
hm_gen_password() { printf 'x'; }
hm_confirm_plan() { return 1; }
hm_confirm_plan_critical() { return 1; }
hm_access_resolve_site() { printf '%s' "${1:-example.com}"; }
hm_access_require_site_user() { printf 'siteuser'; }
hm_find_site_by_arg() { return 1; }
hm_detect_all() { :; }
C_BOLD=""; C_RESET=""; C_DIM=""

# shellcheck disable=SC1091
source "${ROOT}/commands/access/ssh.sh"
# shellcheck disable=SC1091
source "${ROOT}/commands/access/cyberpanel.sh"
# shellcheck disable=SC1091
source "${ROOT}/commands/access/ftp.sh"

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
assert_ok() {
  local label="$1"; shift
  if "$@"; then echo "OK   ${label}"; else echo "FAIL ${label}"; fail=1; fi
}
assert_fail() {
  local label="$1"; shift
  if "$@"; then echo "FAIL ${label}"; fail=1; else echo "OK   ${label}"; fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hmtools-ftp-test.XXXXXX")"
SITE="${TMP}/home/blog.pl"
mkdir -p "${SITE}/public_html/sub"
SITE_R="$(realpath -m "${SITE}")"

assert_eq "root /" "$(hm_access_ftp_resolve_chroot "${SITE}" "/")" "${SITE_R}"
assert_eq "rel public_html" "$(hm_access_ftp_resolve_chroot "${SITE}" "public_html")" "${SITE_R}/public_html"
assert_eq "cp-style /public_html" "$(hm_access_ftp_resolve_chroot "${SITE}" "/public_html")" "${SITE_R}/public_html"
assert_eq "abs under site" "$(hm_access_ftp_resolve_chroot "${SITE}" "${SITE_R}/public_html/sub")" "${SITE_R}/public_html/sub"
assert_fail "escape .." hm_access_ftp_resolve_chroot "${SITE}" "../other"
assert_fail "outside abs" hm_access_ftp_resolve_chroot "${SITE}" "/tmp/evil"

SHOW='Login              : blogftp
Password           : \$1\$xxxx
UID                : 1001 (blog)
GID                : 1001 (blog)
Directory          : /home/blog.pl/./
OK'
assert_eq "parse dir" "$(hm_access_pure_pw_parse_dir "${SHOW}")" "/home/blog.pl/"
assert_eq "parse uid" "$(hm_access_pure_pw_parse_uid "${SHOW}")" "1001"

assert_ok "dir under site" hm_access_ftp_dir_under_site "/home/blog.pl/public_html" "/home/blog.pl"
assert_ok "dir eq site" hm_access_ftp_dir_under_site "/home/blog.pl/" "/home/blog.pl"
assert_fail "dir other site" hm_access_ftp_dir_under_site "/home/shop.pl/" "/home/blog.pl"

rm -rf "${TMP}"

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
