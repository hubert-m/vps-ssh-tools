#!/usr/bin/env bash
# Kopia PKI nie trafia do applog.
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
export HM_OVPN_ROOT="${root}/ovpn"
export HM_OVPN_ETC="${root}/ovpn/server"
export HM_OVPN_PKI="${root}/pki"
export HM_OVPN_APPLOG="${root}/applog"
export HM_OVPN_BACKUP_DIR="${root}/backups"
mkdir -p "${HM_OVPN_PKI}/private" "${HM_OVPN_ETC}"
printf 'SECRET-BACKUP-CA\n' > "${HM_OVPN_PKI}/private/ca.key"
# shellcheck disable=SC1091
source commands/openvpn/main.sh

out="$(cmd_openvpn backup "${root}/backups/one")"
[[ -f "${root}/backups/one/private/ca.key" ]] && ok backup-file || bad backup-file
printf '%s\n' "${out}" | grep -q 'SECRET-BACKUP-CA' && bad backup-out || ok backup-out
[[ -f "${HM_OVPN_APPLOG}" ]] && grep -q 'SECRET-BACKUP-CA' "${HM_OVPN_APPLOG}" && bad backup-log || ok backup-log
if cmd_openvpn restore "${root}/backups/one"; then bad restore-yes; else ok restore-yes; fi
printf 'gone\n' > "${HM_OVPN_PKI}/private/ca.key"
cmd_openvpn restore "${root}/backups/one" --yes >/dev/null
grep -q 'SECRET-BACKUP-CA' "${HM_OVPN_PKI}/private/ca.key" && ok restore || bad restore
if cmd_openvpn backup "${root}/../escape"; then bad backup-dotdot; else ok backup-dotdot; fi

[[ "${fail}" -eq 0 ]] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
