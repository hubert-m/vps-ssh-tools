#!/usr/bin/env bash
# openvpn client add/list/show/export — profil, nazwy, umask, brak sekretów w logu.
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
hm_have_cmd() { [[ "$1" == "sha256sum" ]]; }
hm_confirm_plan() { return 0; }
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
export HM_OVPN_EXPORT="${root}/clients"
export HM_OVPN_APPLOG="${root}/applog"
export HM_OVPN_TMP="${root}/tmp"
export HM_OVPN_MOCK_LOG="${root}/easyrsa.log"
export HM_OVPN_STATUS="${root}/status.txt"
export HM_OVPN_PORT="1194"
export HM_OVPN_PROTO="udp"
export HM_OVPN_SERVER_CN="server"
export PATH="${root}/bin:${PATH}"
mkdir -p "${root}/bin" "${HM_OVPN_PKI}" "${HM_OVPN_ETC}" "${HM_OVPN_TMP}"
unset HM_OVPN_MOCK || true
unset HM_OVPN_REMOTE || true
cat > "${HM_OVPN_ETC}/hmtools.state" <<'EOF'
PORT=1194
PROTO=udp
SUBNET=10.8.0.0/24
ENDPOINT=vpn.test
PKI=pki
EOF

cat > "${HM_OVPN_PKI}/ca.crt" <<'EOF'
-----BEGIN CERTIFICATE-----
Q0E=
-----END CERTIFICATE-----
EOF
cat > "${root}/cert.pem" <<'EOF'
Certificate:
    Data:
        Subject: CN=laptop
-----BEGIN CERTIFICATE-----
Q0VSVAo=
-----END CERTIFICATE-----
EOF
cat > "${root}/key.pem" <<'EOF'
-----BEGIN PRIVATE KEY-----
S0VZ
-----END PRIVATE KEY-----
EOF
cat > "${HM_OVPN_ETC}/tls-crypt.key" <<'EOF'
-----BEGIN OpenVPN Static key V1-----
5441
-----END OpenVPN Static key V1-----
EOF
export HM_OVPN_FIXTURE_CERT="${root}/cert.pem"
export HM_OVPN_FIXTURE_KEY="${root}/key.pem"

cat > "${root}/bin/easyrsa" <<'EOF'
#!/usr/bin/env bash
printf 'easyrsa %s\n' "$*" >> "${HM_OVPN_MOCK_LOG}"
printf 'expire=%s\n' "${EASYRSA_CERT_EXPIRE:-}" >> "${HM_OVPN_MOCK_LOG}"
if [[ -n "${EASYRSA_PASSOUT:-}" ]]; then
  printf 'passfile-set\n' >> "${HM_OVPN_MOCK_LOG}"
fi
name=""
take=0
for a in "$@"; do
  if [[ "${take}" -eq 1 ]]; then
    name="${a}"
    break
  fi
  [[ "${a}" == "build-client-full" ]] && take=1
done
mkdir -p "${HM_OVPN_PKI}/issued" "${HM_OVPN_PKI}/private"
cp "${HM_OVPN_FIXTURE_CERT}" "${HM_OVPN_PKI}/issued/${name}.crt"
cp "${HM_OVPN_FIXTURE_KEY}" "${HM_OVPN_PKI}/private/${name}.key"
EOF
cat > "${root}/bin/openssl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *x509* ]]; then
  printf 'serial=01\nSHA256 Fingerprint=AB:CD\nnotBefore=Jan  1 00:00:00 2026 GMT\nnotAfter=Jan  1 00:00:00 2028 GMT\nsubject=CN=laptop\n'
fi
EOF
chmod +x "${root}/bin/easyrsa" "${root}/bin/openssl" || true

# shellcheck disable=SC1091
source commands/openvpn/main.sh

before="$(find "${HM_OVPN_PKI}" -type f | wc -l | tr -d ' ')"
if cmd_openvpn client add 'bad name' --yes >/dev/null 2>&1; then bad name-bad; else ok name-bad; fi
if cmd_openvpn client add server --yes >/dev/null 2>&1; then bad name-reserved; else ok name-reserved; fi
after="$(find "${HM_OVPN_PKI}" -type f | wc -l | tr -d ' ')"
[[ "${before}" == "${after}" ]] && ok name-nofiles || bad name-nofiles

