#!/usr/bin/env bash
# site new: bazy + .env 0600, hasło poza stdout/argv/manifestem/applogiem, rollback nie rusza cudzych baz.
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
source lib/site/db.sh
# shellcheck disable=SC1091
source commands/site-create/wizard-db.sh

fail=0
PASS='GenPass12xYzAb99'
root="$(mktemp -d "${TMPDIR:-/tmp}/hmtools-dbenv.XXXXXX")"
trap 'rm -rf "${root}"' EXIT
export HM_SITE_HOME_BASE="${root}/home"
export HM_SITE_MANIFEST_DIR="${root}/manifest"
export HM_SITE_STATE_DIR="${root}/state"
export HM_SITE_USER="api"
export HM_SITE_DB_MOCK=1
export HM_SITE_DB_ARGV_LOG="${root}/argv.log"
export HM_SITE_DB_SQL_LOG="${root}/sql.log"
export HM_REDIS_VERSION=6
export TMP_DIR="${root}/tmp"
export LOG_DIR="${root}/logs"
export LOG_ENABLED=1
mkdir -p "${TMP_DIR}" "${LOG_DIR}" "${HM_SITE_HOME_BASE}"
: > "${HM_SITE_DB_ARGV_LOG}"
: > "${HM_SITE_DB_SQL_LOG}"

hm_file_log_ui() { :; }
hm_confirm_plan() { return 0; }
hm_gen_password() { printf '%s' "${PASS}"; }
hm_have_cmd() {
  case "${1:-}" in
    psql|redis-cli|openssl|mysql|mariadb) return 0 ;;
    *) return 1 ;;
  esac
}
hm_mysql_cli() { printf '%s\n' mysql; }
hm_pkg_install() { return 0; }
hm_del_db_owned_by_other() { [[ "${1:-}" == "legacy_db" ]]; }

ok() { echo "OK   $1"; }
bad() { echo "FAIL $1"; fail=1; }

assert_clean() {
  local name="$1" blob="$2"
  if printf '%s' "${blob}" | grep -F -q "${PASS}"; then
    bad "${name}"
    return
  fi
  ok "${name}"
}

# --- site new postgres + redis (bieżąca powłoka, żeby został HM_SITE_LAST_NEW) ---
outf="${root}/new.out"
cmd_site_new api.example.pl --runtime node --db postgres --pg-version 17 --redis --yes >"${outf}" 2>&1 || true
out="$(cat "${outf}")"
assert_clean "new-stdout" "${out}"
printf '%s' "${out}" | grep -q 'Brak TTY — sekret nie został wypisany' && ok "new-no-tty" || bad "new-no-tty"
printf '%s' "${out}" | grep -q 'Dane dostępowe zapisano w' && ok "new-path" || bad "new-path"

envf="${HM_SITE_HOME_BASE}/api.example.pl/shared/.env"
[[ -f "${envf}" ]] && ok "env-exists" || bad "env-exists"
mode="$(stat -c '%a' "${envf}" 2>/dev/null || stat -f '%OLp' "${envf}")"
dmode="$(stat -c '%a' "$(dirname "${envf}")" 2>/dev/null || stat -f '%OLp' "$(dirname "${envf}")")"
probe="${root}/chmod-probe"
: > "${probe}"
chmod 0600 "${probe}"
pmode="$(stat -c '%a' "${probe}" 2>/dev/null || echo none)"
if [[ "${pmode}" == "600" || "${pmode}" == "0600" ]]; then
  [[ "${mode}" == "600" || "${mode}" == "0600" ]] && ok "env-mode" || bad "env-mode=${mode}"
  [[ "${dmode}" == "750" || "${dmode}" == "0750" ]] && ok "shared-mode" || bad "shared-mode=${dmode}"
else
  ok "env-mode-platform"
  ok "shared-mode-platform"
fi
grep -F -q "${PASS}" "${envf}" && ok "env-has-secret" || bad "env-has-secret"

