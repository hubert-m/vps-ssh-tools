#!/usr/bin/env bash
# Regresja: bloki suspend / openbasedir (strip/idempotencja), IP rewrite, status detect
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }
hm_mktemp() { mktemp "${TMPDIR:-/tmp}/hm.XXXXXX${1:-}"; }
hm_confirm_plan() { return 1; }
hm_ols_reload_soft() { return 0; }
hm_help_topic() { :; }
hm_is_valid_domain() { [[ "$1" == *.* ]]; }
hm_file_log() { :; }
C_BOLD=""; C_RESET=""; C_DIM=""; C_CYAN=""; C_RED=""
_hm_cmd_help() { cat >/dev/null; }
_hm_cmd_register_site() { :; }
hm_vhost_conf_path() { echo "${TEST_VHOST_CONF:-}"; [[ -f "${TEST_VHOST_CONF:-}" ]]; }
hm_discover_sites() { HM_SITES_LIST=("example.pl" "other.pl"); }
hm_tsv_unfield() { [[ "${1:-}" == "-" ]] && printf '' || printf '%s' "${1:-}"; }
hm_tsv_field() { [[ -z "${1:-}" ]] && printf '-' || printf '%s' "$1"; }

# shellcheck disable=SC1091
source commands/ols/vhost.sh
# shellcheck disable=SC1091
source commands/suspend/main.sh

fail=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

conf="${tmpdir}/vhconf.conf"
export TEST_VHOST_CONF="${conf}"
cat > "${conf}" <<'EOF'
docRoot                   $VH_ROOT/public_html
vhDomain                  example.pl
rewrite  {
  enable                  1
  autoLoadHtaccess        1
}
extprocessor lsphp {
  type                    lsapi
  address                 uds://tmp/lshttpd/lsphp.sock
}
context / {
  type                    NULL
}
EOF

# --- IP rewrite escape ---
re="$(hm_suspend_ip_to_rewrite "1.2.3.4")"
if [[ "${re}" == '1\.2\.3\.4' ]]; then
  echo "OK   ip-escape"
else
  echo "FAIL ip-escape got=${re}"
  fail=1
fi

if hm_suspend_is_valid_ip "8.8.8.8"; then
  echo "OK   ip-valid"
else
  echo "FAIL ip-valid"
  fail=1
fi
if hm_suspend_is_valid_ip "bad"; then
  echo "FAIL ip-bad"
  fail=1
else
  echo "OK   ip-bad"
fi

# --- suspend block idempotent ---
tmp="$(mktemp)"
body="$(hm_suspend_block_body "503" "10.0.0.1" "/x.html" "test")"
hm_ols_vhost_strip_block "${conf}" "suspend" "${tmp}"
{
  cat "${tmp}"
  echo "# hmtools:suspend BEGIN"
  printf '%s\n' "${body}"
  echo "# hmtools:suspend END"
} > "${tmp}.a"
cp "${tmp}.a" "${conf}"

if hm_ols_vhost_has_block "${conf}" "suspend"; then
  echo "OK   suspend-has-block"
else
  echo "FAIL suspend-has-block"
  fail=1
fi

if grep -q 'RewriteCond %{REMOTE_ADDR} !\^10\\.0\\.0\\.1\$' "${conf}" \
  || grep -qF 'RewriteCond %{REMOTE_ADDR} !^10\.0\.0\.1$' "${conf}"; then
  echo "OK   suspend-allow-ip"
else
  echo "FAIL suspend-allow-ip"
  grep -n REMOTE_ADDR "${conf}" || true
  fail=1
fi

if grep -q 'R=503' "${conf}"; then
  echo "OK   suspend-503"
else
  echo "FAIL suspend-503"
  fail=1
fi

# drugi strip+append = jeden blok
hm_ols_vhost_strip_block "${conf}" "suspend" "${tmp}"
{
  cat "${tmp}"
  echo "# hmtools:suspend BEGIN"
  printf '%s\n' "$(hm_suspend_block_body "503" "" "" "")"
  echo "# hmtools:suspend END"
} > "${tmp}.b"
cp "${tmp}.b" "${conf}"
c="$(grep -c 'hmtools:suspend BEGIN' "${conf}" || true)"
if [[ "${c}" -eq 1 ]]; then
  echo "OK   suspend-idempotent"
else
  echo "FAIL suspend-idempotent count=${c}"
  fail=1
fi

# unsuspend strip → brak bloku
hm_ols_vhost_strip_block "${conf}" "suspend" "${tmp}"
cp "${tmp}" "${conf}"
if hm_ols_vhost_has_block "${conf}" "suspend"; then
  echo "FAIL unsuspend-strip"
  fail=1
else
  echo "OK   unsuspend-strip"
fi

# --- openbasedir ---
paths="/home/example.pl/:/tmp/:/usr/local/lsws/"
hm_ols_vhost_strip_block "${conf}" "openbasedir" "${tmp}"
{
  cat "${tmp}"
  echo "# hmtools:openbasedir BEGIN"
  hm_openbasedir_block_body "${paths}"
  echo "# hmtools:openbasedir END"
} > "${tmp}.o"
cp "${tmp}.o" "${conf}"

if grep -q 'php_admin_value open_basedir' "${conf}" && hm_ols_vhost_has_block "${conf}" "openbasedir"; then
  echo "OK   openbasedir-on"
else
  echo "FAIL openbasedir-on"
  fail=1
fi

hm_ols_vhost_strip_block "${conf}" "openbasedir" "${tmp}"
cp "${tmp}" "${conf}"
if hm_ols_vhost_has_block "${conf}" "openbasedir"; then
  echo "FAIL openbasedir-off"
  fail=1
else
  echo "OK   openbasedir-off"
fi

# --- maintenance body ma errorpage / context ---
mb="$(hm_suspend_block_body "maintenance" "" "${tmpdir}/suspended.html" "Brak płatności")"
if [[ "${mb}" == *errorpage* && "${mb}" == *hmtools-suspended.html* ]]; then
  echo "OK   maintenance-page"
else
  echo "FAIL maintenance-page"
  fail=1
fi

# --- HTML template exists ---
if [[ -f share/suspended.html ]]; then
  echo "OK   share-html"
else
  echo "FAIL share-html"
  fail=1
fi

# --- probe accept 503 ---
# mock curl via PATH
mkdir -p "${tmpdir}/bin"
cat > "${tmpdir}/bin/curl" <<'EOF'
#!/usr/bin/env bash
# zawsze 503
echo 503
EOF
chmod +x "${tmpdir}/bin/curl"
# hm_ols_vhost_http_probe uses curl -o /dev/null -w '%{http_code}' — our stub echoes 503 always
# Actually the stub replaces curl entirely; -w still runs but we only echo 503 once at end... 
# Better stub:
cat > "${tmpdir}/bin/curl" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  if [[ "$a" == "%{http_code}" ]]; then
    printf '503'
    exit 0
  fi
done
printf '503'
exit 0
EOF
chmod +x "${tmpdir}/bin/curl"
PATH="${tmpdir}/bin:$PATH"
if hm_ols_vhost_http_probe "example.pl" "503"; then
  echo "OK   probe-accept-503"
else
  echo "FAIL probe-accept-503"
  fail=1
fi

if [[ "${fail}" -eq 0 ]]; then
  echo "ALL OK"
  exit 0
fi
echo "FAILED=${fail}"
exit 1
