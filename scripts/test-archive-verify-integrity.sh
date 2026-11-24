#!/usr/bin/env bash
# safety: hm_backup_verify_remote_archive — ucięty/zmieniony tar/chunk/dump ⇒ rc≠0;
# błąd uploadu artefaktu ⇒ brak hm_site_execute_delete.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
# shellcheck disable=SC1091
source lib/common/ui.sh
hm_file_log_ui() { :; }
hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_info() { echo "INFO: $*"; }
hm_ok() { echo "OK: $*"; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }
hm_mktemp() { mktemp "${TMP}/hm.XXXXXX${1:-}"; }
C_BOLD=""; C_RESET=""; C_DIM=""

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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hm-arch-verify.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
export TMP_DIR="${TMP}"

SNAP="${TMP}/shop.test/20200101-120000"
mkdir -p "${SNAP}/db" "${TMP}/src"
echo "hello world content for archive" > "${TMP}/src/index.html"
tar -C "${TMP}/src" -czf "${SNAP}/files.tar.gz" .
HASH="$(sha256sum "${SNAP}/files.tar.gz" | awk '{print $1}')"
printf '%s\n' "{\"type\":\"archive\",\"sha256_files\":\"${HASH}\",\"files_mode\":\"tar\",\"status\":\"ok\"}" \
  > "${SNAP}/manifest.json"
printf '%s  files.tar.gz\n' "${HASH}" > "${SNAP}/SHA256SUMS"
# minimalny dump gzip
printf 'SELECT 1;\n' | gzip -c > "${SNAP}/db/shop_app.sql.gz"

# --- (a) dobry snapshot → rc=0 ---
set +e
hm_backup_verify_remote_archive "${SNAP}" tar 0 shop_app >/dev/null 2>&1
rc=$?
set -e
[[ "${rc}" -eq 0 ]] && pass "(a) integralny snapshot → rc=0" || fail "(a) oczekiwano rc=0, got=${rc}"

# --- (b) ucięty files.tar.gz → rc≠0 ---
cp -a "${SNAP}" "${TMP}/cut"
truncate -s $(( $(stat -c%s "${TMP}/cut/files.tar.gz") * 60 / 100 )) "${TMP}/cut/files.tar.gz" 2>/dev/null \
  || dd if="${SNAP}/files.tar.gz" of="${TMP}/cut/files.tar.gz" bs=1 count=20 status=none 2>/dev/null
set +e
hm_backup_verify_remote_archive "${TMP}/cut" tar 0 shop_app >/dev/null 2>&1
rc=$?
set -e
[[ "${rc}" -ne 0 ]] && pass "(b) ucięty files.tar.gz → rc≠0" || fail "(b) oczekiwano rc≠0"

# --- (c) podmieniony bajt w środku (manifest nadal ze starym SHA) → rc≠0 ---
cp -a "${SNAP}" "${TMP}/flip"
printf '\xff' | dd of="${TMP}/flip/files.tar.gz" bs=1 seek=10 conv=notrunc status=none 2>/dev/null || true
set +e
hm_backup_verify_remote_archive "${TMP}/flip" tar 0 shop_app >/dev/null 2>&1
rc=$?
set -e
[[ "${rc}" -ne 0 ]] && pass "(c) uszkodzony bajt / SHA ≠ → rc≠0" || fail "(c) oczekiwano rc≠0"

# --- (d) ucięty dump → rc≠0 ---
cp -a "${SNAP}" "${TMP}/dbcut"
truncate -s 5 "${TMP}/dbcut/db/shop_app.sql.gz" 2>/dev/null || dd if=/dev/zero of="${TMP}/dbcut/db/shop_app.sql.gz" bs=1 count=5 status=none
set +e
hm_backup_verify_remote_archive "${TMP}/dbcut" tar 0 shop_app >/dev/null 2>&1
rc=$?
set -e
[[ "${rc}" -ne 0 ]] && pass "(d) ucięty dump → rc≠0" || fail "(d) oczekiwano rc≠0"

