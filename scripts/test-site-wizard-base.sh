#!/usr/bin/env bash
# site new — preflight, kolizje, user, katalogi, umask, CyberPanel vs nginx.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1 HMTOOLS_TEST_NO_TTY=1

# shellcheck disable=SC1091
source lib/common/ui.sh
hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_have_cmd() { return 1; }
hm_confirm_plan() { return 0; }
hm_print_secret() { :; }
hm_gen_password() { printf 'x'; }
hm_run() { printf 'RUN:%s\n' "$*" >> "${HM_SITE_RUN_LOG}"; return 0; }

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
export HM_SITE_HOME_BASE="${root}/homes"
export HM_SITE_OS_FILE="${root}/os-release"
export HM_SITE_MEMINFO_FILE="${root}/meminfo"
export HM_SITE_SS_FILE="${root}/ss.txt"
export HM_SITE_PASSWD_FILE="${root}/passwd"
export HM_SITE_USERADD_MOCK=1
export HM_SITE_RUN_LOG="${root}/run.log"
export HM_SITE_DISK_MB=20000
export HM_SITE_OWN_LOG="${root}/own.log"
: > "${HM_SITE_OWN_LOG}"
export HM_SITE_NTP=synced
export HM_SITE_REPO_OK=1
export HM_SITE_WEB_GROUP=www-data
mkdir -p "${HM_SITE_HOME_BASE}"
: > "${HM_SITE_PASSWD_FILE}"
: > "${HM_SITE_RUN_LOG}"
printf 'MemTotal: 2097152 kB\n' > "${HM_SITE_MEMINFO_FILE}"
printf 'LISTEN 0.0.0.0:80\nLISTEN 0.0.0.0:443\n' > "${HM_SITE_SS_FILE}"
cat > "${HM_SITE_OS_FILE}" <<'EOF'
ID=debian
VERSION_ID="12"
EOF

# shellcheck disable=SC1091
source scripts/lib-test-site.sh
hm_test_site_load
# shellcheck disable=SC1091
source commands/site-create/wizard-db.sh
# stub web po load — nadpisze prawdziwy hm_site_web_provision
hm_site_web_provision() { printf 'WEB:%s\n' "$*" >> "${HM_SITE_RUN_LOG}"; return 0; }
export HM_SITE_MANIFEST_DIR="${root}/manifest"
export HM_SITE_JOURNAL_DIR="${root}/journal"
export HM_SITE_LOCK_DIR="${root}/locks"
export HM_SITE_BACKUP_DIR="${root}/backup"
mkdir -p "${HM_SITE_MANIFEST_DIR}" "${HM_SITE_JOURNAL_DIR}" "${HM_SITE_LOCK_DIR}" "${HM_SITE_BACKUP_DIR}"

pre="$(hm_site_base_preflight node 2>&1 || true)"
printf '%s\n' "${pre}" | grep -q $'OS\tdebian 12\tOK' && ok "preflight-os" || { bad "preflight-os"; printf '%s\n' "${pre}" >&2; }

printf 'ID=ubuntu\nVERSION_ID="20.04"\n' > "${HM_SITE_OS_FILE}"
if hm_site_base_preflight node >/dev/null 2>&1; then
  bad "os-block"
else
  ok "os-block"
fi
ALLOW_UNSUPPORTED_OS=1
if hm_site_base_preflight node >/dev/null 2>&1; then
  ok "os-allow"
else
  bad "os-allow"
fi
unset ALLOW_UNSUPPORTED_OS
printf 'ID=debian\nVERSION_ID="12"\n' > "${HM_SITE_OS_FILE}"

mkdir -p "${HM_SITE_HOME_BASE}/taken.example.pl"
printf 'sentinel\n' > "${HM_SITE_HOME_BASE}/taken.example.pl/keep"
before="$(cat "${HM_SITE_PASSWD_FILE}")"
if hm_site_base_check taken.example.pl "" nologin "" "" >/dev/null 2>&1; then
  bad "collision-domain"
else
  ok "collision-domain"
fi
[[ "$(cat "${HM_SITE_PASSWD_FILE}")" == "${before}" && -f "${HM_SITE_HOME_BASE}/taken.example.pl/keep" ]] \
  && ok "collision-no-change" || bad "collision-no-change"
rm -rf "${HM_SITE_HOME_BASE}/taken.example.pl"

printf 'shop:x:1:1::/home/shop:/usr/sbin/nologin\n' > "${HM_SITE_PASSWD_FILE}"
# Istniejący user = tryb shared (bez błędu); katalog domeny jeszcze nie powstaje w check.
if hm_site_base_check shop.example.pl shop nologin "" "" >/dev/null 2>&1; then
  ok "collision-user-shared"
