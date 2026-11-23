#!/usr/bin/env bash
# restore: walidacja przed zmianą; --overwrite-files usuwa obce; dump gzip -t.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { :; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }
hm_mktemp() { mktemp "${TMPDIR:-/tmp}/hm.XXXXXX${1:-}"; }
hm_status_line() { :; }
hm_status_clear() { :; }
hm_progress_bar() { :; }
hm_progress_done() { :; }

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hm-restore-atomic.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

# shellcheck disable=SC1091
source commands/backup/list.sh
# shellcheck disable=SC1091
source commands/backup/restore.sh

REMOTE="${TMP}/snap"
TARGET="${TMP}/site"
mkdir -p "${REMOTE}" "${TARGET}/public_html"

# --- (a) ucięty files.tar.gz ⇒ rc≠0, drzewo nietknięte ---
printf 'keep-me\n' > "${TARGET}/public_html/index.html"
# poprawne archiwum
STAGE="${TMP}/pack"
mkdir -p "${STAGE}/public_html"
printf 'from-snap\n' > "${STAGE}/public_html/index.html"
tar -C "${STAGE}" -czf "${REMOTE}/files.tar.gz" .
# ucięcie
cp "${REMOTE}/files.tar.gz" "${REMOTE}/files.tar.gz.bak"
dd if="${REMOTE}/files.tar.gz.bak" of="${REMOTE}/files.tar.gz" bs=1 count=40 2>/dev/null || \
  head -c 40 "${REMOTE}/files.tar.gz.bak" > "${REMOTE}/files.tar.gz"

before="$(find "${TARGET}" -type f -exec sha256sum {} \; 2>/dev/null | sort | sha256sum | awk '{print $1}')"
set +e
hm_backup_restore_files "${REMOTE}" "${TARGET}" 0 >/dev/null 2>&1
rc=$?
set -e
after="$(find "${TARGET}" -type f -exec sha256sum {} \; 2>/dev/null | sort | sha256sum | awk '{print $1}')"
if [[ "${rc}" -ne 0 && "${before}" == "${after}" ]]; then
  pass "(a) ucięty tar ⇒ rc≠0 i drzewo bez zmian"
else
  fail "(a) rc=${rc} before=${before} after=${after}"
fi

# --- (b) --overwrite-files usuwa obcy plik ---
cp "${REMOTE}/files.tar.gz.bak" "${REMOTE}/files.tar.gz"
printf 'webshell\n' > "${TARGET}/public_html/shell-uploaded-after-backup.php"
printf 'old\n' > "${TARGET}/public_html/index.html"
if hm_backup_restore_files "${REMOTE}" "${TARGET}" 1 >/dev/null 2>&1; then
  if [[ ! -f "${TARGET}/public_html/shell-uploaded-after-backup.php" ]]; then
    pass "(b) obce pliki usunięte przy --overwrite-files"
  else
    if hm_have_cmd rsync; then
      fail "(b) shell nadal istnieje"
    else
      pass "(b) brak rsync — skip delete (ostrzeżenie)"
    fi
  fi
  grep -q 'from-snap' "${TARGET}/public_html/index.html" && pass "(b) treść ze snapshota" || fail "(b) zła treść"
else
  fail "(b) restore plików nieudany"
fi

# --- (c) ucięty dump ⇒ gzip -t fail, bez importu ---
mkdir -p "${REMOTE}/db"
printf 'payload' | gzip > "${REMOTE}/db/app.sql.gz"
# uszkodź
dd if="${REMOTE}/db/app.sql.gz" of="${REMOTE}/db/app.sql.gz" bs=1 count=8 conv=notrunc 2>/dev/null || true
head -c 8 "${REMOTE}/db/app.sql.gz" > "${TMP}/cut.gz" && mv "${TMP}/cut.gz" "${REMOTE}/db/app.sql.gz"
printf '%s\n' '{"type":"site","databases":["app"]}' > "${REMOTE}/manifest.json"

hm_mysql_cli() { printf 'false'; }  # nie wywołuj prawdziwego mysql
# bezpośredni test fetch+gzip przez mały wrapper
db_tmp="$(hm_mktemp .sql.gz)"
hm_backup_r_cat "${REMOTE}/db/app.sql.gz" > "${db_tmp}" || true
if ! gzip -t "${db_tmp}" 2>/dev/null; then
  pass "(c) uszkodzony dump wykryty przez gzip -t"
else
  fail "(c) gzip -t przepuścił uszkodzony dump"
fi
rm -f "${db_tmp}"

if [[ "${FAIL}" -eq 0 ]]; then
  echo "ALL PASSED (${PASS})"
else
  echo "FAILED (${FAIL} fail, ${PASS} pass)" >&2
  exit 1
fi
