#!/usr/bin/env bash
# openvpn audit, fail2ban i rotacja CA — bez sieci i bez prawdziwego OpenVPN.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1
export LOG_CAPTURE_OUTPUT=1

# shellcheck disable=SC1091
source lib/common/ui.sh
hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_have_cmd() { return 1; }
hm_confirm_plan() {
  [[ "$*" == *"--yes"* ]] || return 1
  return 0
}
hm_confirm_plan_critical() { return 1; }
hm_pkg_install() { :; }
_hm_cmd_help() { :; }
_hm_cmd_register() { :; }

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

# shellcheck disable=SC1091
source commands/openvpn/main.sh

root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
export HM_OVPN_ETC="${root}/server"
export HM_OVPN_PKI="${root}/pki"
export HM_OVPN_EXPORT="${root}/no-clients"
export HM_OVPN_APPLOG="${root}/applog"
export HM_OVPN_BACKUP_DIR="${root}/backups"
export HM_OVPN_F2B_JAIL="${root}/jail.conf"
export HM_OVPN_F2B_FILTER="${root}/filter.conf"
export HM_OVPN_CALL_LOG="${root}/calls.log"
export HM_OVPN_MOCK=1
export HM_OVPN_MOCK_LOG="${root}/mock.log"
mkdir -p "${HM_OVPN_ETC}"
: > "${HM_OVPN_CALL_LOG}"
: > "${HM_OVPN_MOCK_LOG}"

sed "s|/etc/openvpn/server|${root}/missing|g" "${HMTOOLS_ROOT}/scripts/fixtures/openvpn/hm.conf" > "$(hm_ovpn_conf_file)"
out="$(hm_ovpn_security_audit)"
printf '%s\n' "${out}" | grep -q '^BŁĄD:' && bad good-clean || ok good-clean
snap="$(mktemp)"
cp -f "$(hm_ovpn_conf_file)" "${snap}"
hm_ovpn_security_audit >/dev/null
cmp -s "$(hm_ovpn_conf_file)" "${snap}" && ok audit-readonly || bad audit-readonly

key="${root}/tls.key"
printf 'not-a-secret-mode\n' > "${key}"
chmod 0644 "${key}" || true
mode="$(stat -c '%a' -- "${key}" 2>/dev/null || stat -f '%OLp' "${key}" 2>/dev/null || true)"
cat > "$(hm_ovpn_conf_file)" <<EOF
port 1194
proto udp
cipher BF-CBC
comp-lzo
tls-version-min 1.2
auth SHA256
tls-crypt ${key}
user nobody
group nogroup
crl-verify ${root}/missing/crl.pem
management /run/openvpn-server/hm.sock unix
EOF
out="$(hm_ovpn_security_audit)"
printf '%s\n' "${out}" | grep -q 'comp-lzo' && ok bad-compress || bad bad-compress
printf '%s\n' "${out}" | grep -q 'słaby cipher' && ok bad-cipher || bad bad-cipher
if [[ "${mode}" == "644" || "${mode}" == "0644" ]]; then
  printf '%s\n' "${out}" | grep -q 'chmod 0600' && ok bad-mode || bad bad-mode
else
  ok bad-mode-platform
fi

cat > "$(hm_ovpn_conf_file)" <<EOF
port 1194
comp-lzo
cipher BF-CBC
auth SHA256
tls-crypt ${key}
user nobody
group nogroup
crl-verify ${root}/missing/crl.pem
management /run/openvpn-server/hm.sock unix
EOF
cp -f "$(hm_ovpn_conf_file)" "${snap}"
if hm_ovpn_security_audit --fix >/dev/null 2>&1; then bad fix-noyes; else ok fix-noyes; fi
cmp -s "$(hm_ovpn_conf_file)" "${snap}" && ok fix-noyes-file || bad fix-noyes-file
hm_ovpn_security_audit --fix --yes >/dev/null
grep -q 'comp-lzo' "$(hm_ovpn_conf_file)" && bad fix-compress || ok fix-compress
grep -q '^tls-version-min 1.2$' "$(hm_ovpn_conf_file)" && ok fix-tls || bad fix-tls
grep -q 'BF-CBC' "$(hm_ovpn_conf_file)" && ok fix-keeps-cipher || bad fix-keeps-cipher
[[ -f "$(hm_ovpn_conf_file).bak-hmtools" ]] && ok fix-backup || bad fix-backup

