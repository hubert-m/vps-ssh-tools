#!/usr/bin/env bash
# mail spam, senders, quota, dmarc — fixture, bez haseł i bez XXE.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_have_cmd() { return 1; }
hm_confirm_plan() { return 0; }
hm_file_log() { :; }
hm_help_topic() { :; }
_hm_cmd_help() { cat >/dev/null; }
_hm_cmd_register() { :; }
_hm_cmd_register_site() { :; }
hm_notify() { printf 'notify %s\n' "$2" >> "${root}/notify"; }

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT

# shellcheck disable=SC1091
source commands/mail/main.sh

cat > "${root}/spam.txt" <<'EOF'
engine=rspamd
active=yes
version=3.8.1
ham=10
spam=2
reject=1
EOF
export HM_MAIL_SPAM_STATUS="${root}/spam.txt"
st="$(cmd_mail spam status)"
printf '%s\n' "${st}" | grep -q 'engine: rspamd' && ok spam-engine || bad spam-engine
printf '%s\n' "${st}" | grep -q 'reject: 1' && ok spam-reject || bad spam-reject

cat > "${root}/mail.log" <<'EOF'
from=<a@example.com>, sasl_username=a@example.com, password=SECRET-MAIL
from=<a@example.com>, sasl_username=a@example.com
from=<b@example.com>, sasl_username=b@example.com
EOF
export HM_MAIL_LOG="${root}/mail.log"
export HM_MAIL_SENDER_MAX=1
export HM_MAIL_DEDUP="${root}/dedup"
out="$(cmd_mail senders --since 24h)"
printf '%s\n' "${out}" | grep -q $'a@example.com\t2' && ok senders-count || bad senders-count
printf '%s\n' "${out}" | grep -q 'SECRET-MAIL' && bad senders-secret || ok senders-secret
printf '%s\n' "${out}" | grep -q 'mail passwd' && ok senders-hint || bad senders-hint
[[ "$(grep -c notify "${root}/notify" 2>/dev/null || true)" -eq 1 ]] && ok senders-dedup-first || bad senders-dedup-first
cmd_mail senders --since 24h >/dev/null
[[ "$(grep -c notify "${root}/notify" 2>/dev/null || true)" -eq 1 ]] && ok senders-dedup-second || bad senders-dedup-second
# Przyrost count nie omija dedupu (klucz = user + dzień)
printf '%s\n' 'from=<a@example.com>, sasl_username=a@example.com' >> "${root}/mail.log"
cmd_mail senders --since 24h >/dev/null
[[ "$(grep -c notify "${root}/notify" 2>/dev/null || true)" -eq 1 ]] && ok senders-dedup-grow || bad senders-dedup-grow
# grep -Fx: kropka w adresie nie jest wildcardem
printf 'aXexample.com %s\n' "$(date +%Y-%m-%d)" >> "${root}/dedup"
# nie powinno zablokować prawdziwego klucza — już zablokowany; sprawdź brak fałszywego matcha przy czystym dedup
: > "${root}/dedup2"
export HM_MAIL_DEDUP="${root}/dedup2"
printf 'evil.example.com %s\n' "$(date +%Y-%m-%d)" > "${root}/dedup2"
# a@example.com nadal alertuje na świeżym pliku
: > "${root}/notify"
cmd_mail senders >/dev/null
[[ "$(grep -c notify "${root}/notify" 2>/dev/null || true)" -ge 1 ]] && ok senders-dedup-fx || bad senders-dedup-fx
export HM_MAIL_DEDUP="${root}/dedup"

# Jedna wiadomość: sasl + qmgr from= tego samego queue ID → count 1 (nie 2)
cat > "${root}/mail-qid.log" <<'EOF'
Nov 16 12:00:01 vps postfix/smtpd[1]: ABCDE1: client=x, sasl_username=q@example.com
Nov 16 12:00:01 vps postfix/qmgr[2]: ABCDE1: from=<q@example.com>, size=10
Nov 16 12:00:02 vps postfix/qmgr[2]: FFFFFF: from=<ext@other.com>, size=20
Nov 16 12:00:03 vps postfix/pickup[3]: LOCAL1: uid=1000 from=<local@example.com>
EOF
export HM_MAIL_LOG="${root}/mail-qid.log"
export HM_MAIL_SENDER_MAX=999
: > "${root}/notify"
outq="$(cmd_mail senders)"
printf '%s\n' "${outq}" | grep -q $'q@example.com\t1' && ok senders-qid-once || bad senders-qid-once
printf '%s\n' "${outq}" | grep -q 'ext@other.com' && bad senders-no-external || ok senders-no-external
printf '%s\n' "${outq}" | grep -q $'local@example.com\t1' && ok senders-pickup || bad senders-pickup

