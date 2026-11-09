#!/usr/bin/env bash
# Regresja: wp — detekcja path, dry-run search-replace flagi, snap meta, find_cli
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
hm_ols_reload_soft() { return 0; }
hm_ols_cache_flush() { return 0; }
hm_help_topic() { :; }
hm_is_valid_domain() { [[ "$1" == *.* ]]; }
hm_file_log() { :; }
hm_run() { printf 'RUN:%s\n' "$*"; return 0; }
hm_gen_password() { printf 'TestPass12!xYz'; }
hm_access_require_site_user() { printf '%s' "siteuser"; }
hm_php_branch_for_site() { printf '8.3'; }
hm_php_bin_for_branch() { return 1; }
hm_extract_db_from_file() {
  local f="$1"
  grep -E "DB_NAME" "${f}" 2>/dev/null | sed -E "s/.*['\"]DB_NAME['\"][[:space:]]*,[[:space:]]*['\"]([^'\"]+)['\"].*/\1\twp-config/" || true
}
hm_mysql_dump_local() {
  local db="$1" out="$2"
  mkdir -p "$(dirname "${out}")"
  printf 'SQL' | gzip -c > "${out}"
  return 0
}
hm_mysql_cli() { command -v mysql 2>/dev/null || command -v true; }
hm_tsv_unfield() { [[ "${1:-}" == "-" ]] && printf '' || printf '%s' "${1:-}"; }
hm_discover_sites() { HM_SITES_LIST=("example.pl"); }
hm_resolve_site_paths() {
  printf '%s\t%s\t%s\t-\t-\t8.3\tuser|active\n' "$1" "${TEST_ROOT}" "${TEST_DOC}"
}
hm_site_context_push() { HM_SITE_DOMAIN="$1"; HM_SITE_DOCROOT="${TEST_DOC}"; HM_SITE_ROOT="${TEST_ROOT}"; HM_SITE_USER=siteuser; HM_SITE_PHP=8.3; }
hm_site_context_pop() { :; }
hm_with_site_context() { local d="$1"; shift; hm_site_context_push "$d"; "$@"; }
C_BOLD=""; C_RESET=""; C_DIM=""; C_CYAN=""; C_RED=""; C_GREEN=""; C_YELLOW=""
_hm_cmd_help() { cat >/dev/null; }
_hm_cmd_register() { :; }
_hm_cmd_register_site() { :; }

fail=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
TEST_ROOT="${tmpdir}/home/example.pl"
TEST_DOC="${TEST_ROOT}/public_html"
mkdir -p "${TEST_DOC}/wp-content/plugins" "${TEST_DOC}/wp-content/themes" "${TEST_DOC}/blog"
cat > "${TEST_DOC}/wp-config.php" <<'EOF'
<?php
define('DB_NAME', 'example_wp');
define('DB_USER', 'u');
define('DB_PASSWORD', 'p');
define('DB_HOST', 'localhost');
EOF

# fake wp-cli
mkdir -p "${tmpdir}/bin"
cat > "${tmpdir}/bin/wp" <<'EOF'
#!/bin/sh
# mock: echo args for tests
echo "wp-mock $*"
exit 0
EOF
chmod +x "${tmpdir}/bin/wp"
export PATH="${tmpdir}/bin:${PATH}"

HM_SITE_DOMAIN="example.pl"
HM_SITE_DOCROOT="${TEST_DOC}"
HM_SITE_ROOT="${TEST_ROOT}"
HM_SITE_USER="siteuser"
HM_SITE_PHP="8.3"

# shellcheck disable=SC1091
source commands/wp/main.sh

# --- find path ---
p="$(hm_wp_find_path "${TEST_DOC}")"
if [[ "${p}" == "${TEST_DOC}" ]]; then
  echo "OK   find-path-docroot"
else
  echo "FAIL find-path-docroot got=${p}"
  fail=1
fi

# depth-1 nested
rm -f "${TEST_DOC}/wp-config.php"
mkdir -p "${TEST_DOC}/app"
cp /dev/null "${TEST_DOC}/app/wp-config.php" 2>/dev/null || true
cat > "${TEST_DOC}/app/wp-config.php" <<'EOF'
<?php
define('DB_NAME', 'nested_wp');
EOF
p="$(hm_wp_find_path "${TEST_DOC}")"
if [[ "${p}" == "${TEST_DOC}/app" ]]; then
  echo "OK   find-path-depth1"
else
  echo "FAIL find-path-depth1 got=${p}"
  fail=1
fi
# restore
rm -rf "${TEST_DOC}/app"
cat > "${TEST_DOC}/wp-config.php" <<'EOF'
<?php
define('DB_NAME', 'example_wp');
EOF

# --- db name ---
db="$(hm_wp_db_name "${TEST_DOC}")"
if [[ "${db}" == "example_wp" ]]; then
  echo "OK   db-name"
else
  echo "FAIL db-name got=${db}"
  fail=1
fi

# --- find cli (system/PATH, brak bundled) ---
cli="$(hm_wp_find_cli)"
if [[ -n "${cli}" && -x "${cli}" && "${cli}" != *"/lib/wp-cli/wp-cli.phar" ]]; then
  echo "OK   find-cli"
