#!/usr/bin/env bash
# Regresja: hm_site_context_push/pop przywraca REPL; tymczasowy use nie zostaje
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=/dev/null
source "${ROOT}/lib/common/context.sh"

# Stub — discover nie jest potrzebny do samego stosu pól
hm_set_site_context() {
  HM_SITE_DOMAIN="${1}"
  HM_SITE_ROOT="/home/${1}"
  HM_SITE_DOCROOT="/home/${1}/public_html"
  HM_SITE_LOGS=""
  HM_SITE_VHOST=""
  HM_SITE_PHP="8.2"
  HM_SITE_USER="u_${1}"
  HM_SITE_STATUS="active"
}

fail=0
assert_eq() {
  local label="$1" got="$2" want="$3"
  if [[ "${got}" != "${want}" ]]; then
    echo "FAIL ${label}: got='${got}' want='${want}'"
    fail=1
  else
    echo "OK   ${label}"
  fi
}

# 1) pusty → tymczasowy → z powrotem pusty
hm_clear_site_context
hm_site_context_push "a.example"
assert_eq "temp domain" "${HM_SITE_DOMAIN}" "a.example"
hm_site_context_pop
assert_eq "restore empty" "${HM_SITE_DOMAIN}" ""

# 2) use b → tymczasowy a → z powrotem b
hm_set_site_context "b.example"
hm_site_context_push "a.example"
assert_eq "switched" "${HM_SITE_DOMAIN}" "a.example"
hm_site_context_pop
assert_eq "restore b" "${HM_SITE_DOMAIN}" "b.example"
assert_eq "restore root" "${HM_SITE_ROOT}" "/home/b.example"

# 3) zagnieżdżenie
hm_set_site_context "outer"
hm_site_context_push "mid"
hm_site_context_push "inner"
assert_eq "inner" "${HM_SITE_DOMAIN}" "inner"
hm_site_context_pop
assert_eq "mid" "${HM_SITE_DOMAIN}" "mid"
hm_site_context_pop
assert_eq "outer" "${HM_SITE_DOMAIN}" "outer"

# 4) hm_with_site_context
hm_clear_site_context
hm_set_site_context "keep.me"
_hm_with_probe() { assert_eq "inside with" "${HM_SITE_DOMAIN}" "temp.me"; }
hm_with_site_context "temp.me" _hm_with_probe
assert_eq "after with" "${HM_SITE_DOMAIN}" "keep.me"

# 5) redis sites używa push/pop
block="$(sed -n '/^hm_redis_cmd_sites()/,/^hm_redis_cmd_flushdb()/p' "${ROOT}/commands/redis/main.sh" | sed '$d')"
if ! printf '%s\n' "${block}" | grep -q 'hm_site_context_push'; then
  echo "FAIL redis sites bez hm_site_context_push"
  fail=1
else
  echo "OK   redis sites push"
fi
if ! printf '%s\n' "${block}" | grep -q 'hm_site_context_pop'; then
  echo "FAIL redis sites bez hm_site_context_pop"
  fail=1
else
  echo "OK   redis sites pop"
fi

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