list="$(cmd_site_env list api.example.pl 2>&1 || true)"
assert_clean "env-list" "${list}"
printf '%s' "${list}" | grep -q 'DATABASE_URL=postgres://api_app:\*\*\*\*@127.0.0.1:5432/api_app' \
  && ok "env-list-mask" || bad "env-list-mask"

show="$(cmd_site_env show DATABASE_URL 2>&1 || true)"
assert_clean "env-show-notty" "${show}"
printf '%s' "${show}" | grep -q 'Brak TTY' && ok "env-show-warn" || bad "env-show-warn"

if cmd_site_env set LEAKVAL "${PASS}" 2>/dev/null; then
  bad "env-set-argv-rejected"
else
  ok "env-set-argv-rejected"
fi
setout="$(printf '%s\n' "${PASS}" | cmd_site_env set CUSTOM_TOKEN 2>&1 || true)"
assert_clean "env-set-stdin" "${setout}"

man="$(hm_site_manifest_path api.example.pl)"
assert_clean "manifest" "$(cat "${man}")"
grep -q '"type":"postgres"' "${man}" && ok "manifest-pg" || bad "manifest-pg"
grep -q '"name":"api_app"' "${man}" && ok "manifest-name" || bad "manifest-name"

assert_clean "argv" "$(cat "${HM_SITE_DB_ARGV_LOG}")"
grep -q 'psql' "${HM_SITE_DB_ARGV_LOG}" && ok "argv-psql" || bad "argv-psql"
grep -q 'redis-cli' "${HM_SITE_DB_ARGV_LOG}" && ok "argv-redis" || bad "argv-redis"
# hasło jest w SQL do serwera (stdin), nie w argv
grep -F -q "${PASS}" "${HM_SITE_DB_SQL_LOG}" && ok "sql-has-secret" || bad "sql-has-secret"
grep -q 'CREATE ROLE api_app' "${HM_SITE_DB_SQL_LOG}" && ok "sql-role" || bad "sql-role"
grep -q 'REVOKE ALL ON DATABASE api_app FROM PUBLIC' "${HM_SITE_DB_SQL_LOG}" && ok "sql-revoke" || bad "sql-revoke"

unit="$(hm_site_state_dir api.example.pl)/app.service"
grep -q "EnvironmentFile=-${envf}" "${unit}" && ok "unit-envfile" || bad "unit-envfile"
assert_clean "unit" "$(cat "${unit}")"
eco="${HM_SITE_HOME_BASE}/api.example.pl/shared/ecosystem.config.cjs"
grep -q "env_file:" "${eco}" && ok "pm2-envfile" || bad "pm2-envfile"
assert_clean "pm2" "$(cat "${eco}")"

# brak plików tymczasowych z hasłem
if grep -R -F -l -- "${PASS}" "${TMP_DIR}" >/dev/null 2>&1; then
  bad "tmp-leftover"
else
  ok "tmp-leftover"
fi

# --- rollback: cudza baza zostaje, nasza znika ---
printf 'mysql\tlegacy_db\tlegacy_db\t127.0.0.1\n' >> "$(hm_site_db_ledger_path api.example.pl)"
: > "${HM_SITE_DB_SQL_LOG}"
: > "${HM_SITE_DB_ARGV_LOG}"
hm_site_db_rollback api.example.pl
sqlroll="$(cat "${HM_SITE_DB_SQL_LOG}")"
printf '%s' "${sqlroll}" | grep -q 'DROP DATABASE IF EXISTS api_app' && ok "rollback-ours" || bad "rollback-ours"
printf '%s' "${sqlroll}" | grep -q 'DROP ROLE IF EXISTS api_app' && ok "rollback-role" || bad "rollback-role"
if printf '%s' "${sqlroll}" | grep -q 'legacy_db'; then
  bad "rollback-foreign"
else
  ok "rollback-foreign"
fi
grep -q $'mysql\tlegacy_db\t' "$(hm_site_db_ledger_path api.example.pl)" && ok "ledger-keeps-foreign" || bad "ledger-keeps-foreign"

