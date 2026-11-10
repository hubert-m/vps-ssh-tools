#!/usr/bin/env bash
# backup verify: izolowany drill, sprzątanie, tar/dump/klucz, cele local/s3/restic.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hmtools-verify-test.XXXXXX")"
fail=0
ok() { echo "OK   $*"; }
bad() { echo "FAIL $*"; fail=1; }

hm_err() { echo "$*" >&2; }
hm_confirm_plan() { return 0; }
hm_notify() { printf '%s\n' "$*" >> "${HM_BACKUP_VERIFY_ALERTS}"; }

export HM_BACKUP_VERIFY_HISTORY="${TMP}/history.jsonl"
export HM_BACKUP_VERIFY_ALERTS="${TMP}/alerts.txt"
export TMP_DIR="${TMP}/work"
export LOG_DIR="${TMP}/logs"
export HM_BACKUP_VERIFY_CRON="${TMP}/cron/hmtools-backup-verify"
export HM_BACKUP_VERIFY_MODE_LOG="${TMP}/mode.txt"
export HM_MYSQL_LOG="${TMP}/mysql.log"
export HM_MYSQL_SQL="${TMP}/last.sql"
export HM_RCLONE_LOG="${TMP}/rclone.log"
export HM_RESTIC_LOG="${TMP}/restic.log"
export HM_BACKUP_VERIFY_MYSQL="${TMP}/mysql.sh"
export HM_BACKUP_VERIFY_RCLONE_BIN="${TMP}/rclone.sh"
export HM_BACKUP_VERIFY_RESTIC_BIN="${TMP}/restic.sh"
export HM_BACKUP_VERIFY_RESTIC_REPO="restic-test:repo"
export BACKUP_LOCAL_ROOT="${TMP}/local-root"
mkdir -p "${TMP_DIR}" "${LOG_DIR}"

cat > "${HM_BACKUP_VERIFY_MYSQL}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HM_MYSQL_LOG}"
if [[ "$*" == *"information_schema"* ]]; then
  echo 1
  exit 0
fi
if [[ "$*" == *"CREATE DATABASE"* || "$*" == *"DROP DATABASE"* ]]; then
  exit 0
fi
cat > "${HM_MYSQL_SQL}"
if [[ "${HM_MYSQL_FAIL:-}" == "1" ]]; then
  exit 1
fi
if grep -Eiq 'USE[[:space:]]|CREATE[[:space:]]+DATABASE|DROP[[:space:]]+DATABASE' "${HM_MYSQL_SQL}"; then
  echo "LIVE SQL" >> "${HM_MYSQL_LOG}"
  exit 99
fi
echo "IMPORT $1" >> "${HM_MYSQL_LOG}"
exit 0
EOF

cat > "${HM_BACKUP_VERIFY_RCLONE_BIN}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HM_RCLONE_LOG}"
dest="${!#}"
mkdir -p "${dest}"
cp -a "${HM_BACKUP_VERIFY_FIXTURE}/." "${dest}/"
EOF

cat > "${HM_BACKUP_VERIFY_RESTIC_BIN}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HM_RESTIC_LOG}"
if [[ -n "${RESTIC_PASSWORD_FILE:-}" ]] && grep -q 'BADKEY-SECRET' "${RESTIC_PASSWORD_FILE}"; then
  echo "wrong password" >&2
  exit 1
fi
dest=""
prev=""
for a in "$@"; do
  if [[ "${prev}" == "--target" ]]; then
    dest="${a}"
  fi
  prev="${a}"
done
mkdir -p "${dest}"
cp -a "${HM_BACKUP_VERIFY_FIXTURE}/." "${dest}/"
EOF

mk_good() {
  local d="$1" sum
  mkdir -p "${d}/db" "${d}/payload"
  echo hello > "${d}/payload/index.html"
  tar -czf "${d}/files.tar.gz" -C "${d}/payload" index.html
  printf '%s\n' 'CREATE TABLE t (id INT);' 'USE live_shop;' 'CREATE DATABASE live_shop;' | gzip -c > "${d}/db/shop.sql.gz"
  sum="$(sha256sum "${d}/files.tar.gz" | awk '{print $1}')"
  sum="${sum#\\}"
  printf '%s  %s\n' "${sum}" "files.tar.gz" > "${d}/SHA256SUMS"
  printf '{"sha256_files":"%s","domain":"example.pl"}\n' "${sum}" > "${d}/manifest.json"
}

