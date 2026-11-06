#!/usr/bin/env bash
# Regresja: mail diag — parse queue, delete --from exact, log domain, DNSBL rev, DKIM compare
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_have_cmd() {
  case "$1" in
    postqueue|postsuper|dig|openssl|ss|nc|postconf|opendkim-genkey|systemctl|curl) return 1 ;;
    timeout) return 1 ;;
    *) command -v "$1" >/dev/null 2>&1 ;;
  esac
}
hm_mktemp() { mktemp "${TMPDIR:-/tmp}/hm.XXXXXX${1:-}"; }
hm_confirm_plan() { return 0; }
hm_confirm_plan_critical() { return 0; }
hm_run_timeout() { shift; "$@"; }
hm_help_topic() { :; }
hm_is_valid_domain() { [[ "$1" == *.* ]]; }
hm_file_log() { :; }
hm_detect_all() { :; }
C_BOLD=""; C_RESET=""; C_DIM=""; C_CYAN=""; C_RED=""; C_GREEN=""; C_YELLOW=""
_hm_cmd_help() { cat >/dev/null; }
_hm_cmd_register() { :; }

fail=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

# mock postqueue/postsuper
mkdir -p "${tmpdir}/bin"
cat > "${tmpdir}/bin/postqueue" <<'EOF'
#!/bin/sh
if [ "$1" = "-j" ]; then
  cat <<'JSON'
{"queue_id":"ABC123","sender":"spam@example.pl","message_size":100,"recipients":[{"address":"a@other.com","delay_reason":"host said 421"}]}
{"queue_id":"DEF456","sender":"ok@other.pl","message_size":50,"recipients":[{"address":"b@example.pl","delay_reason":"deferred"}]}
{"queue_id":"GHI789","sender":"spam@example.pl","message_size":80,"recipients":[{"address":"c@x.com","delay_reason":"timeout"}]}
JSON
  exit 0
fi
if [ "$1" = "-p" ]; then echo "Mail queue is empty"; exit 0; fi
if [ "$1" = "-f" ]; then exit 0; fi
exit 0
EOF
chmod +x "${tmpdir}/bin/postqueue"

DELETED="${tmpdir}/deleted.txt"
: > "${DELETED}"
cat > "${tmpdir}/bin/postsuper" <<EOF
#!/bin/sh
echo "\$2" >> "${DELETED}"
exit 0
EOF
chmod +x "${tmpdir}/bin/postsuper"

# dig mock — controlled answers
cat > "${tmpdir}/bin/dig" <<'EOF'
#!/bin/sh
# dig +short TXT name / MX / -x / A for dnsbl
args="$*"
case "$*" in
  *TXT*example.pl*)
    echo '"v=spf1 ip4:203.0.113.10 -all"'
    ;;
  *TXT*default._domainkey.example.pl*)
    echo '"v=DKIM1; k=rsa; p=AAAABBBB"'
    ;;
  *TXT*_dmarc.example.pl*)
    echo '"v=DMARC1; p=none"'
    ;;
  *MX*example.pl*)
    echo "10 mail.example.pl."
    ;;
  *-x*203.0.113.10*)
    echo "mail.example.pl."
    ;;
  *10.113.0.203.zen.spamhaus.org*)
    echo "127.0.0.2"
    ;;
  *10.113.0.203.*)
    # other lists clean
    ;;
  *myip.opendns.com*)
    echo "203.0.113.10"
    ;;
esac
exit 0
EOF
chmod +x "${tmpdir}/bin/dig"

export PATH="${tmpdir}/bin:${PATH}"

# force have_cmd for our mocks
hm_have_cmd() {
  case "$1" in
    postqueue|postsuper|dig) return 0 ;;
    openssl|ss|nc|postconf|opendkim-genkey|systemctl|curl|timeout) return 1 ;;
    *) command -v "$1" >/dev/null 2>&1 ;;
  esac
}

# shellcheck disable=SC1091
source commands/mail/diag.sh

# --- queue parse ---
n="$(hm_mail_queue_parse | wc -l | tr -d ' ')"
if [[ "${n}" -eq 3 ]]; then
  echo "OK   queue-parse-3"
else
  echo "FAIL queue-parse (${n})"
  fail=1
fi

# --- delete --from exact (tylko spam@example.pl → 2 qid) ---
hm_mail_have_postfix() { return 0; }
hm_mail_queue_delete --from spam@example.pl --yes >/dev/null
# postsuper -d QID → script gets $2 as qid when called as postsuper -d ID
# our mock: echo "$2" — with `postsuper -d ABC` → $1=-d $2=ABC ✓
cnt="$(wc -l < "${DELETED}" | tr -d ' ')"
if [[ "${cnt}" -eq 2 ]] && grep -q ABC123 "${DELETED}" && grep -q GHI789 "${DELETED}" \
  && ! grep -q DEF456 "${DELETED}"; then
  echo "OK   delete-from-exact"