umask 022
saved="$(umask)"
cmd_openvpn client add laptop --days 365 --static-ip 10.8.0.50 --yes >"${root}/add.out"
[[ "$(umask)" == "${saved}" ]] && ok umask || bad umask
diff -u "${HMTOOLS_ROOT}/scripts/fixtures/openvpn/laptop.ovpn" "${HM_OVPN_EXPORT}/laptop.ovpn" && ok golden || bad golden
grep -q '<tls-crypt>' "${HM_OVPN_EXPORT}/laptop.ovpn" && grep -q '5441' "${HM_OVPN_EXPORT}/laptop.ovpn" && ok tls-body || bad tls-body
grep -q 'remote vpn.test 1194' "${HM_OVPN_EXPORT}/laptop.ovpn" && ok endpoint-state || bad endpoint-state
HM_OVPN_REMOTE=override.example cmd_openvpn client export laptop --out "${root}/over.ovpn" >/dev/null
grep -q 'remote override.example 1194' "${root}/over.ovpn" && ok endpoint-override || bad endpoint-override
unset HM_OVPN_REMOTE
rc=0
HM_OVPN_REMOTE=vpn.example cmd_openvpn client export laptop --out "${root}/bad.ovpn" >/dev/null 2>"${root}/bad.err" || rc=$?
[[ "${rc}" -ne 0 ]] && grep -q 'vpn.example' "${root}/bad.err" && [[ ! -s "${root}/bad.ovpn" ]] && ok endpoint-placeholder || bad endpoint-placeholder
unset HM_OVPN_REMOTE
mv "${HM_OVPN_ETC}/tls-crypt.key" "${HM_OVPN_ETC}/tls-crypt.key.bak"
rc=0
cmd_openvpn client export laptop --out "${root}/notls.ovpn" >/dev/null 2>"${root}/notls.err" || rc=$?
[[ "${rc}" -ne 0 ]] && grep -q 'tls-crypt' "${root}/notls.err" && ok tls-missing || bad tls-missing
mv "${HM_OVPN_ETC}/tls-crypt.key.bak" "${HM_OVPN_ETC}/tls-crypt.key"
grep -q 'BEGIN PRIVATE KEY' "${root}/add.out" "${HM_OVPN_APPLOG}" && bad add-leak || ok add-secret
grep -q 'BEGIN OpenVPN Static key' "${root}/add.out" "${HM_OVPN_APPLOG}" && bad add-tls-leak || ok add-tls
grep -q 'plik:' "${root}/add.out" && grep -q 'sha256:' "${root}/add.out" && grep -q 'scp root@' "${root}/add.out" && ok add-meta || bad add-meta
probe="${root}/probe"
: > "${probe}"
chmod 0600 "${probe}" || true
if [[ "$(stat -c %a "${probe}" 2>/dev/null || stat -f %OLp "${probe}")" == "600" ]]; then
  [[ "$(stat -c %a "${HM_OVPN_EXPORT}/laptop.ovpn" 2>/dev/null || stat -f %OLp "${HM_OVPN_EXPORT}/laptop.ovpn")" == "600" ]] && ok ovpn-mode || bad ovpn-mode
  [[ "$(stat -c %a "${HM_OVPN_EXPORT}" 2>/dev/null || stat -f %OLp "${HM_OVPN_EXPORT}")" == "700" ]] && ok ovpn-dir || bad ovpn-dir
else
  ok ovpn-mode-platform
  ok ovpn-dir-platform
fi
log_before="$(wc -l < "${HM_OVPN_MOCK_LOG}" | tr -d ' ')"
if cmd_openvpn client add laptop --yes >/dev/null 2>&1; then bad dup; else ok dup; fi
log_after="$(wc -l < "${HM_OVPN_MOCK_LOG}" | tr -d ' ')"
[[ "${log_before}" == "${log_after}" ]] && ok dup-nofiles || bad dup-nofiles

: > "${HM_OVPN_MOCK_LOG}"
cmd_openvpn client add phone --pass --no-export --yes >"${root}/pass.out" <<'EOF'
s3cret-pass
s3cret-pass
EOF
grep -q 'passfile-set' "${HM_OVPN_MOCK_LOG}" && ok pass-file || bad pass-file
grep -q 'nopass' "${HM_OVPN_MOCK_LOG}" && bad pass-nopass || ok pass-nopass
grep -q 's3cret-pass' "${HM_OVPN_MOCK_LOG}" "${HM_OVPN_APPLOG}" "${root}/pass.out" && bad pass-leak || ok pass-hidden
find "${HM_OVPN_TMP}" -type f | grep -q . && bad pass-tmp || ok pass-tmp
ps -ef >"${root}/ps.txt" 2>/dev/null || ps aux >"${root}/ps.txt" 2>/dev/null || : >"${root}/ps.txt"
grep -q 's3cret-pass' "${root}/ps.txt" && bad pass-ps || ok pass-ps

printf 'CLIENT_LIST,laptop,1.2.3.4,10.8.0.50,2026-11-10\n' > "${HM_OVPN_STATUS}"
printf 'R\t%s\t\t02\t/CN=old\n' "$(date -u -d '+10 days' '+%y%m%d%H%M%SZ')" >> "${HM_OVPN_PKI}/index.txt"
printf 'E\t%s\t\t03\t/CN=gone\n' "$(date -u -d '-2 days' '+%y%m%d%H%M%SZ')" >> "${HM_OVPN_PKI}/index.txt"
list="$(cmd_openvpn client list)"
printf '%s\n' "${list}" | grep -q 'Nazwa' && printf '%s\n' "${list}" | grep -q 'laptop' && ok list-table || bad list-table
printf '%s\n' "${list}" | grep -q 'old' && bad list-hides-revoked || ok list-hides-revoked
all="$(cmd_openvpn client list --all)"
printf '%s\n' "${all}" | grep -q 'unieważniony' && printf '%s\n' "${all}" | grep -q 'wygasły' && ok list-all || bad list-all
printf '%s\n' "${all}" | grep -q '10.8.0.50' && printf '%s\n' "${all}" | grep -q 'tak' && ok list-session || bad list-session
show="$(cmd_openvpn client show laptop)"
printf '%s\n' "${show}" | grep -q 'serial=01' && printf '%s\n' "${show}" | grep -q 'sesja: połączony' && ok show || bad show
printf '%s\n' "${show}" | grep -q 'BEGIN PRIVATE KEY' && bad show-key || ok show-key

rc=0
cmd_openvpn client export laptop --print >"${root}/print.out" 2>"${root}/print.err" || rc=$?
[[ "${rc}" -ne 0 ]] && ok print-rc || bad print-rc
grep -q 'BEGIN PRIVATE KEY' "${root}/print.out" "${root}/print.err" "${HM_OVPN_APPLOG}" && bad print-leak || ok print-secret
grep -q 'Brak TTY' "${root}/print.out" "${root}/print.err" && ok print-tty || bad print-tty

[[ "${fail}" -eq 0 ]] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
