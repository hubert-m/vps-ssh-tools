#!/usr/bin/env bash
# site show / runtime / doctor oraz webs delete wg manifestu.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1
export HMTOOLS_TEST_NO_TTY=1

# shellcheck disable=SC1091
source lib/common/ui.sh
hm_file_log_ui() { :; }
# shellcheck disable=SC1091
source lib/site/env.sh
# shellcheck disable=SC1091
source lib/site/tx.sh
# shellcheck disable=SC1091
source lib/site/db.sh
# shellcheck disable=SC1091
source lib/site/lifecycle.sh

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
export HM_SITE_HOME_BASE="${root}/homes"
export HM_SITE_MANIFEST_DIR="${root}/manifests"
export HM_SITE_STATE_DIR="${root}/state"
export HM_SITE_SYSTEMD_DIR="${root}/systemd"
export HM_SITE_LOGROTATE_DIR="${root}/logrotate.d"
export HM_SITE_FW_DIR="${root}/fw"
export HM_SITE_VHOST_DIR="${root}/vhosts"
home="${HM_SITE_HOME_BASE}/app.example"
state="$(hm_site_state_dir app.example)"
mkdir -p "${home}" "${state}" "${root}/ext" "${root}/pkgs/php8.3" "${root}/pkgs/php8.4" \
  "${HM_SITE_SYSTEMD_DIR}" "${HM_SITE_LOGROTATE_DIR}" "${HM_SITE_FW_DIR}" "${HM_SITE_VHOST_DIR}"
printf 'pkg\n' > "${root}/pkgs/php8.3/keep"
printf 'pkg\n' > "${root}/pkgs/php8.4/keep"
printf 'shared-runtime\n' > "${root}/ext/shared-php"

man="$(hm_site_manifest_path app.example)"
mkdir -p "$(dirname "${man}")"
cat > "${man}" <<'EOF'
{"schema":1,"domain":"app.example","webserver":"nginx","runtime":{"type":"php","version":"8.3","manager":"fpm"},"env_file":"/tmp/none","databases":[]}
EOF
printf 'php=8.3\n' > "${state}/fpm.conf"
printf '22\n' > "${home}/.nvmrc"
mkdir -p "${home}/.nvm/versions/node/v22" "${state}/venv-3.11"
ln -sfn "venv-3.11" "${state}/venv" 2>/dev/null || true
if ! ls -ld "${state}/venv" | grep -F -q -- '->'; then
  rm -rf "${state}/venv"
  printf 'venv-3.11\n' > "${state}/venv"
fi

unit="${HM_SITE_SYSTEMD_DIR}/hm-app.example.service"
printf 'ExecStart=/node/v22/bin/node\n' > "${unit}"
vh="${HM_SITE_VHOST_DIR}/app.example.conf"
printf 'server_name app.example;\n' > "${vh}"
fpm="${state}/pool.conf"
printf 'php=8.3\n' > "${fpm}"
dbf="${state}/db.sql"
printf 'CREATE DATABASE app;\n' > "${dbf}"
fw="${HM_SITE_FW_DIR}/hm-app.example.rules"
printf 'allow 80\n' > "${fw}"
portf="${state}/port"
printf '3001\n' > "${portf}"
lr="${HM_SITE_LOGROTATE_DIR}/hm-app.example"
printf 'daily\n' > "${lr}"
cronf="${HM_SITE_SYSTEMD_DIR}/hm-app.example-cron"
printf '0 * * * * true\n' > "${cronf}"
worker="${HM_SITE_SYSTEMD_DIR}/hm-app.example-worker"
timer="${HM_SITE_SYSTEMD_DIR}/hm-app.example.timer"
printf 'w\n' > "${worker}"
printf 't\n' > "${timer}"

hm_site_resource_add app.example cron "${cronf}" 0
hm_site_resource_add app.example worker "${worker}" 0
hm_site_resource_add app.example fpm "${fpm}" 0
hm_site_resource_add app.example port "${portf}" 0
hm_site_resource_add app.example db "${dbf}" 0
hm_site_resource_add app.example unit "${unit}" 0
hm_site_resource_add app.example vhost "${vh}" 0
hm_site_resource_add app.example firewall "${fw}" 0
hm_site_resource_add app.example logrotate "${lr}" 0
hm_site_resource_add app.example timer "${timer}" 0
hm_site_resource_add app.example fpm "${root}/ext/shared-php" 1

