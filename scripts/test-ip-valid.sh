#!/usr/bin/env bash
# Szybki test hm_is_valid_ip (security)
set -euo pipefail
cd "$(dirname "$0")/.."
_hm_cmd_help() { :; }
_hm_cmd_register() { :; }
_hm_cmd_register_site() { :; }
hm_err() { :; }
hm_warn() { :; }
hm_ok() { :; }
hm_info() { :; }
hm_confirm() { return 0; }
hm_confirm_plan() { return 0; }
hm_detect_all() { :; }
# shellcheck disable=SC1091
source commands/security/main.sh

fail=0
assert_ok() {
  local n="$1" ip="$2"
  if hm_is_valid_ip "${ip}"; then
    echo "OK   valid ${n}"
  else
    echo "FAIL valid ${n} (${ip})"
    fail=1
  fi
}
assert_bad() {
  local n="$1" ip="$2"
  if hm_is_valid_ip "${ip}"; then
    echo "FAIL invalid ${n} (${ip}) accepted"
    fail=1
  else
    echo "OK   reject ${n}"
  fi
}

assert_ok "v4" "1.2.3.4"
assert_bad "0.0.0.0" "0.0.0.0"
assert_bad "octet" "999.1.1.1"
assert_bad "short v6" "1:2"
assert_bad "double ::" "1::2::3"
assert_ok "::1" "::1"
assert_ok "fe80" "fe80::1"
assert_ok "full v6" "2001:0db8:85a3:0000:0000:8a2e:0370:7334"
assert_bad "7 hextets no ::" "2001:db8:85a3:0:0:8a2e:370"

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
