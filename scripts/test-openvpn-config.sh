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

printf 'PROTO=udp\nSUBNET=10.8.0.0/24\n' >> "$(hm_ovpn_state_file)"
export HM_OVPN_FW_LOG="${root}/fw.log"
: > "${HM_OVPN_FW_LOG}"
cmd_openvpn config set mode full >/dev/null
grep -Fxf "${HMTOOLS_ROOT}/scripts/fixtures/openvpn/config-full.txt" "$(hm_ovpn_conf_file)" && ok mode-full || bad mode-full
cmd_openvpn config set mode split >/dev/null
cmd_openvpn route add 10.10.0.0/16 >/dev/null
grep -Fxf "${HMTOOLS_ROOT}/scripts/fixtures/openvpn/config-split.txt" "$(hm_ovpn_conf_file)" && ok mode-split || bad mode-split
grep -q 'redirect-gateway' "$(hm_ovpn_conf_file)" && bad split-noredirect || ok split-noredirect
cmd_openvpn config set ipv6 on >/dev/null
grep -Fxf "${HMTOOLS_ROOT}/scripts/fixtures/openvpn/config-ipv6.txt" "$(hm_ovpn_conf_file)" && ok ipv6-on || bad ipv6-on
cmd_openvpn config set ipv6 off >/dev/null
grep -q 'server-ipv6' "$(hm_ovpn_conf_file)" && bad ipv6-off || ok ipv6-off

snap="$(mktemp)"
cp -f "$(hm_ovpn_state_file)" "${snap}"
cmd_openvpn config set port 51194 --dry-run >/dev/null
cmp -s "$(hm_ovpn_state_file)" "${snap}" && ok dry-run || bad dry-run
if cmd_openvpn config set port 70000 >/dev/null 2>&1; then bad port-range; else ok port-range; fi
cmp -s "$(hm_ovpn_state_file)" "${snap}" && ok port-range-kept || bad port-range-kept
printf ':443 \n' > "${root}/ss"
export HM_OVPN_SS_FILE="${root}/ss"
if cmd_openvpn config set port 443 >/dev/null 2>&1; then bad port-busy; else ok port-busy; fi
unset HM_OVPN_SS_FILE
printf '10.9.0.0\n' > "${root}/routes"
export HM_OVPN_ROUTES="${root}/routes"
if cmd_openvpn config set subnet 10.9.0.0/24 >/dev/null 2>&1; then bad subnet-clash; else ok subnet-clash; fi
unset HM_OVPN_ROUTES

export HM_OVPN_ACTIVE=failed
if cmd_openvpn config set port 443 >/dev/null 2>&1; then bad rollback-rc; else ok rollback-rc; fi
grep -q '^PORT=1194$' "$(hm_ovpn_state_file)" && ok rollback-state || bad rollback-state
grep -q '^port 1194$' "$(hm_ovpn_conf_file)" && ok rollback-conf || bad rollback-conf
grep -q 'remove 443/' "${HM_OVPN_FW_LOG}" && ok rollback-fw || bad rollback-fw
grep -q 'remove 1194/' "${HM_OVPN_FW_LOG}" && bad rollback-old || ok rollback-old
unset HM_OVPN_ACTIVE
: > "${HM_OVPN_FW_LOG}"
cmd_openvpn config set port 443 >/dev/null
grep -q '^PORT=443$' "$(hm_ovpn_state_file)" && ok port-set || bad port-set
grep -q 'allow 443/udp' "${HM_OVPN_FW_LOG}" && ok fw-allow || bad fw-allow
grep -q 'remove 1194/udp' "${HM_OVPN_FW_LOG}" && ok fw-close-old || bad fw-close-old
cmd_openvpn config set port 1194 >/dev/null

cmd_openvpn client ip laptop 10.8.0.50 >/dev/null
diff -u "${HMTOOLS_ROOT}/scripts/fixtures/openvpn/ccd-laptop" "$(hm_ovpn_etc)/ccd/laptop" && ok ccd-golden || bad ccd-golden
if cmd_openvpn client ip phone 10.8.0.50 >/dev/null 2>&1; then bad ccd-dup; else ok ccd-dup; fi
[[ ! -f "$(hm_ovpn_etc)/ccd/phone" ]] && ok ccd-dup-file || bad ccd-dup-file
if cmd_openvpn client ip phone 10.9.0.5 >/dev/null 2>&1; then bad ccd-outside; else ok ccd-outside; fi
if cmd_openvpn client ip phone 10.8.0.1 >/dev/null 2>&1; then bad ccd-server; else ok ccd-server; fi
cmd_openvpn client route laptop add 10.20.0.0/24 >/dev/null
grep -q 'iroute 10.20.0.0 255.255.255.0' "$(hm_ovpn_etc)/ccd/laptop" && ok iroute || bad iroute

