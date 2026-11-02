#!/usr/bin/env bash
# Testy sentinel "-" dla pustych pól TSV (hm_tsv_field / hm_resolve_site_paths)
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
# shellcheck disable=SC1091
source lib/common/ui.sh
# shellcheck disable=SC1091
source commands/_shared/sites/discover.sh

fail=0

# Stub zależnych helperów — tylko kształt TSV
hm_vhost_conf_path() { printf ''; }
hm_ols_vhroot_for_domain() { printf ''; }
hm_parse_vhost_docroot() { printf ''; }
hm_parse_vhost_php() { printf ''; }
hm_expand_ols_vars() { printf '%s' "$1"; }
hm_cyberpanel_site_meta() { printf ''; }
PANEL=""
OLS_ROOT=""

assert_eq() {
  local name="$1" got="$2" want="$3"
  if [[ "${got}" != "${want}" ]]; then
    echo "FAIL ${name}: got=[${got}] want=[${want}]"
    fail=1
    return
  fi
  echo "OK   ${name}"
}

# 1) puste vhost → collapse: php dostaje rest (objaw webs: PHP=box|active)
raw=$'dom\troot\tdoc\tlogs\t\t8.2\tbox|active'
IFS=$'\t' read -r d root doc logs vhost php rest <<<"${raw}"
assert_eq "collapse-php-shifted" "${php}" "box|active"

# 2) with sentinels — columns stay put
safe=$'dom\troot\tdoc\t-\t-\t8.2\t-|active'
IFS=$'\t' read -r d root doc logs vhost php rest <<<"${safe}"
assert_eq "safe-logs" "${logs}" "-"
assert_eq "safe-vhost" "${vhost}" "-"
assert_eq "safe-php" "${php}" "8.2"
assert_eq "safe-rest" "${rest}" "-|active"

# 3) hm_tsv_field / unfield
assert_eq "field-empty" "$(hm_tsv_field '')" "-"
assert_eq "field-keep" "$(hm_tsv_field '/home/x')" "/home/x"
assert_eq "unfield-dash" "$(hm_tsv_unfield '-')" ""
assert_eq "unfield-keep" "$(hm_tsv_unfield '/a')" "/a"

# 4) resolve bez vhosta / bez katalogów → puste ścieżki jako "-"
row="$(hm_resolve_site_paths "example.test")"
IFS=$'\t' read -r d root doc logs vhost php rest <<<"${row}"
assert_eq "resolve-domain" "${d}" "example.test"
assert_eq "resolve-root-dash" "${root}" "-"
assert_eq "resolve-doc-dash" "${doc}" "-"
assert_eq "resolve-logs-dash" "${logs}" "-"
assert_eq "resolve-vhost-dash" "${vhost}" "-"
assert_eq "resolve-php" "${php}" "?"
assert_eq "resolve-rest" "${rest}" "-|active"

# 5) set context odtwarza puste stringi
hm_set_site_context "example.test"
assert_eq "ctx-root-empty" "${HM_SITE_ROOT}" ""
assert_eq "ctx-vhost-empty" "${HM_SITE_VHOST}" ""
assert_eq "ctx-user-empty" "${HM_SITE_USER}" ""
assert_eq "ctx-status" "${HM_SITE_STATUS}" "active"
assert_eq "ctx-php" "${HM_SITE_PHP}" "?"

# 6) db TSV: pusty user bez sentinela vs z
db_bad=$'mydb\t\t2048\tdetected'
IFS=$'\t' read -r name user size origin <<<"${db_bad}"
assert_eq "db-collapse-user" "${user}" "2048"
db_ok=$'mydb\t-\t2048\tdetected'
IFS=$'\t' read -r name user size origin <<<"${db_ok}"
assert_eq "db-safe-user" "${user}" "-"
assert_eq "db-safe-size" "${size}" "2048"
assert_eq "db-safe-origin" "${origin}" "detected"

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
