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

# archive.sh: nieudane exact-assign NIE może zerować arg przed partial fallback
# (pusty arg → *""* matchuje WSZYSTKIE domeny; zachowany „shop” → tylko myshop.pl)
_resolve_like_archive() {
  local domain="$1"
  local domain_arg="${domain}"
  domain="$(hm_find_site_by_arg_exact "${domain_arg}" 2>/dev/null)" || {
    domain="$(hm_find_site_by_arg "${domain_arg}")" || return 1
  }
  printf '%s\n' "${domain}"
}
err="$(_resolve_like_archive shop 2>&1)" && {
  echo "FAIL archive-preserve-arg: expected failure (non-TTY), got=${err}"
  fail=1
} || {
  case "${err}" in
    *myshop.pl*)
      # non-TTY: błąd z podpowiedzią jedynej podobnej — NIE Ambiguous wszystkich
      if [[ "${err}" == *Ambiguous* && "${err}" == *alpha.test* ]]; then
        echo "FAIL archive-preserve-arg: pusty arg (Ambiguous z alpha) — domain_arg nie zachowany?"
        fail=1
      else
        echo "OK   archive-preserve-arg"
      fi
      ;;
    *)
      echo "FAIL archive-preserve-arg: unexpected err=[${err}]"
      fail=1
      ;;
  esac
}

# regresja: wzorzec BEZ domain_arg (stary bug) → Ambiguous wszystkich stron
_resolve_broken() {
  local domain="$1"
  domain="$(hm_find_site_by_arg_exact "${domain}" 2>/dev/null)" || {
    domain="$(hm_find_site_by_arg "${domain}")" || return 1
  }
  printf '%s\n' "${domain}"
}
err="$(_resolve_broken shop 2>&1)" && {
  echo "FAIL broken-pattern-demo: expected failure"
  fail=1
} || {
  case "${err}" in
    *Ambiguous*alpha.test*|*Ambiguous*myshop*)
      echo "OK   broken-pattern-demo (pusty arg → Ambiguous wszystkich)"
      ;;
    *)
      echo "FAIL broken-pattern-demo: expected Ambiguous-all, got=[${err}]"
      fail=1
      ;;
  esac
}

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL OK"
exit 0
