#!/usr/bin/env bash
# safety: users del odmawia www-data / właściciela serwisu; bez userdel w logu.
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
hm_confirm_plan_critical() { return 0; }
C_BOLD=""; C_RESET=""; C_DIM=""

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hm-users-del.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

export HM_USERS_PASSWD="${TMP}/passwd"
export HM_USERS_SHADOW="${TMP}/shadow"
export HM_USERS_SUDOERS_D="${TMP}/sudoers.d"
export HM_USERS_HOME_BASE="${TMP}/home"
export HM_USERS_ACTION_LOG="${TMP}/actions.log"
export HM_SITE_MANIFEST_DIR="${TMP}/sites"
mkdir -p "${HM_USERS_SUDOERS_D}" "${HM_USERS_HOME_BASE}" "${HM_SITE_MANIFEST_DIR}"
: > "${HM_USERS_ACTION_LOG}"

cat > "${HM_USERS_PASSWD}" <<'EOF'
root:x:0:0:root:/root:/bin/bash
www-data:x:33:33:www-data:/var/www:/usr/sbin/nologin
shop2tes:x:1001:1001:shop2:/home/shop2tes:/bin/bash
deploy:x:1002:1002:deploy:/home/deploy:/bin/bash
EOF

printf '{"schema":1,"domain":"shop2.test","user":"shop2tes","databases":[]}\n' \
  > "${HM_SITE_MANIFEST_DIR}/shop2.test.json"

_hm_cmd_help() { :; }
_hm_cmd_register() { :; }
# shellcheck disable=SC1091
source commands/users/main.sh

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

set +e
cmd_users_del www-data >/dev/null 2>&1
rc=$?
set -e
[[ "${rc}" -ne 0 ]] && pass "www-data rc≠0" || fail "www-data powinien być odmówiony"
grep -q 'deleted www-data' "${HM_USERS_ACTION_LOG}" && fail "www-data w action log" || pass "www-data bez userdel w logu"
grep -q '^www-data:' "${HM_USERS_PASSWD}" && pass "www-data nadal w passwd" || fail "www-data usunięty z passwd"

set +e
cmd_users_del shop2tes >/dev/null 2>&1
rc=$?
set -e
[[ "${rc}" -ne 0 ]] && pass "shop2tes (site owner) rc≠0" || fail "shop2tes powinien być odmówiony"
grep -q 'deleted shop2tes' "${HM_USERS_ACTION_LOG}" && fail "shop2tes w action log" || pass "shop2tes bez userdel w logu"
grep -q '^shop2tes:' "${HM_USERS_PASSWD}" && pass "shop2tes nadal w passwd" || fail "shop2tes usunięty"

# zwykły deploy bez manifestu — OK (test mode)
set +e
cmd_users_del deploy >/dev/null 2>&1
rc=$?
set -e
[[ "${rc}" -eq 0 ]] && pass "deploy (bez site) usuwalny" || fail "deploy powinien przejść"
grep -q 'deleted deploy' "${HM_USERS_ACTION_LOG}" && pass "deploy w action log" || fail "brak deploy w logu"

echo ""
echo "Wynik: ${PASS} pass, ${FAIL} fail"
[[ "${FAIL}" -eq 0 ]]
