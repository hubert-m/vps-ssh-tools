#!/usr/bin/env bash
# Regresja: child domain / shared Unix — archive/delete nie kasuje HOME mastera ani crontab
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
# shellcheck disable=SC1091
source lib/common/ui.sh
# shellcheck disable=SC1091
source lib/os_family.sh
hm_file_log_ui() { :; }

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

# stubi ścieżek CyberPanel-like: master + child ten sam vhRoot
hm_detect_all() { :; }
hm_discover_sites() {
  HM_SITES_LIST=("alpha.test" "child.alpha.test")
}
hm_resolve_site_paths() {
  local d="$1"
  case "${d}" in
    alpha.test)
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "alpha.test" \
        "$(hm_tsv_field /home/alpha.test)" \
        "$(hm_tsv_field /home/alpha.test/public_html)" \
        "$(hm_tsv_field /home/alpha.test/logs)" \
        "$(hm_tsv_field /usr/local/lsws/conf/vhosts/alpha.test)" \
        "$(hm_tsv_field 8.1)" \
        "$(hm_tsv_field alpha1)|active"
      ;;
    child.alpha.test)
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "child.alpha.test" \
        "$(hm_tsv_field /home/alpha.test)" \
        "$(hm_tsv_field /home/alpha.test/public_html/child.alpha.test)" \
        "$(hm_tsv_field /home/alpha.test/logs)" \
        "$(hm_tsv_field /usr/local/lsws/conf/vhosts/child.alpha.test)" \
        "$(hm_tsv_field 8.1)" \
        "$(hm_tsv_field alpha1)|active"
      ;;
  esac
}
hm_tsv_field() { printf '%s' "${1//$'\t'/%09}"; }
hm_tsv_unfield() { printf '%s' "${1//%09/$'\t'}"; }
hm_del_user_is_protected() { return 1; }
hm_dbs_for_site() { return 0; }
hm_del_mysql_users_for_db() { return 0; }
hm_del_mysql_user_exclusive() { return 1; }
hm_del_db_owned_by_other() { return 1; }
hm_site_context_push() { :; }
hm_site_context_pop() { :; }
hm_pm2_parse_apps() { return 0; }
hm_pm2_match_site() { return 0; }
hm_del_ols_mentions_domain() { return 1; }
hm_del_cyberpanel_has_domain() { return 1; }
hm_dir_size_bytes() { echo 0; }
hm_is_valid_db_name() { return 0; }
# id/crontab — child shared user istnieje
id() {
  if [[ "${1:-}" == "alpha1" ]] || [[ "${2:-}" == "alpha1" ]]; then
    return 0
  fi
  command id "$@" 2>/dev/null || return 1
}
crontab() {
  if [[ "${1:-}" == "-u" && "${2:-}" == "alpha1" && "${3:-}" == "-l" ]]; then
    echo "0 * * * * /bin/true # master cron"
    return 0
  fi
  return 0
}

# shellcheck disable=SC1091
source commands/delete-site/delete.sh

# --- child: ROOT = docroot, nie cały home; cron pominięty (shared) ---
if hm_site_collect_delete_inventory "child.alpha.test" 0 0 0 0; then
  assert_eq "child-root-is-docroot" "${HM_DEL_ROOT}" "/home/alpha.test/public_html/child.alpha.test"
  assert_eq "child-flag" "${HM_DEL_CHILD_OF_SHARED}" "1"
  assert_eq "child-user-shared" "${HM_DEL_USER_SHARED}" "1"
  assert_eq "child-cron-count-zero" "${HM_DEL_CRON_COUNT}" "0"
  hm_site_build_delete_plan
  has_cron=0
  for k in "${HM_DEL_PLAN_KEYS[@]}"; do
    [[ "${k}" == "cron" ]] && has_cron=1
  done
  assert_eq "child-plan-no-cron" "${has_cron}" "0"
else
  echo "FAIL child-inventory-returned-error"
  fail=1
fi

# --- master: odmowa bo child docroot wewnątrz HOME ---
if hm_site_collect_delete_inventory "alpha.test" 0 0 0 0; then
  echo "FAIL master-should-block-without-force"
  fail=1
else
  echo "OK   master-blocks-nested-children"
fi

# --- master + --force-nested: przechodzi ---
if hm_site_collect_delete_inventory "alpha.test" 0 0 0 1; then
  assert_eq "master-force-root" "${HM_DEL_ROOT}" "/home/alpha.test"
  assert_eq "master-force-flag" "${HM_DEL_FORCE_NESTED}" "1"
else
  echo "FAIL master-force-nested-should-pass"
  fail=1
fi

# --- plan: shared → brak kroku cron nawet gdy COUNT>0 (bezpośrednio) ---
HM_DEL_USER="alpha1"
HM_DEL_USER_SHARED=1
HM_DEL_USER_PROTECTED=0
HM_DEL_CRON_COUNT=3
HM_DEL_KEEP_DB=1
HM_DEL_KEEP_SSL=1
HM_DEL_KEEP_USER=1
HM_DEL_PM2=()
HM_DEL_DBS=()
HM_DEL_DB_USERS=()
HM_DEL_SSL_PATHS=()
HM_DEL_HAS_CP=0
HM_DEL_VHOST_DIR=""
HM_DEL_HAS_OLS_MAP=0
HM_DEL_ROOT="/tmp/x"
HM_DEL_SIZE=1
hm_site_build_delete_plan
has_cron=0
for k in "${HM_DEL_PLAN_KEYS[@]}"; do
  [[ "${k}" == "cron" ]] && has_cron=1
done
assert_eq "plan-shared-skips-cron" "${has_cron}" "0"

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL OK"
exit 0
