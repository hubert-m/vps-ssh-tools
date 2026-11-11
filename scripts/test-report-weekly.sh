#!/usr/bin/env bash
# report weekly — sekcje opcjonalne, JSON dla webhooka, brak sekretów.
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
hm_notify() { printf 'MAIL %s\n%s\n' "$2" "$3" > "${HM_REPORT_MAIL}"; }
hm_notify_send_webhook() { printf '%s\n' "$2" > "${HM_REPORT_HOOK}"; }
_hm_cmd_help() { :; }
_hm_cmd_register() { :; }

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
export HM_REPORT_CRON="${root}/cron"
export HM_REPORT_MAIL="${root}/mail"
export HM_REPORT_HOOK="${root}/hook"
export NOTIFY_WEBHOOK_URL="https://hooks.example/secret-token-VALUE"
export HM_REPORT_PASSWORD="hunter2-password"
printf 'nginx failed\n' > "${root}/svc"
printf 'backup-local 12MB OK\n' > "${root}/bak"
printf 'shop.example wygasa 10d\nA & B <C> "D"\n' > "${root}/ssl"
export HM_REPORT_SERVICES="${root}/svc"
export HM_REPORT_BACKUP="${root}/bak"
export HM_REPORT_SSL="${root}/ssl"
unset HM_REPORT_HTTP HM_REPORT_UPDATES HM_REPORT_BANS HM_REPORT_DISK HM_REPORT_STATS HM_REPORT_AUDIT || true

# shellcheck disable=SC1091
source commands/report/main.sh

text="$(cmd_report weekly)"
printf '%s\n' "${text}" | grep -q '## Usługi' && printf '%s\n' "${text}" | grep -q 'nginx failed' && ok text-svc || bad text-svc
printf '%s\n' "${text}" | grep -q 'pominięto — brak monitor http' && ok text-skip || bad text-skip
printf '%s\n' "${text}" | grep -q 'shop.example wygasa' && ok text-ssl || bad text-ssl
printf '%s\n' "${text}" | grep -Eq 'secret-token-VALUE|hunter2-password' && bad text-secret || ok text-secret

html="$(cmd_report weekly --html)"
printf '%s\n' "${html}" | grep -q '<h2>Certyfikaty</h2>' && ok html || bad html
printf '%s\n' "${html}" | grep -q 'A &amp; B &lt;C&gt; &quot;D&quot;' && ok html-escape || bad html-escape
printf '%s\n' "${text}" | grep -q 'A & B <C> "D"' && ok text-raw || bad text-raw

issues="$(cmd_report weekly --issues-only)"
printf '%s\n' "${issues}" | grep -q 'Usługi' && printf '%s\n' "${issues}" | grep -q 'Certyfikaty' && ok issues-keep || bad issues-keep
printf '%s\n' "${issues}" | grep -q '## Kopie' && bad issues-ok || ok issues-ok

cmd_report weekly --send >/dev/null
grep -q 'nginx failed' "${HM_REPORT_MAIL}" && ok send-mail || bad send-mail
grep -q '"title":"Usługi"' "${HM_REPORT_HOOK}" && ok send-json || bad send-json
grep -Eq 'secret-token-VALUE|hunter2-password' "${HM_REPORT_MAIL}" "${HM_REPORT_HOOK}" && bad send-secret || ok send-secret

cmd_report schedule enable >/dev/null
grep -q 'hmtools-report' "${HM_REPORT_CRON}" && ok cron || bad cron
cmd_report schedule disable >/dev/null
[[ ! -e "${HM_REPORT_CRON}" ]] && ok cron-off || bad cron-off

unset HM_REPORT_SERVICES HM_REPORT_BACKUP HM_REPORT_SSL || true
lib="${root}/var/lib/hmtools"
mkdir -p "${lib}/stats" "${lib}/monitor" "${lib}/security" "${lib}/backup-verify"
printf 'cpu avg 12\n' > "${lib}/stats/week.json"
printf 'audit ssh OK\n' > "${lib}/security/audit.json"
printf 'shop.example\t200\t10\t40\tOK\tok\n' > "${lib}/monitor/latest.txt"
printf 'os security 0\n' > "${lib}/vuln-os.json"
printf 'backup-local ostatnia OK 12MB\n' > "${lib}/backup-status.txt"
cmd_stats() { cat "${lib}/stats/week.json"; }
cmd_security() { cat "${lib}/security/audit.json"; }
cmd_monitor() { cat "${lib}/monitor/latest.txt"; }
cmd_vuln() { cat "${lib}/vuln-os.json"; }
cmd_backup() { cat "${lib}/backup-status.txt"; }
live="$(cmd_report weekly --dry-run)"
printf '%s\n' "${live}" | grep -q 'cpu avg 12' && ok live-stats || bad live-stats
printf '%s\n' "${live}" | grep -q 'audit ssh OK' && ok live-audit || bad live-audit
printf '%s\n' "${live}" | grep -q 'shop.example' && ok live-http || bad live-http
printf '%s\n' "${live}" | grep -q 'os security 0' && ok live-vuln || bad live-vuln
printf '%s\n' "${live}" | grep -q 'backup-local ostatnia OK' && ok live-backup || bad live-backup
printf '%s\n' "${live}" | grep -q 'pominięto — brak modułu usług' && ok live-skip-svc || bad live-skip-svc

[[ "${fail}" -eq 0 ]] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
