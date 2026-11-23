#!/usr/bin/env bash
# safety: archive bierze DB z .dbs; brak zrzutu ⇒ brak DROP (guard).
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }
hm_is_valid_db_name() { [[ "$1" =~ ^[A-Za-z0-9_]+$ ]]; }
hm_mktemp() { mktemp "${TMP}/hm.XXXXXX${1:-}"; }
hm_json_escape_str() { printf '%s' "$1" | sed 's/\\/\\\\/g;s/"/\\"/g'; }
hm_backup_excludes_list() { echo ""; }
hm_dir_size_bytes() { echo 100; }
hm_human_size() { echo "${1}B"; }
C_BOLD=""; C_RESET=""; C_DIM=""

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hm-arch-wiz.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
export TMP_DIR="${TMP}"
export HM_SITE_MANIFEST_DIR="${TMP}/sites"
mkdir -p "${HM_SITE_MANIFEST_DIR}" "${TMP}/src" "${TMP}/remote"
printf 'hello\n' > "${TMP}/src/index.html"
printf 'mysql\tshopx_app\tshopxu\tlocalhost\t3306\n' > "${HM_SITE_MANIFEST_DIR}/.shop.example.test.dbs"

# shellcheck disable=SC1091
source lib/site/tx.sh
# shellcheck disable=SC1091
source lib/rclone_drive.sh
# shellcheck disable=SC1091
source commands/backup/list.sh
# shellcheck disable=SC1091
source commands/backup/core.sh
# shellcheck disable=SC1091
source commands/backup/archive.sh

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

DELETE_CALLED=0
DUMPED=0
hm_site_execute_delete() { DELETE_CALLED=1; return 0; }
hm_archive_purge_remote() { :; }
hm_load_config() { :; }
hm_detect_all() { :; }
hm_rclone_check() { return 0; }
hm_backup_check_space() { return 0; }
hm_backup_acquire_lock() { return 0; }
hm_backup_release_lock() { :; }
hm_find_site_by_arg_exact() { printf '%s\n' "$1"; }
hm_find_site_by_arg() { printf '%s\n' "$1"; }
hm_site_collect_delete_inventory() {
  HM_DEL_DOMAIN="shop.example.test"
  HM_DEL_ROOT="${TMP}/src"
  HM_DEL_DOCROOT="${TMP}/src"
  HM_DEL_USER=""
  HM_DEL_DBS=()  # puste — jak gdy prefix-match skipował; .dbs musi uzupełnić
  HM_DEL_SKIP_DBS=("shopx_app|prefix-match|tylko prefix-match")
  HM_DEL_DB_USERS=()
  HM_DEL_PM2=()
  HM_DEL_USER_SHARED=0
  HM_DEL_USER_PROTECTED=0
  HM_DEL_CHILD_OF_SHARED=0
  HM_DEL_VHOST_DIR=""
  HM_DEL_SIZE=100
  return 0
}
hm_set_site_context() { :; }
hm_status_line() { :; }
hm_status_clear() { :; }
hm_site_print_delete_inventory() { :; }
hm_site_build_delete_plan() { HM_DEL_PLAN_STEPS=("DROP DATABASE shopx_app"); }
hm_confirm_plan_critical() { return 0; }
hm_rclone_ensure_backup_layout() { :; }
hm_rclone_mkdir() { mkdir -p "${1#*:}" 2>/dev/null || mkdir -p "$1" 2>/dev/null || true; }
hm_backup_stamp() { echo "20200101-120000"; }
hm_backup_dest_site() { echo "${TMP}/remote/$1/$2"; }
hm_backup_resolve_files_root() { echo "${TMP}/src"; }
hm_stream_mysqldump() {
  local db="$1" dest="$2"
  DUMPED=1
  mkdir -p "$(dirname "${dest}")"
  printf 'SELECT 1;\n' | gzip -c > "${dest}"
  return 0
}
hm_write_manifest_and_upload() {
  local base="$1" man="$2"
  mkdir -p "${base}"
  cp "${man}" "${base}/manifest.json"
  return 0
}
hm_rclone_copyto() { mkdir -p "$(dirname "$2")"; cp -a "$1" "$2"; }
hm_archive_pack_ssl() { return 1; }
hm_archive_write_ols_snippet() { : > "$2"; }
hm_archive_export_cyberpanel_sql() { return 1; }
hm_archive_export_mysql_accounts() { return 1; }
hm_archive_export_unix_account() { return 1; }
hm_ensure_secure_tmpdir() { :; }
hm_site_context_push() { :; }
hm_site_context_pop() { :; }
hm_backup_verify_remote_archive() { return 0; }

export RCLONE_REMOTE="${TMP}/remote"
CHUNK_THRESHOLD_MB=999999
HM_SITE_VHOST=""

set +e
_hm_backup_archive_site_body "shop.example.test" >"${TMP}/out_a.txt" 2>&1
rc=$?
set -e

snap="$(echo "${TMP}/remote/shop.example.test/"*/db/shopx_app.sql.gz)"
if [[ -f "${snap}" ]]; then
  pass "(a) db/shopx_app.sql.gz istnieje (z .dbs mimo pustego HM_DEL_DBS)"
else
  fail "(a) brak dumpa shopx_app"
fi
[[ "${DUMPED}" -eq 1 ]] && pass "(a) mysqldump wywołany" || fail "(a) brak mysqldump"
if [[ "${DELETE_CALLED}" -eq 1 && "${rc}" -eq 0 ]]; then
  pass "(a) Faza II po udanym dumpie"
else
  fail "(a) delete/rc: del=${DELETE_CALLED} rc=${rc}"
  tail -n 40 "${TMP}/out_a.txt" | sed 's/^/  | /'
fi

# --- (b) brak dumpa ⇒ guard, bez delete ---
DELETE_CALLED=0
rm -rf "${TMP}/remote"
mkdir -p "${TMP}/remote"
hm_stream_mysqldump() { return 1; }  # fail dump
set +e
_hm_backup_archive_site_body "shop.example.test" >/dev/null 2>&1
rc=$?
set -e
[[ "${DELETE_CALLED}" -eq 0 ]] && pass "(b) brak dumpa ⇒ bez hm_site_execute_delete" || fail "(b) delete mimo braku dumpa"
[[ "${rc}" -ne 0 ]] && pass "(b) rc≠0" || fail "(b) oczekiwano rc≠0"

echo ""
echo "Wynik: ${PASS} pass, ${FAIL} fail"
[[ "${FAIL}" -eq 0 ]]
