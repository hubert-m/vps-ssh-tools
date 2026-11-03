#!/usr/bin/env bash
# Test: hm_redis_reply_is_error + parse integer CLIENT KILL
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

hm_err() { echo "ERR: $*" >&2; }
hm_ok() { :; }
hm_info() { :; }
hm_warn() { :; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }

# shellcheck disable=SC1091
source "${ROOT}/commands/redis/cli.sh"

fail=0
assert_yes() {
  local label="$1" sample="$2"
  if hm_redis_reply_is_error "${sample}"; then echo "OK   err: ${label}"
  else echo "FAIL expected error: ${label}"; fail=1; fi
}
assert_no() {
  local label="$1" sample="$2"
  if hm_redis_reply_is_error "${sample}"; then echo "FAIL expected ok: ${label}"; fail=1
  else echo "OK   ok:  ${label}"; fi
}

assert_yes "ERR unknown" "ERR Unknown option or number of arguments for CONFIG SET"
assert_yes "paren error" "(error) ERR Invalid save parameters"
assert_yes "NOAUTH" "NOAUTH Authentication required."
assert_yes "WRONGPASS" "(error) WRONGPASS invalid username-password pair"
assert_no  "OK" "OK"
assert_no  "integer 0" "(integer) 0"
assert_no  "integer 2" "(integer) 2"
assert_no  "PONG" "PONG"

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
