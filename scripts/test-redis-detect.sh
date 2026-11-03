#!/usr/bin/env bash
# Test parse redis.conf (unixsocket / requirepass / port) — bez żywego Redis
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

hm_err() { echo "ERR: $*" >&2; }
hm_ok() { :; }
hm_info() { :; }
hm_warn() { :; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }

# shellcheck disable=SC1091
source "${ROOT}/commands/redis/cli.sh"

fail=0
assert_eq() {
  local label="$1" got="$2" want="$3"
  if [[ "${got}" == "${want}" ]]; then
    echo "OK   ${label}"
  else
    echo "FAIL ${label}: got='${got}' want='${want}'"
    fail=1
  fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hmtools-redis-test.XXXXXX")"
CONF="${TMP}/redis.conf"
cat > "${CONF}" <<'EOF'
# comment
port 6381
bind 127.0.0.1 ::1
unixsocket /run/redis/redis-server.sock
unixsocketperm 770
requirepass "s3cret-pass"
# requirepass ignored
EOF

assert_eq "port" "$(hm_redis_conf_get "${CONF}" port)" "6381"
assert_eq "unixsocket" "$(hm_redis_conf_get "${CONF}" unixsocket)" "/run/redis/redis-server.sock"
assert_eq "requirepass" "$(hm_redis_conf_get "${CONF}" requirepass)" "s3cret-pass"
assert_eq "bind-first-field" "$(hm_redis_conf_get "${CONF}" bind | awk '{print $1}')" "127.0.0.1"

# komentarz nie nadpisuje
cat > "${CONF}" <<'EOF'
requirepass realpass
# requirepass fake
EOF
assert_eq "requirepass-last-active" "$(hm_redis_conf_get "${CONF}" requirepass)" "realpass"

rm -rf "${TMP}"

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
