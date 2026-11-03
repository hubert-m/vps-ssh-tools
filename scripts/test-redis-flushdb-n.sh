#!/usr/bin/env bash
# Regresja: flushdb N musi wołać redis-cli z -n N (nie osobny SELECT)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

hm_err() { echo "ERR: $*" >&2; }
hm_ok() { echo "OK: $*"; }
hm_info() { :; }
hm_warn() { echo "WARN: $*"; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }
hm_confirm_plan() { return 0; }
hm_detect_all() { :; }
C_BOLD=""; C_RESET=""; C_DIM=""; C_GREEN=""; C_YELLOW=""

LOG="$(mktemp "${TMPDIR:-/tmp}/hmtools-redis-flush.XXXXXX.log")"
FAKE_CLI="${TMPDIR:-/tmp}/hmtools-fake-redis-cli.$$"
cat > "${FAKE_CLI}" <<'EOF'
#!/usr/bin/env bash
echo "ARGV:$*" >> "${HM_FAKE_REDIS_LOG}"
case "${*: -1}" in
  PING) echo PONG ;;
  FLUSHDB) echo OK ;;
  DBSIZE) echo 0 ;;
  *) echo OK ;;
esac
exit 0
EOF
chmod +x "${FAKE_CLI}"
export HM_FAKE_REDIS_LOG="${LOG}"

# shellcheck disable=SC1091
source "${ROOT}/commands/redis/cli.sh"
# cli.sh resetuje REDIS_* — mock dopiero po source
REDIS_BIN="${FAKE_CLI}"
REDIS_HOST=127.0.0.1
REDIS_PORT=6379
REDIS_SOCK=""
REDIS_PASS=""
REDIS_SERVICE=""
REDIS_CONF=""

hm_redis_require() { return 0; }

# inline flushdb logic (jak w main) do testu bez pełnego main
hm_redis_cmd_flushdb_test() {
  local n="${1:-0}" out
  REDIS_CLI_DB="${n}"
  out="$(hm_redis_cli_checked FLUSHDB)" || { unset REDIS_CLI_DB; return 1; }
  left="$(REDIS_CLI_DB="${n}" hm_redis_cli DBSIZE 2>/dev/null | tr -d '\r' || true)"
  unset REDIS_CLI_DB
  printf '%s' "${left}"
}

: > "${LOG}"
hm_redis_cmd_flushdb_test 3 >/dev/null

fail=0
if ! grep -qE -- '-n 3' "${LOG}"; then
  echo "FAIL: brak -n 3 w wywołaniu redis-cli"
  cat "${LOG}"
  fail=1
else
  echo "OK   flushdb przekazuje -n 3"
fi
if grep -qE 'SELECT' "${LOG}"; then
  echo "FAIL: nieoczekiwane SELECT (osobne połączenie)"
  fail=1
else
  echo "OK   brak osobnego SELECT"
fi
# FLUSHDB i DBSIZE z -n
flush_n="$(grep 'FLUSHDB' "${LOG}" | grep -cE -- '-n 3' || true)"
dbsize_n="$(grep 'DBSIZE' "${LOG}" | grep -cE -- '-n 3' || true)"
if [[ "${flush_n}" -ge 1 && "${dbsize_n}" -ge 1 ]]; then
  echo "OK   FLUSHDB i DBSIZE z -n 3"
else
  echo "FAIL FLUSHDB/DBSIZE bez -n (flush=${flush_n} dbsize=${dbsize_n})"
  cat "${LOG}"
  fail=1
fi

rm -f "${LOG}" "${FAKE_CLI}"

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
