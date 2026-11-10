#!/usr/bin/env bash
# Szablony vhost, rejestr portów, cofnięcie przy błędzie walidacji.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1 HMTOOLS_TEST_NO_TTY=1
export HM_SITE_WEB_VALIDATE=ok

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_have_cmd() {
  case "$1" in
    nginx|apache2|apachectl) return 0 ;;
    *) command -v "$1" >/dev/null 2>&1 ;;
  esac
}
hm_is_valid_domain() { [[ "$1" == *.* ]]; }
hm_confirm_plan() { return 0; }
hm_print_secret() { :; }
hm_gen_password() { printf 'x'; }
hm_pkg_install() { echo "PKG:$*" >> "${HM_SITE_WEB_LOG}"; }

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
export HM_SITE_HOME_BASE="${root}/homes"
export HM_SITE_PORT_FILE="${root}/ports.json"
export HM_SITE_SS_FILE="${root}/ss.txt"
export HM_SITE_WEB_LOG="${root}/web.log"
export HM_SITE_WEB_JOURNAL="${root}/journal.txt"
export HM_SITE_WEB_CONF_DIR="${root}/conf"
export HM_APP_PORT_RANGE=3001-3005
export HM_SITE_USER=app
mkdir -p "${HM_SITE_HOME_BASE}" "${HM_SITE_WEB_CONF_DIR}"
: > "${HM_SITE_WEB_LOG}"
printf 'LISTEN 0.0.0.0:3001\n' > "${HM_SITE_SS_FILE}"

# shellcheck disable=SC1091
source lib/site/env.sh
# shellcheck disable=SC1091
source lib/site/web.sh
# shellcheck disable=SC1091
source lib/site/db.sh
# shellcheck disable=SC1091
source commands/site-create/wizard-db.sh

export HM_SITE_WEB_DOMAIN=app.example.pl
export HM_SITE_WEB_ROOT=/home/app.example.pl/public_html
export HM_SITE_WEB_UPSTREAM=127.0.0.1:3007
export HM_SITE_WEB_SOCK=/run/php/app.example.pl.sock
export HM_SITE_WEB_LOGDIR=/home/app.example.pl/logs
export HM_SITE_WEB_USER=app
for s in nginx apache ols; do
  for t in php-fpm proxy static spa; do
    got="${root}/${s}-${t}.conf"
    hm_site_web_render "${s}" "${t}" > "${got}"
    if diff -u "scripts/fixtures/vhost/${s}-${t}.conf" "${got}" >/dev/null; then
      ok "snap-${s}-${t}"
    else
      bad "snap-${s}-${t}"
      diff -u "scripts/fixtures/vhost/${s}-${t}.conf" "${got}" >&2 || true
    fi
  done
done
if grep -q '0.0.0.0' "${root}/nginx-proxy.conf" || ! grep -q '127.0.0.1:3007' "${root}/nginx-proxy.conf"; then
  bad "upstream-loopback"
else
  ok "upstream-loopback"
fi

p1="$(hm_site_web_reserve_port a.example.pl auto)"
p2="$(hm_site_web_reserve_port b.example.pl auto)"
p1b="$(hm_site_web_reserve_port a.example.pl auto)"
[[ "${p1}" == "3002" && "${p2}" == "3003" && "${p1b}" == "3002" ]] && ok "ports-unique" || { bad "ports-unique"; echo "p1=${p1} p2=${p2} p1b=${p1b}" >&2; }
if hm_site_web_reserve_port c.example.pl 3001 >/dev/null 2>&1; then
  bad "port-ss-busy"
else
  ok "port-ss-busy"
fi
if hm_site_web_reserve_port c.example.pl 3002 >/dev/null 2>&1; then
  bad "port-dup"
else
  ok "port-dup"
fi

dest="${HM_SITE_WEB_CONF_DIR}/old.example.pl.conf"
printf 'OLD\n' > "${dest}"
export HM_SITE_WEB_VALIDATE=fail
export HM_SITE_WEB_DOMAIN=old.example.pl
export HM_SITE_WEB_UPSTREAM=127.0.0.1:3010
body="$(hm_site_web_render nginx proxy)"
if hm_site_web_apply_file nginx proxy "${dest}" "${body}" >/dev/null 2>&1; then
  bad "validate-fail"
else
  ok "validate-fail"
fi
if [[ "$(cat "${dest}")" == "OLD" ]] && grep -q "undo ${dest}" "${HM_SITE_WEB_JOURNAL}" \
  && ! grep -q 'reload nginx' "${HM_SITE_WEB_LOG}"; then
  ok "validate-restore"
else
  bad "validate-restore"
  echo "dest=$(cat "${dest}")" >&2
fi
export HM_SITE_WEB_VALIDATE=ok

export OLS_VHOSTS="${root}/vhosts"
ols_called=0
hm_sc_write_vhconf() { ols_called=1; mkdir -p "${OLS_VHOSTS}/$1"; printf 'vh %s\n' "$*" > "${OLS_VHOSTS}/$1/vhconf.conf"; }
hm_sc_ols_append_vhost_block() { printf 'map %s\n' "$1" >> "${OLS_VHOSTS}/$1/vhconf.conf"; }
if hm_site_web_provision olsphp.example.pl ols php-fpm auto 0 1 8.4 >/dev/null 2>&1 \
  && [[ "${ols_called}" -eq 1 ]] \
  && grep -q 'vh olsphp.example.pl 8.4' "${OLS_VHOSTS}/olsphp.example.pl/vhconf.conf"; then
  ok "ols-php-same-writer"
else
  bad "ols-php-same-writer"
fi

out="${root}/new.out"
cmd_site_new app.example.pl --db none --webserver nginx --vhost-type proxy --proxy-port auto --ssl --yes >"${out}" 2>&1 || {
  bad "site-new-web"
  cat "${out}" >&2
  exit 1
}
conf="${HM_SITE_WEB_CONF_DIR}/app.example.pl.conf"
if [[ -f "${conf}" ]] && grep -q '127.0.0.1:' "${conf}" && ! grep -q '0.0.0.0' "${conf}" \
  && grep -q 'reload nginx' "${HM_SITE_WEB_LOG}" \
  && grep -q 'certbot certonly --webroot' "${HM_SITE_WEB_LOG}"; then
  ok "site-new-web"
else
  bad "site-new-web"
  cat "${out}" >&2 || true
fi

if [[ "${fail}" -eq 0 ]]; then
  echo "ALL PASSED"
else
  echo "FAILED" >&2
  exit 1
fi
