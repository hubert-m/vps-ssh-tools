#!/usr/bin/env bash
# Regresja: hm_complete_filter_names + filtry mysql/pm2/supervisor
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/lib/complete/helpers.sh"

fail=0
assert_has() {
  local label="$1" hay="$2" needle="$3"
  if printf '%s\n' "${hay}" | grep -qx "${needle}"; then
    echo "OK   ${label}"
  else
    echo "FAIL ${label}: missing '${needle}' in: ${hay}"
    fail=1
  fi
}

out="$(printf '%s\n' 'alpha-db' 'beta-shop' 'gamma' | hm_complete_filter_names 'bet')"
assert_has "substring bet" "${out}" "beta-shop"

out="$(printf '%s\n' 'opinie-worker' 'scraper' | hm_complete_filter_names 'opi' all)"
assert_has "prefix opi" "${out}" "opinie-worker"

hm_list_all_databases() { printf '%s\n' 'mast_mastercrm' 'opin_oof_backoffice'; }
out="$(hm_complete_filter_mysql_dbs 'mast')"
assert_has "mysql db" "${out}" "mast_mastercrm"

hm_pm2_parse_apps() { printf '%s\n' 'api-app|1|online|/home/x|x.js|3000|1|0'; }
out="$(hm_complete_filter_pm2 'api')"
assert_has "pm2 name" "${out}" "api-app"
assert_has "pm2 all" "$(hm_complete_filter_pm2 'a')" "all"

hm_supervisor_list_names() { printf '%s\n' 'scraper-worker:scraper-worker_00'; }
out="$(hm_complete_filter_supervisor 'scrap')"
assert_has "supervisor" "${out}" "scraper-worker:scraper-worker_00"

if grep -q 'hm_complete_filter_mysql_dbs' "${ROOT}/lib/complete/tab.sh" \
  && grep -q 'hm_complete_filter_pm2' "${ROOT}/lib/complete/tab.sh" \
  && grep -q 're_access_site' "${ROOT}/lib/complete/tab.sh"; then
  echo "OK   tab.sh wired for mysql/pm2/access"
else
  echo "FAIL tab.sh missing new filters"
  fail=1
fi

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