# --- (c2) tryb chunków: poprawne part_* + (joined) → rc=0 ---
CHUNK_SNAP="${TMP}/chunk.ok/20200101-120000"
mkdir -p "${CHUNK_SNAP}/files.chunks" "${CHUNK_SNAP}/db"
# podziel istniejący tar na 2 części
split -b 40 -d -a 4 --additional-suffix='' "${SNAP}/files.tar.gz" "${CHUNK_SNAP}/files.chunks/files.tar.gz.part_" 2>/dev/null \
  || split -b 40 -d -a 4 "${SNAP}/files.tar.gz" "${CHUNK_SNAP}/files.chunks/files.tar.gz.part_"
# ujednolić nazwy: part_0000 / part_0001
shopt -s nullglob
_parts=( "${CHUNK_SNAP}/files.chunks"/files.tar.gz.part_* )
if [[ "${#_parts[@]}" -lt 2 ]]; then
  # split na niektórych systemach: part_00 — dopnij drugi pusty? lepiej ręcznie
  rm -rf "${CHUNK_SNAP}/files.chunks"
  mkdir -p "${CHUNK_SNAP}/files.chunks"
  dd if="${SNAP}/files.tar.gz" of="${CHUNK_SNAP}/files.chunks/files.tar.gz.part_0000" bs=1 count=40 status=none 2>/dev/null \
    || head -c 40 "${SNAP}/files.tar.gz" > "${CHUNK_SNAP}/files.chunks/files.tar.gz.part_0000"
  dd if="${SNAP}/files.tar.gz" of="${CHUNK_SNAP}/files.chunks/files.tar.gz.part_0001" bs=1 skip=40 status=none 2>/dev/null \
    || tail -c +41 "${SNAP}/files.tar.gz" > "${CHUNK_SNAP}/files.chunks/files.tar.gz.part_0001"
