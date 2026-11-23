#!/usr/bin/env bash
# safety: domyślna baza mysql w kontekście strony bez prefix-match (shop ≠ shop2).
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { :; }
hm_ok() { :; }
hm_info() { :; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }
hm_is_valid_db_name() { [[ "$1" =~ ^[A-Za-z0-9_]+$ ]]; }
hm_db_size_bytes() { echo 0; }
hm_list_all_databases() { printf '%s\n' shoptes_app shop2tes_app; }
hm_detect_all() { PANEL=none; }
hm_cyberpanel_dbs_for_domain() { return 0; }
hm_cyberpanel_dbs_for_user() { return 0; }
hm_extract_db_from_file() {
  local f="$1" k="$2"
  if [[ "${f}" == *"/shop.test/"* && "${k}" == "env" ]]; then
    printf 'shoptes_app\t.env\n'
  fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hm-mysql-def.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
export HM_SITE_MANIFEST_DIR="${TMP}/sites"
mkdir -p "${HM_SITE_MANIFEST_DIR}" "${TMP}/shop.test" "${TMP}/shop2.test"
printf 'DB_DATABASE=shoptes_app\n' > "${TMP}/shop.test/.env"
printf 'mysql\tshoptes_app\tu\tlocalhost\t3306\n' > "${HM_SITE_MANIFEST_DIR}/.shop.test.dbs"
printf 'mysql\tshop2tes_app\tu\tlocalhost\t3306\n' > "${HM_SITE_MANIFEST_DIR}/.shop2.test.dbs"

# shellcheck disable=SC1091
source lib/site/tx.sh
# shellcheck disable=SC1091
source lib/db.sh

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

got="$(hm_mysql_default_db_for_site shop.test "${TMP}/shop.test" "${TMP}/shop.test" "" || true)"
[[ "${got}" == "shoptes_app" ]] && pass "shop.test → shoptes_app" || fail "got=${got}"
[[ "${got}" != *shop2* ]] && pass "shop.test nie bierze shop2*" || fail "prefix leak"

got2="$(hm_mysql_default_db_for_site shop2.test "${TMP}/shop2.test" "${TMP}/shop2.test" "" || true)"
[[ "${got2}" == "shop2tes_app" ]] && pass "shop2.test → shop2tes_app" || fail "got2=${got2}"

echo ""
echo "Wynik: ${PASS} pass, ${FAIL} fail"
[[ "${FAIL}" -eq 0 ]]
