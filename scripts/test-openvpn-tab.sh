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

if grep -q 'hm_complete_openvpn_clients' lib/complete/tab.sh \
  && grep -q 'revoke|renew|export|show|ip' lib/complete/tab.sh \
  && grep -q 'ENDPOINT PORT PROTO DNS SUBNET' lib/complete/tab.sh; then
  ok tab-wired
else
  bad tab-wired
fi

[[ "${fail}" -eq 0 ]] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