# sesja nie rusza wpisu spoza tej próby
HM_SITE_DB_SESSION_LEDGER=$'postgres\tnew_only\tnew_only\t127.0.0.1\n'
printf 'postgres\tnew_only\tnew_only\t127.0.0.1\n' >> "$(hm_site_db_ledger_path api.example.pl)"
: > "${HM_SITE_DB_SQL_LOG}"
hm_site_db_rollback_session api.example.pl
grep -q 'DROP DATABASE IF EXISTS new_only' "${HM_SITE_DB_SQL_LOG}" && ok "session-drop" || bad "session-drop"
grep -q $'mysql\tlegacy_db\t' "$(hm_site_db_ledger_path api.example.pl)" && ok "session-keeps-foreign" || bad "session-keeps-foreign"

# inny użytkownik: tryb 0600. su tylko gdy jest root i konto nobody.
if [[ "$(id -u)" -eq 0 ]] && id nobody >/dev/null 2>&1; then
  if su nobody -s /bin/sh -c "cat $(printf '%q' "${envf}")" >/dev/null 2>&1; then
    bad "other-user-read"
  else
    ok "other-user-read"
  fi
else
  ok "other-user-read-mode-only"
fi

# Istniejąca baza (nie w manifeście) → rc≠0, bez unbound variable, rollback HOME/.dbs
hm_mysql_db_exists() { return 0; }
hm_mysql_create() { hm_err "mysql_create nie powinno być wołane"; return 1; }
hm_site_db_ensure_mysql() { return 0; }
hm_site_base_check() {
  HM_SITE_BASE_DOMAIN="${1:-}"
  HM_SITE_BASE_USER="${2:-xuser}"
  HM_SITE_BASE_RUNTIME="${3:-php}"
  return 0
}
hm_site_base_apply() {
  local home d="${HM_SITE_BASE_DOMAIN:-collide.example}"
  home="$(hm_site_home "${d}")"
  mkdir -p "${home}/shared" "${home}/public_html" "${home}/logs"
  : > "${home}/shared/.env"
  chmod 0600 "${home}/shared/.env" 2>/dev/null || true
  return 0
}
hm_site_unix_user() { printf 'xuser\n'; }
hm_site_web_provision() { return 0; }
hm_tx_begin() { HM_TX_JOURNAL="${root}/tx.journal"; : > "${HM_TX_JOURNAL}"; return 0; }
hm_tx_step() { return 2; }
hm_tx_done() { return 0; }
hm_tx_rollback() {
  local d="$1" home
  home="$(hm_site_home "${d}")"
  rm -rf -- "${home}"
  rm -f -- "$(hm_site_manifest_path "${d}")" "${HM_SITE_MANIFEST_DIR}/.${d}.dbs"
  HM_TX_JOURNAL=""
  printf 'rolled:%s\n' "${d}" >> "${root}/rollback.log"
  return 0
}
hm_tx_note_undo() { return 0; }
: > "${root}/rollback.log"
col_out="${root}/collide.out"
if cmd_site_new collide.example --runtime php --db mysql --yes >"${col_out}" 2>&1; then
  bad "mysql-exists-rc"
else
  ok "mysql-exists-rc"
fi
if grep -qi 'unbound variable' "${col_out}"; then
  bad "mysql-exists-unbound"
else
  ok "mysql-exists-unbound"
fi
grep -Eiq 'Odmowa:.*(baza|db)|już istnieje' "${col_out}" && ok "mysql-exists-msg" || { bad "mysql-exists-msg"; cat "${col_out}" >&2; }
[[ ! -d "$(hm_site_home collide.example)" ]] && ok "mysql-exists-no-home" || bad "mysql-exists-no-home"
[[ ! -f "${HM_SITE_MANIFEST_DIR}/.collide.example.dbs" ]] && ok "mysql-exists-no-dbs" || bad "mysql-exists-no-dbs"
grep -q 'rolled:collide.example' "${root}/rollback.log" && ok "mysql-exists-rollback" || bad "mysql-exists-rollback"

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
exit 0