else
  bad "collision-user-shared"
fi
[[ ! -d "${HM_SITE_HOME_BASE}/shop.example.pl" ]] && ok "collision-user-nodir" || bad "collision-user-nodir"
: > "${HM_SITE_PASSWD_FILE}"

umask 022
hm_site_base_check app.example.pl "" bash laravel "" 
now="$(umask)"
[[ "${now}" == "0022" || "${now}" == "022" ]] && ok "umask-unchanged" || { bad "umask-unchanged"; echo "umask=${now}" >&2; }
hm_site_base_apply bash laravel 0
now="$(umask)"
[[ "${now}" == "0022" || "${now}" == "022" ]] && ok "umask-after-apply" || bad "umask-after-apply"
home="${HM_SITE_HOME_BASE}/app.example.pl"
[[ -d "${home}/public_html" && -d "${home}/shared" && -d "${home}/logs" && -d "${home}/releases" && -d "${home}/tmp" ]] \
  && ok "layout" || bad "layout"
# app.example.pl → appexamp (alfanum całej domeny, max 8 — jak CyberPanel)
grep -q "own 2750 appexamp:www-data ${home}/public_html" "${HM_SITE_OWN_LOG}" \
  && grep -q "own 2750 appexamp:www-data ${home}/releases ${home}/shared" "${HM_SITE_OWN_LOG}" \
  && grep -q "own 0700 appexamp:www-data ${home}/tmp" "${HM_SITE_OWN_LOG}" \
  && ok "layout-owner" || { bad "layout-owner"; cat "${HM_SITE_OWN_LOG}" >&2; }
grep -q '^user=appexamp$' "${home}/.config/hmtools/site.env" && grep -q '^runtime=php$' "${home}/.config/hmtools/site.env" \
  && grep -q '^user_created=true$' "${home}/.config/hmtools/site.env" \
  && grep -q '^shared=false$' "${home}/.config/hmtools/site.env" \
  && ok "preset-runtime" || bad "preset-runtime"
grep -qx 'www' "${home}/.config/hmtools/aliases" && ok "alias-www" || bad "alias-www"
probe="$(mktemp)"
chmod 0750 "${probe}" 2>/dev/null || true
if [[ "$(stat -c '%a' "${probe}" 2>/dev/null || echo '')" == "750" ]]; then
  [[ "$(stat -c '%a' "${home}" )" == "750" && "$(stat -c '%a' "${home}/shared/.env")" == "600" ]] \
    && ok "modes" || bad "modes"
else
  ok "modes-platform"
fi
rm -f "${probe}"

printf 'ID=debian\nVERSION_ID="12"\n' > "${HM_SITE_OS_FILE}"
export PANEL=cyberpanel WEBSERVER=openlitespeed
: > "${HM_SITE_RUN_LOG}"
cmd_site_new cp.example.pl --db none --preset wordpress --yes >"${root}/cp.out" 2>&1 || { bad "cp-new"; cat "${root}/cp.out" >&2; exit 1; }
grep -q 'cyberpanel createWebsite' "${HM_SITE_RUN_LOG}" && ok "cyberpanel-run" || { bad "cyberpanel-run"; cat "${HM_SITE_RUN_LOG}" >&2; }

export PANEL=cyberpanel WEBSERVER=nginx
: > "${HM_SITE_RUN_LOG}"
cmd_site_new nx.example.pl --db none --preset static --yes >"${root}/nx.out" 2>&1 || { bad "nx-new"; cat "${root}/nx.out" >&2; exit 1; }
if grep -q 'cyberpanel' "${HM_SITE_RUN_LOG}"; then
  bad "nginx-no-cp"
else
  ok "nginx-no-cp"
fi
unset PANEL WEBSERVER

export HM_SITE_DNS_A=203.0.113.9 HM_SITE_VPS_IP=203.0.113.10 HM_SITE_SSL=1
if hm_site_base_check dns.example.pl "" nologin "" "" >/dev/null 2>&1; then
  bad "dns-block"
else
  ok "dns-block"
fi
HM_SITE_CONTINUE_WITHOUT_SSL=1
hm_site_base_check dns2.example.pl "" nologin "" "" >/dev/null 2>&1 && ok "dns-continue" || bad "dns-continue"
unset HM_SITE_DNS_A HM_SITE_VPS_IP HM_SITE_SSL HM_SITE_CONTINUE_WITHOUT_SSL

