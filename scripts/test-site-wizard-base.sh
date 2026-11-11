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
source lib/site/env.sh
# shellcheck disable=SC1091
source lib/site/base.sh
# shellcheck disable=SC1091
source lib/site/db.sh
# shellcheck disable=SC1091
source commands/site-create/wizard-db.sh

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
if hm_site_base_check shop.example.pl shop nologin "" "" >/dev/null 2>&1; then
  bad "collision-user"
else
  ok "collision-user"
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
grep -q "own 2750 app:www-data ${home}/public_html" "${HM_SITE_OWN_LOG}" \
  && grep -q "own 2750 app:www-data ${home}/releases ${home}/shared" "${HM_SITE_OWN_LOG}" \
  && grep -q "own 0700 app:www-data ${home}/tmp" "${HM_SITE_OWN_LOG}" \
  && ok "layout-owner" || { bad "layout-owner"; cat "${HM_SITE_OWN_LOG}" >&2; }
grep -q '^user=app$' "${home}/.config/hmtools/site.env" && grep -q '^runtime=php$' "${home}/.config/hmtools/site.env" \
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

if [[ "${fail}" -eq 0 ]]; then
  echo "ALL PASSED"
else
  echo "FAILED" >&2
  exit 1
fi