fi
# rename jeżeli split dał part_00 zamiast part_0000
for _p in "${CHUNK_SNAP}/files.chunks"/files.tar.gz.part_*; do
  [[ -f "${_p}" ]] || continue
  _bn="$(basename "${_p}")"
  if [[ "${_bn}" =~ ^files\.tar\.gz\.part_([0-9]+)$ ]]; then
    _num="${BASH_REMATCH[1]}"
    _want="$(printf 'files.tar.gz.part_%04d' "$((10#${_num}))")"
    if [[ "${_bn}" != "${_want}" ]]; then
      mv -f "${_p}" "${CHUNK_SNAP}/files.chunks/${_want}"
    fi
  fi
done
shopt -u nullglob
_nparts="$(find "${CHUNK_SNAP}/files.chunks" -name 'files.tar.gz.part_*' | wc -l | tr -d ' ')"
: > "${CHUNK_SNAP}/SHA256SUMS"
for _p in $(find "${CHUNK_SNAP}/files.chunks" -name 'files.tar.gz.part_*' | sort); do
  _h="$(sha256sum "${_p}" | awk '{print $1}')"
  printf '%s  files.chunks/%s\n' "${_h}" "$(basename "${_p}")" >> "${CHUNK_SNAP}/SHA256SUMS"
done
printf '%s  files.tar.gz (joined)\n' "${HASH}" >> "${CHUNK_SNAP}/SHA256SUMS"
printf '%s\n' "{\"type\":\"archive\",\"sha256_files\":\"${HASH}\",\"files_mode\":\"chunks\",\"status\":\"ok\"}" \
  > "${CHUNK_SNAP}/manifest.json"
printf 'chunks=%s\n' "${_nparts}" > "${CHUNK_SNAP}/files.chunks/files.tar.gz.chunks.txt"
cp -a "${SNAP}/db/shop_app.sql.gz" "${CHUNK_SNAP}/db/"
set +e
hm_backup_verify_remote_archive "${CHUNK_SNAP}" chunks "${_nparts}" shop_app >/dev/null 2>&1
rc=$?
set -e
[[ "${rc}" -eq 0 ]] && pass "(c2) chunki OK + (joined) → rc=0" || fail "(c2) oczekiwano rc=0, got=${rc}"

# --- (c3) flip bajtu w part_0001 → rc≠0 ---
cp -a "${CHUNK_SNAP}" "${TMP}/chunk.flip"
_flip_part="$(find "${TMP}/chunk.flip/files.chunks" -name 'files.tar.gz.part_0001' | head -1)"
if [[ -n "${_flip_part}" && -f "${_flip_part}" ]]; then
  printf '\xff' | dd of="${_flip_part}" bs=1 seek=2 conv=notrunc status=none 2>/dev/null || true
  set +e
  hm_backup_verify_remote_archive "${TMP}/chunk.flip" chunks "${_nparts}" shop_app >/dev/null 2>&1
  rc=$?
  set -e
  [[ "${rc}" -ne 0 ]] && pass "(c3) uszkodzony chunk → rc≠0" || fail "(c3) oczekiwano rc≠0"
else
  fail "(c3) brak part_0001 do flip"
fi

# --- (e) błąd copyto ssl → archive nie woła delete ---
DELETE_CALLED=0
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
hm_site_collect_delete_inventory() { return 0; }
hm_set_site_context() { :; }
hm_status_line() { :; }
hm_status_clear() { :; }
hm_site_print_delete_inventory() { :; }
hm_confirm_plan_critical() { return 0; }
hm_rclone_ensure_backup_layout() { :; }
hm_rclone_mkdir() { mkdir -p "${1#*:}" 2>/dev/null || mkdir -p "$1" 2>/dev/null || true; }
hm_backup_stamp() { echo "20200101-120000"; }
hm_backup_dest_site() { echo "${TMP}/remote/$1/$2"; }
hm_backup_resolve_files_root() { echo "${TMP}/src"; }
hm_dir_size_bytes() { echo 100; }
hm_stream_mysqldump() { return 0; }
hm_write_manifest_and_upload() {
  local base="$1" man="$2"
  mkdir -p "${base}"
  cp "${man}" "${base}/manifest.json"
  return 0
}
hm_rclone_copyto() {
  local src="$1" dest="$2"
  if [[ "${dest}" == *ssl.tar.gz ]]; then
    return 1
  fi
  mkdir -p "$(dirname "${dest}")"
  cp -a "${src}" "${dest}"
}
hm_archive_pack_ssl() {
  local out="$2"
  echo x | gzip -c > "${out}"
  return 0
}
hm_archive_write_ols_snippet() { : > "$2"; }
hm_archive_export_cyberpanel_sql() { return 1; }
hm_archive_export_mysql_accounts() { return 1; }
hm_archive_export_unix_account() { return 1; }
hm_json_escape_str() { printf '%s' "$1" | sed 's/\\/\\\\/g;s/"/\\"/g'; }
hm_backup_excludes_list() { echo ""; }
hm_ensure_secure_tmpdir() { :; }
hm_site_context_push() { :; }
hm_site_context_pop() { :; }

HM_DEL_ROOT="${TMP}/src"
HM_DEL_DOCROOT="${TMP}/src"
HM_DEL_USER=""
HM_DEL_VHOST_DIR=""
HM_SITE_VHOST=""
HM_DEL_DBS=()
HM_DEL_DB_USERS=()
HM_DEL_PM2=()
HM_DEL_USER_SHARED=0
HM_DEL_USER_PROTECTED=0
HM_DEL_CHILD_OF_SHARED=0
CHUNK_THRESHOLD_MB=999999
export RCLONE_REMOTE="${TMP}/remote"
mkdir -p "${TMP}/remote"

# hm_archive_upload_site_files używa stream — upewnij się że działa lokalnie
set +e
_hm_backup_archive_site_body "shop.test" >/dev/null 2>&1
rc=$?
set -e
if [[ "${DELETE_CALLED}" -eq 0 ]]; then
  pass "(e) błąd uploadu ssl ⇒ brak hm_site_execute_delete (rc=${rc})"
else
  fail "(e) hm_site_execute_delete wywołane mimo błędu ssl"
fi

echo ""
echo "Wynik: ${PASS} pass, ${FAIL} fail"
[[ "${FAIL}" -eq 0 ]]
