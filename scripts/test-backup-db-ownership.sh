#!/usr/bin/env bash
# safety: hm_dbs_for_site bez prefix-match; restore odmawia cudzej bazy z .dbs.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { :; }
hm_info() { :; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }
hm_is_valid_db_name() { [[ "$1" =~ ^[A-Za-z0-9_]+$ ]]; }
hm_db_size_bytes() { echo 0; }
hm_list_all_databases() {
  printf '%s\n' shopexam_app shop2tes_app shopping_pl
}
hm_detect_all() { PANEL=none; }
hm_cyberpanel_dbs_for_domain() { return 0; }
hm_cyberpanel_dbs_for_user() { return 0; }
hm_extract_db_from_file() { return 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hm-db-own.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
export HM_SITE_MANIFEST_DIR="${TMP}/sites"
mkdir -p "${HM_SITE_MANIFEST_DIR}"
# shellcheck disable=SC1091
source lib/site/tx.sh
# shellcheck disable=SC1091
source lib/db.sh
# shellcheck disable=SC1091
source commands/backup/restore.sh

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

printf 'mysql\tshopexam_app\tshopu\tlocalhost\t3306\n' > "${HM_SITE_MANIFEST_DIR}/.shop.test.dbs"
printf 'mysql\tshop2tes_app\tshop2u\tlocalhost\t3306\n' > "${HM_SITE_MANIFEST_DIR}/.shop2.test.dbs"

# --- (a) snapshot shop.test nie zawiera shop2* przez heurystykę ---
out="$(hm_dbs_for_site "shop.test" "${TMP}/doc" "${TMP}/root" "" 2>/dev/null || true)"
if echo "${out}" | grep -q 'shop2tes_app'; then
  fail "(a) shop.test dostał shop2tes_app: ${out}"
else
  pass "(a) shop.test bez shop2tes_app"
fi
if echo "${out}" | grep -q 'shopexam_app'; then
  pass "(a) shop.test ma shopexam_app z manifestu"
else
  fail "(a) brak shopexam_app: ${out}"
fi

# prefix-match nie wraca
hout="$(hm_heuristic_dbs_for_site "${TMP}/doc" "shop.test" "${TMP}/root" 2>/dev/null || true)"
if echo "${hout}" | grep -q 'prefix-match'; then
  fail "(a) heurystyka nadal emituje prefix-match"
else
  pass "(a) brak prefix-match w heurystyce"
fi

# --- (b) belongs_to_other: shop2tes_app przy restore shop.test ---
PANEL=none
if hm_backup_db_belongs_to_other_domain "shop2tes_app" "shop.test"; then
  pass "(b) odmowa: shop2tes_app należy do innego .dbs"
else
  fail "(b) oczekiwano odmowy dla shop2tes_app"
fi
if hm_backup_db_belongs_to_other_domain "shopexam_app" "shop.test"; then
  fail "(b) własna baza shopexam_app uznana za cudzą"
else
  pass "(b) własna baza OK"
fi

# --- (c) --force-foreign-db omija ---
HM_BACKUP_FORCE_FOREIGN_DB=1
if hm_backup_db_belongs_to_other_domain "shop2tes_app" "shop.test"; then
  fail "(c) force nadal odmawia"
else
  pass "(c) --force-foreign-db pozwala"
fi
HM_BACKUP_FORCE_FOREIGN_DB=0

echo ""
echo "Wynik: ${PASS} pass, ${FAIL} fail"
[[ "${FAIL}" -eq 0 ]]
