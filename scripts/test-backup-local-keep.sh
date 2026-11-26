#!/usr/bin/env bash
# backup local --keep: chroni archive, kasuje uszkodzone (w tym ucięty gzip ze status=ok), zostawia N ok.
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

mk_ok_tar() {
  local dest="$1"
  local stage="${TMP}/pack-$$"
  mkdir -p "${stage}/public_html"
  printf 'ok\n' > "${stage}/public_html/index.html"
  tar -C "${stage}" -czf "${dest}" .
  rm -rf "${stage}"
}

# 4 stampy: archive, ok, ok, uszkodzony (najnowszy — brak payload)
# sort -r: 180000, 173835, 173748, 173700
A_BAD="20261122-180000"      # brak payload → incomplete
A_ARCH="20261122-173835"     # archive
A_OK2="20261122-173748"      # ok
A_OK1="20261122-173700"      # ok starszy

mkdir -p "${BASE}/${A_BAD}"
printf '%s\n' '{"type":"site","status":"ok"}' > "${BASE}/${A_BAD}/manifest.json"
# brak files.tar.gz / db → incomplete

mkdir -p "${BASE}/${A_ARCH}"
mk_ok_tar "${BASE}/${A_ARCH}/files.tar.gz"
printf '%s\n' '{"type":"archive","status":"ok","archived":true}' > "${BASE}/${A_ARCH}/manifest.json"

mkdir -p "${BASE}/${A_OK2}"
mk_ok_tar "${BASE}/${A_OK2}/files.tar.gz"
printf '%s\n' '{"type":"site","status":"ok"}' > "${BASE}/${A_OK2}/manifest.json"

mkdir -p "${BASE}/${A_OK1}"
mk_ok_tar "${BASE}/${A_OK1}/files.tar.gz"
printf '%s\n' '{"type":"site","status":"ok"}' > "${BASE}/${A_OK1}/manifest.json"

# overlap warn (ścieżka absolutna)
warn="$(hm_backup_local_warn_remote_overlap 2>&1 || true)"
if printf '%s' "${warn}" | grep -qi 'pokrywa'; then
  pass "(0) ostrzeżenie overlap BACKUP_LOCAL_ROOT/RCLONE_REMOTE"
else
  fail "(0) brak ostrzeżenia overlap: ${warn}"
fi
# forma local:/… + końcowy /
export RCLONE_REMOTE="local:${TMP}/remote/"
warn="$(hm_backup_local_warn_remote_overlap 2>&1 || true)"
if printf '%s' "${warn}" | grep -qi 'pokrywa'; then
  pass "(0b) ostrzeżenie overlap local:/…"
else
  fail "(0b) brak ostrzeżenia local:/…: ${warn}"
fi
export RCLONE_REMOTE="${TMP}/remote"

# --yes w parserze (nie „Nie znaleziono strony: --yes”)
hm_find_site_by_arg() { printf '%s' "$1"; }
hm_is_valid_domain() { [[ "$1" == *.* ]]; }
hm_load_config() { :; }
hm_confirm_plan() {
  local a
  for a in "$@"; do [[ "$a" == "--yes" ]] && return 0; done
  echo "confirm-missing-yes" >&2
  return 1
}
hm_backup_acquire_lock() { return 0; }
hm_backup_release_lock() { :; }
hm_backup_site() { return 0; }
yes_err="$(hm_backup_local_site shop.example.test --keep 2 --yes 2>&1 || true)"
if printf '%s' "${yes_err}" | grep -qiE 'Nie znaleziono strony: --yes|Nieznany argument: --yes|confirm-missing-yes'; then
  fail "(0c) --yes źle sparsowane: ${yes_err}"
else
  pass "(0c) --yes rozpoznane w parserze"
fi
grep -qE '\-\-yes\|-y' commands/backup/local.sh && pass "(0d) --yes w local.sh" || fail "(0d) brak --yes"

hm_backup_local_prune_domain "${DOMAIN}" 2

[[ -d "${BASE}/${A_ARCH}" ]] && pass "(1) archive zachowany" || fail "(1) archive skasowany"
[[ ! -d "${BASE}/${A_BAD}" ]] && pass "(2) uszkodzony usunięty" || fail "(2) uszkodzony został"
[[ -d "${BASE}/${A_OK2}" ]] && pass "(3) nowszy ok zachowany" || fail "(3) ok2 skasowany"
[[ -d "${BASE}/${A_OK1}" ]] && pass "(4) starszy ok zachowany (keep=2)" || fail "(4) ok1 skasowany mimo keep=2"

# keep=1 → zostaje archive + 1 najnowszy ok
mk_ok_tar "${BASE}/${A_OK1}/files.tar.gz"
printf '%s\n' '{"type":"site","status":"ok"}' > "${BASE}/${A_OK1}/manifest.json"
hm_backup_local_prune_domain "${DOMAIN}" 1
[[ -d "${BASE}/${A_ARCH}" ]] && pass "(5) archive przy keep=1" || fail "(5) archive przy keep=1"
[[ -d "${BASE}/${A_OK2}" ]] && pass "(6) najnowszy ok przy keep=1" || fail "(6) ok2 przy keep=1"
[[ ! -d "${BASE}/${A_OK1}" ]] && pass "(7) starszy ok usunięty przy keep=1" || fail "(7) ok1 został przy keep=1"

# (8) 2 dobre + 1 ucięty (status=ok, plik istnieje) — keep=2 ⇒ dwa dobre, ucięty poza N
A_TRUNC="20261122-190000"
A_G1="20261122-185000"
A_G2="20261122-184000"
rm -rf "${BASE:?}/${A_OK2}" "${BASE:?}/${A_OK1}" "${BASE:?}/${A_BAD}" 2>/dev/null || true
mkdir -p "${BASE}/${A_TRUNC}" "${BASE}/${A_G1}" "${BASE}/${A_G2}"
mk_ok_tar "${BASE}/${A_G1}/files.tar.gz"
mk_ok_tar "${BASE}/${A_G2}/files.tar.gz"
mk_ok_tar "${TMP}/full.tar.gz"
# ucięcie ~40% — gzip -t fail, plik obecny, status=ok
dd if="${TMP}/full.tar.gz" of="${BASE}/${A_TRUNC}/files.tar.gz" bs=1 count=40 2>/dev/null \
  || head -c 40 "${TMP}/full.tar.gz" > "${BASE}/${A_TRUNC}/files.tar.gz"
printf '%s\n' '{"type":"site","status":"ok"}' > "${BASE}/${A_TRUNC}/manifest.json"
printf '%s\n' '{"type":"site","status":"ok"}' > "${BASE}/${A_G1}/manifest.json"
printf '%s\n' '{"type":"site","status":"ok"}' > "${BASE}/${A_G2}/manifest.json"

hm_backup_local_prune_domain "${DOMAIN}" 2
[[ -d "${BASE}/${A_ARCH}" ]] && pass "(8a) archive nadal chroniony" || fail "(8a) archive skasowany"
[[ -d "${BASE}/${A_G1}" && -d "${BASE}/${A_G2}" ]] && pass "(8b) dwa dobre zostają przy keep=2" || fail "(8b) dobre skasowane"
[[ ! -d "${BASE}/${A_TRUNC}" ]] && pass "(8c) ucięty status=ok usunięty (nie w N)" || fail "(8c) ucięty został i wyparł dobre"

if [[ "${FAIL}" -eq 0 ]]; then
  echo "ALL PASSED (${PASS})"
else
  echo "FAILED (${FAIL} fail, ${PASS} pass)" >&2
  exit 1
fi