export HM_OVPN_SSH_IP=203.0.113.5
hm_ovpn_fail2ban on >/dev/null
grep -q '203.0.113.5' "${HM_OVPN_F2B_JAIL}" && ok f2b-ignore || bad f2b-ignore
grep -q 'TLS Error: TLS handshake failed' "${HM_OVPN_F2B_FILTER}" && ok f2b-filter || bad f2b-filter
grep -q 'AUTH_FAILED' "${HM_OVPN_F2B_FILTER}" && ok f2b-auth || bad f2b-auth
sample="${root}/sample.log"
printf '%s\n' 'noise' 'TLS Error: TLS handshake failed' 'AUTH_FAILED' > "${sample}"
out="$(HM_OVPN_F2B_SAMPLE="${sample}" hm_ovpn_fail2ban status)"
printf '%s\n' "${out}" | grep -q 'fail2ban: on' && ok f2b-on || bad f2b-on
printf '%s\n' "${out}" | grep -q 'dopasowania: 2' && ok f2b-match || bad f2b-match
hm_ovpn_fail2ban off >/dev/null
out="$(hm_ovpn_fail2ban status)"
printf '%s\n' "${out}" | grep -q 'fail2ban: off' && ok f2b-off || bad f2b-off

mkdir -p "${HM_OVPN_PKI}/private"
printf 'SECRET-CA-KEY\n' > "${HM_OVPN_PKI}/private/ca.key"
printf 'OLD-CA\n' > "${HM_OVPN_PKI}/ca.crt"
printf 'V\t/CN=laptop/\n' > "${HM_OVPN_PKI}/index.txt"
printf 'port 1194\nca placeholder\n' > "$(hm_ovpn_conf_file)"
if hm_ovpn_ca rotate >/dev/null 2>&1; then bad ca-noyes; else ok ca-noyes; fi
[[ ! -f "${HM_OVPN_ETC}/ca-bundle.crt" ]] && ok ca-noyes-file || bad ca-noyes-file
out="$(hm_ovpn_ca rotate --yes)"
grep -q 'OLD-CA' "${HM_OVPN_ETC}/ca-bundle.crt" && ok ca-old || bad ca-old
grep -q 'NEW-CA' "${HM_OVPN_ETC}/ca-bundle.crt" && ok ca-new || bad ca-new
grep -q 'ca-bundle.crt' "$(hm_ovpn_conf_file)" && ok ca-conf || bad ca-conf
grep -q 'build-client-full laptop' "${HM_OVPN_CALL_LOG}" && ok ca-client || bad ca-client
printf '%s\n' "${out}" | grep -q 'SECRET-CA-KEY' && bad ca-leak || ok ca-leak
[[ -f "$(hm_ovpn_ca_pending)" ]] && ok ca-pending || bad ca-pending
out="$(hm_ovpn_ca rotate finish --yes)"
grep -q 'OLD-CA' "${HM_OVPN_ETC}/ca-bundle.crt" && bad ca-finished-old || ok ca-finished-old
grep -q 'NEW-CA' "${HM_OVPN_ETC}/ca-bundle.crt" && ok ca-finished-new || bad ca-finished-new
[[ ! -f "$(hm_ovpn_ca_pending)" ]] && ok ca-pending-gone || bad ca-pending-gone
printf '%s\n' "${out}" | grep -q 'SECRET-CA-KEY' && bad ca-finish-leak || ok ca-finish-leak

if [[ "${fail}" -eq 0 ]]; then
  echo "ALL PASSED"
else
  echo "FAILED" >&2
  exit 1
fi