mk_good "${TMP}/good"
mkdir -p "${BACKUP_LOCAL_ROOT}/example.pl"
cp -a "${TMP}/good" "${BACKUP_LOCAL_ROOT}/example.pl/20260101"
export HM_BACKUP_VERIFY_FIXTURE="${TMP}/good"

# shellcheck disable=SC1091
source commands/backup/verify.sh

left_work() {
  find "${TMP_DIR}" -maxdepth 1 -name 'hmtools-verify.*' 2>/dev/null | wc -l | tr -d '[:space:]'
}

: > "${HM_MYSQL_LOG}"
: > "${HM_BACKUP_VERIFY_ALERTS}"
js="$(hm_backup_verify_cmd example.pl 20260101 --targets local,s3,b2,gdrive,sftp --json)" || true
printf '%s\n' "${js}" | grep -q '"result":"PASS"' && ok "dobry snapshot PASS" || bad "brak PASS: ${js}"
grep -q 'hmtools-s3:backup/example.pl/20260101' "${HM_RCLONE_LOG}" && ok "rclone s3" || bad "brak rclone s3"
grep -q 'hmtools-b2:backup/example.pl/20260101' "${HM_RCLONE_LOG}" && ok "rclone b2" || bad "brak rclone b2"
grep -q 'hmtools-gdrive:backup/example.pl/20260101' "${HM_RCLONE_LOG}" && ok "rclone gdrive" || bad "brak rclone gdrive"
grep -q 'hmtools-sftp:backup/example.pl/20260101' "${HM_RCLONE_LOG}" && ok "rclone sftp" || bad "brak rclone sftp"
grep -q 'IMPORT hmtools_verify_' "${HM_MYSQL_LOG}" && ok "import do bazy drill" || bad "brak importu"
grep -q 'DROP DATABASE IF EXISTS `hmtools_verify_' "${HM_MYSQL_LOG}" && ok "DROP po drill" || bad "brak DROP"
if grep -q 'live_shop' "${HM_MYSQL_SQL}" || grep -q 'LIVE SQL' "${HM_MYSQL_LOG}"; then
  bad "SQL żywego sklepu doszedł do mysql"
else
  ok "USE/CREATE DATABASE odfiltrowane"
fi
if grep -q 'CREATE DATABASE `live_shop`' "${HM_MYSQL_LOG}"; then
  bad "utworzono żywą bazę"
else
  ok "brak żywej bazy w mysql"
fi
[[ "$(left_work)" == "0" ]] && ok "katalog drill sprzątnięty" || bad "został katalog drill"
if [[ -f "${HM_BACKUP_VERIFY_MODE_LOG}" ]]; then
  mode="$(tr -d '[:space:]' < "${HM_BACKUP_VERIFY_MODE_LOG}")"
  probe="$(mktemp -d "${TMP}/probe.XXXXXX")"
  chmod 0700 "${probe}" 2>/dev/null || true
  pmode="$(stat -c '%a' "${probe}" 2>/dev/null || echo "")"
  rmdir "${probe}" 2>/dev/null || true
  if [[ "${pmode}" == "700" || "${pmode}" == "0700" ]]; then
    [[ "${mode}" == "700" || "${mode}" == "0700" ]] && ok "katalog 0700" || bad "mode=${mode}"
  else
    ok "chmod 0700 bez efektu na tej platformie (${pmode})"
  fi
fi

# ucięty tar
mkdir -p "${TMP}/cut/db"
echo 'not-a-tar' > "${TMP}/cut/files.tar.gz"
printf '%s\n' 'CREATE TABLE t (id INT);' | gzip -c > "${TMP}/cut/db/shop.sql.gz"
rm -rf "${BACKUP_LOCAL_ROOT}/example.pl/cut"
cp -a "${TMP}/cut" "${BACKUP_LOCAL_ROOT}/example.pl/cut"
: > "${HM_BACKUP_VERIFY_ALERTS}"
if hm_backup_verify_cmd example.pl cut --target local >/dev/null; then
  bad "ucięty tar przeszedł"
else
  ok "ucięty tar FAIL"
fi
grep -q 'uszkodzony tar' "${HM_BACKUP_VERIFY_ALERTS}" && ok "alert tar" || bad "brak alertu tar"
[[ "$(left_work)" == "0" ]] && ok "sprzątanie po tar" || bad "został katalog po tar"

