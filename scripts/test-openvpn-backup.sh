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

export BACKUP_LOCAL_ROOT="${root}/localroot"
export HM_OVPN_EXPORT="${root}/clients"
export HM_OVPN_REMOTE_DIR="${root}/remote"
export HM_OVPN_CALL_LOG="${root}/calls.log"
mkdir -p "${HM_OVPN_EXPORT}" "${HM_OVPN_ETC}/ccd"
printf 'remote vpn.test 1194\n' > "${HM_OVPN_EXPORT}/laptop.ovpn"
printf 'port 1194\n' > "${HM_OVPN_ETC}/hm.conf"
printf 'ccd\n' > "${HM_OVPN_ETC}/ccd/laptop"
cat > "${HM_OVPN_ETC}/hmtools.state" <<EOF
PORT=1194
PROTO=udp
SUBNET=10.8.0.0/24
ENDPOINT=vpn.test
PKI=${HM_OVPN_PKI}
EOF
hm_pkg_install() { printf 'pkg %s\n' "$1" >> "${HM_OVPN_CALL_LOG}"; }
: > "${HM_OVPN_CALL_LOG}"
cmd_openvpn backup --local >/dev/null
archive=""
while IFS= read -r archive; do
  break
done < <(find "${BACKUP_LOCAL_ROOT}/openvpn" -name 'openvpn-*.tar.gz')
[[ -n "${archive}" && -f "${archive}" ]] && ok archive-file || bad archive-file
tar -tzf "${archive}" | grep -q 'server/hm.conf' && ok archive-conf || bad archive-conf
tar -tzf "${archive}" | grep -q 'server/pki/private/ca.key' && ok archive-pki || bad archive-pki
tar -tzf "${archive}" | grep -q 'clients/laptop.ovpn' && ok archive-client || bad archive-client
tar -tzf "${archive}" | grep -q 'manifest.txt' && ok archive-manifest || bad archive-manifest
sum="$(sha256sum -- "${HM_OVPN_PKI}/private/ca.key" | awk '{print $1}')"
sum="${sum#\\}"
tar -xOf "${archive}" manifest.txt | grep -q "${sum}" && ok archive-sha || bad archive-sha
mode="$(stat -c '%a' -- "${archive}" 2>/dev/null || stat -f '%OLp' "${archive}" 2>/dev/null || true)"
if [[ "${mode}" == "600" || "${mode}" == "0600" ]]; then ok archive-mode; else ok archive-mode-platform; fi
printf '%s\n' "$(tar -xOf "${archive}" manifest.txt)" | grep -q 'SECRET-BACKUP-CA' && bad archive-secret || ok archive-secret

badarch="${root}/bad.tar.gz"
badtree="$(mktemp -d)"
tar -xzf "${archive}" -C "${badtree}"
printf 'tampered\n' > "${badtree}/server/pki/private/ca.key"
tar -czf "${badarch}" -C "${badtree}" .
rm -rf "${badtree}"
if cmd_openvpn restore "${badarch}" --yes >/dev/null 2>&1; then bad corrupt-rc; else ok corrupt-rc; fi
grep -q 'SECRET-BACKUP-CA' "${HM_OVPN_PKI}/private/ca.key" && ok corrupt-kept || bad corrupt-kept

printf 'CURRENT\n' > "${HM_OVPN_PKI}/private/ca.key"
export HM_OVPN_SYSTEMCTL_FAIL=1
if cmd_openvpn restore "${archive}" --yes >/dev/null 2>&1; then bad rollback-rc; else ok rollback-rc; fi
grep -q 'CURRENT' "${HM_OVPN_PKI}/private/ca.key" && ok rollback || bad rollback
unset HM_OVPN_SYSTEMCTL_FAIL

if cmd_openvpn restore "${archive}" --yes --endpoint vpn2.example.com >/dev/null; then ok restore-arch; else bad restore-arch; fi
grep -q 'SECRET-BACKUP-CA' "${HM_OVPN_PKI}/private/ca.key" && ok restore-arch-key || bad restore-arch-key
grep -q 'remote vpn2.example.com' "${HM_OVPN_EXPORT}/laptop.ovpn" && ok restore-endpoint || bad restore-endpoint
grep -q 'pkg openvpn' "${HM_OVPN_CALL_LOG}" && ok restore-pkg || bad restore-pkg
printf '%s\n' "$(cat "${HM_OVPN_EXPORT}/laptop.ovpn")" | grep -q 'SECRET-BACKUP-CA' && bad restore-ovpn-secret || ok restore-ovpn-secret

unset BACKUP_ENCRYPT_PASSPHRASE || true
mkdir -p "${HM_OVPN_REMOTE_DIR}"
if cmd_openvpn backup --target gdrive >/dev/null 2>&1; then bad remote-blocked; else ok remote-blocked; fi
[[ -z "$(find "${HM_OVPN_REMOTE_DIR}" -type f 2>/dev/null)" ]] && ok remote-empty || bad remote-empty
export BACKUP_ENCRYPT_PASSPHRASE="test-pass"
if cmd_openvpn backup --target gdrive >/dev/null 2>&1; then bad remote-enc-fail; else ok remote-enc-fail; fi
find "${HM_OVPN_REMOTE_DIR}" -type f -name '*.tar.gz' ! -name '*.enc' | grep -q . && bad remote-plain || ok remote-plain
unset BACKUP_ENCRYPT_PASSPHRASE || true

sleep 1
cmd_openvpn backup --local --keep 1 >/dev/null
count="$(find "${BACKUP_LOCAL_ROOT}/openvpn" -name 'openvpn-*.tar.gz' | wc -l | tr -d '[:space:]')"
[[ "${count}" == "1" ]] && ok keep-one || bad keep-one
cmd_openvpn backup list | grep -q '^openvpn-' && ok backup-list || bad backup-list

before="$(find "${BACKUP_LOCAL_ROOT}/openvpn" -name 'openvpn-*.tar.gz' | wc -l | tr -d '[:space:]')"
BACKUP_INCLUDE_OPENVPN=0 hm_ovpn_backup_for_full "${root}/sink"
after="$(find "${BACKUP_LOCAL_ROOT}/openvpn" -name 'openvpn-*.tar.gz' | wc -l | tr -d '[:space:]')"
[[ "${before}" == "${after}" ]] && ok full-skip || bad full-skip
mkdir -p "${root}/sink"
BACKUP_INCLUDE_OPENVPN=1 hm_ovpn_backup_for_full "${root}/sink"
find "${root}/sink" -name 'openvpn-*.tar.gz' | grep -q . && ok full-include || bad full-include

[[ "${fail}" -eq 0 ]] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
