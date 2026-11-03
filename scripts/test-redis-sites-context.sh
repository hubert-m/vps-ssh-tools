#!/usr/bin/env bash
# Regresja: redis sites przywraca kontekst REPL po skanie (push/pop)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${ROOT}/commands/redis/main.sh"

block="$(sed -n '/^hm_redis_cmd_sites()/,/^hm_redis_cmd_flushdb()/p' "${SRC}" | sed '$d')"

fail=0
if ! printf '%s\n' "${block}" | grep -q 'hm_site_context_push'; then
  echo "FAIL brak hm_site_context_push"
  fail=1
else
  echo "OK   hm_site_context_push"
fi
if ! printf '%s\n' "${block}" | grep -q 'hm_site_context_pop'; then
  echo "FAIL brak hm_site_context_pop"
  fail=1
else
  echo "OK   hm_site_context_pop"
fi

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
