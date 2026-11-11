#!/usr/bin/env bash
# cf — token poza argv, zakresy CF, mock 200/403/429.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_confirm_plan() { return 0; }
hm_help_topic() { :; }
_hm_cmd_help() { cat >/dev/null; }
_hm_cmd_register() { :; }

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
export HM_CF_TOKEN_FILE="${root}/token"
export HM_CF_OLS="${root}/realip.conf"
export HM_CF_LOG="${root}/api.log"
export HM_CF_CODE=200
export HM_CF_BODY=$'proxied=yes\nssl=flexible'
: > "${HM_CF_LOG}"

cat > "${root}/curl" <<'EOF'
#!/usr/bin/env bash
out=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -K|--data-binary|-o|-w)
      if [[ "$1" == "-o" ]]; then out="$2"; fi
      shift 2
      ;;
    --) shift ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "${url}" >> "${HM_CF_LOG}"
if [[ "${url}" == *ips-v4* ]]; then
  printf '%s\n' '173.245.48.0/20' '0.0.0.0/0' 'not-a-range' 'X-Forwarded-For' > "${out}"
  printf '200'
  exit 0
fi
if [[ "${url}" == *ips-v6* ]]; then
  printf '%s\n' '2400:cb00::/32' '::/0' > "${out}"
  printf '200'
  exit 0
fi
printf '%s\n' "${HM_CF_BODY:-success=yes}" > "${out}"
printf '%s' "${HM_CF_CODE:-200}"
EOF
chmod +x "${root}/curl" || true
export HM_CF_CURL="${root}/curl"

# shellcheck disable=SC1091
source commands/cf/main.sh

printf 'SECRET-CF-TOKEN\n' | cmd_cf setup >"${root}/setup.out" 2>"${root}/setup.err"
grep -q 'SECRET-CF-TOKEN' "${root}/setup.out" "${root}/setup.err" && bad setup-leak || ok setup-quiet
grep -qx 'SECRET-CF-TOKEN' "${HM_CF_TOKEN_FILE}" && ok setup-file || bad setup-file
if cmd_cf setup SECRET-CF-TOKEN >"${root}/argv.out" 2>"${root}/argv.err"; then bad setup-argv; else ok setup-argv; fi
grep -q 'SECRET-CF-TOKEN' "${root}/argv.out" "${root}/argv.err" && bad setup-argv-leak || ok setup-argv-quiet
mode="$(stat -c '%a' "${HM_CF_TOKEN_FILE}" 2>/dev/null || stat -f '%OLp' "${HM_CF_TOKEN_FILE}")"
if [[ "${mode}" == "600" ]]; then ok token-mode; else printf 'token-mode-platform %s\n' "${mode}"; fi

cmd_cf realip apply >/dev/null
grep -q 'trustedProxy 173.245.48.0/20' "${HM_CF_OLS}" && ok realip-v4 || bad realip-v4
grep -q 'trustedProxy 2400:cb00::/32' "${HM_CF_OLS}" && ok realip-v6 || bad realip-v6
grep -q '0.0.0.0/0' "${HM_CF_OLS}" && bad realip-world || ok realip-world
grep -q 'X-Forwarded-For' "${HM_CF_OLS}" && bad realip-header || ok realip-header
grep -q 'useIpInProxyHeader 1' "${HM_CF_OLS}" && ok realip-header-on || bad realip-header-on

st="$(cmd_cf status example.com)"
printf '%s\n' "${st}" | grep -q 'proxied=yes' && ok status-proxied || bad status-proxied
printf '%s\n' "${st}" | grep -q 'Flexible' && ok status-flexible || bad status-flexible
printf '%s\n' "${st}" | grep -q 'SECRET-CF-TOKEN' && bad status-leak || ok status-leak

export HM_CF_CODE=403
export HM_CF_BODY='error SECRET-CF-TOKEN'
if cmd_cf status example.com >"${root}/e403.out" 2>"${root}/e403.err"; then bad cf-403; else ok cf-403; fi
grep -q 'SECRET-CF-TOKEN' "${root}/e403.out" "${root}/e403.err" && bad cf-403-leak || ok cf-403-redact
grep -q '\[redacted\]' "${root}/e403.err" && ok cf-403-mark || bad cf-403-mark

export HM_CF_CODE=429
export HM_CF_BODY='slow'
if cmd_cf purge example.com --all >"${root}/e429.out" 2>"${root}/e429.err"; then bad cf-429; else ok cf-429; fi
grep -q '429' "${root}/e429.err" && ok cf-429-msg || bad cf-429-msg

export HM_CF_CODE=200
export HM_CF_BODY='success=yes'
: > "${HM_CF_LOG}"
cmd_cf purge example.com --all >/dev/null
grep -q 'purge_cache' "${HM_CF_LOG}" && ok purge || bad purge
cmd_cf attack on example.com >/dev/null
grep -q 'security_level' "${HM_CF_LOG}" && ok attack || bad attack
cmd_cf block PL example.com >/dev/null
grep -q 'access_rules' "${HM_CF_LOG}" && ok block || bad block
grep -q 'SECRET-CF-TOKEN' "${HM_CF_LOG}" && bad api-log-token || ok api-log-token

export HM_CF_PURGE_ON_DEPLOY=1
export HM_SITE_DOMAIN=example.com
: > "${HM_CF_LOG}"
hm_cf_after_deploy
grep -q 'purge_cache' "${HM_CF_LOG}" && ok deploy-hook || bad deploy-hook
grep -q 'hm_cf_after_deploy' commands/git/deploy.sh commands/clone/main.sh && ok deploy-wired || bad deploy-wired

[[ "${fail}" -eq 0 ]] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
