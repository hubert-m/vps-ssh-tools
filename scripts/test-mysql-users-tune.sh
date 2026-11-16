#!/usr/bin/env bash
# Regresja: mysql users/grant/revoke/passwd/slow/tune (mock hm_mysql_exec)
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }
hm_confirm_plan() { return 0; }
hm_detect_all() { :; }
hm_print_secret() { echo "SECRET_LEN=${#1}"; }
hm_sql_quote() { printf "'%s'" "${1//\'/\'\'}"; }
C_BOLD=""; C_RESET=""; C_DIM=""
_hm_cmd_help() { cat >/dev/null; }
_hm_cmd_register() { :; }

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
SQL_LOG="${root}/sql.log"
: > "${SQL_LOG}"

hm_mysql_exec() {
  local all="$*"
  if [[ "${1:-}" == "-e" || "${1:-}" == "-N" ]]; then
    printf '%s\n' "$*" >> "${SQL_LOG}"
    # minimalne odpowiedzi dla tune/users
    if [[ "$*" == *"mysql.user"* ]]; then
      printf '%s\n' "wpuser localhost set ok"
      return 0
    fi
    if [[ "$*" == *"innodb_buffer_pool_size"* ]]; then
      printf '%s\n' "innodb_buffer_pool_size 134217728"
      return 0
    fi
    if [[ "$*" == *"max_connections"* ]]; then
      printf '%s\n' "max_connections 151"
      return 0
    fi
    if [[ "$*" == *"data_length"* ]]; then
      printf '%s\n' "200"
      return 0
    fi
    if [[ "$*" == *"Innodb_buffer_pool"* ]]; then
      printf '%s\n' "Innodb_buffer_pool_read_requests 1000"
      printf '%s\n' "Innodb_buffer_pool_reads 10"
      return 0
    fi
    if [[ "$*" == *"Created_tmp_disk_tables"* ]]; then
      printf '%s\n' "Created_tmp_disk_tables 5"
      return 0
    fi
    if [[ "$*" == *"data_free"* ]]; then
      printf '%s\n' "10"
      return 0
    fi
    return 0
  fi
  # stdin SQL (passwd)
  cat >> "${SQL_LOG}"
  return 0
}

# shellcheck disable=SC1091
source commands/mysql/main.sh

hm_mysql_user_protected root && ok protect-root || bad protect-root
hm_mysql_user_protected cyberpanel && ok protect-cp || bad protect-cp
hm_mysql_user_protected wpuser && { bad protect-wp; } || ok protect-wp-ok

if cmd_mysql_revoke root appdb 2>/dev/null; then bad revoke-root; else ok revoke-root; fi
if cmd_mysql_grant wpuser appdb --ro; then ok grant-ro; else bad grant-ro; fi
grep -q 'GRANT SELECT' "${SQL_LOG}" && ok grant-sql || bad grant-sql

export HM_MYSQL_USERS_FIXTURE="${root}/users.txt"
printf 'wpuser\tlocalhost\tset\tok\n' > "${HM_MYSQL_USERS_FIXTURE}"
cmd_mysql_users | grep -q wpuser && ok users || bad users

slow="${root}/slow.log"
cat > "${slow}" <<'EOF'
# Time: 2026-11-16T10:00:00.000000Z
# User@Host: wp[wp] @ localhost []
# Query_time: 1.500  Lock_time: 0.000 Rows_sent: 1 Rows_examined: 100
SELECT * FROM posts WHERE id=1;
# Query_time: 2.000  Lock_time: 0.000 Rows_sent: 1 Rows_examined: 100
SELECT * FROM posts WHERE id=2;
# Query_time: 0.100  Lock_time: 0.000 Rows_sent: 1 Rows_examined: 1
SELECT 1;
EOF
export HM_MYSQL_SLOW_LOG="${slow}"
out="$(cmd_mysql_slow --top 5)"
printf '%s\n' "${out}" | grep -q 'SELECT \* FROM posts WHERE id=N' && ok slow-top || bad "slow-top ${out}"

export HM_MYSQL_TUNE_FIXTURE="${root}/tune.txt"
printf 'advice\n' > "${HM_MYSQL_TUNE_FIXTURE}"
cmd_mysql_tune | grep -q advice && ok tune-fixture || bad tune-fixture
unset HM_MYSQL_TUNE_FIXTURE
# live tune path with mocks
cmd_mysql_tune >/dev/null && ok tune-live || bad tune-live

sf="${root}/pass.txt"
printf 'S3cretPassWord999' > "${sf}"
chmod 600 "${sf}"
cmd_mysql_passwd wpuser --secret-file "${sf}" >/dev/null
grep -q 'ALTER USER' "${SQL_LOG}" && ok passwd-sql || bad passwd-sql
grep -q "S3cretPassWord999" "${SQL_LOG}" && ok passwd-quoted || bad passwd-quoted

if [[ "${fail}" -ne 0 ]]; then
  echo FAILED
  exit 1
fi
echo "ALL OK"
