#!/usr/bin/env bash
# status, log i who nie wypisują klucza.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1
export LANG=C
export LOG_CAPTURE_OUTPUT=1

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
export HM_OVPN_APPLOG="${root}/applog"
export HM_OVPN_STATUS="${root}/status.log"
export HM_OVPN_MGMT_LOG="${root}/mgmt.log"
mkdir -p "${HM_OVPN_ETC}" "${HM_OVPN_PKI}/private"
# shellcheck disable=SC1091
source commands/openvpn/main.sh

printf 'ENDPOINT=vpn.test\n' > "$(hm_ovpn_state_file)"
printf '%s\n' '-----BEGIN PRIVATE KEY-----' 'SECRET-OVPN-KEY' '-----END PRIVATE KEY-----' 'kick laptop' > "${HM_OVPN_APPLOG}"
printf 'CLIENT_LIST,laptop,10.8.0.2,\n' > "${HM_OVPN_STATUS}"
out="$(cmd_openvpn status; cmd_openvpn log; cmd_openvpn who)"
printf '%s\n' "${out}" | grep -q 'SECRET-OVPN-KEY' && bad leak || ok noleak
printf '%s\n' "${out}" | grep -q 'kick laptop' && ok log-plain || bad log-plain
printf '%s\n' "${out}" | grep -qx 'laptop' && ok who || bad who
cmd_openvpn kick laptop >/dev/null
grep -q 'kill laptop' "${HM_OVPN_MGMT_LOG}" && ok kick || bad kick
grep -q 'SECRET-OVPN-KEY' "${HM_OVPN_MGMT_LOG}" && bad kick-leak || ok kick-noleak

: > "${HM_OVPN_APPLOG}"
export HM_OVPN_CALL_LOG="${root}/calls.log"
: > "${HM_OVPN_CALL_LOG}"
printf 'port 1194\nproto udp\n' > "$(hm_ovpn_conf_file)"
out="$(cmd_openvpn status; cmd_openvpn doctor; cmd_openvpn config show; cmd_openvpn audit; cmd_openvpn fail2ban status; cmd_openvpn log)"
printf '%s\n' "${out}" | grep -q 'PRIVATE KEY' && bad cmds-private || ok cmds-private
printf '%s\n' "${out}" | grep -q 'OpenVPN Static key' && bad cmds-static || ok cmds-static
grep -q 'PRIVATE KEY' "${HM_OVPN_APPLOG}" && bad applog-private || ok applog-private
grep -q 'OpenVPN Static key' "${HM_OVPN_APPLOG}" && bad applog-static || ok applog-static
grep -q 'PASSWORD-TEST' "${HM_OVPN_CALL_LOG}" && bad argv-pass || ok argv-pass

[[ "${fail}" -eq 0 ]] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
