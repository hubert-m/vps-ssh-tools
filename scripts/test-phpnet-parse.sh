#!/usr/bin/env bash
# Testy parsera odpowiedzi php.net (hm_php_parse_phpnet_json)
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
# shellcheck disable=SC1091
source lib/common/ui.sh
# shellcheck disable=SC1091
source commands/php/repo.sh

fail=0
assert_ok() {
  local name="$1" json="$2" want="$3" got
  if ! got="$(hm_php_parse_phpnet_json "${json}")"; then
    echo "FAIL ${name}: oczekiwano OK (${want}), dostano rc≠0"
    fail=1
    return
  fi
  if [[ "${got}" != "${want}" ]]; then
    echo "FAIL ${name}: got=${got} want=${want}"
    fail=1
    return
  fi
  echo "OK   ${name}"
}

assert_fail() {
  local name="$1" json="$2"
  if hm_php_parse_phpnet_json "${json}" >/dev/null 2>&1; then
    echo "FAIL ${name}: oczekiwano rc≠0"
    fail=1
    return
  fi
  echo "OK   ${name}"
}

assert_ok "valid object key" '{"8.4.14":{"date":"..."}}' "8.4.14"
assert_fail "error unknown" '{"error":"Unknown version"}'
assert_fail "empty object" '{}'
assert_fail "empty array" '[]'
assert_fail "empty string" ''
assert_fail "html" '<!DOCTYPE html><html><body>no</body></html>'
assert_fail "error key with jq trap" '{"error":"Unknown version","8.0.0":{}}'

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