# pusty dump
mkdir -p "${TMP}/empty/db" "${TMP}/empty/payload"
echo x > "${TMP}/empty/payload/a.txt"
tar -czf "${TMP}/empty/files.tar.gz" -C "${TMP}/empty/payload" a.txt
printf '' | gzip -c > "${TMP}/empty/db/shop.sql.gz"
esum="$(sha256sum "${TMP}/empty/files.tar.gz" | awk '{print $1}')"
esum="${esum#\\}"
printf '%s  %s\n' "${esum}" files.tar.gz > "${TMP}/empty/SHA256SUMS"
printf '{"sha256_files":"%s"}\n' "${esum}" > "${TMP}/empty/manifest.json"
rm -rf "${BACKUP_LOCAL_ROOT}/example.pl/empty"
cp -a "${TMP}/empty" "${BACKUP_LOCAL_ROOT}/example.pl/empty"
: > "${HM_BACKUP_VERIFY_ALERTS}"
if hm_backup_verify_cmd example.pl empty --target local >/dev/null; then
  bad "pusty dump przeszedł"
else
  ok "pusty dump FAIL"
fi
grep -q 'pusty dump' "${HM_BACKUP_VERIFY_ALERTS}" && ok "alert pusty dump" || bad "brak alertu dumpa"
[[ "$(left_work)" == "0" ]] && ok "sprzątanie po pustym dumpie" || bad "został katalog po dumpie"

# zły klucz restic — sekret nie wchodzi do raportu ani alertu
printf '%s\n' 'BADKEY-SECRET' > "${TMP}/bad.pass"
export HM_BACKUP_VERIFY_PASSFILE="${TMP}/bad.pass"
: > "${HM_BACKUP_VERIFY_ALERTS}"
: > "${HM_RESTIC_LOG}"
if hm_backup_verify_cmd example.pl 20260101 --target restic >/dev/null; then
  bad "zły klucz przeszedł"
else
  ok "zły klucz FAIL"
fi
grep -q 'zly klucz' "${HM_BACKUP_VERIFY_ALERTS}" && ok "alert klucza" || bad "brak alertu klucza"
if grep -q 'BADKEY-SECRET' "${HM_BACKUP_VERIFY_ALERTS}" "${HM_BACKUP_VERIFY_HISTORY}" "${HM_RESTIC_LOG}"; then
  bad "sekret klucza w raporcie"
else
  ok "sekret klucza poza raportem"
fi
[[ "$(left_work)" == "0" ]] && ok "sprzątanie po złym kluczu" || bad "został katalog po kluczu"

# import pada — DROP i tak jest
printf '%s\n' 'ok-pass' > "${TMP}/ok.pass"
export HM_BACKUP_VERIFY_PASSFILE="${TMP}/ok.pass"
export HM_MYSQL_FAIL=1
: > "${HM_MYSQL_LOG}"
if hm_backup_verify_cmd example.pl 20260101 --target local >/dev/null; then
  bad "padający import przeszedł"
else
  ok "import FAIL"
fi
grep -q 'DROP DATABASE IF EXISTS `hmtools_verify_' "${HM_MYSQL_LOG}" && ok "DROP po błędzie importu" || bad "brak DROP po imporcie"
[[ "$(left_work)" == "0" ]] && ok "sprzątanie po imporcie" || bad "został katalog po imporcie"
unset HM_MYSQL_FAIL

# restic dobry + schedule
if hm_backup_verify_cmd example.pl 20260101 --target restic --json | grep -q '"result":"PASS"'; then
  ok "restic PASS"
else
  bad "restic nie PASS"
fi
hm_backup_verify_cmd schedule enable >/dev/null
grep -q 'backup verify --weekly --yes' "${HM_BACKUP_VERIFY_CRON}" && ok "cron tygodniowy" || bad "brak crona"
hm_backup_verify_cmd schedule disable >/dev/null
[[ ! -f "${HM_BACKUP_VERIFY_CRON}" ]] && ok "cron usunięty" || bad "cron został"

if grep -q 'BADKEY-SECRET' "${HM_BACKUP_VERIFY_HISTORY}"; then
  bad "historia zawiera sekret"
else
  ok "historia bez sekretu"
fi

rm -rf "${TMP}"
if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
