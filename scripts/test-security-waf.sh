#!/usr/bin/env bash
# Regresja: security waf — parse audit, exact host, whitelist vhconf + exclusions
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }
hm_mktemp() { mktemp "${TMPDIR:-/tmp}/hm.XXXXXX${1:-}"; }
hm_confirm_plan() { return 0; }
hm_confirm_plan_critical() { return 0; }
hm_run_timeout() { shift; "$@"; }
hm_help_topic() { :; }
hm_is_valid_domain() { [[ "$1" == *.* ]]; }
hm_file_log() { :; }
hm_ols_reload_soft() { return 0; }
hm_ols_vhost_conf_for() { printf '%s' "${FAKE_VHCONF}"; }
hm_vhost_conf_path() { printf '%s' "${FAKE_VHCONF}"; }
hm_ols_vhost_has_block() {
  local conf="$1" name="$2"
  grep -qF "# hmtools:${name} BEGIN" "${conf}" 2>/dev/null
}
hm_ols_vhost_strip_block() {
  local conf="$1" name="$2" out="$3"
  awk -v n="${name}" '
    BEGIN { skip=0; begin="# hmtools:" n " BEGIN"; end="# hmtools:" n " END" }
    index($0, begin) { skip=1; next }
    index($0, end) { skip=0; next }
    !skip { print }
  ' "${conf}" > "${out}"
}
hm_ols_vhost_apply_tmp() {
  local domain="$1" conf="$2" tmp="$3"
  cat "${tmp}" > "${conf}"
  return 0
}
C_BOLD=""; C_RESET=""; C_DIM=""; C_CYAN=""; C_RED=""; C_GREEN=""; C_YELLOW=""
_hm_cmd_help() { cat >/dev/null; }
_hm_cmd_register() { :; }
_hm_cmd_register_site() { :; }

fail=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

export OLS_ROOT="${tmpdir}/lsws"
mkdir -p "${OLS_ROOT}/conf/modsec/owasp-modsecurity-crs/rules" \
  "${OLS_ROOT}/conf/vhosts/example.pl" \
  "${OLS_ROOT}/logs" \
  "${OLS_ROOT}/modules"
printf 'module mod_security {\n  SecRuleEngine On\n}\n' > "${OLS_ROOT}/conf/httpd_config.conf"
touch "${OLS_ROOT}/modules/mod_security.so"
printf 'SecRuleEngine On\nSecAuditLog %s/logs/auditmodsec.log\n' "${OLS_ROOT}" \
  > "${OLS_ROOT}/conf/modsec.conf"
touch "${OLS_ROOT}/conf/modsec/owasp-modsecurity-crs/rules/REQUEST-942-APPLICATION-ATTACK-SQLI.conf"

FAKE_VHCONF="${OLS_ROOT}/conf/vhosts/example.pl/vhconf.conf"
printf 'docRoot /home/example.pl/public_html\n' > "${FAKE_VHCONF}"

# sample audit log (2 hits example.pl, 1 other.example.pl — substring trap)
cat > "${OLS_ROOT}/logs/auditmodsec.log" <<'EOF'
--abc123-A--
[05/Nov/2026:10:00:00 +0000] 1.2.3.4
--abc123-B--
GET /wp-admin/admin-ajax.php HTTP/1.1
Host: example.pl
--abc123-H--
Message: [id "949110"] [msg "Inbound Anomaly Score Exceeded"]
--def456-A--
[05/Nov/2026:10:01:00 +0000] 5.6.7.8
--def456-B--
POST /xmlrpc.php HTTP/1.1
Host: example.pl
--def456-H--
Message: [id "949110"] [msg "Inbound Anomaly Score Exceeded"]
--ghi789-A--
[05/Nov/2026:10:02:00 +0000] 9.9.9.9
--ghi789-B--
GET / HTTP/1.1
Host: other.example.pl
--ghi789-H--
Message: [id "941100"] [msg "XSS Attack Detected"]
EOF