else
  echo "FAIL find-cli got=${cli}"
  fail=1
fi

# --- bundled phar ma pierwszeństwo; cli-info bez kontekstu strony ---
_saved_root="${HMTOOLS_ROOT}"
_saved_domain="${HM_SITE_DOMAIN:-}"
HMTOOLS_ROOT="${tmpdir}/hmroot"
mkdir -p "${HMTOOLS_ROOT}/lib/wp-cli"
cat > "${HMTOOLS_ROOT}/lib/wp-cli/wp-cli.phar" <<'EOF'
#!/bin/sh
if [ "$1" = "--info" ]; then
  echo "WP-CLI version: 9.9.9-test"
  exit 0
fi
exit 1
EOF
chmod +x "${HMTOOLS_ROOT}/lib/wp-cli/wp-cli.phar"
cli="$(hm_wp_find_cli)"
if [[ "${cli}" == "${HMTOOLS_ROOT}/lib/wp-cli/wp-cli.phar" ]]; then
  echo "OK   find-cli-bundled"
else
  echo "FAIL find-cli-bundled got=${cli}"
  fail=1
fi
unset HM_SITE_DOMAIN
info_out="$(cmd_wp cli-info 2>&1 || true)"
if [[ "${info_out}" == *"9.9.9-test"* && "${info_out}" == *"lib/wp-cli/wp-cli.phar"* ]]; then
  echo "OK   cli-info-global"
else
  echo "FAIL cli-info-global got=${info_out}"
  fail=1
fi
HMTOOLS_ROOT="${_saved_root}"
HM_SITE_DOMAIN="${_saved_domain}"

# --- weryfikacja SHA-512 (bez sieci) ---
# shellcheck disable=SC1091
source scripts/install-wp-cli.sh
printf 'wpcli-test' > "${tmpdir}/blob"
if sum="$(hm_wpcli_sha512 "${tmpdir}/blob")"; then
  printf '%s\n' "${sum}" > "${tmpdir}/blob.sha512"
  if hm_wpcli_verify_sha512 "${tmpdir}/blob" "${tmpdir}/blob.sha512"; then
    echo "OK   sha512-match"
  else
    echo "FAIL sha512-match"
    fail=1
  fi
  printf '%s\n' "deadbeef" > "${tmpdir}/blob.bad"
  if hm_wpcli_verify_sha512 "${tmpdir}/blob" "${tmpdir}/blob.bad"; then
    echo "FAIL sha512-reject"
    fail=1
  else
    echo "OK   sha512-reject"
  fi
else
  echo "SKIP sha512 (brak sha512sum/shasum/openssl)"
fi

# --- snapshot create ---
# skip chown failures
stamp="$(hm_wp_snap_create "test" 2>/dev/null | sed -n '$p' || true)"
if [[ -n "${stamp}" && -f "${TEST_ROOT}/.hmtools-snap/${stamp}/meta.txt" \
  && -f "${TEST_ROOT}/.hmtools-snap/${stamp}/db.sql.gz" ]]; then
  echo "OK   snap-create"
else
  echo "FAIL snap-create stamp=${stamp}"
  ls -la "${TEST_ROOT}/.hmtools-snap/${stamp}/" 2>/dev/null || ls -la "${TEST_ROOT}/.hmtools-snap/" 2>/dev/null || true
  fail=1
fi

# --- search-replace defaults to dry-run (parse only) ---
# intercept hm_wp_run
_calls=()
hm_wp_run() {
  shift || true  # skip flag
  _calls+=("$*")
  # dry-run should include --dry-run
  printf '1\n'
  return 0
}
hm_wp_smoke_http() { return 0; }
hm_wp_require_site() { return 0; }
hm_wp_resolve_path() { printf '%s' "${TEST_DOC}"; }

_calls=()
hm_wp_search_replace "https://old.pl" "https://example.pl" --yes >/dev/null
joined="${_calls[*]}"
if [[ "${joined}" == *"--dry-run"* ]]; then
  echo "OK   sr-default-dry-run"
else
  echo "FAIL sr-default-dry-run got=${joined}"
  fail=1
fi

_calls=()
hm_wp_search_replace "https://old.pl" "https://example.pl" --execute --yes >/dev/null
joined="${_calls[*]}"
if [[ "${joined}" != *"--dry-run"* && "${joined}" == *"search-replace"* ]]; then
  echo "OK   sr-execute"
else
  echo "FAIL sr-execute got=${joined}"
  fail=1
fi

# --- redact passWord ---
# shellcheck disable=SC1091
source lib/logging.sh 2>/dev/null || true
if declare -F hm_run_cmd_redacted >/dev/null 2>&1; then
  r="$(hm_run_cmd_redacted cyberpanel installWordPress --passWord 'Secret123!' --domainName x.pl)"
  if [[ "${r}" == *'***'* && "${r}" != *Secret123* ]]; then
    echo "OK   redact-passWord"
  else
    echo "FAIL redact-passWord got=${r}"
    fail=1
  fi
else
  echo "SKIP redact (logging not loaded)"
fi

if [[ "${fail}" -eq 0 ]]; then
  echo "ALL PASSED"
  exit 0
fi
echo "FAILED=${fail}"
exit 1
