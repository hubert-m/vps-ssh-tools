#!/usr/bin/env bash
# restore-full: bez --overwrite-db nie rusza niepustych; gzip fail ⇒ rc≠0; ścieżka full/sites.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { :; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }
hm_mktemp() { mktemp "${TMPDIR:-/tmp}/hm.XXXXXX${1:-}"; }
hm_is_valid_db_name() { [[ "$1" =~ ^[A-Za-z0-9_]+$ ]]; }
hm_sql_quote() { printf "'%s'" "${1//\'/\'\'}"; }
hm_confirm_plan_critical() { return 0; }
hm_load_config() { :; }
hm_detect_all() { :; }
hm_rclone_check() { return 0; }
hm_backup_acquire_lock() { return 0; }
hm_backup_release_lock() { return 0; }
hm_backup_abort_if_enc_without_passphrase() { return 0; }
hm_backup_list_stamps() { printf '%s\n' "20261122-174121"; }
hm_backup_dest_full() { printf '%s' "${REMOTE_FULL}/$1"; }
hm_backup_snapshot_is_incomplete() { return 1; }
hm_backup_restore_db_accounts() { return 0; }
hm_backup_fetch_maybe_decrypt() { return 1; }
hm_mysql_cli() { printf '%s' "${MYSQL_BIN}"; }
PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hm-restore-full.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
REMOTE_FULL="${TMP}/full"
STAMP="20261122-174121"
mkdir -p "${REMOTE_FULL}/${STAMP}/databases" "${REMOTE_FULL}/${STAMP}/sites/shop.test"
export DB_NONEMPTY_MARK="${TMP}/nonempty"
mkdir -p "${DB_NONEMPTY_MARK}"
touch "${DB_NONEMPTY_MARK}/blog_app"

# dobre dumpy
printf 'SELECT 1;\n' | gzip > "${REMOTE_FULL}/${STAMP}/databases/blog_app.sql.gz"
printf 'SELECT 1;\n' | gzip > "${REMOTE_FULL}/${STAMP}/databases/new_only.sql.gz"
# uszkodzony
printf 'x' > "${REMOTE_FULL}/${STAMP}/databases/broken_app.sql.gz"

# mock mysql: loguj CREATE/import; czytaj stdin
MYSQL_BIN="${TMP}/mysql.sh"
cat > "${MYSQL_BIN}" <<EOF
#!/bin/sh
echo "mysql \$*" >> "${TMP}/mysql.log"
cat >/dev/null
exit 0
EOF
chmod +x "${MYSQL_BIN}"
: > "${TMP}/mysql.log"

mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/rclone" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  lsf)
    p="$2"
    [[ -d "${p}" ]] && ls -1 "${p}" 2>/dev/null
    ;;
  lsd)
    p="$2"
    if [[ -d "${p}" ]]; then
      for d in "${p}"/*; do
        [[ -d "${d}" ]] && echo "0 0000-00-00 00:00:00 -1 $(basename "${d}")"
      done
    fi
    ;;
  cat) cat "$2" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "${TMP}/bin/rclone"
export PATH="${TMP}/bin:${PATH}"
export TMP REMOTE_FULL

# shellcheck disable=SC1091
source commands/backup/restore.sh
# Nadpisz po source
hm_backup_db_is_nonempty() { [[ -f "${DB_NONEMPTY_MARK}/$1" ]]; }

# (a) bez overwrite — pomiń blog_app, broken ⇒ fail
set +e
out="$(hm_backup_restore_full "${STAMP}" 2>&1)"
rc=$?
set -e
printf '%s\n' "${out}" > "${TMP}/err.txt"
if [[ "${rc}" -ne 0 ]]; then
  pass "(a) rc≠0 przy uszkodzonym dumpie"
else
  fail "(a) oczekiwano rc≠0, rc=${rc}"
fi
if printf '%s' "${out}" | grep -q 'Pomijam istniejącą'; then
  pass "(a) istniejąca baza pominięta bez --overwrite-db"
else
  fail "(a) brak pominięcia blog_app: ${out}"
fi

# (b) ścieżka full/sites rozpoznana przez dest fallback (jednostkowo)
full_site="$(hm_backup_dest_full "${STAMP}")/sites/shop.test"
[[ -d "${full_site}" ]] && pass "(b) full/.../sites/shop.test istnieje" || fail "(b) brak sites"

# (c) z --overwrite-db tylko dobre dumpy (bez broken)
rm -f "${REMOTE_FULL}/${STAMP}/databases/broken_app.sql.gz"
: > "${TMP}/mysql.log"
set +e
outc="$(hm_backup_restore_full "${STAMP}" --overwrite-db 2>&1)"
rc=$?
set -e
[[ "${rc}" -eq 0 ]] && pass "(c) restore-full --overwrite-db rc=0 bez broken" || fail "(c) rc=${rc} ${outc}"

if [[ "${FAIL}" -eq 0 ]]; then
  echo "ALL PASSED (${PASS})"
else
  echo "FAILED (${FAIL} fail, ${PASS} pass)" >&2
  exit 1
fi
