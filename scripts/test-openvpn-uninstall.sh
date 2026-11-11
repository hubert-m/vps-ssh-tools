#!/usr/bin/env bash
# openvpn uninstall — kopia PKI, markery, ip_forward, SSH zostaje.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1

# shellcheck disable=SC1091
source lib/common/ui.sh
hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_have_cmd() { return 1; }
hm_confirm_plan() { return 0; }
hm_confirm_plan_critical() {
  [[ "$1" == "OPENVPN" ]] || return 1
  [[ "$*" == *"--yes"* ]] || return 1
  return 0
}
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

seed() {
  export HM_OVPN_ETC="${root}/server"
  export HM_OVPN_PKI="${root}/server/hm/pki"
  export HM_OVPN_ROOT="${root}/ovpn"
  export HM_OVPN_UFW_RULES="${root}/before.rules"
  export HM_OVPN_CSF_POST="${root}/csfpost.sh"
  export HM_OVPN_SYSCTL_D="${root}/sysctl.d"
  export HM_OVPN_CRON="${root}/cron/hmtools-openvpn"
  export HM_OVPN_F2B_JAIL="${root}/jail.d/hmtools-openvpn.conf"
  export HM_OVPN_NAT_UNIT="${root}/hmtools-openvpn-nat.service"
  export HM_OVPN_EXPORT="${root}/clients"
  export HM_OVPN_BACKUP_DIR="${root}/backups"
  export HM_OVPN_FORWARD_STATE="${root}/forward"
  export HM_OVPN_CALL_LOG="${root}/calls.log"
  mkdir -p "${HM_OVPN_PKI}/private" "${HM_OVPN_ETC}/ccd" "${root}/cron" "${root}/jail.d" "${HM_OVPN_EXPORT}" "${HM_OVPN_SYSCTL_D}"
  printf 'SECRET-UNINSTALL-CA\n' > "${HM_OVPN_PKI}/private/ca.key"
  printf 'vpn\n' > "${HM_OVPN_EXPORT}/laptop.ovpn"
  printf 'net.ipv4.ip_forward=1\n' > "${HM_OVPN_SYSCTL_D}/99-hmtools-openvpn.conf"
  printf 'server 10.8.0.0 255.255.255.0\n' > "${HM_OVPN_ETC}/hm.conf"
  cat > "${HM_OVPN_ETC}/hmtools.state" <<EOF
PORT=1194
PROTO=udp
SUBNET=10.8.0.0/24
ENDPOINT=vpn.test
PKI=${HM_OVPN_PKI}
PREV_FORWARD=1
FW=ufw
PACKAGES=yes
EOF
  printf '1\n' > "${HM_OVPN_FORWARD_STATE}"
  cat > "${HM_OVPN_UFW_RULES}" <<'EOF'
-A ufw-before-input -p tcp --dport 22 -j ACCEPT
# BEGIN hmtools-openvpn
-A POSTROUTING -s 10.8.0.0/24 -o eth0 -j MASQUERADE
# END hmtools-openvpn
EOF
  printf '# cudzy cron\n' > "${root}/cron/other"
  printf '# hmtools-openvpn\n0 3 * * * root hmtools openvpn check\n' > "${HM_OVPN_CRON}"
  printf '[hmtools-openvpn]\n' > "${HM_OVPN_F2B_JAIL}"
  printf 'nat\n' > "${HM_OVPN_NAT_UNIT}"
  : > "${HM_OVPN_CALL_LOG}"
}

seed
if hm_ovpn_uninstall >/dev/null 2>&1; then bad noyes-rc; else ok noyes-rc; fi
[[ -f "${HM_OVPN_PKI}/private/ca.key" ]] && ok noyes-kept || bad noyes-kept
grep -q 'MASQUERADE' "${HM_OVPN_UFW_RULES}" && ok noyes-nat || bad noyes-nat

hm_ovpn_uninstall --dry-run >/dev/null
[[ -f "${HM_OVPN_ETC}/hm.conf" ]] && ok dry-kept || bad dry-kept
[[ ! -d "${root}/backups" || -z "$(find "${root}/backups" -type f 2>/dev/null)" ]] && ok dry-nobackup || bad dry-nobackup

