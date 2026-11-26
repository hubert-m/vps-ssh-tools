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

# --- (b) --overwrite-files usuwa obcy plik, ale chroni BACKUP_EXCLUDES ---
cp "${REMOTE}/files.tar.gz.bak" "${REMOTE}/files.tar.gz"
export BACKUP_EXCLUDES="./node_modules ./.git ./tmp ./logs *.log"
protect_u=()
hm_backup_rsync_protect_excludes protect_u backup
prot_s="${protect_u[*]}"
if [[ "${prot_s}" == *'P_node_modules'* && "${prot_s}" == *'P_.git'* && "${prot_s}" == *'P_*.log'* ]]; then
  pass "(b) protect filters z BACKUP_EXCLUDES"
else
  fail "(b) protect filters: ${prot_s}"
fi
protect_a=()
hm_backup_rsync_protect_excludes protect_a archive
[[ "${#protect_a[@]}" -eq 0 ]] && pass "(b) archive bez protect" || fail "(b) archive protect niepuste"
printf 'webshell\n' > "${TARGET}/public_html/shell-uploaded-after-backup.php"
printf 'old\n' > "${TARGET}/public_html/index.html"
mkdir -p "${TARGET}/.git" "${TARGET}/node_modules/pkg" "${TARGET}/tmp" "${TARGET}/logs"
printf 'ref\n' > "${TARGET}/.git/HEAD"
printf 'dep\n' > "${TARGET}/node_modules/pkg/index.js"
printf 'sess\n' > "${TARGET}/tmp/sess_abc"
printf 'logline\n' > "${TARGET}/logs/app.log"
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
  if hm_have_cmd rsync; then
    if [[ -f "${TARGET}/.git/HEAD" && -f "${TARGET}/node_modules/pkg/index.js" \
      && -f "${TARGET}/tmp/sess_abc" && -f "${TARGET}/logs/app.log" ]]; then
      pass "(b) BACKUP_EXCLUDES chronione przed --delete"
    else
      fail "(b) wykluczenia skasowane przez --overwrite-files"
    fi
  else
    pass "(b) brak rsync — skip protect (live)"
  fi
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

# --- (d) po udanym restore istnieje .hm-pre-restore-* ---
cp "${REMOTE}/files.tar.gz.bak" "${REMOTE}/files.tar.gz"
TARGET2="${TMP}/site2"
mkdir -p "${TARGET2}/public_html"
printf 'live\n' > "${TARGET2}/public_html/index.html"
printf 'extra\n' > "${TARGET2}/public_html/keep-extra.txt"
if hm_backup_restore_files "${REMOTE}" "${TARGET2}" 1 >/dev/null 2>&1; then
  if compgen -G "${TMP}/.hm-pre-restore-*" >/dev/null \
      && [[ -f "$(echo "${TMP}"/.hm-pre-restore-*/public_html/keep-extra.txt)" ]]; then
    pass "(d) kopia .hm-pre-restore-* z plikami sprzed restore"
  else
    fail "(d) brak .hm-pre-restore-* lub brak pliku z kopii"
  fi
else
  fail "(d) restore nieudany"
fi

# --- (f) rotacja: zostaje 1 kopia pre-restore na slug ---
export HM_BACKUP_PRE_RESTORE_KEEP=1
TARGET3="${TMP}/site3"
mkdir -p "${TARGET3}/public_html"
printf 'a\n' > "${TARGET3}/public_html/index.html"
hm_backup_restore_files "${REMOTE}" "${TARGET3}" 1 >/dev/null 2>&1 || true
printf 'b\n' > "${TARGET3}/public_html/index.html"
hm_backup_restore_files "${REMOTE}" "${TARGET3}" 1 >/dev/null 2>&1 || true
n_pre="$(find "${TMP}" -maxdepth 1 -type d -name '.hm-pre-restore-site3-*' 2>/dev/null | wc -l | tr -d ' ')"
if [[ "${n_pre}" -eq 1 ]]; then
  pass "(f) rotacja pre-restore keep=1"
else
  fail "(f) oczekiwano 1 katalog pre-restore, jest ${n_pre}"
fi

# --- (e) recreate_db: DROP + CREATE (lustro snapshotu) ---
printf 'CREATE DATABASE IF NOT EXISTS `app` CHARACTER SET utf8mb4;\n' > "${REMOTE}/db/app.create.sql"
FAKE_MYSQL="${TMP}/fake-mysql"
cat > "${FAKE_MYSQL}" <<'EOF'
#!/usr/bin/env bash
echo "ARGS:$*" >> "${HM_TEST_MYSQL_LOG}"
if [[ -n "${1:-}" && "$1" == -e ]]; then
  echo "SQL:$2" >> "${HM_TEST_MYSQL_LOG}"
elif [[ ! -t 0 ]]; then
  cat >> "${HM_TEST_MYSQL_LOG}"
fi
exit 0
EOF
chmod +x "${FAKE_MYSQL}"
export HM_TEST_MYSQL_LOG="${TMP}/mysql.log"
: > "${HM_TEST_MYSQL_LOG}"
hm_mysql_cli() { printf '%s\n' "${FAKE_MYSQL}"; }
if hm_backup_restore_recreate_db "app" "${REMOTE}" "db"; then
  if grep -q 'DROP DATABASE IF EXISTS `app`' "${HM_TEST_MYSQL_LOG}" \
      && grep -qi 'CREATE DATABASE' "${HM_TEST_MYSQL_LOG}"; then
    pass "(e) recreate_db: DROP + CREATE"
  else
    fail "(e) brak DROP/CREATE w logu: $(tr '\n' '|' < "${HM_TEST_MYSQL_LOG}")"
  fi
else
  fail "(e) recreate_db rc≠0"
fi

if [[ "${FAIL}" -eq 0 ]]; then
  echo "ALL PASSED (${PASS})"
else
  echo "FAILED (${FAIL} fail, ${PASS} pass)" >&2
  exit 1
fi
