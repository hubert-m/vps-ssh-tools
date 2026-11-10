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
printf 'shop.example wygasa 10d\n' > "${root}/ssl"
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

[[ "${fail}" -eq 0 ]] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
