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
hm_backup_restore_safety_dump_db() { hm_ok "mock safety dump $1 → ${TMP}/pre-restore-$1.sql.gz"; : > "${TMP}/pre-restore-$1.sql.gz"; return 0; }
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

# (d) --system: nie nadpisuje etc/passwd; błąd tar ⇒ rc≠0
FAKE_ROOT="${TMP}/sysroot"
mkdir -p "${FAKE_ROOT}/etc"
printf 'liveuser:x:1001:1001::/home/liveuser:/bin/bash\n' > "${FAKE_ROOT}/etc/passwd"
printf 'liveuser:$6$hash:19000:0:99999:7:::\n' > "${FAKE_ROOT}/etc/shadow"
# archiwum z passwd (inny) + sshd_config
mkdir -p "${TMP}/syspack/etc"
printf 'olduser:x:1000:1000::/home/old:/bin/bash\n' > "${TMP}/syspack/etc/passwd"
printf 'PermitRootLogin no\n' > "${TMP}/syspack/etc/ssh_config_hmtest"
tar -C "${TMP}/syspack" -czf "${REMOTE_FULL}/${STAMP}/system-configs.tar.gz" .
hm_backup_fetch_maybe_decrypt() {
  local base="$1" name="$2" out="$3"
  if [[ "${name}" == "system-configs.tar.gz" && -f "${base}/${name}" ]]; then
    cp -a "${base}/${name}" "${out}"
    return 0
  fi
  return 1
}
# unit: wykluczenia passwd + apply bez przenoszenia trybu ./ (0700 staging → root)
stage="${TMP}/sysstage"
mkdir -p "${stage}"
tar -xzf "${REMOTE_FULL}/${STAMP}/system-configs.tar.gz" -C "${stage}"
rm -f -- "${stage}/etc/passwd" "${stage}/etc/shadow" "${stage}/etc/group" "${stage}/etc/gshadow" 2>/dev/null || true
chmod 0755 "${FAKE_ROOT}"
chmod 0700 "${stage}"
printf 'OLDCONF\n' > "${FAKE_ROOT}/etc/ssh_config_hmtest"
mkdir -p "${FAKE_ROOT}/var/lib/mysql"
printf 'db\n' > "${FAKE_ROOT}/var/lib/mysql/ibdata"
export HM_BACKUP_PRE_SYSTEM_DIR="${TMP}/pre-system"
if ! hm_backup_apply_system_stage "${stage}" "${FAKE_ROOT}"; then
  fail "(d) hm_backup_apply_system_stage rc"
fi
root_mode="$(stat -c '%a' "${FAKE_ROOT}" 2>/dev/null || echo '?')"
if grep -q 'liveuser' "${FAKE_ROOT}/etc/passwd" \
  && [[ -f "${FAKE_ROOT}/etc/ssh_config_hmtest" ]] \
  && ! grep -q 'olduser' "${FAKE_ROOT}/etc/passwd" \
  && [[ "${root_mode}" == "755" ]]; then
  pass "(d) --system pomija passwd, stosuje inne pliki, / zostaje 755"
else
  fail "(d) passwd/ssh/mode root_mode=${root_mode}"
fi
pre_arc="$(echo "${HM_BACKUP_PRE_SYSTEM_DIR}"/system-*.tar.gz)"
if [[ -f "${pre_arc}" ]]; then
  listing="$(tar -tzf "${pre_arc}" 2>/dev/null || true)"
  if printf '%s\n' "${listing}" | grep -q 'etc/ssh_config_hmtest' \
      && ! printf '%s\n' "${listing}" | grep -q 'ibdata'; then
    pass "(d) pre-restore system tylko nadpisywane pliki"
  else
    fail "(d) pre-restore system ma zły zakres: ${listing}"
  fi
else
  fail "(d) brak pre-restore system-*.tar.gz"
fi
# nieudana kopia pre-restore ⇒ dest nietknięty
FAKE2="${TMP}/sysroot2"
mkdir -p "${FAKE2}/etc"
printf 'KEEP\n' > "${FAKE2}/etc/keep.conf"
mkdir -p "${TMP}/sysstage2/etc"
printf 'NEW\n' > "${TMP}/sysstage2/etc/keep.conf"
: > "${TMP}/pre-not-dir"
export HM_BACKUP_PRE_SYSTEM_DIR="${TMP}/pre-not-dir"
if hm_backup_apply_system_stage "${TMP}/sysstage2" "${FAKE2}"; then
  fail "(d2) apply przy złym katalogu pre-restore powinien paść"
else
  if grep -q '^KEEP$' "${FAKE2}/etc/keep.conf"; then
    pass "(d2) nieudany pre-restore system nie rusza dest"
  else
    fail "(d2) dest zmieniony mimo błędu kopii"
  fi
fi
export HM_BACKUP_PRE_SYSTEM_DIR="${TMP}/pre-system"
# uszkodzony tar system-configs ⇒ fail_n
printf 'not-a-gzip' > "${REMOTE_FULL}/${STAMP}/system-configs.tar.gz"
set +e
outd="$(hm_backup_restore_full "${STAMP}" --system --overwrite-db 2>&1)"
rc=$?
set -e
if [[ "${rc}" -ne 0 ]] && printf '%s' "${outd}" | grep -qi 'system-configs'; then
  pass "(d) uszkodzony system-configs ⇒ rc≠0"
else
  fail "(d) oczekiwano rc≠0 przy złym system-configs: rc=${rc}"
fi

if [[ "${FAIL}" -eq 0 ]]; then
  echo "ALL PASSED (${PASS})"
else
  echo "FAILED (${FAIL} fail, ${PASS} pass)" >&2
  exit 1
fi
