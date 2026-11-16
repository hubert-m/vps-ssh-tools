#!/usr/bin/env bash
# Regresja: ratelimit / protect wp / geoip / bots — bloki vhconf, stan, DNS botów, ochrona IP sesji
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1
export HM_RL_DIRECT_WRITE=1
export HM_RL_STATE_DIR="$(mktemp -d)"
export HM_RL_F2B_DIR="${HM_RL_STATE_DIR}/jail.d"
export HM_RL_F2B_FILTER="${HM_RL_STATE_DIR}/filter.d/hmtools-wp-login.conf"
export HM_RL_F2B_JAIL="${HM_RL_F2B_DIR}/hmtools-wp-login.conf"
export TEST_SESSION_IP=203.0.113.50
export OLS_ROOT="${HMTOOLS_ROOT}/scripts/fixtures/ratelimit"

# shellcheck source=lib/common/ui.sh
source "${HMTOOLS_ROOT}/lib/common/ui.sh"

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }
hm_mktemp() { mktemp "${TMPDIR:-/tmp}/hm.XXXXXX${1:-}"; }
hm_confirm_plan() { return 0; }
hm_help_topic() { :; }
hm_is_valid_domain() { [[ "$1" == *.* ]]; }
hm_is_valid_ip() {
  [[ "${1:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}
hm_session_ssh_ip() { printf '%s' "${TEST_SESSION_IP}"; }
hm_ols_reload_soft() { return 0; }
C_BOLD=""; C_RESET=""
_hm_cmd_help() { cat >/dev/null; }
_hm_cmd_register() { :; }

fail=0
ok() { echo "OK   $1"; }
bad() { echo "FAIL $1"; fail=1; }

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}" "${HM_RL_STATE_DIR}"' EXIT

TEST_VHCONF="${tmpdir}/vhconf.conf"
cp "${HMTOOLS_ROOT}/scripts/fixtures/ratelimit/vhconf.base" "${TEST_VHCONF}"
export TEST_VHCONF

hm_vhost_conf_path() { printf '%s' "${TEST_VHCONF}"; }
hm_ols_vhost_conf_for() { printf '%s' "${TEST_VHCONF}"; }
hm_ols_vhroot_for_domain() { printf '%s' "${tmpdir}/home"; }

hm_ols_vhost_strip_block() {
  local conf="$1" name="$2" out="$3"
  awk -v n="${name}" '
    BEGIN { skip=0; begin="# hmtools:" n " BEGIN"; end="# hmtools:" n " END" }
    index($0, begin) { skip=1; next }
    index($0, end) { skip=0; next }
    !skip { print }
  ' "${conf}" > "${out}"
}
hm_ols_vhost_write() { cat "$2" > "$1"; }
hm_ols_vhost_has_block() {
  grep -qF "# hmtools:${2} BEGIN" "${1}" 2>/dev/null
}

# shellcheck disable=SC1091
source commands/ratelimit/main.sh

# --- trusted IP w accessControl (sesja) ---
body="$(hm_rl_block_ratelimit_body "/wp-login.php" 5 15)"
printf '%s\n' "${body}" | grep -qF "${TEST_SESSION_IP}T" \
  && ok "trusted-session-ip" || bad "trusted-session-ip"

# --- ratelimit set ---
export HM_OLS_VHOST_YES=1
hm_rl_cmd_set example.pl --rps 8 --burst 16 --path /wp-login.php --yes \
  >/dev/null 2>&1 || bad "ratelimit-set-rc"
grep -q '# hmtools:ratelimit BEGIN' "${TEST_VHCONF}" \
  && ok "ratelimit-vhconf-block" || bad "ratelimit-vhconf-block"
grep -q 'context /wp-login.php' "${TEST_VHCONF}" \
  && ok "ratelimit-context-path" || bad "ratelimit-context-path"
grep -q 'dynReqPerSec            8' "${TEST_VHCONF}" \
  && ok "ratelimit-rps" || bad "ratelimit-rps"

# --- protect wp ---
mkdir -p "${tmpdir}/home/logs" 2>/dev/null || true
hm_rl_cmd_protect_wp example.pl --rps 3 --xmlrpc block --yes \
  >/dev/null 2>&1 || bad "protect-wp-rc"
grep -q '# hmtools:protect-wp BEGIN' "${TEST_VHCONF}" && ok "protect-wp-block" || bad "protect-wp-block"
grep -q 'accessible              0' "${TEST_VHCONF}" && ok "xmlrpc-block" || bad "xmlrpc-block"
[[ -f "${HM_RL_F2B_JAIL}" ]] && ok "f2b-jail-stub" || bad "f2b-jail-stub"
grep -q 'hmtools-wp-login' "${HM_RL_F2B_JAIL}" 2>/dev/null \
  && ok "f2b-jail-name" || bad "f2b-jail-name"
grep -q "${TEST_SESSION_IP}" "${HM_RL_F2B_JAIL}" 2>/dev/null \
  && ok "f2b-ignore-session" || bad "f2b-ignore-session"

# --- geoip block ---
hm_rl_cmd_geoip block PL --domain example.pl --yes >/dev/null 2>&1 || bad "geoip-rc"
grep -q '# hmtools:geoip BEGIN' "${TEST_VHCONF}" && ok "geoip-block" || bad "geoip-block"
grep -q 'GEOIP_COUNTRY_CODE' "${TEST_VHCONF}" && ok "geoip-rewrite" || bad "geoip-rewrite"
grep -qE '\(PL\)' "${TEST_VHCONF}" && ok "geoip-country-pl" || bad "geoip-country-pl"

# --- bots verify (mock DNS) ---
export HM_RL_MOCK_PTR=crawl-66-249-66-1.googlebot.com
export HM_RL_MOCK_FWD=66.249.66.1
hm_rl_bot_verify_ip 66.249.66.1 && ok "bot-verify-google" || bad "bot-verify-google"
export HM_RL_MOCK_PTR=evil.example.com
export HM_RL_MOCK_FWD=1.2.3.4
hm_rl_bot_verify_ip 1.2.3.4 && bad "bot-verify-reject" || ok "bot-verify-reject"

export HM_RL_BOTS_DOMAIN=example.pl
hm_rl_cmd_bots allow on --yes >/dev/null 2>&1 || bad "bots-on-rc"
grep -q '# hmtools:bots BEGIN' "${TEST_VHCONF}" && ok "bots-vhconf" || bad "bots-vhconf"
export HM_RL_MOCK_PTR=crawl-66-249-66-1.googlebot.com
export HM_RL_MOCK_FWD=66.249.66.1
hm_rl_cmd_bots allow verify 66.249.66.1 >/dev/null 2>&1 || bad "bots-verify-cmd"
grep -qxF '66.249.66.1' "$(hm_rl_bots_ips_file)" \
  && ok "bots-ip-saved" || bad "bots-ip-saved"

# --- cloudflare hint in block ---
grep -q 'realip' "${TEST_VHCONF}" && ok "cf-realip-comment" || bad "cf-realip-comment"

if [[ "${fail}" -eq 0 ]]; then
  echo "ALL OK"
  exit 0
fi
echo "FAILED (${fail} checks)"
exit 1