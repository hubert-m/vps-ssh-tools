#!/usr/bin/env bash
# Regresja: redis sites przywraca kontekst REPL po skanie
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${ROOT}/commands/redis/main.sh"

block="$(sed -n '/^hm_redis_cmd_sites()/,/^hm_redis_cmd_flushdb()/p' "${SRC}" | sed '$d')"

fail=0
if ! printf '%s\n' "${block}" | grep -q 'prev_domain'; then
  echo "FAIL brak zapisu prev_domain"
  fail=1
else
  echo "OK   zapis prev_domain"
fi
if ! printf '%s\n' "${block}" | grep -q 'hm_clear_site_context'; then
  echo "FAIL brak hm_clear_site_context przy pustym kontekście"
  fail=1
else
  echo "OK   clear gdy był hmtools>"
fi
if ! printf '%s\n' "${block}" | grep -q 'hm_set_site_context "${prev_domain}"'; then
  echo "FAIL brak przywrócenia prev_domain"
  fail=1
else
  echo "OK   restore poprzedniego use"
fi

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
