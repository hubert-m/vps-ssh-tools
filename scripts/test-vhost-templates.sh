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
unset HM_SITE_WEB_PROXY_NAME HM_SITE_WEB_ALIASES_LINE HM_SITE_WEB_SERVER_NAMES HM_SITE_WEB_FORWARDED_PROTO HM_SITE_SSL HM_SITE_WEB_SSL
export HM_SITE_ALIASES=www
for s in nginx apache ols; do
  for t in php-fpm proxy static spa; do
    got="${root}/${s}-${t}.conf"
    unset HM_SITE_WEB_PROXY_NAME HM_SITE_WEB_ALIASES_LINE HM_SITE_WEB_SERVER_NAMES HM_SITE_WEB_FORWARDED_PROTO
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
export HM_SITE_PORT_ANSWER=3004
asked="$(hm_site_web_reserve_port d.example.pl 3002)"
[[ "${asked}" == "3004" ]] && ok "port-ask" || { bad "port-ask"; echo "asked=${asked}" >&2; }
unset HM_SITE_PORT_ANSWER
grep -q 'X-Real-IP' "${root}/ols-proxy.conf" && grep -q '127.0.0.1:3007' "${root}/ols-proxy.conf" && ok "ols-node-headers" || bad "ols-node-headers"
grep -q 'extprocessor node_app_example_pl' "${root}/ols-proxy.conf" && ok "ols-proxy-unique" || bad "ols-proxy-unique"
# Jeden backslash przed kropką (nie \\.) — inaczej OLS nie blokuje /.env
if awk '/context exp:/{ print; exit }' "${root}/ols-proxy.conf" | grep -F 'exp:^/\.(env|git)' >/dev/null \
  && ! awk '/context exp:/{ print; exit }' "${root}/ols-proxy.conf" | grep -F 'exp:^/\\.(env|git)' >/dev/null; then
  ok "ols-dotfile-re"
else
  bad "ols-dotfile-re"
fi
grep -q 'module cache' "${root}/ols-proxy.conf" && grep -q 'maxReqBodySize' "${root}/ols-proxy.conf" && ok "ols-proxy-tuning" || bad "ols-proxy-tuning"
# nginx proxy: www w server_name (spójnie z OLS vhAliases)
unset HM_SITE_WEB_PROXY_NAME HM_SITE_WEB_ALIASES_LINE HM_SITE_WEB_SERVER_NAMES HM_SITE_WEB_FORWARDED_PROTO
export HM_SITE_ALIASES=www
hm_site_web_render nginx proxy > "${root}/ngx-proxy-www.conf"
grep -q 'server_name app.example.pl www.app.example.pl;' "${root}/ngx-proxy-www.conf" && ok "nginx-www" || bad "nginx-www"

# --no-www: brak vhAliases / bez www w nginx; SSL → https w X-Forwarded-Proto
unset HM_SITE_WEB_PROXY_NAME HM_SITE_WEB_ALIASES_LINE HM_SITE_WEB_SERVER_NAMES HM_SITE_WEB_FORWARDED_PROTO
export HM_SITE_ALIASES=none HM_SITE_SSL=1
hm_site_web_render ols proxy > "${root}/ols-proxy-nowww.conf"
grep -q 'vhAliases' "${root}/ols-proxy-nowww.conf" && bad "ols-no-www" || ok "ols-no-www"
grep -q 'X-Forwarded-Proto "https"' "${root}/ols-proxy-nowww.conf" && ok "ols-proto-ssl" || bad "ols-proto-ssl"
hm_site_web_render nginx proxy > "${root}/ngx-proxy-nowww.conf"
grep -q 'server_name app.example.pl;' "${root}/ngx-proxy-nowww.conf" \
  && ! grep -q 'www.app.example.pl' "${root}/ngx-proxy-nowww.conf" && ok "nginx-no-www" || bad "nginx-no-www"
unset HM_SITE_ALIASES HM_SITE_SSL
export HM_SITE_ALIASES=www

dest="${HM_SITE_WEB_CONF_DIR}/old.example.pl.conf"
printf 'OLD\n' > "${dest}"
export HM_SITE_WEB_VALIDATE=fail
export HM_SITE_WEB_DOMAIN=old.example.pl
export HM_SITE_WEB_UPSTREAM=127.0.0.1:3010
export HM_SITE_WEB_ADOPT=1
body="$(hm_site_web_render nginx proxy)"
if hm_site_web_apply_file nginx proxy "${dest}" "${body}" >/dev/null 2>&1; then
  bad "validate-fail"
else
  ok "validate-fail"
