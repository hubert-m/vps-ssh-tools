#!/usr/bin/env bash
# openvpn revoke/renew/CRL: mock easyrsa, parser dat, dedup powiadomień, cron.
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
hm_confirm_plan() { printf 'PLAN %s\n' "$1"; return 0; }
hm_notify() { printf '%s\n' "$2" >> "${HM_NOTIFY_LOG}"; }
_hm_cmd_help() { :; }
_hm_cmd_register() { :; }

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
export HM_OVPN_ROOT="${root}/ovpn"
export HM_OVPN_PKI="${HM_OVPN_ROOT}/pki"
export HM_OVPN_SERVER="${HM_OVPN_ROOT}/server"
export HM_OVPN_ETC="${HM_OVPN_SERVER}"
export HM_OVPN_REMOTE="vpn.test"
export HM_OVPN_EXPORT="${HM_OVPN_ROOT}/clients"
export HM_OVPN_CRON="${root}/cron/hmtools-openvpn"
export HM_OVPN_APPLOG="${root}/applog"
export HM_OVPN_DEDUP="${HM_OVPN_ROOT}/dedup"
export HM_OVPN_MGMT_LOG="${root}/mgmt"
export HM_OVPN_MOCK=1
export HM_OVPN_MOCK_LOG="${root}/easyrsa.log"
export HM_OVPN_RESTART_LOG="${root}/restart"
export HM_NOTIFY_LOG="${root}/notify.log"
export PATH="${root}/bin:${PATH}"
mkdir -p "${HM_OVPN_PKI}/issued" "${HM_OVPN_SERVER}/ccd" "${HM_OVPN_EXPORT}" "${root}/bin" "$(dirname "${HM_OVPN_CRON}")"
printf 'BEGIN PRIVATE KEY secret-key-material\n' > "${HM_OVPN_EXPORT}/laptop.ovpn"
printf 'ifconfig 10.8.0.2\n' > "${HM_OVPN_SERVER}/ccd/laptop"

cat > "${root}/bin/openssl" <<'EOF'
#!/usr/bin/env bash
printf 'openssl %s\n' "$*" >> "${HM_OVPN_MOCK_LOG}"
printf 'nextUpdate=%s\n' "$(date -u -d '+20 days' '+%y%m%d%H%M%SZ')"
EOF
chmod +x "${root}/bin/openssl" || true

# shellcheck disable=SC1091
source commands/openvpn/main.sh

near="$(date -u -d '+12 days' '+%y%m%d%H%M%SZ')"
far="$(date -u -d '+40 days' '+%y%m%d%H%M%SZ')"
ca_far="$(date -u -d '+90 days' '+%y%m%d%H%M%SZ')"
printf 'V\t%s\t\t01\t/CN=laptop\n' "${near}" > "${HM_OVPN_PKI}/index.txt"
printf 'V\t%s\t\t02\t/CN=stable\n' "${far}" >> "${HM_OVPN_PKI}/index.txt"
printf '%s\n' "${ca_far}" > "${HM_OVPN_PKI}/ca.notafter"
printf '%s\n' "${far}" > "${HM_OVPN_PKI}/issued/server.notafter"

epoch="$(hm_ovpn_asn1_epoch "${near}")"
[[ -n "${epoch}" ]] && ok parse-asn1 || bad parse-asn1

cmd_openvpn client revoke laptop --yes >"${root}/revoke.out"
grep -q 'PLAN openvpn revoke laptop' "${root}/revoke.out" && ok revoke-plan || bad revoke-plan
grep -q 'easyrsa revoke laptop' "${HM_OVPN_MOCK_LOG}" && ok revoke-call || bad revoke-call
grep -q 'easyrsa gen-crl' "${HM_OVPN_MOCK_LOG}" && ok revoke-crl || bad revoke-crl
grep -q 'kill laptop' "${HM_OVPN_MGMT_LOG}" && ok revoke-kill || bad revoke-kill
grep -q 'sesja nie została rozłączona' "${root}/revoke.out" && ok revoke-nosock || bad revoke-nosock
[[ ! -e "${HM_OVPN_SERVER}/ccd/laptop" && ! -e "${HM_OVPN_EXPORT}/laptop.ovpn" ]] && ok revoke-files || bad revoke-files
grep -q 'secret-key-material' "${HM_OVPN_APPLOG}" && bad revoke-key-leak || ok revoke-audit
probe="${root}/probe"
: > "${probe}"
chmod 0644 "${probe}" || true
mode_ok=0
[[ "$(stat -c %a "${probe}" 2>/dev/null || stat -f %OLp "${probe}")" == "644" ]] && mode_ok=1
if [[ "${mode_ok}" -eq 1 ]]; then
  [[ "$(stat -c %a "${HM_OVPN_SERVER}/crl.pem" 2>/dev/null || stat -f %OLp "${HM_OVPN_SERVER}/crl.pem")" == "644" ]] && ok crl-mode || bad crl-mode