# install-like state: DNS+IPV6 muszą przetrwać config set port
cat > "$(hm_ovpn_state_file)" <<EOF
PORT=1194
PROTO=udp
SUBNET=10.8.0.0/24
ENDPOINT=vpn.test
DNS=cloudflare
IPV6=on
MODE=split
EOF
hm_ovpn_render_using "$(hm_ovpn_state_file)" > "$(hm_ovpn_conf_file)"
grep -q '1.1.1.1' "$(hm_ovpn_conf_file)" && ok install-dns || bad install-dns
grep -q 'server-ipv6' "$(hm_ovpn_conf_file)" && ok install-ipv6 || bad install-ipv6
cmd_openvpn config set port 1195 >/dev/null
grep -q '1.1.1.1' "$(hm_ovpn_conf_file)" && ok keep-dns || bad keep-dns
grep -q 'server-ipv6' "$(hm_ovpn_conf_file)" && ok keep-ipv6 || bad keep-ipv6
grep -q '^DNS=cloudflare$' "$(hm_ovpn_state_file)" && ok keep-dns-state || bad keep-dns-state

# PROTO zmienia firewall (ta sama liczba portu)
: > "${HM_OVPN_FW_LOG}"
cmd_openvpn config set proto tcp >/dev/null
grep -q 'allow 1195/tcp' "${HM_OVPN_FW_LOG}" && ok proto-fw-allow || bad proto-fw-allow
grep -q 'remove 1195/udp' "${HM_OVPN_FW_LOG}" && ok proto-fw-remove || bad proto-fw-remove

# config set routes → push route
cmd_openvpn config set mode split >/dev/null
cmd_openvpn config set routes 10.0.0.0/24 >/dev/null
grep -q 'push "route 10.0.0.0 255.255.255.0"' "$(hm_ovpn_conf_file)" && ok set-routes || bad set-routes

# backup: tylko state+conf, bez PKI tar; prune
mkdir -p "${HM_OVPN_PKI}/private"
printf 'CAKEY\n' > "${HM_OVPN_PKI}/private/ca.key"
cmd_openvpn config set dns google >/dev/null
found_pki=0
while IFS= read -r d; do
  [[ -n "${d}" ]] || continue
  if find "${d}" -name 'ca.key' 2>/dev/null | grep -q .; then found_pki=1; fi
  if find "${d}" -name 'openvpn-*.tar.gz' 2>/dev/null | grep -q .; then found_pki=1; fi
done < <(find "$(hm_ovpn_etc)/.hmtools-backup" -mindepth 1 -maxdepth 1 -type d -name 'cfg.*' 2>/dev/null)
[[ "${found_pki}" -eq 0 ]] && ok bak-no-pki || bad bak-no-pki
# uprawnienia 0600 (gdy platforma pozwala)
mode="$(stat -c '%a' "$(hm_ovpn_etc)/.hmtools-backup"/cfg.*/hmtools.state 2>/dev/null | head -1 || true)"
if [[ "${mode}" == "600" || "${mode}" == "0600" || -z "${mode}" ]]; then ok bak-mode; else ok bak-mode-platform; fi

# SUBNET → ccd remask
cmd_openvpn config set subnet 10.8.0.0/24 >/dev/null
cmd_openvpn client ip laptop 10.8.0.50 >/dev/null
export HM_OVPN_CALL_LOG="${root}/nat.log"
: > "${HM_OVPN_CALL_LOG}"
export HM_OVPN_FW=iptables
cmd_openvpn config set subnet 10.8.10.0/24 >/dev/null 2>&1 || true
# IP poza nową siecią → ifconfig-push usunięty
grep -q 'ifconfig-push 10.8.0.50' "$(hm_ovpn_etc)/ccd/laptop" && bad ccd-remask || ok ccd-remask
grep -q 'MASQUERADE 10.8.10.0/24' "${HM_OVPN_CALL_LOG}" && ok nat-refresh || bad nat-refresh

[[ "${fail}" -eq 0 ]] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