fi
unset HM_SITE_WEB_ADOPT
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
export HM_SITE_SSL_LIVE="${root}/le/live"
# runtime domyślnie node — potrzebny mock (W06: provision także bez --node)
export HM_SITE_NODE_MOCK=1 HM_NODE_FETCH_MOCK=1
export HM_NODE_INDEX_FILE="${root}/node-index.json"
export HM_NODE_FETCH_BODY="${root}/nvm-install.sh"
export HM_NODE_FETCH_LOG="${root}/node-fetch.log"
export HM_SITE_NODE_LOG="${root}/node.log"
printf '%s\n' '[{"version":"v24.11.1","lts":"Krypton","security":false}]' > "${HM_NODE_INDEX_FILE}"
printf '%s\n' '#!/bin/bash' 'mkdir -p "$NVM_DIR"' 'echo ok > "$NVM_DIR/nvm.sh"' > "${HM_NODE_FETCH_BODY}"
export HM_NODE_NVM_PIN_SHA256="$(sha256sum "${HM_NODE_FETCH_BODY}" | awk '{print $1}')"
: > "${HM_NODE_FETCH_LOG}"
: > "${HM_SITE_NODE_LOG}"
# shellcheck disable=SC1091
source lib/site/node.sh
cmd_site_new app.example.pl --db none --webserver nginx --vhost-type proxy --proxy-port auto --ssl --yes >"${out}" 2>&1 || {
  bad "site-new-web"
  cat "${out}" >&2
  exit 1
}
conf="${HM_SITE_WEB_CONF_DIR}/app.example.pl.conf"
if [[ -f "${conf}" ]] && grep -q '127.0.0.1:' "${conf}" && ! grep -q '0.0.0.0' "${conf}" \
  && grep -q 'reload nginx' "${HM_SITE_WEB_LOG}" \
  && grep -q 'certbot certonly --webroot' "${HM_SITE_WEB_LOG}" \
  && grep -q 'listen 443 ssl' "${conf}" \
  && grep -q 'ssl_certificate ' "${conf}" \
  && grep -q 'return 301 https' "${conf}"; then
  ok "site-new-web"
  ok "ssl-https-block"
else
  bad "site-new-web"
  cat "${out}" >&2 || true
  cat "${conf}" >&2 || true
fi

export HM_SITE_WEB_CONF_DIR="${root}/nginx/sites-available"
export HM_TX_JOURNAL="${root}/tx.journal"
: > "${HM_TX_JOURNAL}"
: > "${HM_SITE_WEB_LOG}"
reslog="${root}/resources.txt"
: > "${reslog}"
hm_site_resource_add() { printf '%s %s\n' "$2" "$3" >> "${reslog}"; }
mkdir -p "${HM_SITE_WEB_CONF_DIR}"
out="${root}/static.out"
cmd_site_new static.example.pl --runtime static --db none --webserver nginx --yes >"${out}" 2>&1 || {
  bad "site-new-static"
  cat "${out}" >&2
  exit 1
}
sconf="${HM_SITE_WEB_CONF_DIR}/static.example.pl.conf"
slink="${root}/nginx/sites-enabled/static.example.pl.conf"
if [[ -f "${sconf}" ]] && grep -q 'try_files' "${sconf}" && grep -q 'public_html' "${sconf}" \
  && ! grep -q 'proxy_pass' "${sconf}" && grep -q 'Vhost nginx/static' "${out}" \
  && ! grep -q 'nginx/proxy' "${out}"; then
  ok "static-template"
else
  bad "static-template"
  cat "${out}" >&2 || true
fi
if grep -F -q "$(printf 'undo=nginx-vhost\t%s' "${slink}")" "${HM_TX_JOURNAL}" \
  && grep -F -q "vhost ${slink}" "${reslog}" \
  && [[ -e "${slink}" ]]; then
  probe_a="${root}/probe-target"
  probe_b="${root}/probe-link"
  printf 'x\n' > "${probe_a}"
  ln -sfn "${probe_a}" "${probe_b}" || true
  if ls -ld -- "${probe_b}" 2>/dev/null | grep -F -q -- '->'; then
    if ls -ld -- "${slink}" 2>/dev/null | grep -F -q -- '->'; then
      ok "nginx-enabled"
    else
      bad "nginx-enabled"
      ls -ld -- "${slink}" >&2 || true
    fi
  else
    ok "nginx-enabled-platform"
  fi
else
  bad "nginx-enabled"
  ls -ld -- "${slink}" >&2 || true
  cat "${HM_TX_JOURNAL}" >&2 || true
  cat "${reslog}" >&2 || true
fi
hm_os_nginx_sites_enabled() { return 1; }
rlink="$(hm_site_web_nginx_enable rhel.example.pl "${root}/nginx/sites-available/rhel.example.pl.conf" || true)"
if [[ -z "${rlink}" ]] && [[ ! -e "${root}/nginx/sites-enabled/rhel.example.pl.conf" ]]; then
  ok "rhel-no-symlink"
else
  bad "rhel-no-symlink"
fi
unset -f hm_os_nginx_sites_enabled

