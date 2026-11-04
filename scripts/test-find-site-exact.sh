#!/usr/bin/env bash
# Regresja: brak cichego partial match (alpha.test ≠ child.alpha.test)
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
# shellcheck disable=SC1091
source lib/common/ui.sh

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
assert_fail() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "FAIL ${name}: expected failure"
    fail=1
    return
  fi
  echo "OK   ${name}"
}

# shellcheck disable=SC1091
source commands/_shared/sites/discover.sh

# stub po source — nie uruchamiaj prawdziwego discover/detect
hm_discover_sites() { :; }
HM_SITES_LIST=("alpha.test" "child.alpha.test" "myshop.pl")

assert_eq "exact-alpha" "$(hm_find_site_by_arg_exact alpha.test)" "alpha.test"
assert_eq "exact-child" "$(hm_find_site_by_arg_exact child.alpha.test)" "child.alpha.test"
assert_fail "exact-no-partial" hm_find_site_by_arg_exact shop.pl
assert_fail "exact-substring" hm_find_site_by_arg_exact alpha

# non-TTY partial → błąd (nie child.alpha.test po cichu)
assert_fail "partial-silent-forbidden" hm_find_site_by_arg alpha

assert_eq "exact-mode" "$(hm_find_site_by_arg alpha.test exact)" "alpha.test"
assert_eq "by-number" "$(hm_find_site_by_arg_exact 1)" "alpha.test"

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL OK"
exit 0
