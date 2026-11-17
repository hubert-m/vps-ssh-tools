#!/usr/bin/env bash
# openvpn bez argumentów, status, doctor, help. Bez sieci i bez roota.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1 HMTOOLS_TEST_NO_TTY=1
export LANG=C

# shellcheck disable=SC1091
source lib/common/ui.sh
hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }
hm_confirm_plan() { return 0; }
declare -A HM_CMD_HELP
_hm_cmd_help() { local t="$1"; HM_CMD_HELP["${t}"]="$(cat)"; }
_hm_cmd_register() { :; }
hm_help_topic() { printf '%s\n' "${HM_CMD_HELP[${1}]:-}"; }

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
export HM_OVPN_ROOT="${root}/ovpn"
export HM_OVPN_ETC="${root}/ovpn/server"
export HM_OVPN_PKI="${HM_OVPN_ETC}/pki"
export HM_OVPN_SERVER="${HM_OVPN_ETC}"
export HM_OVPN_APPLOG="${root}/applog"
export HM_OVPN_CALL_LOG="${root}/calls.log"
export HM_OVPN_UNIT="${root}/unit.service"
export HM_OVPN_MGMT="${root}/hm.sock"
mkdir -p "${HM_OVPN_ETC}" "${root}/bin"
# shellcheck disable=SC1091
source scripts/_openvpn_mocks.sh
hm_ovpn_mock_bins "${root}/bin"
export PATH="${root}/bin:${PATH}"

# shellcheck disable=SC1091
source commands/openvpn/main.sh
# shellcheck disable=SC1091
source lib/detect.sh

hint="$(cmd_openvpn)"
printf '%s\n' "${hint}" | grep -q 'install --dry-run' && ok bare-hint || bad bare-hint

mkdir -p "${HM_OVPN_PKI}"
printf 'ENDPOINT=vpn.test\nPORT=1194\nPROTO=udp\n' > "$(hm_ovpn_state_file)"
printf 'V\t270101000000Z\t\t01\tunknown\t/CN=server\nV\t270101000000Z\t\t02\tunknown\t/CN=laptop\n' \
  > "${HM_OVPN_PKI}/index.txt"
st="$(LANG=C cmd_openvpn status)"
printf '%s\n' "${st}" | grep -q 'endpoint: vpn.test' && ok status-ep || bad status-ep
printf '%s\n' "${st}" | grep -q 'klienci: 1' && ok status-clients || bad status-clients
stpl="$(LANG=pl_PL.UTF-8 cmd_openvpn)"
printf '%s\n' "${stpl}" | grep -q 'instancja: hm' && ok status-lang || bad status-lang

: > "${HM_OVPN_UNIT}"
printf 'tls\n' > "$(hm_ovpn_tls_key_path)"
mkdir -p "${HM_OVPN_PKI}/private"
printf 'ca\n' > "${HM_OVPN_PKI}/private/ca.key"
chmod 0600 "$(hm_ovpn_tls_key_path)" "${HM_OVPN_PKI}/private/ca.key" 2>/dev/null || true
drc=0
doc="$(hm_ovpn_doctor)" || drc=$?
printf '%s\n' "${doc}" | grep -q 'pakiet openvpn: jest' && ok doctor-pkg || bad doctor-pkg
printf '%s\n' "${doc}" | grep -q 'pakiet easy-rsa: jest' && ok doctor-easyrsa || bad doctor-easyrsa
printf '%s\n' "${doc}" | grep -q 'unit: jest' && ok doctor-unit || bad doctor-unit
printf '%s\n' "${doc}" | grep -q "pki: ${HM_OVPN_PKI}" && ok doctor-pki-path || bad doctor-pki-path
# domyślna ścieżka bez HM_OVPN_PKI → …/hm/pki
(
  unset HM_OVPN_PKI
  d="$(hm_ovpn_pki)"
  [[ "${d}" == "${HM_OVPN_ETC}/hm/pki" ]] && ok pki-default-hm || bad pki-default-hm
)
# easyrsa tylko w /usr/share (symulacja)
mkdir -p "${root}/share/easy-rsa"
printf '#!/usr/bin/env bash\nexit 0\n' > "${root}/share/easy-rsa/easyrsa"
chmod +x "${root}/share/easy-rsa/easyrsa" || true
# tymczasowo schowaj easyrsa z PATH mocków
mv "${root}/bin/easyrsa" "${root}/bin/easyrsa.bak" 2>/dev/null || true
# podmień detekcję ścieżek przez HM_OVPN_EASYRSA wskazujący share
export HM_OVPN_EASYRSA="${root}/share/easy-rsa/easyrsa"
doc2="$(hm_ovpn_doctor)" || true
printf '%s\n' "${doc2}" | grep -q 'pakiet easy-rsa: jest' && ok doctor-easyrsa-share || bad doctor-easyrsa-share
unset HM_OVPN_EASYRSA
mv "${root}/bin/easyrsa.bak" "${root}/bin/easyrsa" 2>/dev/null || true
mode="$(hm_ovpn_mode "$(hm_ovpn_tls_key_path)" || true)"
if [[ "${mode}" == "600" || "${mode}" == "400" ]]; then
  [[ "${drc}" -eq 0 ]] && ok doctor-mode || bad doctor-mode
