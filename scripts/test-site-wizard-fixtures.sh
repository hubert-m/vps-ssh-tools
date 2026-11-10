#!/usr/bin/env bash
# Fixtures katalogów (apt/dnf/nvm/node/dotnet/python) i snapshot vhosta oraz unitu.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

fix="${HMTOOLS_ROOT}/scripts/fixtures/site-wizard"

# shellcheck disable=SC1091
source lib/site/php.sh
# shellcheck disable=SC1091
source lib/site/node.sh
# shellcheck disable=SC1091
source lib/site/web.sh
# shellcheck disable=SC1091
source lib/site/catalog.sh

apt="$(hm_site_php_parse_apt_policy "${fix}/apt-policy.txt")"
printf '%s\n' "${apt}" | grep -q $'8.4\tinstalled' && ok "apt-84" || bad "apt-84"
printf '%s\n' "${apt}" | grep -q $'8.3\trepo' && ok "apt-83" || bad "apt-83"
printf '%s\n' "${apt}" | grep -q $'8.2\tmissing' && ok "apt-82" || bad "apt-82"

dnf="$(hm_site_php_parse_dnf_list "${fix}/dnf-list.txt")"
printf '%s\n' "${dnf}" | grep -q $'8.4\tinstalled' && ok "dnf-84" || bad "dnf-84"
printf '%s\n' "${dnf}" | grep -q $'8.3\trepo' && ok "dnf-83" || bad "dnf-83"

nvm="$(hm_site_catalog_nvm_majors "${fix}/nvm-ls-remote.txt")"
printf '%s\n' "${nvm}" | grep -qx '20' && ok "nvm-20" || bad "nvm-20"
printf '%s\n' "${nvm}" | grep -qx '22' && ok "nvm-22" || bad "nvm-22"
printf '%s\n' "${nvm}" | grep -q 'rc' && bad "nvm-rc" || ok "nvm-no-rc"

node="$(hm_site_node_majors "${fix}/node-index.json")"
printf '%s\n' "${node}" | grep -q $'v24.11.0\tfalse\tfalse' && ok "node-24" || bad "node-24"
printf '%s\n' "${node}" | grep -q $'v22.14.0\tJod\ttrue' && ok "node-22" || bad "node-22"

dot="$(hm_site_catalog_dotnet "${fix}/dotnet-releases-index.json")"
printf '%s\n' "${dot}" | grep -q $'9.0\tactive' && ok "dotnet-9" || bad "dotnet-9"
printf '%s\n' "${dot}" | grep -q $'8.0\tactive' && ok "dotnet-8" || bad "dotnet-8"
printf '%s\n' "${dot}" | grep -q $'6.0\teol' && ok "dotnet-6" || bad "dotnet-6"

py="$(hm_site_catalog_python "${fix}/python-status.json")"
printf '%s\n' "${py}" | grep -q $'3.13\tbugfix' && ok "py-313" || bad "py-313"
printf '%s\n' "${py}" | grep -q $'3.8\tend-of-life' && ok "py-38" || bad "py-38"

export HM_SITE_WEB_DOMAIN=app.example
export HM_SITE_WEB_ROOT=/var/www/app.example/public_html
export HM_SITE_WEB_UPSTREAM=127.0.0.1:3000
export HM_SITE_WEB_SOCK=/run/php/app.sock
export HM_SITE_WEB_LOGDIR=/var/www/app.example/logs
export HM_SITE_WEB_USER=app
rendered="$(hm_site_web_render nginx proxy)"
if diff -u "${fix}/nginx-proxy.snap" <(printf '%s\n' "${rendered}") >/dev/null; then
  ok "vhost-snap"
else
  bad "vhost-snap"
fi
printf '%s\n' "${rendered}" | grep -q '127.0.0.1:3000' && ok "vhost-loopback" || bad "vhost-loopback"
printf '%s\n' "${rendered}" | grep -q '0.0.0.0' && bad "vhost-public" || ok "vhost-no-public"

root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
home="${root}/app.example"
mkdir -p "${home}/.nvm/alias" "${home}/.nvm/versions/node/v22.14.0/bin" "${root}/units"
printf 'v22.14.0\n' > "${home}/.nvm/alias/default"
printf '#!/bin/sh\n' > "${home}/.nvm/versions/node/v22.14.0/bin/node"
export HM_SITE_NODE_MOCK=1
export HM_SYSTEMD_UNIT_DIR="${root}/units"
unit="$(hm_site_node_write_systemd app.example "${home}" app "node server.js" 3001)"
expected="$(sed "s|HOME|${home}|g" "${fix}/hm-app.service.snap")"
if diff -u <(printf '%s\n' "${expected}") "${unit}" >/dev/null; then
  ok "unit-snap"
else
  bad "unit-snap"
  diff -u <(printf '%s\n' "${expected}") "${unit}" >&2 || true
fi
grep -q 'HOST=127.0.0.1' "${unit}" && ok "unit-loopback" || bad "unit-loopback"
grep -q '0.0.0.0' "${unit}" && bad "unit-public" || ok "unit-no-public"

if [[ "${fail}" -ne 0 ]]; then
  echo FAILED
  exit 1
fi
echo "ALL OK"
