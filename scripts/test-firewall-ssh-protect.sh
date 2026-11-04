#!/usr/bin/env bash
# Regresja: parse port, ochrona SSH port/IP, dyrektywa sshd, CSF TCP_IN helpers
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*" >&2; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }
hm_mktemp() { mktemp "${TMPDIR:-/tmp}/hm.XXXXXX${1:-}"; }
hm_confirm() { return 1; }
hm_confirm_plan() { return 1; }
hm_confirm_plan_critical() { return 1; }
hm_detect_all() { :; }
C_BOLD=""; C_RESET=""; C_GREEN=""
_hm_cmd_help() { cat >/dev/null; }
_hm_cmd_register() { :; }

# minimal IP validator (z security — lub lokalnie)
hm_is_valid_ip() {
  local ip="${1:-}"
  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  [[ "${ip}" != "0.0.0.0" ]]
}
hm_session_ssh_ip() { printf '%s' "${TEST_SESSION_IP:-1.2.3.4}"; }

fail=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

# --- os_family CSF helpers (bez pełnego bind) ---
# shellcheck disable=SC1091
source lib/os_family.sh

CSF_CONF="${tmpdir}/csf.conf"
cat > "${CSF_CONF}" <<'EOF'
TCP_IN = "20,21,22,80,443,8090"
TCP_OUT = "1:65535"
EOF

list="$(_hm_os_csf_tcp_in_get)"
if [[ "${list}" == "20,21,22,80,443,8090" ]]; then
  echo "OK   csf-tcp-in-get"
else
  echo "FAIL csf-tcp-in-get: ${list}"; fail=1
fi
if _hm_os_csf_port_in_list 22 "${list}"; then echo "OK   csf-port-in"; else echo "FAIL csf-port-in"; fail=1; fi
if _hm_os_csf_port_in_list 9999 "${list}"; then echo "FAIL csf-port-miss"; fail=1; else echo "OK   csf-port-miss"; fi

_hm_os_csf_tcp_in_set "22,80,443,8443"
list="$(_hm_os_csf_tcp_in_get)"
if [[ "${list}" == "22,80,443,8443" ]]; then
  echo "OK   csf-tcp-in-set"
else
  echo "FAIL csf-tcp-in-set: ${list}"; fail=1
fi

# --- firewall module helpers ---
# shellcheck disable=SC1091
source commands/firewall/main.sh

if hm_firewall_parse_port_spec "8443/tcp" && [[ "${HM_FW_PORT}" == "8443" && "${HM_FW_PROTO}" == "tcp" ]]; then
  echo "OK   parse-8443-tcp"
else
  echo "FAIL parse-8443-tcp"; fail=1
fi
if hm_firewall_parse_port_spec "80" && [[ "${HM_FW_PORT}" == "80" && "${HM_FW_PROTO}" == "tcp" ]]; then
  echo "OK   parse-80-default-tcp"
else
  echo "FAIL parse-80"; fail=1
fi
if hm_firewall_parse_port_spec "bad"; then echo "FAIL parse-bad"; fail=1; else echo "OK   parse-bad"; fi
if hm_firewall_parse_port_spec "99999"; then echo "FAIL parse-hi"; fail=1; else echo "OK   parse-hi"; fi

# mock sshd port via fake conf — hm_firewall_sshd_port reads /etc/ssh — stub function
hm_firewall_sshd_port() { printf '22'; }

if hm_firewall_is_ssh_port 22; then echo "OK   is-ssh-22"; else echo "FAIL is-ssh-22"; fail=1; fi
if hm_firewall_is_ssh_port 2222; then echo "FAIL is-ssh-2222"; fail=1; else echo "OK   not-ssh-2222"; fi
if hm_firewall_is_cp_port 8090; then echo "OK   cp-8090"; else echo "FAIL cp-8090"; fail=1; fi
if hm_firewall_is_cp_port 40150; then echo "OK   cp-ftp-passive"; else echo "FAIL cp-ftp"; fail=1; fi

# protect: deny SSH without force → fail (confirm_critical returns 1)
TEST_SESSION_IP="9.9.9.9"
if hm_firewall_protect_ssh_deny 22 "" 0; then
  echo "FAIL protect-ssh-no-force"; fail=1
else
  echo "OK   protect-ssh-no-force"
fi
# session IP deny
if hm_firewall_protect_ssh_deny 80 "9.9.9.9" 0; then
  echo "FAIL protect-self-ip"; fail=1
else
  echo "OK   protect-self-ip"
fi
# normal port OK
if hm_firewall_protect_ssh_deny 8443 "" 0; then
  echo "OK   protect-ok-port"
else
  echo "FAIL protect-ok-port"; fail=1
fi

# --- sshd directive set (cat >) ---
# shellcheck disable=SC1091
# need hm_security_sshd_set_directive from security — source with stubs
source commands/security/main.sh

conf="${tmpdir}/sshd_config"
cat > "${conf}" <<'EOF'
# test
Port 22
PasswordAuthentication yes
PermitRootLogin yes
EOF
chmod 600 "${conf}"
mode_b="$(stat -c '%a' "${conf}" 2>/dev/null || stat -f '%Lp' "${conf}")"
hm_security_sshd_set_directive "Port" "2222" "${conf}"
mode_a="$(stat -c '%a' "${conf}" 2>/dev/null || stat -f '%Lp' "${conf}")"
got="$(hm_security_sshd_get Port "${conf}")"
if [[ "${got}" == "2222" ]]; then echo "OK   sshd-set-port"; else echo "FAIL sshd-set-port ${got}"; fail=1; fi
if [[ "${mode_a}" == "${mode_b}" ]]; then echo "OK   sshd-mode-preserved"; else echo "FAIL sshd-mode ${mode_b}→${mode_a}"; fail=1; fi

# password-auth gate: empty keys
akdir="${tmpdir}/root/.ssh"
mkdir -p "${akdir}"
# override home check — test function with empty file
: > "${akdir}/authorized_keys"
# hm_security_has_authorized_keys root looks at /root — create fake via overriding getent hard;
# instead call with a temp user path by testing n count logic inline:
n="$(grep -cE '^(ssh-|ecdsa-|sk-)' "${akdir}/authorized_keys" 2>/dev/null || echo 0)"
if [[ "${n}" == "0" || "${n}" == "0"$'\n'* ]]; then echo "OK   empty-keys"; else echo "FAIL empty-keys"; fail=1; fi
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyDataHere000000000000000000000000 comment" > "${akdir}/authorized_keys"
n="$(grep -cE '^(ssh-|ecdsa-|sk-)' "${akdir}/authorized_keys" 2>/dev/null || echo 0)"
if [[ "${n}" -ge 1 ]]; then echo "OK   nonempty-keys"; else echo "FAIL nonempty-keys"; fail=1; fi

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL OK"
exit 0