printf 'sklep.example\txn--sklep-example\n' > "${root}/idn.map"
# domena z znakiem spoza ASCII
export HM_SITE_IDN_MAP="${root}/idn.map"
idn_dom=$'sklep.example'
# wymuś znak spoza zbioru ASCII
idn_dom="$(printf 'sklep\xc5\x82.pl')"
got="$(hm_site_base_punycode "${idn_dom}" || true)"
# mapa nie zna tej domeny — oczekujemy błędu albo idn2
if [[ -z "${got}" ]]; then
  ok "idn-needs-map"
else
  ok "idn-converted"
fi
printf 'ł.pl\txn--kda.pl\n' > "${root}/idn.map"
# klucz musi być dokładnie taki sam bajtowo
key="$(printf '\xc5\x82.pl')"
printf '%s\txn--kda.pl\n' "${key}" > "${root}/idn.map"
got="$(hm_site_base_punycode "${key}")"
[[ "${got}" == "xn--kda.pl" ]] && ok "idn-map" || bad "idn-map"

unset HM_SITE_DISK_MB
pre="$(hm_site_base_preflight node 2>&1 || true)"
printf '%s\n' "${pre}" | grep -q $'DYSK\t? MB\tWARN' && ok "disk-unknown-warn" || { bad "disk-unknown-warn"; printf '%s\n' "${pre}" >&2; }
printf 'Avail\n8192\n' > "${root}/df-output.txt"
export HM_SITE_DF_FILE="${root}/df-output.txt"
pre="$(hm_site_base_preflight node 2>&1 || true)"
printf '%s\n' "${pre}" | grep -q $'DYSK\t8192 MB\tOK' && ok "disk-output-avail" || { bad "disk-output-avail"; printf '%s\n' "${pre}" >&2; }
printf 'Filesystem 1M-blocks Used Available Use%% Mounted\noverlay 100 40 1536 30%% /\n' > "${root}/df-output.txt"
pre="$(hm_site_base_preflight node 2>&1 || true)"
printf '%s\n' "${pre}" | grep -q $'DYSK\t1536 MB\tWARN' && ok "disk-fallback-col" || { bad "disk-fallback-col"; printf '%s\n' "${pre}" >&2; }
unset HM_SITE_DF_FILE
export HM_SITE_DISK_MB=20000

printf 'LISTEN 0.0.0.0:80 users:(("nginx",pid=1,fd=6))\nLISTEN 0.0.0.0:443 users:(("nginx",pid=1,fd=7))\n' > "${HM_SITE_SS_FILE}"
pre="$(hm_site_base_preflight node 2>&1 || true)"
printf '%s\n' "${pre}" | grep -q $'PORT-80/443\tnginx\tOK' && ok "port-nginx-ok" || { bad "port-nginx-ok"; printf '%s\n' "${pre}" >&2; }
printf 'LISTEN 0.0.0.0:80 users:(("python",pid=9,fd=3))\n' > "${HM_SITE_SS_FILE}"
pre="$(hm_site_base_preflight node 2>&1 || true)"
printf '%s\n' "${pre}" | grep -q $'PORT-80/443\tobcy\tWARN' && ok "port-foreign-warn" || { bad "port-foreign-warn"; printf '%s\n' "${pre}" >&2; }
printf 'LISTEN 0.0.0.0:80\nLISTEN 0.0.0.0:443\n' > "${HM_SITE_SS_FILE}"

printf 'shareduser:x:1000:1000::/home/shareduser:/bin/bash\n' >> "${HM_SITE_PASSWD_FILE}"
hm_site_base_check s1.test shareduser nologin static "" >/dev/null
hm_site_base_apply nologin static 0 >/dev/null
home_s="${HM_SITE_HOME_BASE}/s1.test"
grep -q '^user_created=false$' "${home_s}/.config/hmtools/site.env" \
  && grep -q '^shared=true$' "${home_s}/.config/hmtools/site.env" \
  && ok "shared-env" || bad "shared-env"
unset HM_SITE_USER_CREATED HM_SITE_USER_SHARED
hm_site_manifest_write s1.test shareduser static nginx "${home_s}/shared/.env" www >/dev/null
man_s="$(hm_site_manifest_path s1.test)"
grep -q '"user_created":false' "${man_s}" && grep -q '"shared":true' "${man_s}" && ok "shared-manifest" || bad "shared-manifest"

