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
cat > "${root}/xxe.xml" <<'EOF'
<!DOCTYPE foo [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
<source_ip>&xxe;</source_ip>
EOF
if cmd_mail dmarc report "${root}/xxe.xml" >/dev/null 2>&1; then bad dmarc-xxe; else ok dmarc-xxe; fi
dd if=/dev/zero bs=1024 count=1100 of="${root}/big.xml" status=none 2>/dev/null || dd if=/dev/zero bs=1024 count=1100 of="${root}/big.xml" >/dev/null
if cmd_mail dmarc report "${root}/big.xml" >/dev/null 2>&1; then bad dmarc-size; else ok dmarc-size; fi

[[ "${fail}" -eq 0 ]] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