# --since filtruje po dacie syslog (stara linia odpada)
cat > "${root}/mail-since.log" <<EOF
Jan  1 00:00:01 vps postfix/smtpd[1]: OLD001: client=x, sasl_username=old@example.com
$(date '+%b %e %H:%M:%S') vps postfix/smtpd[1]: NEW001: client=x, sasl_username=new@example.com
EOF
export HM_MAIL_LOG="${root}/mail-since.log"
outs="$(cmd_mail senders --since 24h)"
printf '%s\n' "${outs}" | grep -q 'old@example.com' && bad senders-since-old || ok senders-since-old
printf '%s\n' "${outs}" | grep -q $'new@example.com\t1' && ok senders-since-new || bad senders-since-new
export HM_MAIL_LOG="${root}/mail.log"
export HM_MAIL_SENDER_MAX=1

printf 'a@example.com\t100\t1000\nb@example.com\t950\t1000\n' > "${root}/quota"
export HM_MAIL_QUOTA="${root}/quota"
q="$(cmd_mail quota example.com)"
printf '%s\n' "${q}" | grep -q $'a@example.com\t100\t1000' && ok quota-row || bad quota-row
printf '%s\n' "${q}" | grep -q '950/1000' && ok quota-warn || bad quota-warn

cat > "${root}/dmarc.xml" <<'EOF'
<feedback>
<source_ip>203.0.113.5</source_ip>
<spf>fail</spf>
<dkim>pass</dkim>
</feedback>
EOF
rep="$(cmd_mail dmarc report "${root}/dmarc.xml")"
printf '%s\n' "${rep}" | grep -q $'203.0.113.5\tfail\tpass' && ok dmarc || bad dmarc
# Zminifikowany XML — wiele rekordów w jednej linii
printf '%s' '<feedback><source_ip>198.51.100.1</source_ip><spf>pass</spf><dkim>fail</dkim><source_ip>198.51.100.2</source_ip><spf>fail</spf><dkim>pass</dkim></feedback>' \
  > "${root}/dmarc-mini.xml"
rep2="$(cmd_mail dmarc report "${root}/dmarc-mini.xml")"
printf '%s\n' "${rep2}" | grep -q $'198.51.100.1\tpass\tfail' && ok dmarc-mini-1 || bad dmarc-mini-1
printf '%s\n' "${rep2}" | grep -q $'198.51.100.2\tfail\tpass' && ok dmarc-mini-2 || bad dmarc-mini-2
cat > "${root}/xxe.xml" <<'EOF'
<!DOCTYPE foo [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
<source_ip>&xxe;</source_ip>
EOF
if cmd_mail dmarc report "${root}/xxe.xml" >/dev/null 2>&1; then bad dmarc-xxe; else ok dmarc-xxe; fi
dd if=/dev/zero bs=1024 count=1100 of="${root}/big.xml" status=none 2>/dev/null || dd if=/dev/zero bs=1024 count=1100 of="${root}/big.xml" >/dev/null
if cmd_mail dmarc report "${root}/big.xml" >/dev/null 2>&1; then bad dmarc-size; else ok dmarc-size; fi

# Bez fixture — czytelny brak danych / domyślne ścieżki
unset HM_MAIL_SPAM_STATUS HM_MAIL_LOG HM_MAIL_QUOTA
export HM_MAIL_DEDUP="${root}/dedup-default"
export HM_MAIL_DIR="${root}/mail-state"
st2="$(cmd_mail spam status)"
printf '%s\n' "${st2}" | grep -q 'ham: brak danych' && ok spam-no-stats || bad spam-no-stats
if cmd_mail senders >/dev/null 2>&1; then bad senders-no-log; else ok senders-no-log; fi
# Domyślny log
mkdir -p "${root}/var/log"
printf 'sasl_username=c@example.com\n' > "${root}/var/log/mail.log"
# hm_mail_find_log szuka /var/log/mail.log — w teście przez HM_MAIL_LOG symulujemy default po unset:
# ustawiamy plik pod ścieżką oczekiwaną tylko gdy istnieje; tu sprawdzamy find przez HM_MAIL_LOG pusty + brak /var/log
# → już ok senders-no-log. Osobno: po wskazaniu pliku przez ścieżkę produkcyjną-like:
export HM_MAIL_LOG="${root}/var/log/mail.log"
export HM_MAIL_SENDER_MAX=0
out3="$(cmd_mail senders)"
printf '%s\n' "${out3}" | grep -q $'c@example.com\t1' && ok senders-default-path || bad senders-default-path
# Dedup domyślny powstał
[[ -f "${HM_MAIL_DEDUP}" ]] && ok dedup-default-file || bad dedup-default-file
if cmd_mail quota >/dev/null 2>&1; then bad quota-no-data; else ok quota-no-data; fi

[[ "${fail}" -eq 0 ]] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
