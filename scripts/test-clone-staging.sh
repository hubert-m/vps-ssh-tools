#!/usr/bin/env bash
# Regresja: clone/staging — nazwy DB, registry, excludes, deploy bez snap → stop
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
# shellcheck source=lib/common/ui.sh
source "${HMTOOLS_ROOT}/lib/common/ui.sh"

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }
hm_mktemp() { mktemp "${TMPDIR:-/tmp}/hm.XXXXXX${1:-}"; }
hm_confirm_plan() { return 0; }
hm_confirm_plan_critical() { return 0; }
hm_help_topic() { :; }
hm_is_valid_domain() { [[ "$1" == *.* ]]; }
hm_is_valid_db_name() { [[ "$1" =~ ^[A-Za-z][A-Za-z0-9_]{0,63}$ ]]; }
hm_file_log() { :; }
hm_gen_password() { printf 'TestPass12!xYzAb'; }
hm_os_web_group() { echo nogroup; }
hm_ols_reload_soft() { return 0; }
hm_find_site_by_arg_exact() { printf '%s' "$1"; }
hm_set_site_context() {
  HM_SITE_DOMAIN="$1"
  HM_SITE_ROOT="${FAKE_HOME}/$1"
  HM_SITE_DOCROOT="${FAKE_HOME}/$1/public_html"
  HM_SITE_USER="siteuser"
  HM_SITE_PHP="8.3"
}
hm_site_context_push() { hm_set_site_context "$1"; }
hm_site_context_pop() { :; }
hm_mysql_db_exists() { return 1; }
hm_mysql_dump_local() { printf 'dump' | gzip > "$2"; }
hm_mysql_cli() { echo true; }
hm_mysql_exec() { return 0; }
hm_sql_quote() { printf "'%s'" "$1"; }
hm_vhost_conf_path() { printf '%s' "${FAKE_HOME}/$1/vhconf.conf"; }
hm_ols_vhost_strip_block() {
  local conf="$1" name="$2" out="$3"
  awk -v n="${name}" '
    BEGIN { skip=0; b="# hmtools:" n " BEGIN"; e="# hmtools:" n " END" }
    index($0,b){skip=1;next}
    index($0,e){skip=0;next}
    !skip{print}
  ' "${conf}" > "${out}"
}
hm_ols_vhost_write() { cat "$2" > "$1"; }
hm_wp_find_path() { [[ -f "$1/wp-config.php" ]] && printf '%s' "$1" || return 1; }
hm_wp_db_name() { printf 'src_db'; }
hm_wp_run() { return 0; }
hm_wp_ensure_cli() { return 0; }
hm_extract_db_from_file() { return 1; }
hm_mysql_default_db_for_site() { printf 'src_db'; }
cmd_site_create() { mkdir -p "${FAKE_HOME}/$1/public_html"; printf 'docRoot x\n' > "${FAKE_HOME}/$1/vhconf.conf"; return 0; }
C_BOLD=""; C_RESET=""; C_DIM=""; C_CYAN=""; C_RED=""; C_GREEN=""; C_YELLOW=""
_hm_cmd_help() { cat >/dev/null; }
_hm_cmd_register() { :; }
_hm_cmd_register_site() { :; }

fail=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

# mock rsync (Git Bash / Windows często bez rsync)
mkdir -p "${tmpdir}/bin"
cat > "${tmpdir}/bin/rsync" <<'EOF'
#!/bin/sh
# minimal: skopiuj src/ → dst/; --delete usuwa pliki spoza src; --checksum wymusza treść
src=""; dst=""; do_delete=0
for a in "$@"; do
  case "$a" in
    --delete) do_delete=1 ;;
    --checksum|-c|-I|--ignore-times) ;;
    -*) ;;
    *)
      if [ -z "$src" ]; then src=$a
      else dst=$a
      fi
      ;;
  esac