# shellcheck disable=SC1091
source commands/security/waf.sh

# --- parse ---
parsed="$(hm_waf_parse_audit "${OLS_ROOT}/logs/auditmodsec.log")"
nlines="$(printf '%s\n' "${parsed}" | grep -c . || true)"
if [[ "${nlines}" -eq 3 ]]; then
  echo "OK   parse-audit-3"
else
  echo "FAIL parse-audit (got ${nlines})"
  fail=1
fi

# --- exact domain filter (nie other.example.pl) ---
out="$(hm_waf_log_cmd 10 --domain example.pl 2>/dev/null | tr -d '\r' || true)"
if printf '%s\n' "${out}" | grep -q '949110' \
  && ! printf '%s\n' "${out}" | grep -q '941100'; then
  echo "OK   log-domain-exact"
else
  echo "FAIL log-domain-exact"
  printf '%s\n' "${out}" | sed 's/^/  | /'
  fail=1
fi

# substring trap: filtr other.example.pl nie łapie example.pl
out2="$(hm_waf_log_cmd 10 --domain other.example.pl 2>/dev/null | tr -d '\r' || true)"
if printf '%s\n' "${out2}" | grep -q '941100' \
  && ! printf '%s\n' "${out2}" | grep -q '949110'; then
  echo "OK   log-domain-no-substring"
else
  echo "FAIL log-domain-no-substring"
  fail=1
fi

# --- status detects module + OWASP ---
st="$(hm_waf_status 2>/dev/null || true)"
if printf '%s\n' "${st}" | grep -qi 'OWASP' && printf '%s\n' "${st}" | grep -qi 'On'; then
  echo "OK   status-owasp-on"
else
  echo "FAIL status-owasp-on"
  fail=1
fi

# --- whitelist apply (idempotent) ---
HM_SITE_DOMAIN="example.pl"
if hm_waf_whitelist_apply "example.pl" "949110"; then
  if grep -q '# hmtools:waf BEGIN' "${FAKE_VHCONF}" \
    && grep -q 'SecRuleRemoveById 949110' "${FAKE_VHCONF}" \
    && grep -q 'ctl:ruleRemoveById=949110' "$(hm_waf_exclusions_file)"; then
    echo "OK   whitelist-apply"
  else
    echo "FAIL whitelist-apply content"
    fail=1
  fi
else
  echo "FAIL whitelist-apply rc"
  fail=1
fi

# idempotent: drugi raz — wciąż jedna reguła
ids1="$(hm_waf_whitelist_list_ids example.pl | sort -u | tr '\n' ' ')"
hm_waf_whitelist_cmd 949110 >/dev/null 2>&1 || true
ids2="$(hm_waf_whitelist_list_ids example.pl | sort -u | tr '\n' ' ')"
if [[ "${ids1}" == "${ids2}" ]] && [[ "${ids1}" == *949110* ]]; then
  echo "OK   whitelist-idempotent"
else
  echo "FAIL whitelist-idempotent '${ids1}' vs '${ids2}'"
  fail=1
fi

# remove
hm_waf_whitelist_cmd remove 949110 >/dev/null 2>&1 || true
if ! grep -q 'SecRuleRemoveById 949110' "${FAKE_VHCONF}" 2>/dev/null; then
  echo "OK   whitelist-remove"
else
  echo "FAIL whitelist-remove"
  fail=1
fi

# --- mode off: confirm required (mock reject) ---
hm_confirm_plan() { return 1; }
if hm_waf_mode_cmd off 2>/dev/null; then
  echo "FAIL mode-off-should-abort"
  fail=1
else
  echo "OK   mode-off-abort"
fi
# engine nadal On
eng="$(hm_waf_engine_mode)"
if [[ "${eng}" == "On" ]]; then
  echo "OK   mode-off-no-change"
else
  echo "FAIL mode-off-no-change (${eng})"
  fail=1
fi

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED=${fail}"
  exit 1
fi
echo "ALL OK"
exit 0
