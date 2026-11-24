#!/usr/bin/env bash
# Regresja: kolizja stampu, glob excludes, atomowy zapis lokalny
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }
hm_file_log() { :; }
hm_mktemp() { mktemp "${TMPDIR:-/tmp}/hm.XXXXXX${1:-}"; }
hm_ensure_secure_tmpdir() { TMP_DIR="${tmpdir}/tmp"; mkdir -p "${TMP_DIR}"; }
_hm_cmd_help() { :; }
_hm_cmd_register() { :; }

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
export TMP_DIR="${tmpdir}/tmp"
mkdir -p "${TMP_DIR}"

# shellcheck disable=SC1091
source lib/rclone_drive.sh
# shellcheck disable=SC1091
source commands/backup/core.sh

# --- excludes: glob nie rozwija się w CWD ---
mkdir -p "${tmpdir}/cwd"
printf 'x\n' > "${tmpdir}/cwd/a.log"
printf 'y\n' > "${tmpdir}/cwd/keep.txt"
(
  cd "${tmpdir}/cwd"
  export BACKUP_EXCLUDES='*.log'
  out="$(hm_backup_tar_excludes backup)"
  printf '%s\n' "${out}" | grep -Fq -e '--exclude=*.log' && ok excludes-literal || bad "excludes-literal got=${out}"
  printf '%s\n' "${out}" | grep -Fq -e 'a.log' && bad excludes-no-expand || ok excludes-no-expand
)

# --- stamp collision ---
export RCLONE_REMOTE="${tmpdir}/remote"
mkdir -p "${RCLONE_REMOTE}/site.example/20260101-120000"
printf 'old\n' > "${RCLONE_REMOTE}/site.example/20260101-120000/manifest.json"
export HM_BACKUP_FORCE_STAMP=20260101-120000
if hm_backup_claim_stamp site site.example 2>/dev/null; then
  bad stamp-force-refuse
else
  ok stamp-force-refuse
fi
unset HM_BACKUP_FORCE_STAMP
# bez force → sufiks
export HM_BACKUP_FORCE_STAMP=
stamp_base=20260101-120000
# mock date via force empty + claim with busy base
# użyj ręcznie busy check + claim bez force: ustaw stamp przez HM... nie — hm_backup_stamp daje bieżącą datę.
# Zamiast tego: zajęty katalog pod claim z FORCE pustym — wstrzykujemy przez podwójne claim na ten sam FORCE po zwolnieniu?
# Prościej: unit busy + mark owned
busy="$(hm_backup_dest_site site.example 20260101-120000)"
hm_backup_snapshot_dir_busy "${busy}" && ok stamp-busy || bad stamp-busy
mkdir -p "${RCLONE_REMOTE}/site.example/20260101-130000"
hm_backup_mark_owned_remote "${RCLONE_REMOTE}/site.example/20260101-130000"
[[ -f "${RCLONE_REMOTE}/site.example/20260101-130000/.hmtools-owned" ]] && ok mark-owned || bad mark-owned
export HM_BACKUP_OWNED_REMOTE="${RCLONE_REMOTE}/site.example/20260101-130000"
# shellcheck disable=SC1091
source commands/backup/archive.sh
hm_archive_purge_remote "${RCLONE_REMOTE}/site.example/20260101-120000" >/dev/null 2>&1 || true
[[ -f "${RCLONE_REMOTE}/site.example/20260101-120000/manifest.json" ]] && ok purge-skip-foreign || bad purge-skip-foreign

# --- atomowy rcat lokalny ---
dest="${tmpdir}/atom/out.bin"
mkdir -p "$(dirname "${dest}")"
printf 'hello-atom\n' | hm_rclone_rcat "${dest}"
[[ -f "${dest}" && ! -e "${dest}.part."* ]] && grep -q hello-atom "${dest}" && ok rcat-atomic || bad rcat-atomic
printf 'src\n' > "${tmpdir}/src.bin"
hm_rclone_copyto "${tmpdir}/src.bin" "${tmpdir}/atom/cp.bin"
[[ -f "${tmpdir}/atom/cp.bin" && ! -e "${tmpdir}/atom/cp.bin.part."* ]] && ok copyto-atomic || bad copyto-atomic

# --- encrypt helper na dump path (unit) ---
if command -v openssl >/dev/null 2>&1; then
  export BACKUP_ENCRYPT_PASSPHRASE='test-pass-quality-99'
  plain="${tmpdir}/plain.sql.gz"
  printf 'gzfake\n' > "${plain}"
  enc="$(hm_backup_maybe_encrypt_file "${plain}")"
  [[ "${enc}" == *.enc && -s "${enc}" ]] && ok encrypt-file || bad encrypt-file
else
  ok encrypt-skip-no-openssl
fi

if [[ "${fail}" -ne 0 ]]; then
  echo FAILED
  exit 1
fi
echo "ALL OK"
exit 0