out="$(hm_ovpn_uninstall --yes --purge-packages)"
find "${root}/backups" -type f -name ca.key | grep -q . && ok backup-before || bad backup-before
grep -q 'SECRET-UNINSTALL-CA' "${root}/backups/"*/private/ca.key && ok backup-secret || bad backup-secret
printf '%s' "${out}" | grep -q 'SECRET-UNINSTALL-CA' && bad backup-out || ok backup-out
[[ ! -d "${HM_OVPN_PKI}" ]] && ok pki-gone || bad pki-gone
[[ ! -f "${HM_OVPN_ETC}/hm.conf" && ! -f "${HM_OVPN_ETC}/hmtools.state" ]] && ok manifest-gone || bad manifest-gone
[[ ! -f "${HM_OVPN_SYSCTL_D}/99-hmtools-openvpn.conf" ]] && ok sysctl-gone || bad sysctl-gone
[[ "$(tr -d '\r\n' < "${HM_OVPN_FORWARD_STATE}")" == "1" ]] && ok forward-restored || bad forward-restored
grep -q 'dport 22' "${HM_OVPN_UFW_RULES}" && ok ssh-kept || bad ssh-kept
grep -q 'MASQUERADE' "${HM_OVPN_UFW_RULES}" && bad nat-gone || ok nat-gone
grep -q 'BEGIN hmtools-openvpn' "${HM_OVPN_UFW_RULES}" && bad marker-gone || ok marker-gone
[[ ! -f "${HM_OVPN_CRON}" && -f "${root}/cron/other" ]] && ok cron || bad cron
[[ ! -f "${HM_OVPN_F2B_JAIL}" && ! -f "${HM_OVPN_NAT_UNIT}" ]] && ok jail-nat || bad jail-nat
[[ ! -d "${HM_OVPN_EXPORT}" ]] && ok profiles-gone || bad profiles-gone
grep -q 'pkg remove openvpn' "${HM_OVPN_CALL_LOG}" && ok purge || bad purge
printf '%s' "${out}" | grep -q '^kopia: ' && ok report-copy || bad report-copy

if hm_ovpn_uninstall --yes >/dev/null 2>&1; then bad nomanifest; else ok nomanifest; fi
grep -q 'dport 22' "${HM_OVPN_UFW_RULES}" && ok nomanifest-ssh || bad nomanifest-ssh

printf 'server 10.8.0.0 255.255.255.0\n' > "${HM_OVPN_ETC}/foreign.conf"
cat > "${HM_OVPN_UFW_RULES}" <<'EOF'
-A ufw-before-input -p tcp --dport 22 -j ACCEPT
# BEGIN hmtools-openvpn
-A POSTROUTING -s 10.8.0.0/24 -o eth0 -j MASQUERADE
# END hmtools-openvpn
EOF
mkdir -p "${HM_OVPN_PKI}/private"
printf 'SECRET-UNINSTALL-CA\n' > "${HM_OVPN_PKI}/private/ca.key"
hm_ovpn_uninstall --force --yes --no-backup >/dev/null
[[ -f "${HM_OVPN_ETC}/foreign.conf" ]] && ok force-foreign || bad force-foreign
grep -q 'MASQUERADE' "${HM_OVPN_UFW_RULES}" && bad force-marker || ok force-marker
[[ -f "${HM_OVPN_PKI}/private/ca.key" ]] && ok force-keeps-pki || bad force-keeps-pki

seed
hm_ovpn_uninstall --yes --keep-pki --keep-profiles >/dev/null
[[ -f "${HM_OVPN_PKI}/private/ca.key" ]] && ok keep-pki || bad keep-pki
[[ -f "${HM_OVPN_EXPORT}/laptop.ovpn" ]] && ok keep-profiles || bad keep-profiles
[[ ! -f "${HM_OVPN_ETC}/hm.conf" ]] && ok keep-conf-gone || bad keep-conf-gone

if [[ "${fail}" -eq 0 ]]; then
  echo "ALL PASSED"
else
  echo "FAILED" >&2
  exit 1
fi