# Runtime Node/Python nie piszą vhosta — tylko snippety dla W04.
export HM_SITE_STATE_DIR="${root}/state"
mkdir -p "${HM_SITE_STATE_DIR}" "${root}/conf-node"
# shellcheck disable=SC1091
source lib/site/node.sh 2>/dev/null || true
if declare -F hm_site_node_write_proxy >/dev/null 2>&1; then
  hm_site_node_write_proxy node.example.pl 3010 proxy
  [[ ! -f "${root}/conf-node/node.example.pl.conf" ]] \
    && [[ -f "${HM_SITE_STATE_DIR}/node.example.pl/proxy.snippet" ]] \
    && ok "node-no-vhost" || bad "node-no-vhost"
else
  ok "node-no-vhost-skip"
fi
# shellcheck disable=SC1091
source lib/site/python.sh 2>/dev/null || true
if declare -F hm_python_write_vhost >/dev/null 2>&1; then
  mkdir -p "${HM_SITE_HOME_BASE}/py.example/shared"
  hm_python_write_vhost py.example "${HM_SITE_HOME_BASE}/py.example"
  [[ ! -f "${root}/nginx/sites-available/py.example.conf" ]] \
    && [[ -f "${HM_SITE_STATE_DIR}/py.example/vhost.extra" ]] \
    && grep -q 'location /static/' "${HM_SITE_STATE_DIR}/py.example/vhost.extra" \
    && ok "python-snippet-only" || bad "python-snippet-only"
  export HM_SITE_WEB_DOMAIN=py.example
  export HM_SITE_WEB_ROOT="${HM_SITE_HOME_BASE}/py.example/public_html"
  export HM_SITE_WEB_UPSTREAM=127.0.0.1:8000
  export HM_SITE_WEB_LOGDIR="${HM_SITE_HOME_BASE}/py.example/logs"
  unset HM_SITE_WEB_PROXY_NAME HM_SITE_WEB_ALIASES_LINE HM_SITE_WEB_FORWARDED_PROTO
  rendered="$(hm_site_web_render nginx proxy)"
  printf '%s\n' "${rendered}" | grep -q 'location /static/' && ok "extra-in-render" || bad "extra-in-render"
else
  ok "python-snippet-skip"
fi

# apache: sites-enabled + pakiet apache2 (nie „apache”)
ap_avail="${root}/apache2/sites-available"
ap_en="${root}/apache2/sites-enabled"
mkdir -p "${ap_avail}" "${ap_en}"
ap_dest="${ap_avail}/ap.example.pl.conf"
export HM_SITE_WEB_VALIDATE=ok
body="$(hm_site_web_render apache static)"
if hm_site_web_apply_file apache static "${ap_dest}" "${body}" >/dev/null 2>&1 \
  && [[ -f "${ap_dest}" ]] \
  && [[ -e "${ap_en}/ap.example.pl.conf" ]]; then
  ok "apache-enabled"
else
  bad "apache-enabled"
  ls -la "${ap_en}" >&2 || true
fi
# offer_install: apache2 w PATH ⇒ bez hm_pkg_install
: > "${HM_SITE_WEB_LOG}"
hm_os_apache_pkg() { printf 'apache2'; }
hm_pkg_install() { echo "PKG:$*" >> "${HM_SITE_WEB_LOG}"; return 0; }
if hm_site_web_offer_install apache 1 >/dev/null 2>&1 \
  && ! grep -q 'PKG:' "${HM_SITE_WEB_LOG}"; then
  ok "apache-detect-installed"
else
  bad "apache-detect-installed"
  cat "${HM_SITE_WEB_LOG}" >&2 || true
fi
# bez apache* w PATH ⇒ instalacja pakietu z hm_os_apache_pkg (apache2)
hm_have_cmd() {
  case "$1" in
    nginx) return 0 ;;
    *) return 1 ;;
  esac
}
: > "${HM_SITE_WEB_LOG}"
hm_os_apache_pkg() { printf 'apache2'; }
if hm_site_web_offer_install apache 1 >/dev/null 2>&1 \
  && grep -qx 'PKG:apache2' "${HM_SITE_WEB_LOG}"; then
  ok "apache-pkg-apache2"
else
  bad "apache-pkg-apache2"
  cat "${HM_SITE_WEB_LOG}" >&2 || true
fi
# RHEL: httpd
: > "${HM_SITE_WEB_LOG}"
hm_os_apache_pkg() { printf 'httpd'; }
if hm_site_web_offer_install apache 1 >/dev/null 2>&1 \
  && grep -qx 'PKG:httpd' "${HM_SITE_WEB_LOG}"; then
  ok "apache-pkg-httpd"
else
  bad "apache-pkg-httpd"
  cat "${HM_SITE_WEB_LOG}" >&2 || true
fi

if [[ "${fail}" -eq 0 ]]; then
  echo "ALL PASSED"
else
  echo "FAILED" >&2
  exit 1
fi