else
  [[ "${drc}" -ne 0 ]] && ok doctor-mode-platform || bad doctor-mode-platform
fi

help="$(hm_help_topic openvpn)"
printf '%s\n' "${help}" | grep -q 'openvpn install' && ok help-install || bad help-install
printf '%s\n' "${help}" | grep -q 'client revoke' && ok help-revoke || bad help-revoke
printf '%s\n' "${help}" | grep -q 'openvpn doctor' && ok help-doctor || bad help-doctor

export HM_OVPN_DETECT=yes
hm_detect_openvpn
[[ "${OPENVPN}" == "yes" ]] && ok detect-yes || bad detect-yes
export HM_OVPN_DETECT=no
hm_detect_openvpn
[[ "${OPENVPN}" == "no" ]] && ok detect-no || bad detect-no

export HM_OVPN_STATUS="${root}/status-v3.log"
cat > "${HM_OVPN_STATUS}" <<'EOF'
HEADER,CLIENT_LIST,Common Name,Real Address,Virtual Address,Virtual IPv6 Address,Bytes Received,Bytes Sent,Connected Since,Username,Client ID,Peer ID,Data Channel Cipher
CLIENT_LIST,lap top,1.2.3.4:1194,10.8.0.2,,100,200,2026-11-11 10:00:00,,,AES-256-GCM
CLIENT_LIST,host.example,[2001:db8::1]:1194,10.8.0.3,fd42::2,0,0,2026-11-11 10:00:00,,,AES-256-GCM
EOF
snap="$(mktemp)"
cp -f "${HM_OVPN_STATUS}" "${snap}"
who="$(cmd_openvpn who)"
printf '%s\n' "${who}" | grep -q 'lap top' && ok who-space || bad who-space
printf '%s\n' "${who}" | grep -q '2001:db8::1' && ok who-v6 || bad who-v6
cmp -s "${HM_OVPN_STATUS}" "${snap}" && ok who-readonly || bad who-readonly
empty="$(mktemp)"
printf 'HEADER,CLIENT_LIST\n' > "${empty}"
HM_OVPN_STATUS="${empty}" cmd_openvpn who >/dev/null && ok who-empty || bad who-empty
js="$(cmd_openvpn who --json)"
printf '%s\n' "${js}" | grep -q '"cn":"lap top"' && ok who-json || bad who-json
stj="$(cmd_openvpn status --json)"
printf '%s\n' "${stj}" | grep -q '"endpoint":"vpn.test"' && ok status-json || bad status-json