show="$(cmd_site_show app.example)"
printf '%s\n' "${show}" | grep -q 'app.example' && ok "show-domain" || bad "show-domain"
printf '%s\n' "${show}" | grep -q 'php' && ok "show-runtime" || bad "show-runtime"
printf '%s\n' "${show}" | grep -q 'współdzielone' && ok "show-shared" || bad "show-shared"

export HM_SITE_DOCTOR_LISTEN=3002
doc="$(cmd_site_doctor app.example || true)"
printf '%s\n' "${doc}" | grep -q 'DRYF' && ok "doctor-drift" || bad "doctor-drift"
export HM_SITE_DOCTOR_LISTEN=3001
if cmd_site_doctor app.example >/dev/null; then
  ok "doctor-ok"
else
  bad "doctor-ok"
fi

export HM_SITE_RUNTIME_FAIL=1
if cmd_site_runtime php 8.4 app.example --yes; then
  bad "php-fail-rc"
else
  ok "php-fail-rc"
fi
grep -q '"version":"8.3"' "${man}" && ok "php-fail-keeps" || bad "php-fail-keeps"
unset HM_SITE_RUNTIME_FAIL

hm_php_set_site() { return 1; }
export WEBSERVER=ols
if cmd_site_runtime php 8.4 app.example --yes; then
  bad "php-ols-rollback-rc"
else
  ok "php-ols-rollback-rc"
fi
grep -q '"version":"8.3"' "${man}" && ok "php-ols-keeps" || bad "php-ols-keeps"
unset WEBSERVER
hm_php_set_site() { return 0; }

cmd_site_runtime php 8.4 app.example --yes
grep -q '"version":"8.4"' "${man}" && ok "php-switch" || bad "php-switch"
[[ -f "${root}/pkgs/php8.3/keep" && -f "${root}/pkgs/php8.4/keep" ]] && ok "php-shared-pkgs" || bad "php-shared-pkgs"

cat > "${man}" <<'EOF'
{"schema":1,"domain":"app.example","webserver":"nginx","runtime":{"type":"node","version":"22","manager":"systemd"},"env_file":"/tmp/none","databases":[]}
EOF
export HM_SITE_RUNTIME_FAIL=1
if cmd_site_runtime node 24 app.example --yes; then
  bad "node-fail-rc"
else
  ok "node-fail-rc"
fi
grep -q 'v22' "${unit}" && ok "node-fail-unit" || bad "node-fail-unit"
unset HM_SITE_RUNTIME_FAIL
cmd_site_runtime node 24 app.example --yes
grep -q '"version":"24"' "${man}" && ok "node-switch" || bad "node-switch"
grep -q 'v24' "${unit}" && ok "node-unit" || bad "node-unit"
[[ -d "${home}/.nvm/versions/node/v22" ]] && ok "node-old-remains" || bad "node-old-remains"

cat > "${man}" <<'EOF'
{"schema":1,"domain":"app.example","webserver":"nginx","runtime":{"type":"python","version":"3.11","manager":""},"env_file":"/tmp/none","databases":[]}
EOF
export HM_SITE_RUNTIME_FAIL=1
if cmd_site_runtime python 3.12 app.example --yes; then
  bad "py-fail-rc"
else
  ok "py-fail-rc"
fi
pycur="$(ls -ld "${state}/venv")"
if [[ "${pycur}" == *"->"* ]]; then
  pycur="${pycur##*-> }"
else
  pycur="$(tr -d '[:space:]' < "${state}/venv")"
fi
pycur="${pycur//[[:space:]]/}"
[[ "${pycur}" == "venv-3.11" ]] && ok "py-fail-link" || bad "py-fail-link=${pycur}"
unset HM_SITE_RUNTIME_FAIL
cmd_site_runtime python 3.12 app.example --yes
pycur="$(ls -ld "${state}/venv")"
if [[ "${pycur}" == *"->"* ]]; then
  pycur="${pycur##*-> }"
else
  pycur="$(tr -d '[:space:]' < "${state}/venv")"
fi
pycur="${pycur//[[:space:]]/}"
[[ "${pycur}" == "venv-3.12" ]] && ok "py-switch" || bad "py-switch=${pycur}"
[[ -d "${state}/venv-3.11" ]] && ok "py-old-remains" || bad "py-old-remains"

# --- webs delete ---
# shellcheck disable=SC1091
source commands/delete-site/delete.sh

