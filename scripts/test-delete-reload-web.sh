#!/usr/bin/env bash
# webs delete: reload wg webserver (nginx ≠ ols) — bez fałszywego „OLS przeładowany”.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD" HMTOOLS_TEST=1

# shellcheck disable=SC1091
source lib/common/ui.sh
hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_progress_bar() { :; }
hm_progress_done() { :; }
hm_discover_sites() { :; }
hm_clear_site_context() { :; }
hm_ols_reload_soft() { echo "OLS_RELOAD"; return 1; }
hm_site_web_reload() { echo "WEB_RELOAD:$1"; return 0; }

# shellcheck disable=SC1091
source commands/delete-site/delete.sh

fail=0
ok() { echo "OK   $1"; }
bad() { echo "FAIL $1" >&2; fail=1; }

HM_DEL_DOMAIN=qa.test
HM_DEL_PLAN_KEYS=(reload)
HM_DEL_WEB=nginx
out="$(hm_site_execute_delete 2>&1 || true)"
printf '%s\n' "${out}" | grep -q 'WEB_RELOAD:nginx' && ok nginx-call || bad nginx-call
printf '%s\n' "${out}" | grep -q 'ols reload nieudany' && bad nginx-no-ols-warn || ok nginx-no-ols-warn
printf '%s\n' "${out}" | grep -q 'OLS przeładowany' && bad nginx-no-ols-ok || ok nginx-no-ols-ok
printf '%s\n' "${out}" | grep -q 'nginx przeładowany' && ok nginx-ok || bad nginx-ok

HM_DEL_WEB=ols
hm_ols_reload_soft() { echo "OLS_RELOAD"; return 0; }
out="$(hm_site_execute_delete 2>&1 || true)"
printf '%s\n' "${out}" | grep -q 'OLS przeładowany' && ok ols-ok || bad ols-ok

hm_ols_reload_soft() { return 1; }
out="$(hm_site_execute_delete 2>&1 || true)"
printf '%s\n' "${out}" | grep -q 'ols reload nieudany' && ok ols-fail-warn || bad ols-fail-warn
printf '%s\n' "${out}" | grep -q 'OLS przeładowany' && bad ols-no-false-ok || ok ols-no-false-ok

[[ "${fail}" -eq 0 ]] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