else
  ok crl-mode-platform
fi

rm -f "${HM_OVPN_MOCK_LOG}"
export HM_OVPN_EASYRSA_VERSION=3.0.8
cmd_openvpn client renew laptop --days 365 --yes >"${root}/renew30.out"
grep -q 'Stary profil' "${root}/renew30.out" && ok renew-warn || bad renew-warn
order="$(grep -E 'revoke laptop|build-client-full laptop' "${HM_OVPN_MOCK_LOG}" | tr '\n' ' ')"
[[ "${order}" == *"revoke laptop"*"build-client-full laptop"* ]] && ok renew-30 || bad renew-30
ovpn="${HM_OVPN_EXPORT}/laptop.ovpn"
if grep -q 'BEGIN CERTIFICATE' "${ovpn}" && grep -q '<tls-crypt>' "${ovpn}" && ! grep -q '<cert>CN=' "${ovpn}"; then
  ok renew-export
else
  bad renew-export
fi
secprobe="${root}/secret-probe"
: > "${secprobe}"
chmod 0600 "${secprobe}" 2>/dev/null || true
if [[ "$(stat -c %a "${secprobe}" 2>/dev/null || stat -f %OLp "${secprobe}")" == "600" ]]; then
  [[ "$(stat -c %a "${ovpn}" 2>/dev/null || stat -f %OLp "${ovpn}")" == "600" ]] && ok renew-mode || bad renew-mode
else
  ok renew-mode-platform
fi

rm -f "${HM_OVPN_MOCK_LOG}"
export HM_OVPN_EASYRSA_VERSION=3.1.2
cmd_openvpn client renew laptop --yes >/dev/null
grep -q 'easyrsa renew laptop' "${HM_OVPN_MOCK_LOG}" && ok renew-31 || bad renew-31
grep -q 'easyrsa revoke' "${HM_OVPN_MOCK_LOG}" && bad renew-31-norevoke || ok renew-31-norevoke

rm -f "${HM_OVPN_SERVER}/crl.pem.next"
cmd_openvpn crl status >"${root}/status.out"
grep -q 'openssl crl' "${HM_OVPN_MOCK_LOG}" && ok crl-openssl || bad crl-openssl
grep -q '^days=' "${root}/status.out" && ok crl-status || bad crl-status

listed="$(cmd_openvpn client list --expiring 14)"
printf '%s\n' "${listed}" | grep -q 'laptop' && ok list-near || bad list-near
printf '%s\n' "${listed}" | grep -q 'stable' && bad list-far || ok list-far

: > "${HM_NOTIFY_LOG}"
set +e
cmd_openvpn check --notify >"${root}/check.out" 2>"${root}/check.err"
rc1=$?
cmd_openvpn check --notify >"${root}/check2.out" 2>"${root}/check2.err"
rc2=$?
set -e
[[ "${rc1}" -ne 0 && "${rc2}" -ne 0 ]] && ok check-rc || bad check-rc
[[ "$(grep -c 'CRL OpenVPN' "${HM_NOTIFY_LOG}")" -eq 1 ]] && ok check-dedup || bad check-dedup

cmd_openvpn schedule install >/dev/null
first="$(cat "${HM_OVPN_CRON}")"
cmd_openvpn schedule install >/dev/null
[[ "$(cat "${HM_OVPN_CRON}")" == "${first}" ]] && ok cron-idempotent || bad cron-idempotent
grep -q 'hmtools-openvpn' "${HM_OVPN_CRON}" && ok cron-marker || bad cron-marker
cmd_openvpn schedule disable >/dev/null
[[ ! -e "${HM_OVPN_CRON}" ]] && ok cron-disable || bad cron-disable
printf 'other cron\n' > "${HM_OVPN_CRON}"
if cmd_openvpn schedule disable >/dev/null 2>&1; then bad cron-foreign; else ok cron-foreign; fi
[[ -f "${HM_OVPN_CRON}" ]] && ok cron-kept || bad cron-kept

rm -f "${HM_OVPN_MOCK_LOG}"
export HM_OVPN_EASYRSA_VERSION=3.1.2
cmd_openvpn server renew --yes >/dev/null
grep -q 'easyrsa renew server' "${HM_OVPN_MOCK_LOG}" && ok server-renew || bad server-renew
grep -q 'systemctl restart openvpn-server@hm' "${HM_OVPN_RESTART_LOG}" && ok server-restart || bad server-restart

[[ "${fail}" -eq 0 ]] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