if cmd_openvpn kick ghost >/dev/null 2>&1; then bad kick-missing; else ok kick-missing; fi
export HM_OVPN_MGMT_LOG="${root}/mgmt.log"
cmd_openvpn kick host.example --yes >/dev/null
grep -q 'kill host.example' "${HM_OVPN_MGMT_LOG}" && ok kick-dot || bad kick-dot
# kick bez pliku statusu → rc≠0
unset HM_OVPN_STATUS
if cmd_openvpn kick host.example --yes >/dev/null 2>&1; then bad kick-nostatus; else ok kick-nostatus; fi
# ścieżka statusu z hm.conf (jak install: /run/… albo lokalna)
runstat="${root}/run-status-hm.log"
mkdir -p "${root}/run"
printf 'CLIENT_LIST,fromconf,9.9.9.9:1,10.8.0.9,,1,1,t,,,AES\n' > "${runstat}"
printf 'status %s 30\nport 1194\n' "${runstat}" > "$(hm_ovpn_conf_file)"
who2="$(cmd_openvpn who)"
printf '%s\n' "${who2}" | grep -q 'fromconf' && ok who-from-conf || bad who-from-conf
printf '%s\n' "$(cmd_openvpn status)" | grep -q "status_file: ${runstat}" && ok status-path-conf || bad status-path-conf
# client show/list: sesja z hm_ovpn_status_file (nie tylko HM_OVPN_STATUS)
mkdir -p "${HM_OVPN_PKI}/issued"
cat > "${HM_OVPN_PKI}/issued/fromconf.crt" <<'CRT'
-----BEGIN CERT-----
MII=
-----END CERT-----
CRT
openssl() { case "$1" in x509) printf 'subject=CN=fromconf\n';; *) return 0;; esac; }
show_fc="$(cmd_openvpn client show fromconf 2>/dev/null || true)"
printf '%s\n' "${show_fc}" | grep -q 'sesja: połączony' && ok client-show-from-conf || bad client-show-from-conf
unset -f openssl
# kick: nazwa to literal (j.n ≠ jan); bez mgmt → rc≠0
printf 'CLIENT_LIST,jan,1.1.1.1:1,10.8.0.2,,1,1,t,,,AES\n' > "${runstat}"
if cmd_openvpn kick 'j.n' --yes >/dev/null 2>&1; then bad kick-regex; else ok kick-regex; fi
unset HM_OVPN_MGMT_LOG
printf 'CLIENT_LIST,jan,1.1.1.1:1,10.8.0.2,,1,1,t,,,AES\n' > "${runstat}"
if cmd_openvpn kick jan --yes >/dev/null 2>&1; then bad kick-nomgmt; else ok kick-nomgmt; fi
export HM_OVPN_MGMT_LOG="${root}/mgmt.log"

export HM_OVPN_JOURNAL="${root}/journal.log"
cat > "${HM_OVPN_JOURNAL}" <<'EOF'
laptop connected
TLS Error: TLS handshake failed
VERIFY ERROR laptop
-----BEGIN PRIVATE KEY-----
SECRET-STATUS-LOG
AUTH_FAILED
EOF
errlog="$(cmd_openvpn log 2 --errors)"
printf '%s\n' "${errlog}" | grep -q 'AUTH_FAILED' && ok log-err || bad log-err
printf '%s\n' "${errlog}" | grep -q 'connected' && bad log-filter || ok log-filter
printf '%s\n' "${errlog}" | grep -q 'SECRET-STATUS-LOG' && bad log-secret || ok log-secret
lines="$(printf '%s\n' "${errlog}" | grep -c . || true)"
[[ "${lines}" == "2" ]] && ok log-tail || bad log-tail

printf 'port 1194\n' > "$(hm_ovpn_conf_file)"
hm_notify() { printf 'notify %s\n' "$1" >> "${root}/notify"; }
: > "${root}/notify"
export HM_OVPN_ACTIVE=failed
if hm_ovpn_health_section --notify >/dev/null; then bad health-rc; else ok health-rc; fi
sec="$(hm_ovpn_health_section --notify || true)"
printf '%s\n' "${sec}" | grep -q 'OpenVPN' && ok health-section || bad health-section
grep -q 'notify error' "${root}/notify" && ok health-notify || bad health-notify
rm -f "$(hm_ovpn_conf_file)"
if hm_ovpn_health_section >/dev/null; then ok health-absent; else bad health-absent; fi

grep -q 'openvpn-server@hm openvpn@server openvpn' commands/services/main.sh && ok services-catalog || bad services-catalog

[[ "${fail}" -eq 0 ]] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
