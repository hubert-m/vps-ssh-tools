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

# --- self-signed wyłączone ---
if cmd_ssl_self_signed example.test 2>/dev/null; then
  echo "FAIL self-signed-should-refuse"
  fail=1
else
  echo "OK   self-signed-refuse"
fi
if hm_ssl_issue_via_cyberpanel example.test selfsigned 2>/dev/null; then
  echo "FAIL cyberpanel-selfsigned-should-refuse"
  fail=1
else
  echo "OK   cyberpanel-selfsigned-refuse"
fi
if hm_ssl_self_signed_openssl example.test 2>/dev/null; then
  echo "FAIL openssl-selfsigned-should-refuse"
  fail=1
else
  echo "OK   openssl-selfsigned-refuse"
fi

# --- wykrywanie self-signed ---
# shellcheck disable=SC1091
source commands/_shared/sites/ssl.sh
ssdir="$(mktemp -d)"
# Na MSYS/Git bash pojedyncze /CN= jest traktowane jak ścieżka Windows.
openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
  -keyout "${ssdir}/key.pem" -out "${ssdir}/cert.pem" \
  -subj "//CN=self.test" >/dev/null 2>&1 \
  || openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout "${ssdir}/key.pem" -out "${ssdir}/cert.pem" \
    -subj "/CN=self.test" >/dev/null 2>&1 || true
if [[ -s "${ssdir}/cert.pem" ]]; then
  if hm_ssl_is_self_signed "${ssdir}/cert.pem"; then
    echo "OK   detect-self-signed"
  else
    echo "FAIL detect-self-signed"
    fail=1
  fi
  st="$(hm_ssl_status "${ssdir}/cert.pem")"
  assert_eq "status-selfsigned" "${st}" "selfsigned"
else
  echo "FAIL make-self-signed-cert"
  fail=1
fi
# --- purge LE przed issueSSL przy self-signed ---
le="$(mktemp -d)"
mkdir -p "${le}/live/self.test" "${le}/archive/self.test" "${le}/renewal"
cp -f "${ssdir}/cert.pem" "${le}/live/self.test/fullchain.pem"
printf 'x\n' >"${le}/archive/self.test/fullchain1.pem"
printf 'x\n' >"${le}/renewal/self.test"
printf 'x\n' >"${le}/renewal/self.test.conf"
printf 'keep\n' >"${le}/live/other.test"
export HM_SSL_LE_ROOT="${le}"
hm_ssl_paths_for_domain() { printf '%s' "${le}/live/self.test/fullchain.pem"; }
hm_ssl_clear_self_signed_before_issue "self.test" >/dev/null
[[ ! -e "${le}/live/self.test" ]] && echo "OK   purge-live" || {
  echo "FAIL purge-live"
  fail=1
}
[[ ! -e "${le}/archive/self.test" ]] && echo "OK   purge-archive" || {
  echo "FAIL purge-archive"
  fail=1
}
[[ ! -e "${le}/renewal/self.test" && ! -e "${le}/renewal/self.test.conf" ]] && echo "OK   purge-renewal" || {
  echo "FAIL purge-renewal"
  fail=1
}
[[ -f "${le}/live/other.test" ]] && echo "OK   purge-other-kept" || {
  echo "FAIL purge-other-kept"
  fail=1
}
# LE cert (issuer ≠ subject) → bez purge
openssl req -x509 -nodes -newkey rsa:2048 -days 90 \
  -keyout "${ssdir}/cakey.pem" -out "${ssdir}/cacert.pem" \
  -subj "//CN=Fake CA" >/dev/null 2>&1 \
  || openssl req -x509 -nodes -newkey rsa:2048 -days 90 \
    -keyout "${ssdir}/cakey.pem" -out "${ssdir}/cacert.pem" \
    -subj "/CN=Fake CA" >/dev/null 2>&1 || true
# LE-like: osobny issuer przez skopiowanie innego CN nie wystarczy; symuluj subject≠issuer
# przez drugi cert i ręczny plik — hm_ssl_is_self_signed wymaga openssl subject/issuer.
# Tu sprawdzamy brak purge, gdy status nie jest selfsigned (stub).
mkdir -p "${le}/live/ok.test"
printf 'placeholder\n' >"${le}/live/ok.test/fullchain.pem"
hm_ssl_is_self_signed() { return 1; }
hm_ssl_paths_for_domain() { printf '%s' "${le}/live/ok.test/fullchain.pem"; }
hm_ssl_clear_self_signed_before_issue "ok.test" >/dev/null
[[ -f "${le}/live/ok.test/fullchain.pem" ]] && echo "OK   no-purge-when-not-ss" || {
  echo "FAIL no-purge-when-not-ss"
  fail=1
}
unset HM_SSL_LE_ROOT
rm -rf "${ssdir}" "${le}"

# --- acme-update: confirm cancel ---
hm_confirm_plan() { return 1; }
if cmd_ssl_acme_update 2>/dev/null; then
  echo "FAIL acme-update-cancel"
  fail=1
else
  echo "OK   acme-update-cancel"
fi
# dry ścieżka testowa
hm_confirm_plan() { return 0; }
export HMTOOLS_TEST=1
out="$(cmd_ssl_acme_update --yes 2>/dev/null || true)"
if [[ "${out}" == *acme-update*ok* ]]; then
  echo "OK   acme-update-test"
else
  echo "FAIL acme-update-test: [${out}]"
  fail=1
fi
unset HMTOOLS_TEST

grep -q 'acme-update' commands/ssl/main.sh && echo "OK   help-acme" || {
  echo "FAIL help-acme"
  fail=1
}
grep -q 'SELF-SIGNED' commands/ssl/main.sh && echo "OK   list-selfsigned-label" || {
  echo "FAIL list-selfsigned-label"
  fail=1
}

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL OK"
exit 0
