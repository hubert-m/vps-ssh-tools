#!/usr/bin/env bash
# backup local --keep: chroni archive, kasuje uszkodzone, zostawia N ok.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { :; }
hm_info() { :; }

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hm-local-keep.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

export BACKUP_LOCAL_ROOT="${TMP}/remote"
export RCLONE_REMOTE="${TMP}/remote"
DOMAIN="shop.example.test"
BASE="${BACKUP_LOCAL_ROOT}/${DOMAIN}"
mkdir -p "${BASE}"

# shellcheck disable=SC1091
source lib/rclone_drive.sh
# shellcheck disable=SC1091
source commands/backup/list.sh
# shellcheck disable=SC1091
source commands/backup/prune.sh
# shellcheck disable=SC1091
source commands/backup/local.sh

# 4 stampy: archive, ok, ok, uszkodzony (najnowszy)
# sort -r: 180000, 173835, 173748, 173700
A_BAD="20261122-180000"      # ucięty — brak payload
A_ARCH="20261122-173835"     # archive
A_OK2="20261122-173748"      # ok
A_OK1="20261122-173700"      # ok starszy

mkdir -p "${BASE}/${A_BAD}"
printf '%s\n' '{"type":"site","status":"ok"}' > "${BASE}/${A_BAD}/manifest.json"
# brak files.tar.gz / db → incomplete

mkdir -p "${BASE}/${A_ARCH}"
echo payload > "${BASE}/${A_ARCH}/files.tar.gz"
printf '%s\n' '{"type":"archive","status":"ok","archived":true}' > "${BASE}/${A_ARCH}/manifest.json"

mkdir -p "${BASE}/${A_OK2}"
echo payload > "${BASE}/${A_OK2}/files.tar.gz"
printf '%s\n' '{"type":"site","status":"ok"}' > "${BASE}/${A_OK2}/manifest.json"

mkdir -p "${BASE}/${A_OK1}"
echo payload > "${BASE}/${A_OK1}/files.tar.gz"
printf '%s\n' '{"type":"site","status":"ok"}' > "${BASE}/${A_OK1}/manifest.json"

# overlap warn
warn="$(hm_backup_local_warn_remote_overlap 2>&1 || true)"
if printf '%s' "${warn}" | grep -qi 'pokrywa'; then
  pass "(0) ostrzeżenie overlap BACKUP_LOCAL_ROOT/RCLONE_REMOTE"
else
  fail "(0) brak ostrzeżenia overlap: ${warn}"
fi

hm_backup_local_prune_domain "${DOMAIN}" 2

[[ -d "${BASE}/${A_ARCH}" ]] && pass "(1) archive zachowany" || fail "(1) archive skasowany"
[[ ! -d "${BASE}/${A_BAD}" ]] && pass "(2) uszkodzony usunięty" || fail "(2) uszkodzony został"
[[ -d "${BASE}/${A_OK2}" ]] && pass "(3) nowszy ok zachowany" || fail "(3) ok2 skasowany"
[[ -d "${BASE}/${A_OK1}" ]] && pass "(4) starszy ok zachowany (keep=2)" || fail "(4) ok1 skasowany mimo keep=2"

# keep=1 → zostaje archive + 1 najnowszy ok
echo payload > "${BASE}/${A_OK1}/files.tar.gz" 2>/dev/null || mkdir -p "${BASE}/${A_OK1}" && echo payload > "${BASE}/${A_OK1}/files.tar.gz"
printf '%s\n' '{"type":"site","status":"ok"}' > "${BASE}/${A_OK1}/manifest.json"
hm_backup_local_prune_domain "${DOMAIN}" 1
[[ -d "${BASE}/${A_ARCH}" ]] && pass "(5) archive przy keep=1" || fail "(5) archive przy keep=1"
[[ -d "${BASE}/${A_OK2}" ]] && pass "(6) najnowszy ok przy keep=1" || fail "(6) ok2 przy keep=1"
[[ ! -d "${BASE}/${A_OK1}" ]] && pass "(7) starszy ok usunięty przy keep=1" || fail "(7) ok1 został przy keep=1"

if [[ "${FAIL}" -eq 0 ]]; then
  echo "ALL PASSED (${PASS})"
else
  echo "FAILED (${FAIL} fail, ${PASS} pass)" >&2
  exit 1
fi
