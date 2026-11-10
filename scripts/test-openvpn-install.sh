#!/usr/bin/env bash
# openvpn install — tun, obca konfiguracja, dry-run, hm.conf, NAT, idempotencja.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1
export OS_FAMILY=debian

# shellcheck disable=SC1091
source lib/common/ui.sh
hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_have_cmd() { return 1; }
hm_confirm_plan() { return 0; }
hm_confirm_plan_critical() { return 0; }
hm_pkg_install() { printf 'pkg %s\n' "$1" >> "${HM_OVPN_CALL_LOG}"; }
_hm_cmd_help() { :; }
_hm_cmd_register() { :; }

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
mkdir -p "${root}/bin"
cat > "${root}/bin/easyrsa" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${root}/bin/easyrsa" || true
export PATH="${root}/bin:${PATH}"

# shellcheck disable=SC1091
source commands/openvpn/main.sh

hm_ovpn_render_conf /etc/openvpn/server 1194 udp 10.8.0.0/24 nogroup 2.6.0 > "${root}/hm.conf"
diff -u "${HMTOOLS_ROOT}/scripts/fixtures/openvpn/hm.conf" "${root}/hm.conf" && ok golden || bad golden
grep -q 'tls-crypt' "${root}/hm.conf" && grep -q 'tls-version-min 1.2' "${root}/hm.conf" && grep -q 'AES-256-GCM' "${root}/hm.conf" && ok conf-ciphers || bad conf-ciphers
grep -Eq 'compress|comp-lzo' "${root}/hm.conf" && bad conf-compress || ok conf-nocompress
OS_FAMILY=rhel hm_ovpn_packages | grep -q epel-release && ok pkg-rhel || bad pkg-rhel
OS_FAMILY=debian hm_ovpn_packages | grep -q '^openvpn$' && ok pkg-debian || bad pkg-debian

export HM_OVPN_CALL_LOG="${root}/calls.log"
export HM_OVPN_APPLOG="${root}/applog"
export HM_OVPN_OS_OK=0
: > "${HM_OVPN_CALL_LOG}"
if cmd_openvpn install --yes >"${root}/os.out" 2>"${root}/os.err"; then bad os-rc; else ok os-rc; fi
[[ ! -s "${HM_OVPN_CALL_LOG}" ]] && ok os-nopkg || bad os-nopkg
grep -q 'Nieobsługiwany system' "${root}/os.err" && ok os-msg || bad os-msg
export HM_OVPN_OS_OK=1

export HM_OVPN_TUN="${root}/no-tun"
if cmd_openvpn install --yes >"${root}/tun.out" 2>"${root}/tun.err"; then bad tun-rc; else ok tun-rc; fi
[[ ! -s "${HM_OVPN_CALL_LOG}" ]] && ok tun-nopkg || bad tun-nopkg
grep -q '/dev/net/tun' "${root}/tun.err" && ok tun-msg || bad tun-msg
: > "${HM_OVPN_TUN}"

export HM_OVPN_ETC="${root}/etc"
export HM_OVPN_UFW_RULES="${root}/ufw/before.rules"
export HM_OVPN_SYSCTL_D="${root}/sysctl.d"
export HM_OVPN_FW=ufw
export HM_OVPN_SS_FILE="${root}/ss.txt"
printf 'udp 0.0.0.0:1194 \n' > "${HM_OVPN_SS_FILE}"
if cmd_openvpn install --yes --port 1194 >"${root}/port.out" 2>"${root}/port.err"; then bad port-rc; else ok port-rc; fi
[[ ! -f "${HM_OVPN_ETC}/hm.conf" ]] && ok port-nofile || bad port-nofile
: > "${HM_OVPN_SS_FILE}"

mkdir -p "${HM_OVPN_ETC}"
printf 'port 1194\n' > "${HM_OVPN_ETC}/foreign.conf"
if cmd_openvpn install --yes >"${root}/foreign.out" 2>"${root}/foreign.err"; then bad foreign-rc; else ok foreign-rc; fi
[[ -f "${HM_OVPN_ETC}/foreign.conf" && ! -f "${HM_OVPN_ETC}/hm.conf" ]] && ok foreign-kept || bad foreign-kept
rm -f "${HM_OVPN_ETC}/foreign.conf"

printf 'sentinel\n' > "${HM_OVPN_ETC}/sentinel"
snap="$(find "${HM_OVPN_ETC}" -type f -exec sha256sum {} \; | sort)"
cmd_openvpn install --dry-run --yes >"${root}/dry.out"
[[ "$(find "${HM_OVPN_ETC}" -type f -exec sha256sum {} \; | sort)" == "${snap}" ]] && ok dry-snap || bad dry-snap
grep -q 'dry-run: brak zmian' "${root}/dry.out" && ok dry-msg || bad dry-msg
rm -f "${HM_OVPN_ETC}/sentinel"

: > "${HM_OVPN_CALL_LOG}"
cmd_openvpn install --yes --port 1194 --proto udp --dns quad9 --endpoint vpn.example --subnet 10.8.0.0/24 --first-client laptop >"${root}/inst.out"
grep -q 'pkg openvpn' "${HM_OVPN_CALL_LOG}" && grep -q 'pkg easy-rsa' "${HM_OVPN_CALL_LOG}" && ok inst-pkg || bad inst-pkg
grep -q 'easyrsa init-pki' "${HM_OVPN_CALL_LOG}" && ok inst-pki || bad inst-pki
grep -q 'systemctl enable --now openvpn-server@hm' "${HM_OVPN_CALL_LOG}" && ok inst-unit || bad inst-unit
grep -q 'easyrsa build-client-full laptop' "${HM_OVPN_CALL_LOG}" && ok inst-client || bad inst-client
grep -q 'tls-crypt' "${HM_OVPN_ETC}/hm.conf" && grep -q 'AES-256-GCM' "${HM_OVPN_ETC}/hm.conf" && ok inst-conf || bad inst-conf
grep -Eq 'compress|comp-lzo' "${HM_OVPN_ETC}/hm.conf" && bad inst-compress || ok inst-nocompress
grep -q 'BEGIN hmtools-openvpn' "${HM_OVPN_UFW_RULES}" && ok nat-marker || bad nat-marker
grep -Eq 'dport 22|deny.*22|delete.*22' "${HM_OVPN_UFW_RULES}" "${HM_OVPN_ETC}/hm.conf" && bad ssh-touch || ok ssh-safe
second="$(cmd_openvpn install --yes --port 1194 --proto udp --subnet 10.8.0.0/24)"
printf '%s\n' "${second}" | grep -q 'bez zmian' && ok idempotent || bad idempotent
[[ "$(grep -c 'BEGIN hmtools-openvpn' "${HM_OVPN_UFW_RULES}")" -eq 1 ]] && ok nat-once || bad nat-once

[[ "${fail}" -eq 0 ]] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