else
  echo "FAIL delete-from-exact (cnt=${cnt})"
  cat "${DELETED}"
  fail=1
fi

# --- delete QID: odmowa ALL / nieistniejący ---
: > "${DELETED}"
set +e
hm_mail_queue_delete ALL --yes >/dev/null 2>"${tmpdir}/del-all.err"
rc_all=$?
hm_mail_queue_delete nonexist-qid --yes >/dev/null 2>"${tmpdir}/del-miss.err"
rc_miss=$?
set -e
if [[ "${rc_all}" -ne 0 && "${rc_miss}" -ne 0 ]] \
  && [[ ! -s "${DELETED}" ]] \
  && grep -qi 'Nieprawidłowy QID\|ALL' "${tmpdir}/del-all.err" \
  && grep -qi 'Brak wiadomości\|QID' "${tmpdir}/del-miss.err"; then
  echo "OK   delete-qid-validate"
else
  echo "FAIL delete-qid-validate rc=${rc_all}/${rc_miss}"
  cat "${tmpdir}/del-all.err" "${tmpdir}/del-miss.err" "${DELETED}" 2>/dev/null || true
  fail=1
fi

# --- mail check bez dig: pominięto, nie „Brak SPF” ---
hm_have_cmd() {
  case "$1" in
    postqueue|postsuper) return 0 ;;
    dig) return 1 ;;
    *) return 1 ;;
  esac
}
chk="$(hm_mail_check_cmd example.pl 2>&1 || true)"
if printf '%s\n' "${chk}" | grep -qi 'pominięto (brak dig)' \
  && ! printf '%s\n' "${chk}" | grep -q 'Brak SPF' \
  && ! printf '%s\n' "${chk}" | grep -q 'Brak DMARC' \
  && ! printf '%s\n' "${chk}" | grep -q 'Brak TXT default'; then
  echo "OK   check-no-dig-skip"
else
  echo "FAIL check-no-dig-skip"
  printf '%s\n' "${chk}" | head -40
  fail=1
fi
# przywróć dig w have_cmd
hm_have_cmd() {
  case "$1" in
    postqueue|postsuper|dig) return 0 ;;
    openssl|ss|nc|postconf|opendkim-genkey|systemctl|curl|timeout) return 1 ;;
    *) command -v "$1" >/dev/null 2>&1 ;;
  esac
}

# --- log domain filter exact ---
logf="${tmpdir}/mail.log"
cat > "${logf}" <<'EOF'
status=bounced to=<a@example.pl>
status=sent to=<b@evil-example.pl>
status=deferred to=<c@sub.example.pl>
status=bounced to=<d@example.pl>
EOF
hm_mail_log_file() { printf '%s' "${logf}"; }
out="$(hm_mail_log_cmd 50 --domain example.pl --bounced 2>/dev/null | grep status= || true)"
if printf '%s\n' "${out}" | grep -q 'a@example.pl' \
  && printf '%s\n' "${out}" | grep -q 'd@example.pl' \
  && ! printf '%s\n' "${out}" | grep -q 'evil-example' \
  && ! printf '%s\n' "${out}" | grep -q 'sub.example'; then
  echo "OK   log-domain-exact"
else
  echo "FAIL log-domain-exact"
  printf '%s\n' "${out}"
  fail=1
fi

# --- reverse octets ---
rev="$(hm_mail_reverse_octets 203.0.113.10)"
if [[ "${rev}" == "10.113.0.203" ]]; then
  echo "OK   reverse-octets"
else
  echo "FAIL reverse-octets (${rev})"
  fail=1
fi

# --- DKIM extract ---
kf="${tmpdir}/default.txt"
printf 'default._domainkey IN TXT ( "v=DKIM1; k=rsa; " "p=AAAABBBB" )\n' > "${kf}"
p="$(hm_mail_extract_p_from_txtfile "${kf}")"
if [[ "${p}" == "AAAABBBB" ]]; then
  echo "OK   dkim-extract-p"
else
  echo "FAIL dkim-extract-p (${p})"
  fail=1
fi

# --- blacklist lists zen ---
hm_mail_public_ipv4() { printf '203.0.113.10'; }
bl="$(hm_mail_blacklist_cmd 2>/dev/null || true)"
if printf '%s\n' "${bl}" | grep -qi 'LISTED' && printf '%s\n' "${bl}" | grep -q spamhaus; then
  echo "OK   blacklist-listed"
else
  echo "FAIL blacklist-listed"
  printf '%s\n' "${bl}" | head -20
  fail=1
fi

# --- warn without postfix (no crash) ---
hm_mail_have_postfix() { return 1; }
if hm_mail_queue_cmd 2>/dev/null; then
  echo "OK   queue-no-postfix-warn"
else
  echo "FAIL queue-no-postfix-warn"
  fail=1
fi

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED=${fail}"
  exit 1
fi
echo "ALL OK"
exit 0
