#!/usr/bin/env bash
# Regresja: ssl issue helpers — parse ACME, DNS pre-check, dispatch (bez prawdziwego ACME)
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
# shellcheck disable=SC1091
source lib/common/ui.sh
hm_file_log_ui() { :; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }
hm_is_valid_domain() {
  [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]
}
hm_run() { "$@"; }
hm_ols_reload_soft() { return 0; }
hm_find_site_by_arg_exact() { return 1; }
hm_resolve_site_paths() { return 1; }
hm_tsv_unfield() { printf '%s' "$1"; }
hm_mysql_exec() { return 1; }
hm_sql_quote() { printf "'%s'" "${1//\'/\'\'}"; }
hm_print_site_ssl() { :; }
hm_ssl_paths_for_domain() { return 1; }
hm_ssl_status() { echo missing; }
hm_ssl_days_left() { echo ""; }
hm_ssl_expiry() { echo "-"; }
hm_progress_bar() { :; }
hm_progress_done() { :; }
hm_discover_sites() { HM_SITES_LIST=(); }
hm_confirm_plan() { return 1; } # anuluj — nie wołaj ACME w teście CLI

# shellcheck disable=SC1091
source commands/ssl/issue.sh

fail=0
assert_eq() {
  local name="$1" got="$2" want="$3"
  if [[ "${got}" != "${want}" ]]; then
    echo "FAIL ${name}: got=[${got}] want=[${want}]"
    fail=1
    return
  fi
  echo "OK   ${name}"
}

# --- parse ACME ---
assert_eq "parse-rate" "$(hm_ssl_parse_acme_error 'Error: too many certificates already issued — rate limit')" \
  "Rate limit Let's Encrypt — odczekaj lub użyj staging / innego konta ACME."
assert_eq "parse-nxdomain" "$(hm_ssl_parse_acme_error 'DNS problem: NXDOMAIN looking up A')" \
  "Problem DNS (NXDOMAIN/SERVFAIL) — sprawdź A/AAAA i propagację."
assert_eq "parse-http01" "$(hm_ssl_parse_acme_error 'Invalid response from http-01: 404')" \
  "HTTP-01 challenge failed (404/invalid) — .well-known, rewrite, Cloudflare proxy, firewall."

# --- DNS pre-check: mock VPS IP + resolve ---
hm_ssl_vps_ips() { printf '203.0.113.10\n'; }
hm_ssl_resolve_a() {
  case "$1" in
    ok.test) printf '203.0.113.10\n' ;;
    bad.test) printf '198.51.100.1\n' ;;
    empty.test) printf '' ;;
  esac
}
if hm_ssl_precheck_dns "ok.test" >/dev/null; then
  echo "OK   dns-precheck-match"
else
  echo "FAIL dns-precheck-match"
  fail=1
fi
if hm_ssl_precheck_dns "bad.test" >/dev/null 2>&1; then
  echo "FAIL dns-precheck-mismatch-should-fail"
  fail=1
else
  echo "OK   dns-precheck-mismatch"
fi
if hm_ssl_precheck_dns "empty.test" >/dev/null 2>&1; then
  echo "FAIL dns-precheck-empty-should-fail"
  fail=1
else
  echo "OK   dns-precheck-nxdomain"
fi

# --- issue bez domeny / anulowanie confirm ---
if cmd_ssl_issue 2>/dev/null; then
  echo "FAIL issue-no-domain"
  fail=1
else
  echo "OK   issue-no-domain"
fi
# z domeną ale confirm=no → rc≠0, bez ACME
if cmd_ssl_issue example.test --with-www 2>/dev/null; then
  echo "FAIL issue-cancel-should-rc1"
  fail=1
else
  echo "OK   issue-confirm-cancel"
fi

# wildcard bez --dns
if cmd_ssl_issue example.test --wildcard 2>/dev/null; then
  echo "FAIL wildcard-no-dns"
  fail=1
else
  echo "OK   wildcard-requires-dns"
fi

# mail bez cyberpanel
hm_have_cmd() { [[ "$1" == cyberpanel ]] && return 1; command -v "$1" >/dev/null 2>&1; }
hm_confirm_plan() { return 0; }
if cmd_ssl_mail example.test 2>/dev/null; then
  echo "FAIL mail-without-cp"
  fail=1
else
  echo "OK   mail-requires-cyberpanel"
fi

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL OK"
exit 0
