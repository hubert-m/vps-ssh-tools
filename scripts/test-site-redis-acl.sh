#!/usr/bin/env bash
# Redis ACL: unikalne DB, bez FLUSHALL/CONFIG, harden default.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1
export HMTOOLS_TEST_NO_TTY=1
export HM_SITE_DB_MOCK=1

# shellcheck disable=SC1091
source lib/common/ui.sh
hm_file_log_ui() { :; }
# shellcheck disable=SC1091
source lib/site/env.sh
# shellcheck disable=SC1091
source lib/site/tx.sh
# shellcheck disable=SC1091
source lib/site/db.sh

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
export HM_SITE_HOME_BASE="${root}/homes"
export HM_SITE_MANIFEST_DIR="${root}/manifests"
export HM_SITE_STATE_DIR="${root}/state"
export HM_SITE_REDIS_REGISTRY="${root}/redis-dbs.tsv"
export HM_SITE_DB_SQL_LOG="${root}/sql.log"
export HM_REDIS_VERSION=7
: > "${HM_SITE_DB_SQL_LOG}"

mkdir -p "${HM_SITE_HOME_BASE}/r1.test" "${HM_SITE_HOME_BASE}/r2.test" \
  "${HM_SITE_STATE_DIR}/r1.test" "${HM_SITE_STATE_DIR}/r2.test" "${HM_SITE_MANIFEST_DIR}"
# unix user stubs
hm_site_unix_user() { printf '%s' "${1%%.*}"; }
hm_gen_password() { printf 'testpass'; }

db1="$(hm_site_redis_next_db r1.test)" || db1=""
db2="$(hm_site_redis_next_db r2.test)" || db2=""
[[ "${db1}" == "1" ]] && ok "db-r1=1" || bad "db-r1=${db1}"
[[ "${db2}" == "2" ]] && ok "db-r2=2" || bad "db-r2=${db2}"
[[ "${db1}" != "${db2}" ]] && ok "db-unique" || bad "db-same"

# provision ACL (mock)
: > "${HM_SITE_DB_SQL_LOG}"
rm -f "$(dirname "${HM_SITE_REDIS_REGISTRY}")/redis-default-hardened"
# zwolnij numery z poprzedniego next_db, żeby provision dostał świeże
rm -f "${HM_SITE_REDIS_REGISTRY}"
hm_site_redis_provision r1.test cache || bad "provision-r1"
hm_site_redis_provision r2.test cache || bad "provision-r2"
sql="$(cat "${HM_SITE_DB_SQL_LOG}")"
printf '%s' "${sql}" | grep -q 'ACL SETUSER default off' && ok "default-off" || bad "default-off"
printf '%s' "${sql}" | grep -q '\-@dangerous' && ok "acl-dangerous" || bad "acl-dangerous"
printf '%s' "${sql}" | grep -q '\-flushall' && ok "acl-flushall" || bad "acl-flushall"
printf '%s' "${sql}" | grep -q '\-keys' && ok "acl-keys" || bad "acl-keys"
printf '%s' "${sql}" | grep -q '\-scan' && ok "acl-scan" || bad "acl-scan"
printf '%s' "${sql}" | grep -q '\-randomkey' && ok "acl-randomkey" || bad "acl-randomkey"
printf '%s' "${sql}" | grep -q '\-dbsize' && ok "acl-dbsize" || bad "acl-dbsize"
# nie może być gołego +@all bez negacji
if printf '%s' "${sql}" | grep -E 'ACL SETUSER .* \+@all( |$)' | grep -qv '\-@dangerous'; then
  bad "acl-bare-all"
else
  ok "acl-not-bare-all"
fi
grep -q $'r1.test\t' "${HM_SITE_REDIS_REGISTRY}" && ok "reg-r1" || bad "reg-r1"
grep -q $'r2.test\t' "${HM_SITE_REDIS_REGISTRY}" && ok "reg-r2" || bad "reg-r2"

# ledger ma różne DB
e1="$(awk -F'\t' '/^redis/{print $4; exit}' "${HM_SITE_STATE_DIR}/r1.test/db-created.tsv")"
e2="$(awk -F'\t' '/^redis/{print $4; exit}' "${HM_SITE_STATE_DIR}/r2.test/db-created.tsv")"
[[ "${e1}" == "db=1" && "${e2}" == "db=2" ]] && ok "ledger-dbs" || bad "ledger=${e1}/${e2}"

rules="$(hm_site_redis_acl_rules 'r1.test:cache')"
printf '%s' "${rules}" | grep -q 'r1.test:cache:\*' && ok "prefix" || bad "prefix"
printf '%s' "${rules}" | grep -q '\-@admin' && ok "acl-admin" || bad "acl-admin"

# .env dostaje prefiks, którego wymaga ACL
hm_site_env_apply_redis r1.test testpass 1 127.0.0.1 6379 cache
envf="$(hm_site_env_path r1.test)"
grep -q '^REDIS_PREFIX=r1.test:cache:$' "${envf}" && ok "env-prefix" || bad "env-prefix"
grep -q '^CACHE_PREFIX=r1.test:cache:$' "${envf}" && ok "env-cache-prefix" || bad "env-cache-prefix"
grep -q '^KEY_PREFIX=r1.test:cache:$' "${envf}" && ok "env-key-prefix" || bad "env-key-prefix"
grep -q '^REDIS_CACHE_PREFIX=r1.test:cache:$' "${envf}" && ok "env-role-prefix" || bad "env-role-prefix"

# release pod flock: wpis znika
hm_site_redis_registry_release r2.test 2
grep -q $'r2.test\t' "${HM_SITE_REDIS_REGISTRY}" && bad "release-r2" || ok "release-r2"
grep -q $'r1.test\t' "${HM_SITE_REDIS_REGISTRY}" && ok "release-keeps-r1" || bad "release-keeps-r1"

if [[ "${fail}" -ne 0 ]]; then
  echo FAILED
  exit 1
fi
echo ALL OK
