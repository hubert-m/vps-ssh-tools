#!/usr/bin/env bash
# Tab: podkomendy openvpn i CN z index.txt.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
# shellcheck disable=SC1091
source lib/complete/helpers.sh

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
export HM_OVPN_INDEX="${root}/index.txt"
printf '%s\n' 'V	270101000000Z		01	unknown	/CN=laptop' 'R	270101000000Z	260101000000Z	02	unknown	/CN=old' > "${HM_OVPN_INDEX}"

names="$(hm_complete_openvpn_clients "lap")"
printf '%s\n' "${names}" | grep -qx 'laptop' && ok client-prefix || bad client-prefix
printf '%s\n' "$(hm_complete_openvpn_clients "")" | grep -qx 'old' && bad client-revoked || ok client-revoked

# bez HM_OVPN_INDEX: ścieżka jak install (…/server/hm/pki), pomija server/ca
unset HM_OVPN_INDEX HM_OVPN_PKI
mkdir -p "${root}/server/hm/pki"
printf '%s\n' \
  'V	270101000000Z		01	unknown	/CN=laptop' \
  'V	270101000000Z		02	unknown	/CN=server' \
  'V	270101000000Z		03	unknown	/CN=ca' \
  'V	270101000000Z		04	unknown	/CN=phone' \
  > "${root}/server/hm/pki/index.txt"
# stub hm_ovpn_pki jak w module (gdy main.sh nie załadowany)
hm_ovpn_pki() { printf '%s' "${root}/server/hm/pki"; }
all="$(hm_complete_openvpn_clients "")"
printf '%s\n' "${all}" | grep -qx 'laptop' && ok client-hm-pki || bad client-hm-pki
printf '%s\n' "${all}" | grep -qx 'phone' && ok client-hm-phone || bad client-hm-phone
printf '%s\n' "${all}" | grep -qx 'server' && bad client-skip-server || ok client-skip-server
printf '%s\n' "${all}" | grep -qx 'ca' && bad client-skip-ca || ok client-skip-ca
unset -f hm_ovpn_pki
# fallback bez hm_ovpn_pki: /etc/openvpn/server/hm/pki — symulacja przez HM_OVPN_PKI unset + brak funkcji
# (ścieżka systemowa może nie istnieć; sprawdzamy kod źródłowy)
grep -q '/etc/openvpn/server/hm/pki' lib/complete/helpers.sh && ok client-default-path || bad client-default-path

if grep -q 'hm_complete_openvpn_clients' lib/complete/tab.sh \
  && grep -q 'revoke|renew|export|show|ip' lib/complete/tab.sh \
  && grep -q 'port proto dns endpoint subnet ipv6 mode client-to-client max-clients keepalive' lib/complete/tab.sh; then
  ok tab-wired
else
  bad tab-wired
fi

[[ "${fail}" -eq 0 ]] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
