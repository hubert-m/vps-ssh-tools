#!/usr/bin/env bash
# Testy walidacji linii klucza SSH (hm_access_is_valid_ssh_key_line) — bez root/useradd
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# minimalne stuby + source ssh.sh
hm_err() { echo "ERR: $*" >&2; }
hm_ok() { :; }
hm_info() { :; }
hm_warn() { :; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }

# shellcheck disable=SC1091
source "${ROOT}/commands/access/ssh.sh"

fail=0
assert_ok() {
  local label="$1" line="$2"
  if hm_access_is_valid_ssh_key_line "${line}"; then
    echo "OK   valid: ${label}"
  else
    echo "FAIL expected valid: ${label}"
    fail=1
  fi
}
assert_bad() {
  local label="$1" line="$2"
  if hm_access_is_valid_ssh_key_line "${line}"; then
    echo "FAIL expected invalid: ${label}"
    fail=1
  else
    echo "OK   invalid: ${label}"
  fi
}

assert_ok "ed25519" "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJustAFakeKeyForUnitTest comment"
assert_ok "rsa" "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC7fakeKeyMaterialHere== user@host"
assert_ok "ecdsa" "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTY= note"
assert_bad "empty" ""
assert_bad "comment-only" "# ssh-ed25519 AAAA comment"
assert_bad "no-type" "AAAAIJustAFakeKeyForUnitTest"
assert_bad "garbage" "not-a-key at all"

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
