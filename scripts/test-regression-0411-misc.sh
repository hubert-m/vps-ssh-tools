#!/usr/bin/env bash
# Regresja drobiazgów 04.11: restore-full flags, CP strip id, SSH key typ+blob
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
# shellcheck disable=SC1091
source lib/common/ui.sh
hm_file_log_ui() { :; }

fail=0
assert_eq() {
  local name="$1" got="$2" want="$3"
  if [[ "${got}" != "${want}" ]]; then
    echo "FAIL ${name}: got=[${got}] want=[${want}]"
    fail=1
    return
  fi
  echo "OK   ${name}"
}

# --- SSH typ+blob ---
# shellcheck disable=SC1091
source commands/access/ssh.sh

k1="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeBlobForTest1234567890abcdefghijklmnop comment-a"
k2="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeBlobForTest1234567890abcdefghijklmnop other-comment"
k3="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDifferentBlobXXXXXXXXXXXXXXXXXXXXXXXXXXXX x"
assert_eq "blob-same" "$(hm_access_ssh_key_type_blob "${k1}")" "$(hm_access_ssh_key_type_blob "${k2}")"
[[ "$(hm_access_ssh_key_type_blob "${k1}")" != "$(hm_access_ssh_key_type_blob "${k3}")" ]] \
  && echo "OK   blob-diff" || { echo "FAIL blob-diff"; fail=1; }

kf="$(mktemp "${TMPDIR:-/tmp}/hmtools-keys.XXXXXX")"
printf '%s\n' "${k1}" > "${kf}"
hm_access_ssh_key_blob_exists "${k2}" "${kf}" && echo "OK   blob-exists-diff-comment" || { echo "FAIL blob-exists"; fail=1; }
hm_access_ssh_key_blob_exists "${k3}" "${kf}" && { echo "FAIL blob-should-miss"; fail=1; } || echo "OK   blob-miss"
rm -f "${kf}"

# --- CP strip id ---
# shellcheck disable=SC1091
source commands/backup/archive.sh
sqlf="$(mktemp "${TMPDIR:-/tmp}/hmtools-cp.XXXXXX.sql")"
cat > "${sqlf}" <<'EOF'
-- hmtools archive: CyberPanel rows for beta.test (source id=5; id stripped for restore)
USE `cyberpanel`;
INSERT INTO `websiteFunctions_websites` (`id`, `domain`, `adminEmail`) VALUES (5, 'beta.test', 'a@b.c');
INSERT INTO `databases_databases` (`id`, `website_id`, `dbName`) VALUES (9, 5, 'beta_db');
EOF
hm_archive_cp_sql_strip_explicit_ids "${sqlf}"
if grep -q '(`id`' "${sqlf}" || grep -qE 'VALUES \(5,' "${sqlf}"; then
  # website VALUES should no longer start with 5,
  if grep -q "VALUES (5, 'beta.test'" "${sqlf}"; then
    echo "FAIL cp-strip-website-id-value"
    fail=1
  fi
fi
if grep -q '(`id`' "${sqlf}"; then
  echo "FAIL cp-strip-id-column still present"
  fail=1
else
  echo "OK   cp-strip-id-column"
fi
grep -qE "VALUES \([[:space:]]*'beta.test'" "${sqlf}" && echo "OK   cp-strip-website-values" || {
  echo "FAIL cp-strip-website-values: $(cat "${sqlf}")"
  fail=1
}
# website_id w databases zostaje (mapowanie przy restore); id kolumny usunięte
grep -qE "website_id.*,.*dbName" "${sqlf}" && echo "OK   cp-strip-db-keeps-website-id-col" || {
  echo "FAIL cp-db-cols"
  fail=1
}

# --- CP FK remap complete-insert (pozycyjne VALUES, nie website_id=) ---
# shellcheck disable=SC1091
source commands/backup/restore.sh
map_in="$(mktemp "${TMPDIR:-/tmp}/hmtools-cp-map-in.XXXXXX.sql")"
map_out="$(mktemp "${TMPDIR:-/tmp}/hmtools-cp-map-out.XXXXXX.sql")"
cat > "${map_in}" <<'EOF'
INSERT INTO `databases_databases` (`dbName`, `dbUser`, `website_id`) VALUES ('beta_db', 'beta_u', 2);
INSERT INTO databases_databases (dbName,dbUser,website_id) VALUES ('beta_db','beta_u',2);
INSERT INTO `websiteFunctions_childdomains` (`domain`, `master_id`) VALUES ('c.beta.test', 2);
EOF
hm_backup_cp_sql_remap_fk_ids "${map_in}" "${map_out}" 2 4
remap_ok=1
grep -q ", 4);" "${map_out}" || remap_ok=0
grep -q ", 2);" "${map_out}" && remap_ok=0
# trzy linie INSERT, każda z nowym id
[[ "$(grep -c ", 4);" "${map_out}" || true)" -eq 3 ]] || remap_ok=0
if [[ "${remap_ok}" -eq 1 ]]; then
  echo "OK   cp-fk-remap-positional"
else
  echo "FAIL cp-fk-remap-positional: $(cat "${map_out}")"
  fail=1
fi
rm -f "${map_in}" "${map_out}" "${sqlf}"

# --- restore-full arg parse (bez rclone) ---
hm_load_config() { :; }
hm_detect_all() { :; }
hm_rclone_check() { return 0; }
hm_backup_acquire_lock() { return 0; }
hm_backup_release_lock() { :; }
hm_err() { printf 'ERR:%s\n' "$*"; }
hm_info() { :; }
hm_ok() { :; }
hm_warn() { :; }
hm_confirm_plan_critical() { return 1; } # anuluj po parse
hm_backup_list_stamps() { printf '20261104-120000\n'; }
hm_backup_dest_full() { printf 'remote/full/%s\n' "$1"; }
hm_backup_snapshot_is_incomplete() { return 1; }

# restore.sh już sourced powyżej (cp-fk-remap)

# --system jako pierwszy arg NIE może być stampem
out="$(hm_backup_restore_full --system 2>&1)" && rc=0 || rc=$?
case "${out}" in
  *'Nieprawidłowy stamp: --system'*)
    echo "FAIL restore-full-system-as-stamp"
    fail=1
    ;;
  *)
    # confirm anulowany po wyborze stampu — OK
    echo "OK   restore-full-system-flag-parse (rc=${rc})"
    ;;
esac

out="$(hm_backup_restore_full --system 20261104-120000 2>&1)" && rc=0 || rc=$?
case "${out}" in
  *'Nieprawidłowy stamp'*)
    echo "FAIL restore-full-with-stamp: ${out}"
    fail=1
    ;;
  *)
    echo "OK   restore-full-system-and-stamp"
    ;;
esac

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL OK"
exit 0