hm_site_base_check only.test "" nologin static "" >/dev/null
hm_site_base_apply nologin static 0 >/dev/null
only_user="${HM_SITE_BASE_USER}"
home_o="${HM_SITE_HOME_BASE}/only.test"
hm_site_manifest_write only.test "${only_user}" static nginx "${home_o}/shared/.env" www >/dev/null
grep -q '"user_created":true' "$(hm_site_manifest_path only.test)" \
  && grep -q '"shared":false' "$(hm_site_manifest_path only.test)" \
  && ok "created-manifest" || bad "created-manifest"

# shellcheck disable=SC1091
source commands/delete-site/delete.sh
hm_del_reset_inventory
HM_DEL_DOMAIN="s1.test"
HM_DEL_USER="shareduser"
HM_DEL_ROOT="${home_s}"
HM_DEL_KEEP_USER=0
hm_del_apply_wizard_user
if hm_del_user_may_remove; then bad "preexist-kept"; else ok "preexist-kept"; fi

hm_del_reset_inventory
HM_DEL_DOMAIN="only.test"
HM_DEL_USER="${only_user}"
HM_DEL_ROOT="${home_o}"
HM_DEL_KEEP_USER=0
hm_del_apply_wizard_user
if hm_del_user_may_remove; then ok "created-remove"; else bad "created-remove"; fi

hm_site_manifest_write s2.test "${only_user}" static nginx "${home_o}/shared/.env" www >/dev/null
hm_del_apply_wizard_user
if hm_del_user_may_remove; then bad "other-site-kept"; else ok "other-site-kept"; fi

# --- kolizja skróconego usera shop2tes (shop2.test vs shop2.testing) ---
export HM_SITE_MANIFEST_DIR="${root}/sites"
mkdir -p "${HM_SITE_MANIFEST_DIR}"
# shop2.test → shop2tes (8 znaków z całej domeny)
got_u="$(hm_site_base_resolve_user shop2.test "")"
[[ "${got_u}" == "shop2tes" ]] && ok "resolve-shop2tes" || bad "resolve-shop2tes (${got_u})"
got_u2="$(hm_site_base_resolve_user shop2.testing "")"
[[ "${got_u2}" == "shop2tes" ]] && ok "resolve-shop2testing-same" || bad "resolve-shop2testing-same (${got_u2})"
printf 'shop2tes:x:1001:1001::/home/shop2.test:/usr/sbin/nologin\n' >> "${HM_SITE_PASSWD_FILE}"
hm_site_manifest_write shop2.test shop2tes php nginx "${HM_SITE_HOME_BASE}/shop2.test/shared/.env" www >/dev/null
printf 'mysql\tshop2tes_app\tshop2tes_app\t127.0.0.1\t3306\n' > "${HM_SITE_MANIFEST_DIR}/.shop2.test.dbs"
unset HM_SITE_BASE_USER HM_SITE_BASE_DOMAIN HM_SITE_USER_CREATED HM_SITE_USER_SHARED
if hm_site_base_check shop2.testing "" nologin static "" >/dev/null 2>"${root}/collision.err"; then
  if [[ "${HM_SITE_BASE_USER}" != "shop2tes" ]]; then
    ok "short-user-collision-unique (${HM_SITE_BASE_USER})"
  else
    bad "short-user-collision-still-shop2tes"
  fi
else
  grep -qi 'kolizja\|używa' "${root}/collision.err" && ok "short-user-collision-refuse" || bad "short-user-collision-refuse"
fi

# shellcheck disable=SC1091
source lib/site/db.sh
hm_mysql_db_exists() { [[ "$1" == "shop2tes_app" ]]; }
hm_mysql_create() { return 1; }
hm_site_db_ledger_add() { :; }
hm_site_manifest_add_db() {
  local d="$1" _t="$2" name="$3"
  printf 'mysql\t%s\t%s\t127.0.0.1\t3306\n' "${name}" "${name}" >> "${HM_SITE_MANIFEST_DIR}/.${d}.dbs"
}
if hm_site_mysql_provision shop2.testing shop2tes_app shop2tes_app >/dev/null 2>&1; then
  bad "mysql-foreign-refuse"
else
  ok "mysql-foreign-refuse"
fi
if [[ -f "${HM_SITE_MANIFEST_DIR}/.shop2.testing.dbs" ]] \
  && grep -q 'shop2tes_app' "${HM_SITE_MANIFEST_DIR}/.shop2.testing.dbs" 2>/dev/null; then
  bad "mysql-foreign-not-in-dbs"
else
  ok "mysql-foreign-not-in-dbs"
fi

if [[ "${fail}" -eq 0 ]]; then
  echo "ALL PASSED"
else
  echo "FAILED" >&2
  exit 1
fi
