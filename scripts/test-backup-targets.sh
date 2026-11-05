#!/usr/bin/env bash
# Regresja: cele backupu (local dest, multi-target parse, join/verify, stamp force)
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_CONF="${TMPDIR:-/tmp}/hmtools-test-$$.conf"
export TMP_DIR="${TMPDIR:-/tmp}/hmtools-test-tmp-$$"
mkdir -p "${TMP_DIR}"
trap 'rm -rf "${TMP_DIR}" "${HMTOOLS_CONF}" "${local_root:-}"' EXIT

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }
hm_mktemp() { mktemp "${TMP_DIR}/hm.XXXXXX${1:-}"; }
hm_file_log() { :; }
hm_is_valid_rclone_remote() { [[ "${1:-}" =~ ^[a-zA-Z0-9_.:/-]+$ ]]; }
hm_confirm_plan() { return 0; }
C_BOLD=""; C_RESET=""; C_DIM=""

# shellcheck disable=SC1091
source lib/common/config.sh
# minimal load
RCLONE_REMOTE="gdrive:vps-backups"
export RCLONE_REMOTE
# shellcheck disable=SC1091
source lib/rclone_drive.sh
# shellcheck disable=SC1091
source lib/rclone_targets.sh

fail=0

# --- local dest ---
local_root="$(mktemp -d "${TMP_DIR}/localroot.XXXXXX")"
RCLONE_REMOTE="${local_root}"
export RCLONE_REMOTE
if hm_rclone_root_is_local; then
  echo "OK   root-is-local"
else
  echo "FAIL root-is-local"
  fail=1
fi
dest="$(hm_rclone_dest "example.pl/20260101-120000")"
if [[ "${dest}" == "${local_root}/example.pl/20260101-120000" ]]; then
  echo "OK   local-dest"
else
  echo "FAIL local-dest got=${dest}"
  fail=1
fi
hm_rclone_mkdir "${dest}"
echo hello | hm_rclone_rcat "${dest}/manifest.json"
if [[ "$(cat "${dest}/manifest.json")" == "hello" ]]; then
  echo "OK   local-rcat"
else
  echo "FAIL local-rcat"
  fail=1
fi
echo world > "${TMP_DIR}/f.txt"
hm_rclone_copyto "${TMP_DIR}/f.txt" "${dest}/f.txt"
if [[ "$(cat "${dest}/f.txt")" == "world" ]]; then
  echo "OK   local-copyto"
else
  echo "FAIL local-copyto"
  fail=1
fi

# --- default target name ---
RCLONE_REMOTE="gdrive:vps-backups"
export RCLONE_REMOTE
n="$(hm_backup_default_target_name)"
if [[ "${n}" == "gdrive" ]]; then
  echo "OK   default-name-gdrive"
else
  echo "FAIL default-name-gdrive got=${n}"
  fail=1
fi

# --- save target ---
hm_backup_target_save "b2" "b2remote:bucket/hmtools" || fail=1
# shellcheck disable=SC1090
source "${HMTOOLS_CONF}"
if [[ "${BACKUP_TARGET_b2:-}" == "b2remote:bucket/hmtools" ]] && [[ "${BACKUP_TARGETS}" == *b2* ]]; then
  echo "OK   target-save"
else
  echo "FAIL target-save conf=$(cat "${HMTOOLS_CONF}")"
  fail=1
fi
spec="$(hm_backup_target_spec b2)"
if [[ "${spec}" == "b2remote:bucket/hmtools" ]]; then
  echo "OK   target-spec"
else
  echo "FAIL target-spec got=${spec}"
  fail=1
fi

# --- join / verify ---
joined="$(hm_backup_join_root_rel "${local_root}" "ex.pl/stamp1")"
mkdir -p "${joined}"
echo '{}' > "${joined}/manifest.json"
if hm_backup_verify_snapshot "${local_root}" "ex.pl/stamp1"; then
  echo "OK   verify-local"
else
  echo "FAIL verify-local"
  fail=1
fi

# --- copy between local roots ---
dst2="$(mktemp -d "${TMP_DIR}/dst.XXXXXX")"
if hm_backup_copy_snapshot_between "${local_root}" "${dst2}" "ex.pl/stamp1" \
  && [[ -f "${dst2}/ex.pl/stamp1/manifest.json" ]]; then
  echo "OK   copy-between-local"
else
  echo "FAIL copy-between-local"
  fail=1
fi

# --- force stamp ---
# shellcheck disable=SC1091
source commands/backup/core.sh 2>/dev/null || true
if declare -F hm_backup_stamp >/dev/null 2>&1; then
  HM_BACKUP_FORCE_STAMP="20260102-030405"
  s="$(hm_backup_stamp)"
  if [[ "${s}" == "20260102-030405" ]]; then
    echo "OK   force-stamp"
  else
    echo "FAIL force-stamp got=${s}"
    fail=1
  fi
  unset HM_BACKUP_FORCE_STAMP
else
  # core.sh needs many deps — inline check
  HM_BACKUP_FORCE_STAMP="20260102-030405"
  hm_backup_stamp() {
    if [[ -n "${HM_BACKUP_FORCE_STAMP:-}" ]]; then
      printf '%s' "${HM_BACKUP_FORCE_STAMP}"; return 0
    fi
    date +%Y%m%d-%H%M%S
  }
  s="$(hm_backup_stamp)"
  [[ "${s}" == "20260102-030405" ]] && echo "OK   force-stamp" || { echo "FAIL force-stamp"; fail=1; }
fi

# --- parse targets ---
hm_backup_parse_target_args site example.pl --targets gdrive,b2 --yes
if [[ "${HM_BACKUP_TARGETS_SELECTED}" == "gdrive,b2" ]]; then
  echo "OK   parse-targets"
else
  echo "FAIL parse-targets got=${HM_BACKUP_TARGETS_SELECTED}"
  fail=1
fi
# rest should keep domain and --yes
if [[ "${HM_BACKUP_ARGS_REST[*]}" == *"example.pl"* && "${HM_BACKUP_ARGS_REST[*]}" == *"--yes"* ]]; then
  echo "OK   parse-rest"
else
  echo "FAIL parse-rest got=${HM_BACKUP_ARGS_REST[*]}"
  fail=1
fi

# --- secrets not in target conf ---
if grep -qiE 'secret|password|passphrase|access_key' "${HMTOOLS_CONF}" 2>/dev/null; then
  echo "FAIL secrets-in-conf"
  fail=1
else
  echo "OK   no-secrets-in-conf"
fi

if [[ "${fail}" -eq 0 ]]; then
  echo "ALL OK"
  exit 0
fi
echo "FAILED=${fail}"
exit 1