done
src=${src%/}; dst=${dst%/}
[ -d "$src" ] || exit 1
mkdir -p "$dst"
if [ "$do_delete" = 1 ]; then
  find "$dst" -mindepth 1 -print 2>/dev/null | sort -r | while read -r f; do
    rel=${f#"$dst"/}
    [ -e "$src/$rel" ] || rm -rf -- "$f"
  done
fi
# zawsze nadpisz treścią ze src (symulacja --checksum / pełnej synchronizacji)
cp -R "$src"/. "$dst"/ 2>/dev/null || cp -a "$src"/. "$dst"/
exit 0
EOF
chmod +x "${tmpdir}/bin/rsync"
export PATH="${tmpdir}/bin:${PATH}"

FAKE_HOME="${tmpdir}/home"
mkdir -p "${FAKE_HOME}/example.pl/public_html" "${FAKE_HOME}/staging.example.pl/public_html"
printf '<?php define("DB_NAME","src_db");\n' > "${FAKE_HOME}/example.pl/public_html/wp-config.php"
printf 'hello' > "${FAKE_HOME}/example.pl/public_html/index.php"
printf 'docRoot x\n' > "${FAKE_HOME}/example.pl/vhconf.conf"
printf 'docRoot x\n' > "${FAKE_HOME}/staging.example.pl/vhconf.conf"
export HMTOOLS_STATE_DIR="${tmpdir}/state"
export BACKUP_EXCLUDES="./node_modules ./.git ./tmp"

# shellcheck disable=SC1091
source commands/clone/main.sh

# --- db name ---
n="$(hm_clone_db_name_for_domain staging.example.pl)"
if [[ "${n}" == "staging_example_pl" ]]; then
  echo "OK   db-name"
else
  echo "FAIL db-name (${n})"
  fail=1
fi

# --- staging name ---
if hm_clone_is_staging_name example.pl staging.example.pl \
  && ! hm_clone_is_staging_name example.pl other.pl; then
  echo "OK   staging-name"
else
  echo "FAIL staging-name"
  fail=1
fi

# --- registry ---
HM_SITE_DOMAIN="example.pl"
HM_SITE_ROOT="${FAKE_HOME}/example.pl"
hm_clone_registry_add "${HM_SITE_ROOT}" "staging.example.pl" "noindex=1"
hm_clone_registry_add "${HM_SITE_ROOT}" "staging.example.pl" "noindex=1" # idempotent overwrite
cnt="$(grep -c '^staging.example.pl|' "$(hm_clone_registry_path)" || true)"
if [[ "${cnt}" -eq 1 ]]; then
  echo "OK   registry-idempotent"
else
  echo "FAIL registry-idempotent (${cnt})"
  fail=1
fi

# --- marker ---
hm_clone_write_marker "${FAKE_HOME}/staging.example.pl" "example.pl"
prod="$(hm_clone_read_prod_from_marker "${FAKE_HOME}/staging.example.pl")"
if [[ "${prod}" == "example.pl" ]]; then
  echo "OK   marker"
else
  echo "FAIL marker (${prod})"
  fail=1
fi

# --- excludes contain node_modules ---
ex="$(hm_clone_rsync_excludes | tr '\n' ' ')"
if [[ "${ex}" == *node_modules* && "${ex}" == *.hmtools-snap* ]]; then
  echo "OK   excludes"
else
  echo "FAIL excludes (${ex})"
  fail=1
fi

# --- rsync files-only clone ---
HM_SITE_DOMAIN="example.pl"
if hm_clone_run example.pl staging.example.pl --files-only --yes; then
  if [[ -f "${FAKE_HOME}/staging.example.pl/public_html/index.php" ]]; then
    echo "OK   clone-files"
  else
    echo "FAIL clone-files missing index"
    fail=1
  fi
else
  echo "FAIL clone-files rc"
  fail=1
fi

# staging list
out="$(hm_clone_registry_list 2>/dev/null || true)"
if printf '%s\n' "${out}" | grep -q staging.example.pl; then
  echo "OK   staging-list"
else
  echo "FAIL staging-list"
  fail=1
fi

# --- deploy rollback: usunięcie plików dodanych przez deploy (przed mockiem snap fail) ---
prod_doc="${FAKE_HOME}/example.pl/public_html"
printf 'v1' > "${prod_doc}/index.php"
printf 'keep' > "${prod_doc}/a.txt"
rm -f "${prod_doc}/debug-staging.php"
export HMTOOLS_STATE_DIR="${tmpdir}/state"
HM_SITE_DOMAIN="example.pl"
HM_SITE_ROOT="${FAKE_HOME}/example.pl"
HM_SITE_DOCROOT="${prod_doc}"
HM_SITE_USER="siteuser"
stamp="$(hm_clone_snap_prod example.pl)"
# ten sam ROZMIAR co v1 (2 B) — regresja: bez --checksum rsync mógłby pominąć przy tym samym mtime
printf 'v2' > "${prod_doc}/index.php"
touch -r "${prod_doc}/index.php" "${prod_doc}/index.php" 2>/dev/null || true
printf 'staging-debug' > "${prod_doc}/debug-staging.php"
rm -f "${prod_doc}/a.txt"
hm_clone_deploy_rollback "${stamp}" --yes >/dev/null 2>&1 || true
idx="$(cat "${prod_doc}/index.php" 2>/dev/null || true)"
if [[ "${idx}" == "v1" ]] \
  && [[ "$(cat "${prod_doc}/a.txt")" == "keep" ]] \
  && [[ ! -f "${prod_doc}/debug-staging.php" ]]; then
  echo "OK   deploy-rollback-1to1"
else
  echo "FAIL deploy-rollback-1to1 idx=${idx}"
  ls -la "${prod_doc}" || true
  fail=1
fi

# --- deploy: snap fail → abort (no prod overwrite) ---
hm_clone_snap_prod() { hm_err "snap fail"; return 1; }
printf 'PROD' > "${FAKE_HOME}/example.pl/public_html/index.php"
HM_SITE_DOMAIN="staging.example.pl"
HM_SITE_ROOT="${FAKE_HOME}/staging.example.pl"
HM_SITE_DOCROOT="${FAKE_HOME}/staging.example.pl/public_html"
if hm_clone_deploy example.pl --files --yes 2>/dev/null; then
  echo "FAIL deploy-should-abort-without-snap"
  fail=1
else
  echo "OK   deploy-abort-no-snap"
fi
# produkcja nienaruszona
if grep -q 'PROD' "${FAKE_HOME}/example.pl/public_html/index.php"; then
  echo "OK   prod-untouched"
else
  echo "FAIL prod-untouched"
  fail=1
fi

# --- env update (non-WP) ---
passf="$(hm_mktemp .p)"; printf 'SecretPass99xx' > "${passf}"; chmod 600 "${passf}"
envf="${tmpdir}/.env"
cat > "${envf}" <<'EOF'
APP_URL=https://old.example
DB_DATABASE=old
DB_USERNAME=old
DB_PASSWORD="old"
EOF
hm_clone_update_env_db "${envf}" "newdb" "newuser" "${passf}" "https://new.example"
if grep -q 'DB_DATABASE=newdb' "${envf}" && grep -q 'APP_URL=https://new.example' "${envf}"; then
  echo "OK   env-update"
else
  echo "FAIL env-update"
  cat "${envf}"
  fail=1
fi
rm -f "${passf}"

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED=${fail}"
  exit 1
fi
echo "ALL OK"
exit 0
