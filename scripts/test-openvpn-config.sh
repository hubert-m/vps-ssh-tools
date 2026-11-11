#!/usr/bin/env bash
# openvpn config show/set — tylko klucze stanu, bez sekretu.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1
export LANG=C

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_have_cmd() { return 1; }
hm_confirm_plan() { return 0; }
_hm_cmd_help() { :; }
_hm_cmd_register() { :; }

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
export HM_OVPN_ETC="${root}/server"
export HM_OVPN_PKI="${root}/pki"
mkdir -p "${HM_OVPN_ETC}" "${HM_OVPN_PKI}"
# shellcheck disable=SC1091
source commands/openvpn/main.sh

printf 'ENDPOINT=vpn.test\nPORT=1194\nTOKEN=SECRET-CONFIG\n' > "$(hm_ovpn_state_file)"
show="$(cmd_openvpn config show)"
printf '%s\n' "${show}" | grep -q 'ENDPOINT=vpn.test' && ok show-ep || bad show-ep
printf '%s\n' "${show}" | grep -q 'SECRET-CONFIG' && bad show-secret || ok show-secret
cmd_openvpn config set DNS 9.9.9.9 >/dev/null
grep -q '^DNS=9.9.9.9$' "$(hm_ovpn_state_file)" && ok set-dns || bad set-dns
if cmd_openvpn config set TOKEN abc; then bad set-deny; else ok set-deny; fi
if cmd_openvpn config set PORT '1;rm'; then bad set-meta; else ok set-meta; fi

[[ "${fail}" -eq 0 ]] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
