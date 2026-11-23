#!/usr/bin/env bash
# webs delete: DROP z .{domena}.dbs tylko dla baz wyłącznych i w planie.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*" >&2; }
hm_ok() { echo "OK: $*"; }
hm_info() { :; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }
hm_is_valid_db_name() { [[ "$1" =~ ^[A-Za-z0-9_]+$ ]]; }
hm_sql_quote() { printf "'%s'" "${1//\'/\'\'}"; }
hm_db_size_bytes() { echo 0; }
hm_human_size() { echo "${1:-0}B"; }
hm_detect_all() { PANEL=none; WEBSERVER=nginx; }
hm_tsv_unfield() { [[ "$1" == "-" ]] && printf '' || printf '%s' "$1"; }
hm_del_is_nested_child() { return 1; }
hm_progress_bar() { :; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hm-del-db-own.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
export HM_SITE_MANIFEST_DIR="${TMP}/sites"
mkdir -p "${HM_SITE_MANIFEST_DIR}" "${TMP}/home/a.test/public_html" "${TMP}/home/b.test/public_html"

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

hm_site_manifest_dir() { printf '%s' "${HM_SITE_MANIFEST_DIR}"; }

# shellcheck disable=SC1091
source lib/db.sh
# shellcheck disable=SC1091
source lib/site/db.sh
# shellcheck disable=SC1091
source lib/site/lifecycle.sh

# Minimal stubs z delete.sh (bez pełnego source — unikamy ciężkich zależności)
declare -a HM_DEL_DBS=() HM_DEL_SKIP_DBS=() HM_DEL_DB_USERS=() HM_DEL_PLAN_STEPS=() HM_DEL_PLAN_KEYS=()
declare -a HM_DEL_WIZARD=() HM_DEL_PM2=() HM_DEL_SSL_PATHS=() HM_DEL_NESTED_CHILDREN=()
HM_DEL_DOMAIN="" HM_DEL_ROOT="" HM_DEL_DOCROOT="" HM_DEL_USER="" HM_DEL_KEEP_DB=0
HM_DEL_KEEP_SSL=1 HM_DEL_KEEP_USER=1 HM_DEL_FORCE_NESTED=0 HM_DEL_SIZE=0
HM_DEL_WEB=nginx HM_DEL_USER_SHARED=0 HM_DEL_USER_PROTECTED=0 HM_DEL_CRON_COUNT=0
HM_DEL_HAS_CP=0 HM_DEL_HAS_OLS_MAP=0 HM_DEL_VHOST_DIR=""

hm_del_db_owned_by_other() {
  local dbname="$1" skip_domain="$2" other
  hm_is_valid_db_name "${dbname}" || return 1
  if declare -F hm_site_mysql_db_owned_elsewhere >/dev/null 2>&1; then
    other="$(hm_site_mysql_db_owned_elsewhere "${skip_domain}" "${dbname}" 2>/dev/null || true)"
    if [[ -n "${other}" ]]; then
      return 0
    fi
  fi
  return 1
}

MYSQL_LOG="${TMP}/mysql.log"
: > "${MYSQL_LOG}"
hm_mysql_exec() {
  printf '%s\n' "$*" >> "${MYSQL_LOG}"
  return 0
}

printf 'mysql\tshared_app\tshared_u\t127.0.0.1\t3306\n' > "${HM_SITE_MANIFEST_DIR}/.a.test.dbs"
printf 'mysql\tonly_a\tonly_a_u\t127.0.0.1\t3306\n' >> "${HM_SITE_MANIFEST_DIR}/.a.test.dbs"
printf 'mysql\tshared_app\tshared_u\t127.0.0.1\t3306\n' > "${HM_SITE_MANIFEST_DIR}/.b.test.dbs"
printf 'mysql\tonly_b\tonly_b_u\t127.0.0.1\t3306\n' >> "${HM_SITE_MANIFEST_DIR}/.b.test.dbs"

# --- (1) ownership ---
if hm_del_db_owned_by_other shared_app b.test; then
  pass "(1) shared_app owned by other"
else
  fail "(1) shared_app powinno być współdzielone"
fi
if hm_del_db_owned_by_other only_b b.test; then
  fail "(1) only_b uznane za cudze"
else
  pass "(1) only_b wyłączne"
fi

# --- (2) inwentaryzacja jak w collect ---
HM_DEL_DBS=()
HM_DEL_SKIP_DBS=()
while IFS=$'\t' read -r name dbuser size origin; do
  [[ -n "${name}" ]] || continue
  if hm_del_db_owned_by_other "${name}" "b.test"; then
    HM_DEL_SKIP_DBS+=("${name}|${origin}|współdzielona z inną domeną")
  else
    HM_DEL_DBS+=("${name}|${dbuser}|${size}|${origin}")
  fi
done < <(hm_dbs_for_site "b.test" "${TMP}/home/b.test/public_html" "${TMP}/home/b.test" "buser" 2>/dev/null || true)

skip_names="$(printf '%s\n' "${HM_DEL_SKIP_DBS[@]+"${HM_DEL_SKIP_DBS[@]}"}" | cut -d'|' -f1 | tr '\n' ' ')"
drop_names="$(printf '%s\n' "${HM_DEL_DBS[@]+"${HM_DEL_DBS[@]}"}" | cut -d'|' -f1 | tr '\n' ' ')"
echo "${skip_names}" | grep -qw shared_app && pass "(2) shared_app w SKIP" || fail "(2) shared_app nie w SKIP (${skip_names})"
echo "${drop_names}" | grep -qw only_b && pass "(2) only_b w HM_DEL_DBS" || fail "(2) only_b nie w planie (${drop_names})"
echo "${drop_names}" | grep -qw shared_app && fail "(2) shared_app w DROP" || pass "(2) shared_app poza DROP"

# Plan: krok DROP tylko for HM_DEL_DBS
HM_DEL_PLAN_STEPS=()
HM_DEL_PLAN_KEYS=()
if [[ "${#HM_DEL_DBS[@]}" -gt 0 ]]; then
  parts=""
  for dline in "${HM_DEL_DBS[@]}"; do
    IFS='|' read -r dname _ <<<"${dline}"
    parts="${parts:+${parts}; }${dname}"
  done
  HM_DEL_PLAN_STEPS+=("Usunięcie baz MySQL: ${parts}")
  HM_DEL_PLAN_KEYS+=("db")
fi
plan="$(printf '%s\n' "${HM_DEL_PLAN_STEPS[@]+"${HM_DEL_PLAN_STEPS[@]}"}")"
echo "${plan}" | grep -q 'only_b' && pass "(2) only_b w planie" || fail "(2) brak only_b w planie: ${plan}"
echo "${plan}" | grep -q 'shared_app' && fail "(2) shared_app w planie" || pass "(2) shared_app poza planem"

# --- (3) drop_manifest_dbs ---
: > "${MYSQL_LOG}"
HM_DEL_DOMAIN="b.test"
HM_DEL_KEEP_DB=0
warn1="$(hm_site_lifecycle_drop_manifest_dbs "b.test" 2>&1 || true)"
if grep -q 'DROP DATABASE IF EXISTS `shared_app`' "${MYSQL_LOG}"; then
  fail "(3) DROP shared_app mimo współdzielenia"
else
  pass "(3) brak DROP shared_app"
fi
echo "${warn1}" | grep -qi 'shared_app' && pass "(3) ostrzeżenie shared_app" || fail "(3) brak ostrzeżenia: ${warn1}"
if grep -q 'DROP DATABASE IF EXISTS `only_b`' "${MYSQL_LOG}"; then
  pass "(3) DROP only_b (manifest + plan)"
else
  fail "(3) brak DROP only_b: $(cat "${MYSQL_LOG}")"
fi

# poza planem → bez DROP only_b
: > "${MYSQL_LOG}"
HM_DEL_DBS=()
HM_DEL_SKIP_DBS=("shared_app|manifest.dbs|współdzielona")
warn2="$(hm_site_lifecycle_drop_manifest_dbs "b.test" 2>&1 || true)"
grep -q 'DROP DATABASE IF EXISTS `only_b`' "${MYSQL_LOG}" && fail "(3) only_b DROP poza planem" || pass "(3) only_b poza planem = bez DROP"
echo "${warn2}" | grep -qi 'only_b' && pass "(3) ostrzeżenie only_b poza planem" || fail "(3) brak ostrzeżenia only_b: ${warn2}"

if [[ "${FAIL}" -eq 0 ]]; then
  echo "ALL PASSED (${PASS})"
else
  echo "FAILED (${FAIL} fail, ${PASS} pass)" >&2
  exit 1
fi
