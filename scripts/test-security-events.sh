#!/usr/bin/env bash
# security events: Debian i RHEL auth, dedup, authorized_keys, bez sekretów.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

# shellcheck disable=SC1091
source lib/common/ui.sh
hm_file_log_ui() { :; }
_hm_cmd_help() { cat >/dev/null; }
_hm_cmd_register() { :; }

fail=0
ok() { echo "OK   $*"; }
bad() { echo "FAIL $*"; fail=1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hmtools-secev.XXXXXX")"
export HM_SEC_EVENTS_STATE="${TMP}/state"
export HM_SEC_EVENTS_LOG="${TMP}/auth.log"
export HM_SEC_EVENTS_HOST="vps-test"
export HM_SEC_EVENTS_NOW="2026-11-10 18:00:00"
export HM_SEC_EVENTS_WHITELIST="${TMP}/whitelist"
export HM_SEC_EVENTS_GEOIP="${TMP}/geo"
export HM_SEC_EVENTS_PASSWD="${TMP}/passwd"
export HM_SEC_EVENTS_SHADOW="${TMP}/shadow"
export HM_SEC_EVENTS_SUDOERS="${TMP}/sudoers"
export HM_SEC_EVENTS_PORTS="${TMP}/ports"
export HM_SEC_EVENTS_BANS="${TMP}/bans"
export HM_SEC_EVENTS_CRON="${TMP}/cron"
export HM_SEC_EVENTS_NOTIFY=0

printf '%s\n' '203.0.113.50' > "${TMP}/whitelist"
printf '%s %s\n' '203.0.113.10' 'PL' > "${TMP}/geo"

ROOTHOME="${TMP}/home-root"
ALICE="${TMP}/home-alice"
mkdir -p "${ROOTHOME}/.ssh" "${ALICE}/.ssh"
printf '%s\n' 'ssh-ed25519 AAAACALM root' > "${ROOTHOME}/.ssh/authorized_keys"
printf '%s\n' 'ssh-ed25519 AAAACALM alice' > "${ALICE}/.ssh/authorized_keys"
cat > "${TMP}/passwd" <<EOF
root:x:0:0:root:${ROOTHOME}:/bin/bash
alice:x:1000:1000:Alice:${ALICE}:/bin/bash
EOF
printf '%s\n' 'root:$6$SECRETSHADOW$aaa' > "${TMP}/shadow"
printf '%s\n' 'root ALL=(ALL) ALL' > "${TMP}/sudoers"
printf '%s\n' '22' > "${TMP}/ports"
printf '%s\n' '10' > "${TMP}/bans"

# Debian (Accepted, sudo z hasłem w argv, useradd) i RHEL (session opened, su).
cat > "${TMP}/auth.log" <<'EOF'
Jan  1 00:00:01 vps sshd[1]: Accepted password for eve from 192.0.2.9 port 22 ssh2
Nov 10 14:00:01 vps sshd[2]: Accepted publickey for root from 203.0.113.10 port 22 ssh2
Nov 10 14:01:01 vps sshd[3]: Accepted password for alice from 198.51.100.8 port 22 ssh2
Nov 10 14:02:01 vps sudo: alice : TTY=pts/0 ; PWD=/root ; USER=root ; COMMAND=/usr/bin/mysql -pSECRET99
Nov 10 14:03:01 vps useradd[9]: new user: name=bob, UID=1002, GID=1002, home=/home/bob, shell=/bin/bash
Nov 10 14:04:01 vps sshd[4]: Accepted publickey for deploy from 203.0.113.50 port 22 ssh2
Nov 10 14:05:01 vps sudo: pam_unix(sudo:session): session opened for user root by deploy(uid=1001)
Nov 10 14:06:01 vps su: (to root) deploy on pts/1
EOF

NOTIFY="${TMP}/notify"
hm_notify() { printf '%s\n' "$*" >> "${NOTIFY}"; }

# shellcheck disable=SC1091
source commands/security/events.sh

rm -f "${NOTIFY}"
out1="$(cmd_security_events watch run)" || true
printf '%s\n' "${out1}" | grep -q 'ssh-root' && ok "logowanie roota" || bad "brak ssh-root"
printf '%s\n' "${out1}" | grep -q '198.51.100.8' && ok "nowe IP" || bad "brak nowego IP"
if printf '%s\n' "${out1}" | grep -q '203.0.113.50'; then
  bad "IP z whitelist jako nowe"
else
  ok "whitelist nie jest nowym IP"
fi
printf '%s\n' "${out1}" | grep -q $'\tsudo\talice\t' && ok "sudo Debian" || bad "brak sudo Debian"
printf '%s\n' "${out1}" | grep -q $'\tsudo\tdeploy\t' && ok "sudo RHEL" || bad "brak sudo RHEL"
printf '%s\n' "${out1}" | grep -q $'\tsu\tdeploy\t' && ok "su" || bad "brak su"
printf '%s\n' "${out1}" | grep -q 'bob' && ok "useradd" || bad "brak useradd"
printf '%s\n' "${out1}" | grep -q 'PL' && ok "geoip" || bad "brak kraju"
printf '%s\n' "${out1}" | grep -q 'vps-test' && ok "host" || bad "brak hosta"
if printf '%s\n' "${out1}" | grep -q '192.0.2.9'; then
  bad "zdarzenie spoza 24h"
else
  ok "okno 24h"
fi
blob="$(printf '%s\n' "${out1}"; cat "${NOTIFY}" 2>/dev/null || true)"
if printf '%s\n' "${blob}" | grep -q 'SECRET99'; then
  bad "sekret z sudo w alercie"
else
  ok "brak sekretu sudo"
fi
if printf '%s\n' "${blob}" | grep -q 'SECRETSHADOW'; then
  bad "sekret z shadow w alercie"
else
  ok "brak sekretu shadow"
fi
n1="$(grep -c 'ssh-new-ip' <<< "${out1}" || true)"

rm -f "${NOTIFY}"
out2="$(cmd_security_events watch run)" || true
if printf '%s\n' "${out2}" | grep -q '198.51.100.8'; then
  bad "to samo zdarzenie drugi raz"
else
  ok "dedup logu"
fi
[[ ! -s "${NOTIFY}" ]] && ok "brak drugiego notify" || bad "notify powtórzone"

printf '%s\n' 'Nov 10 16:00:01 vps sshd[8]: Accepted publickey for carol from 203.0.113.77 port 22 ssh2' >> "${TMP}/auth.log"
out3="$(cmd_security_events watch run)" || true
printf '%s\n' "${out3}" | grep -q '203.0.113.77' && ok "tylko nowy fragment logu" || bad "offset nie przepuścił nowej linii"
if printf '%s\n' "${out3}" | grep -q '198.51.100.8'; then
  bad "offset powtórzył stary wpis"
else
  ok "offset bez starego wpisu"
fi

printf '%s\n' 'ssh-ed25519 AAAACALM root2 SECRETKEY' > "${ROOTHOME}/.ssh/authorized_keys"
printf '%s\n' 'ssh-ed25519 AAAACALM alice2' > "${ALICE}/.ssh/authorized_keys"
cat > "${TMP}/passwd" <<EOF
root:x:0:0:root:${ROOTHOME}:/bin/bash
toor:x:0:0:toor:${TMP}/toor:/bin/bash
alice:x:1000:1000:Alice:${ALICE}:/bin/bash
EOF
printf '%s\n' 'root:$6$SECRETSHADOW$bbb' > "${TMP}/shadow"
printf '%s\n' '22' > "${TMP}/ports"
printf '%s\n' '3306' >> "${TMP}/ports"
printf '%s\n' '80' > "${TMP}/bans"
rm -f "${NOTIFY}"
out4="$(cmd_security_events watch run)" || true
printf '%s\n' "${out4}" | grep -q $'\tkeys\troot\t' && ok "klucze roota" || bad "brak kluczy roota"
printf '%s\n' "${out4}" | grep -q $'\tkeys\talice\t' && ok "klucze usera strony" || bad "brak kluczy alice"
printf '%s\n' "${out4}" | grep -q $'\tuid0\ttoor\t' && ok "drugi uid 0" || bad "brak uid 0"
printf '%s\n' "${out4}" | grep -q '3306' && ok "nowy port" || bad "brak portu"
printf '%s\n' "${out4}" | grep -q 'skok banów' && ok "skok banów" || bad "brak banów"
printf '%s\n' "${out4}" | grep -q "${TMP}/shadow" && ok "zmiana shadow" || bad "brak zmiany shadow"
blob4="$(printf '%s\n' "${out4}"; cat "${NOTIFY}" 2>/dev/null || true)"
if printf '%s\n' "${blob4}" | grep -q 'SECRETSHADOW\|SECRETKEY'; then
  bad "sekret pliku w alercie"
else
  ok "hash pliku bez treści"
fi

out5="$(cmd_security_events watch run)" || true
if printf '%s\n' "${out5}" | grep -q $'\tkeys\troot\t'; then
  bad "klucze zgłoszone drugi raz"
else
  ok "dedup kluczy"
fi

cmd_security_events watch install >/dev/null
grep -q 'hmtools-security-events' "${HM_SEC_EVENTS_CRON}" && ok "watch install" || bad "cron"
cmd_security_events watch disable >/dev/null
[[ ! -f "${HM_SEC_EVENTS_CRON}" ]] && ok "watch disable" || bad "cron został"

rm -rf "${TMP}"
# n1 użyte tylko jako ślad, że pierwsza seria coś znalazła
[[ "${n1}" -ge 1 ]] || bad "licznik ssh-new-ip"

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
