#!/usr/bin/env bash
# Regresja: logs search + rotate (fixture OLS combined + .gz)
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
C_BOLD=""; C_RESET=""
_hm_cmd_help() { cat >/dev/null; }
_hm_cmd_register() { :; }

# shellcheck disable=SC1091
source commands/logs/main.sh

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
export HM_LOGS_SEARCH_ROOT="${root}/logs"
export HM_LOGS_SEARCH_SITES="a.test,b.test"
mkdir -p "${HM_LOGS_SEARCH_ROOT}/a.test" "${HM_LOGS_SEARCH_ROOT}/b.test"

# combined OLS-like
cat > "${HM_LOGS_SEARCH_ROOT}/a.test/access.log" <<'EOF'
1.2.3.4 - - [16/Nov/2026:10:00:00 +0000] "GET /admin HTTP/1.1" 500 12
5.6.7.8 - - [16/Nov/2026:10:01:00 +0000] "GET /ok HTTP/1.1" 200 9
1.2.3.4 - - [16/Nov/2026:10:02:00 +0000] "POST /login HTTP/1.1" 404 3
EOF
cat > "${HM_LOGS_SEARCH_ROOT}/b.test/access.log" <<'EOF'
1.2.3.4 - - [16/Nov/2026:10:03:00 +0000] "GET /admin HTTP/1.1" 200 4
9.9.9.9 - - [16/Nov/2026:10:04:00 +0000] "GET /x HTTP/1.1" 503 1
EOF
printf '%s\n' '1.2.3.4 - - [16/Nov/2026:09:00:00 +0000] "GET /old HTTP/1.1" 200 1' \
  | gzip > "${HM_LOGS_SEARCH_ROOT}/a.test/access.log.gz"

if hm_logs_safe_regex '/admin'; then ok safe-regex; else bad safe-regex; fi
if hm_logs_safe_regex '$(rm -rf /)'; then bad unsafe-regex; else ok unsafe-regex; fi

out="$(cmd_logs_search --ip 1.2.3.4 --limit 50)"
printf '%s\n' "${out}" | grep -q 'a.test' && printf '%s\n' "${out}" | grep -q '/admin' \
  && ok search-ip || bad search-ip
out="$(cmd_logs_search --url '/admin' --limit 50)"
printf '%s\n' "${out}" | grep -c 'admin' | grep -Eq '^[23]$' && ok search-url || bad "search-url ${out}"
out="$(cmd_logs_search --status 5xx --limit 50)"
printf '%s\n' "${out}" | grep -q '500' && printf '%s\n' "${out}" | grep -q '503' \
  && ok search-5xx || bad search-5xx
out="$(cmd_logs_search --site a.test --status 404 --limit 10)"
printf '%s\n' "${out}" | grep -q '404' && printf '%s\n' "${out}" | grep -qv 'b.test' \
  && ok search-site || bad search-site
out="$(cmd_logs_search --count-by ip --limit 10)"
printf '%s\n' "${out}" | grep -q '1.2.3.4' && ok count-by-ip || bad count-by-ip

# .gz
out="$(cmd_logs_search --site a.test --url '/old' --limit 10)"
printf '%s\n' "${out}" | grep -q '/old' && ok search-gz || bad search-gz

export HM_LOGS_ROTATE_CONF="${root}/hmtools-sites"
cmd_logs_rotate fix >/dev/null
[[ -s "${HM_LOGS_ROTATE_CONF}" ]] && ok rotate-fix || bad rotate-fix
cmd_logs_rotate status >/dev/null && ok rotate-status || bad rotate-status

if [[ "${fail}" -ne 0 ]]; then
  echo FAILED
  exit 1
fi
echo "ALL OK"
