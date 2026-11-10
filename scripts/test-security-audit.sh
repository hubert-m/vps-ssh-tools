#!/usr/bin/env bash
# security audit: czysty Ubuntu+CyberPanel bez FAIL, score, --fix nie rusza sshd.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"
# shellcheck disable=SC1091
source lib/common/ui.sh
# shellcheck disable=SC1091
source lib/site/php.sh
hm_file_log_ui() { :; }
_hm_cmd_help() { cat >/dev/null; }
_hm_cmd_register() { :; }
hm_confirm_plan() { return "${HM_CONFIRM_RC:-0}"; }

fail=0
ok() { echo "OK   $*"; }
bad() { echo "FAIL $*"; fail=1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hmtools-audit.XXXXXX")"

cat > "${TMP}/sshd" <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication yes
MaxAuthTries 4
EOF
cat > "${TMP}/sysctl" <<'EOF'
kernel.randomize_va_space = 2
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.tcp_syncookies = 1
EOF
printf '%s\n' '/usr/bin/sudo' '/usr/bin/passwd' > "${TMP}/suid"
: > "${TMP}/ww"
printf '%s\n' '0.0.0.0:22' '0.0.0.0:80' '0.0.0.0:443' '0.0.0.0:8090' > "${TMP}/listen"
printf '%s\t%s\t%s\t%s\n' '8.4' 'Off' '/home' 'Off' > "${TMP}/php"

export HM_SEC_AUDIT_SSHD="${TMP}/sshd"
export HM_SEC_AUDIT_SYSCTL="${TMP}/sysctl"
export HM_SEC_AUDIT_SHADOW_MODE=640
export HM_SEC_AUDIT_SUID="${TMP}/suid"
export HM_SEC_AUDIT_WW="${TMP}/ww"
export HM_SEC_AUDIT_LISTEN="${TMP}/listen"
export HM_SEC_AUDIT_SEC_UPDATES=0
export HM_SEC_AUDIT_REBOOT=no
export HM_SEC_AUDIT_PHP="${TMP}/php"
export HM_SEC_AUDIT_F2B=active
export HM_SEC_AUDIT_FW=active
export HM_SEC_AUDIT_SYSCTL_OUT="${TMP}/99-hmtools-audit.conf"

# shellcheck disable=SC1091
source commands/security/audit.sh

js="$(cmd_security_audit --json)" || true
printf '%s\n' "${js}" | grep -q '"score":' && ok "json score" || bad "brak score"
printf '%s\n' "${js}" | grep -q '"id":"ssh-root"' && ok "id" || bad "brak id"
printf '%s\n' "${js}" | grep -q '"weight":' && ok "waga" || bad "brak wagi"
printf '%s\n' "${js}" | grep -q '"status":"PASS"' && ok "PASS" || bad "brak PASS"
printf '%s\n' "${js}" | grep -q 'security ssh set' && ok "komenda naprawy" || bad "brak naprawy"
if printf '%s\n' "${js}" | grep -q '"status":"FAIL"'; then
  bad "fałszywy FAIL na czystym fixture CyberPanel"
  printf '%s\n' "${js}"
else
  ok "czysty fixture bez FAIL"
fi
only="$(cmd_security_audit --json --only ssh)" || true
if printf '%s\n' "${only}" | grep -q '"group":"kernel"'; then
  bad "--only ssh puścił kernel"
else
  ok "--only ssh"
fi

cp "${TMP}/sshd" "${TMP}/sshd.before"
if cmd_security_audit --fix ssh-root --yes >/dev/null 2>&1; then
  bad "--fix ssh-root nie powinno się udać"
else
  ok "--fix ssh odrzucone"
fi
if cmp -s "${TMP}/sshd" "${TMP}/sshd.before"; then
  ok "sshd bez zmian"
else
  bad "sshd zostało zmienione"
fi

HM_CONFIRM_RC=0
cmd_security_audit --fix kernel-aslr --yes >/dev/null
grep -q 'kernel.randomize_va_space = 2' "${TMP}/99-hmtools-audit.conf" && ok "fix sysctl" || bad "brak drop-in sysctl"
cmp -s "${TMP}/sshd" "${TMP}/sshd.before" && ok "fix sysctl nie ruszył sshd" || bad "sysctl fix ruszył sshd"

# zły stan: EOL, display_errors, baza na 0.0.0.0, world-writable /etc
printf '%s\t%s\t%s\t%s\n' '7.4' 'On' '-' 'On' > "${TMP}/php"
printf '%s\n' '0.0.0.0:3306' > "${TMP}/listen"
printf '%s\n' '/etc/cron.d/evil' > "${TMP}/ww"
export HM_SEC_AUDIT_SEC_UPDATES=3
export HM_SEC_AUDIT_FW=off
badjs="$(cmd_security_audit --json)" || true
printf '%s\n' "${badjs}" | grep -q '"status":"FAIL"' && ok "FAIL na złym stanie" || bad "brak FAIL"
score="$(printf '%s\n' "${badjs}" | sed -n 's/.*"score":\([0-9]*\).*/\1/p')"
if [[ "${score}" =~ ^[0-9]+$ && "${score}" -le 100 ]]; then
  ok "score ${score} w zakresie"
else
  bad "score=${score}"
fi

rm -rf "${TMP}"
if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
