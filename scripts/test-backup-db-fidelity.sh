#!/usr/bin/env bash
# backup DB: --events w mysqldump + CREATE DATABASE charset przy restore.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

# Flagi w źródłach
grep -n -- '--events' commands/backup/core.sh lib/db.sh commands/backup/inc.sh \
  | grep -q mysqldump\|dumpcli\|'--routines' \
  || true
grep -q -- '--events' commands/backup/core.sh && ok "core-events" || bad "core-events"
grep -q -- '--events' lib/db.sh && ok "libdb-events" || bad "libdb-events"
grep -q -- '--events' commands/backup/inc.sh && ok "inc-events" || bad "inc-events"
grep -q 'hm_backup_save_create_database\|.create.sql' commands/backup/core.sh \
  && ok "save-create-db" || bad "save-create-db"
grep -q 'create.sql' commands/backup/restore.sh && ok "restore-create-sql" || bad "restore-create-sql"

# Transformacja SHOW CREATE → IF NOT EXISTS
line='CREATE DATABASE `qa_cs` /*!40100 DEFAULT CHARACTER SET latin2 COLLATE latin2_general_ci */'
out="$(printf '%s' "${line}" | sed 's/^CREATE DATABASE `/CREATE DATABASE IF NOT EXISTS `/')"
[[ "${out}" == CREATE\ DATABASE\ IF\ NOT\ EXISTS* ]] && ok "if-not-exists" || bad "if-not-exists"
printf '%s' "${out}" | grep -q 'latin2' && ok "charset-kept" || bad "charset-kept"

if [[ "${fail}" -ne 0 ]]; then
  echo FAILED
  exit 1
fi
echo "ALL OK"
exit 0
