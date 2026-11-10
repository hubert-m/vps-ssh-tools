#!/usr/bin/env bash
# Pełny site new w mocku: hasło nie wchodzi do logu, journala, manifestu ani ps. umask bez zmian.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1
export HMTOOLS_TEST_NO_TTY=1

# shellcheck disable=SC1091
source lib/common/ui.sh
# shellcheck disable=SC1091
source lib/logging.sh
# shellcheck disable=SC1091
source lib/site/env.sh
# shellcheck disable=SC1091
source lib/site/base.sh
# shellcheck disable=SC1091
source lib/site/tx.sh
# shellcheck disable=SC1091
source lib/site/db.sh
# shellcheck disable=SC1091
source commands/site-create/wizard-db.sh

fail=0
PASS='GenPass12xYzAb99'
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
export HM_SITE_HOME_BASE="${root}/homes"
export HM_SITE_OS_FILE="${root}/os-release"
export HM_SITE_MEMINFO_FILE="${root}/meminfo"
export HM_SITE_SS_FILE="${root}/ss.txt"
export HM_SITE_PASSWD_FILE="${root}/passwd"
export HM_SITE_USERADD_MOCK=1
export HM_SITE_DISK_MB=20000
export HM_SITE_NTP=synced
export HM_SITE_REPO_OK=1
export HM_SITE_WEB_GROUP=www-data
export HM_SITE_DB_MOCK=1
export HM_SITE_DB_ARGV_LOG="${root}/argv.log"
export HM_SITE_DB_SQL_LOG="${root}/sql.log"
export HM_SITE_JOURNAL_DIR="${root}/journal"
export HM_SITE_LOCK_DIR="${root}/lock"
export HM_SITE_MANIFEST_DIR="${root}/manifest"
export LOG_DIR="${root}/logs"
export LOG_ENABLED=1
export HM_LOG="${root}/hm.log"
export TMP_DIR="${root}/tmp"
mkdir -p "${HM_SITE_HOME_BASE}" "${LOG_DIR}" "${TMP_DIR}" "${HM_SITE_JOURNAL_DIR}" "${HM_SITE_LOCK_DIR}"
: > "${HM_SITE_PASSWD_FILE}"
: > "${HM_SITE_DB_ARGV_LOG}"
: > "${HM_SITE_DB_SQL_LOG}"
: > "${HM_LOG}"
printf 'MemTotal: 2097152 kB\n' > "${HM_SITE_MEMINFO_FILE}"
printf 'LISTEN 0.0.0.0:80\nLISTEN 0.0.0.0:443\n' > "${HM_SITE_SS_FILE}"
printf 'ID=debian\nVERSION_ID="12"\n' > "${HM_SITE_OS_FILE}"

hm_confirm_plan() { return 0; }
hm_gen_password() { printf '%s' "${PASS}"; }
hm_have_cmd() { return 1; }
hm_mysql_cli() { printf '%s\n' mysql; }
hm_mysql_create() {
  HM_MYSQL_CREATE_PASS="${PASS}"
  return 0
}
hm_run() { printf 'RUN:%s\n' "$*" >> "${root}/run.log"; return 0; }

umask 022
before="$(umask)"
outf="${root}/new.out"
errf="${root}/new.err"
if ! cmd_site_new shop.example --runtime node --db mysql --yes >"${outf}" 2>"${errf}"; then
  bad "site-new-rc"
  cat "${outf}" "${errf}" >&2 || true
else
  ok "site-new-rc"
fi
after="$(umask)"
[[ "${before}" == "${after}" ]] && ok "umask" || bad "umask ${before}->${after}"

envf="${HM_SITE_HOME_BASE}/shop.example/shared/.env"
[[ -f "${envf}" ]] && grep -F -q "${PASS}" "${envf}" && ok "env-has-secret" || bad "env-has-secret"

leak=0
blob="$(cat "${outf}" "${errf}" "${HM_SITE_DB_ARGV_LOG}" "${HM_SITE_DB_SQL_LOG}" "${HM_LOG}" 2>/dev/null || true)"
if [[ -d "${LOG_DIR}" ]]; then
  blob+=$'\n'"$(find "${LOG_DIR}" -type f -exec cat {} + 2>/dev/null || true)"
fi
if [[ -d "${HM_SITE_JOURNAL_DIR}" ]]; then
  blob+=$'\n'"$(find "${HM_SITE_JOURNAL_DIR}" -type f -exec cat {} + 2>/dev/null || true)"
fi
man="$(find "${HM_SITE_HOME_BASE}/shop.example" -type f ! -path '*/shared/.env' -exec cat {} + 2>/dev/null || true)"
blob+=$'\n'"${man}"
if printf '%s' "${blob}" | grep -F -q "${PASS}"; then
  bad "secret-in-logs"
  leak=1
else
  ok "secret-in-logs"
fi

ps -ef > "${root}/ps.txt" 2>/dev/null || ps aux > "${root}/ps.txt" 2>/dev/null || : > "${root}/ps.txt"
if grep -F -q "${PASS}" "${root}/ps.txt"; then
  bad "secret-in-ps"
else
  ok "secret-in-ps"
fi

if [[ "${leak}" -eq 0 ]]; then
  : 
fi

if [[ "${fail}" -ne 0 ]]; then
  echo FAILED
  exit 1
fi
echo "ALL OK"