hm_detect_all() { :; }
hm_discover_sites() { HM_SITES_LIST=("app.example"); }
hm_resolve_site_paths() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "app.example" "${home}" "${home}/public_html" "${home}/logs" "-" "8.4" "app|active"
}
hm_tsv_unfield() { printf '%s' "$1"; }
hm_find_site_by_arg() { printf '%s\n' "$1"; }
hm_is_safe_site_root_to_delete() { return 0; }
hm_del_user_is_protected() { return 1; }
hm_dbs_for_site() { return 0; }
hm_del_mysql_users_for_db() { return 0; }
hm_del_db_owned_by_other() { return 1; }
hm_site_context_push() { :; }
hm_site_context_pop() { :; }
hm_pm2_parse_apps() { return 0; }
hm_pm2_match_site() { return 0; }
hm_del_ols_mentions_domain() { return 1; }
hm_del_cyberpanel_has_domain() { return 1; }
hm_dir_size_bytes() { echo 0; }
hm_ols_reload_soft() { return 0; }
hm_clear_site_context() { :; }
hm_confirm_plan() { return 0; }
hm_confirm_plan_critical() { return 0; }
userdel() { return 0; }
pkill() { return 0; }

export HM_SITE_LIFECYCLE_LOG="${root}/order.log"
: > "${HM_SITE_LIFECYCLE_LOG}"
hm_site_delete app.example >/dev/null
for f in "${worker}" "${timer}" "${unit}" "${vh}" "${fpm}" "${dbf}" "${fw}" "${portf}" "${lr}" "${cronf}"; do
  if [[ -e "${f}" ]]; then
    bad "gone ${f}"
  fi
done
[[ -e "${worker}" ]] || ok "deleted-resources"
[[ -f "${root}/ext/shared-php" ]] && ok "shared-kept" || bad "shared-kept"
[[ -f "${root}/pkgs/php8.3/keep" ]] && ok "unlisted-pkg-kept" || bad "unlisted-pkg-kept"
[[ -d "${home}" ]] && bad "home-removed" || ok "home-removed"
order="$(cut -f1 "${HM_SITE_LIFECYCLE_LOG}" | tr '\n' ' ')"
[[ "${order}" == "worker timer unit vhost fpm db firewall port logrotate cron " ]] && ok "delete-order" || { bad "delete-order ${order}"; }

# keep-db / keep-files
home2="${HM_SITE_HOME_BASE}/keep.example"
state2="$(hm_site_state_dir keep.example)"
mkdir -p "${home2}" "${state2}" "${HM_SITE_SYSTEMD_DIR}"
export HM_SITE_DOMAIN=""
man2="$(hm_site_manifest_path keep.example)"
mkdir -p "$(dirname "${man2}")"
printf '%s\n' '{"schema":1,"domain":"keep.example","runtime":{"type":"php","version":"8.3","manager":""}}' > "${man2}"
db2="${state2}/db.sql"
unit2="${HM_SITE_SYSTEMD_DIR}/hm-keep.example.service"
inside="${home2}/local.unit"
printf 'db\n' > "${db2}"
printf 'u\n' > "${unit2}"
printf 'in\n' > "${inside}"
hm_site_resource_add keep.example db "${db2}" 0
hm_site_resource_add keep.example unit "${unit2}" 0
hm_site_resource_add keep.example unit "${inside}" 0
hm_resolve_site_paths() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "keep.example" "${home2}" "${home2}/public_html" "${home2}/logs" "-" "8.3" "keep|active"
}
hm_discover_sites() { HM_SITES_LIST=("keep.example"); }
hm_site_delete keep.example --keep-db --keep-files >/dev/null
[[ -f "${db2}" ]] && ok "keep-db" || bad "keep-db"
[[ -d "${home2}" && -f "${inside}" ]] && ok "keep-files" || bad "keep-files"
[[ -e "${unit2}" ]] && bad "keep-external" || ok "keep-external"

# archive reuse
archived=0
hm_backup_archive_site() { archived=1; printf '%s\n' "$1" > "${root}/archived"; }
hm_site_delete keep.example --archive >/dev/null
[[ "${archived}" -eq 1 ]] && grep -q 'keep.example' "${root}/archived" && ok "archive-reuse" || bad "archive-reuse"
[[ -d "${home2}" ]] && ok "archive-no-direct-delete" || bad "archive-no-direct-delete"

if [[ "${fail}" -ne 0 ]]; then
  echo FAILED
  exit 1
fi
echo "ALL OK"
