#!/usr/bin/env bash
# monitor http: 200/500/timeout/pętla, jeden alert, powrót, brak sekretu w logu.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hmtools-mon-test.XXXXXX")"
fail=0
ok() { echo "OK   $*"; }
bad() { echo "FAIL $*"; fail=1; }

_hm_cmd_help() { cat >/dev/null; }
_hm_cmd_register() { :; }
hm_err() { echo "$*" >&2; }
hm_confirm_plan() { return 0; }
hm_notify() { printf '%s\n' "$*" >> "${HM_NOTIFY_LOG}"; }

export HM_MONITOR_DIR="${TMP}/mon"
export HM_MONITOR_CRON="${TMP}/cron/hmtools-monitor"
export HM_MONITOR_LOG="${TMP}/mon.log"
export HM_NOTIFY_LOG="${TMP}/notify.log"
export HM_MONITOR_CURL="${TMP}/curl.sh"
export HM_MONITOR_FIXTURES="${TMP}/fix"
export LOG_DIR="${TMP}/logs"
mkdir -p "${HM_MONITOR_FIXTURES}" "${LOG_DIR}" "$(dirname "${HM_MONITOR_CRON}")"
: > "${HM_NOTIFY_LOG}"
: > "${HM_MONITOR_LOG}"

cat > "${HM_MONITOR_CURL}" <<'EOF'
#!/usr/bin/env bash
resolve=""
out=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --resolve)
      resolve="$2"
      shift 2
      ;;
    --max-time) shift 2 ;;
    --output)
      out="$2"
      shift 2
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done
printf '%s resolve=%s\n' "${url}" "${resolve}" >> "${HM_MONITOR_LOG}.curl"
host="${url#*://}"
host="${host%%/*}"
host="${host%%:*}"
spec="${HM_MONITOR_FIXTURES}/${host}"
if [[ ! -f "${spec}" ]]; then
  echo "0 0 0 0"
  exit 28
fi
IFS=' ' read -r rc code secs redirs tls < "${spec}"
tail -n +2 "${spec}" > "${out}"
printf '%s %s %s %s\n' "${code}" "${secs}" "${redirs}" "${tls}"
exit "${rc}"
EOF

fix() {
  local host="$1" rc="$2" code="$3" secs="$4" redirs="$5" tls="$6" body="$7"
  printf '%s %s %s %s %s\n%s\n' "${rc}" "${code}" "${secs}" "${redirs}" "${tls}" "${body}" > "${HM_MONITOR_FIXTURES}/${host}"
}

fix example.pl 0 200 0.020 1 40 "hello from page"
fix bad.pl 0 500 0.050 0 12 "hello"
fix loop.pl 0 301 0.010 5 20 "redirect"
fix tout.pl 28 0 0 0 0 ""
fix kw.pl 0 200 0.010 0 30 "nope"
fix secret.pl 0 200 0.015 0 60 "hello"

# shellcheck disable=SC1091
source commands/monitor/main.sh

cmd_monitor add example.pl --keyword hello --expect 200 --fails 2 >/dev/null
cmd_monitor add bad.pl --expect 200 --fails 2 >/dev/null
cmd_monitor add loop.pl --expect 200 --fails 1 >/dev/null
cmd_monitor add tout.pl --expect 200 --fails 2 >/dev/null
cmd_monitor add kw.pl --keyword hello --expect 200 --fails 2 >/dev/null
cmd_monitor add secret.pl --keyword hello --expect 200 --fails 2 \
  --url 'https://user:s3cret@secret.pl/' >/dev/null

js="$(cmd_monitor http example.pl --json)" || true
printf '%s\n' "${js}" | grep -q '"status":"OK"' && ok "200 OK" || bad "200: ${js}"
printf '%s\n' "${js}" | grep -q '"code":"200"' && ok "kod w json" || bad "brak kodu"
grep -q 'example.pl:443:127.0.0.1' "${HM_MONITOR_LOG}.curl" && bad "resolve bez flagi" || true
: > "${HM_MONITOR_LOG}.curl"
cmd_monitor http example.pl --resolve --json >/dev/null || true
grep -q 'example.pl:443:127.0.0.1' "${HM_MONITOR_LOG}.curl" && ok "--resolve lokalny" || bad "brak resolve"

if cmd_monitor http bad.pl >/dev/null; then
  bad "500 przeszło"
else
  ok "500 FAIL"
fi
n="$(grep -c 'error monitor http' "${HM_NOTIFY_LOG}" || true)"
[[ "${n}" == "0" ]] && ok "pierwsza porażka bez alertu" || bad "alert za wcześnie (${n})"
if cmd_monitor http bad.pl >/dev/null; then bad "500 #2 przeszło"; else ok "500 #2"; fi
if cmd_monitor http bad.pl >/dev/null; then bad "500 #3 przeszło"; else ok "500 #3"; fi
n="$(grep -c 'error monitor http' "${HM_NOTIFY_LOG}" || true)"
[[ "${n}" == "1" ]] && ok "jeden alert" || bad "alertów=${n}"

fix bad.pl 0 200 0.020 0 12 "hello"
if cmd_monitor http bad.pl >/dev/null; then
  ok "powrót OK"
else
  bad "powrót nadal FAIL"
fi
grep -q 'wróciło' "${HM_NOTIFY_LOG}" && ok "komunikat wróciło" || bad "brak wróciło"

loop_out="$(cmd_monitor http loop.pl --json || true)"
printf '%s\n' "${loop_out}" | grep -q 'pętla przekierowań' && ok "pętla FAIL" || bad "pętla: ${loop_out}"
tout_out="$(cmd_monitor http tout.pl --json || true)"
printf '%s\n' "${tout_out}" | grep -q 'timeout' && ok "timeout FAIL" || bad "timeout: ${tout_out}"
kw_out="$(cmd_monitor http kw.pl --json || true)"
printf '%s\n' "${kw_out}" | grep -q 'brak keyword' && ok "keyword FAIL" || bad "keyword: ${kw_out}"

sec_out="$(cmd_monitor http secret.pl --json || true)"
list_out="$(cmd_monitor list || true)"
printf '%s\n' "${sec_out}" | grep -q '"status":"OK"' && ok "basic auth sprawdza stronę" || bad "secret check: ${sec_out}"
printf '%s\n' "${list_out}" | grep -q 'auth=yes' && ok "lista bez hasła (auth=yes)" || bad "lista: ${list_out}"
if printf '%s\n' "${sec_out}" "${list_out}" | grep -q 's3cret'; then
  bad "sekret w wyjściu"
else
  ok "sekret poza wyjściem"
fi
if grep -q 's3cret' "${HM_NOTIFY_LOG}" "${HM_MONITOR_LOG}" "${HM_MONITOR_LOG}.curl" "${HM_MONITOR_DIR}/latest.txt" 2>/dev/null; then
  bad "sekret w logu lub raporcie"
else
  ok "sekret poza logiem"
fi
if grep -q 's3cret' "${HM_MONITOR_DIR}/config/secret.pl"; then
  ok "sekret tylko w config"
else
  bad "config nie ma url"
fi

cmd_monitor watch install >/dev/null
grep -q 'monitor http --quiet' "${HM_MONITOR_CRON}" && ok "cron 5 min" || bad "brak crona"
cmd_monitor watch disable >/dev/null
[[ ! -f "${HM_MONITOR_CRON}" ]] && ok "cron usunięty" || bad "cron został"

rm -rf "${TMP}"
if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
