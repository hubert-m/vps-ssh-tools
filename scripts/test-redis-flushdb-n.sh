#!/usr/bin/env bash
# Regresja: flushdb N → -n N; N≥databases / za długa liczba → odmowa BEZ FLUSHDB
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
# CONFIG GET databases
if [[ "$*" == *CONFIG* && "$*" == *databases* ]]; then
  echo "databases"
  echo "16"
  exit 0
fi
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
REDIS_BIN="${FAKE_CLI}"
REDIS_HOST=127.0.0.1
REDIS_PORT=6379
REDIS_SOCK=""
REDIS_PASS=""
REDIS_SERVICE=""
REDIS_CONF=""

hm_redis_require() { return 0; }

fail=0

# --- databases count ---
dbn="$(hm_redis_databases_count)"
if [[ "${dbn}" == "16" ]]; then
  echo "OK   databases_count=16"
else
  echo "FAIL databases_count='${dbn}'"
  fail=1
fi

# --- index OK / poza zakresem ---
if hm_redis_db_index_ok 3 2>/dev/null; then
  echo "OK   db_index_ok 3"
else
  echo "FAIL db_index_ok 3"
  fail=1
fi
if hm_redis_db_index_ok 16 2>/dev/null; then
  echo "FAIL db_index_ok 16 powinien odmówić (databases=16)"
  fail=1
else
  echo "OK   db_index_ok 16 → odmowa"
fi
if hm_redis_db_index_ok 99999999999999999999 2>/dev/null; then
  echo "FAIL zbyt długa liczba powinna być odrzucona"
  fail=1
else
  echo "OK   zbyt długa liczba → odmowa"
fi

# --- flushdb ścieżka z -n (bez wywoływania poza zakresem) ---
: > "${LOG}"
REDIS_CLI_DB=3
hm_redis_cli_checked FLUSHDB >/dev/null || true
left="$(REDIS_CLI_DB=3 hm_redis_cli DBSIZE 2>/dev/null | tr -d '\r' || true)"
unset REDIS_CLI_DB

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
flush_n="$(grep 'FLUSHDB' "${LOG}" | grep -cE -- '-n 3' || true)"
dbsize_n="$(grep 'DBSIZE' "${LOG}" | grep -cE -- '-n 3' || true)"
if [[ "${flush_n}" -ge 1 && "${dbsize_n}" -ge 1 ]]; then
  echo "OK   FLUSHDB i DBSIZE z -n 3"
else
  echo "FAIL FLUSHDB/DBSIZE bez -n (flush=${flush_n} dbsize=${dbsize_n})"
  cat "${LOG}"
  fail=1
fi

# poza zakresem: NIE wolno wołać FLUSHDB
: > "${LOG}"
if hm_redis_db_index_ok 16 2>/dev/null; then
  echo "FAIL nieoczekiwane OK dla 16"
  fail=1
else
  # symulacja: po odmowie index_ok nie wołamy FLUSHDB
  if grep -q FLUSHDB "${LOG}"; then
    echo "FAIL FLUSHDB przy walidacji zakresu"
    fail=1
  else
    echo "OK   brak FLUSHDB przy N≥databases"
  fi
fi

rm -f "${LOG}" "${FAKE_CLI}"

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
