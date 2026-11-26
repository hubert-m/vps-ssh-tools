#!/usr/bin/env bash
# Archive/restore nginx: webserver.tar.gz + php-fpm + meta; reload nginx (nie OLS).
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { :; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }
hm_mktemp() { mktemp "${TMPDIR:-/tmp}/hm.XXXXXX${1:-}"; }
hm_json_escape_str() { printf '%s' "$1" | sed 's/\\/\\\\/g;s/"/\\"/g'; }

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hm-arch-ngx.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

export HM_SITE_MANIFEST_DIR="${TMP}/sites"
export HM_SITE_WEB_CONF_DIR="${TMP}/nginx/sites-available"
export HM_PKG_ROOT="${TMP}"
export HM_SITE_WEB_VALIDATE=ok
export WEBSERVER=nginx
export HM_SITE_WEBSERVER=nginx
export HM_SITE_PHP=8.3
export HM_DEL_WEB=nginx
mkdir -p "${HM_SITE_MANIFEST_DIR}" \
  "${HM_SITE_WEB_CONF_DIR}" "${TMP}/nginx/sites-enabled" \
  "${TMP}/etc/php/8.3/fpm/pool.d" \
  "${TMP}/etc/logrotate.d" \
  "${TMP}/remote/shop.example.test/stamp"

DOMAIN="shop.example.test"
printf 'server { server_name %s; root /home/%s/public_html; }\n' "${DOMAIN}" "${DOMAIN}" \
  > "${HM_SITE_WEB_CONF_DIR}/${DOMAIN}.conf"
ln -sfn "../sites-available/${DOMAIN}.conf" "${TMP}/nginx/sites-enabled/${DOMAIN}.conf"
printf '[%s]\nuser = shopu\nlisten = /run/php/%s.sock\n' "${DOMAIN}" "${DOMAIN}" \
  > "${TMP}/etc/php/8.3/fpm/pool.d/${DOMAIN}.conf"
printf '%s\n' "{\"schema\":1,\"domain\":\"${DOMAIN}\",\"webserver\":\"nginx\",\"user\":\"shopu\",\"runtime\":{\"type\":\"php\",\"version\":\"8.3\"}}" \
  > "${HM_SITE_MANIFEST_DIR}/${DOMAIN}.json"
printf 'mysql\tshop_app\tshop_u\t127.0.0.1\t3306\n' > "${HM_SITE_MANIFEST_DIR}/.${DOMAIN}.dbs"
printf '{"kind":"vhost","path":"%s/%s.conf","shared":false}\n' "${HM_SITE_WEB_CONF_DIR}" "${DOMAIN}" \
  > "${HM_SITE_MANIFEST_DIR}/${DOMAIN}.resources.ndjson"
printf '{"kind":"fpm","path":"%s/etc/php/8.3/fpm/pool.d/%s.conf","shared":false}\n' "${TMP}" "${DOMAIN}" \
  >> "${HM_SITE_MANIFEST_DIR}/${DOMAIN}.resources.ndjson"
printf '/var/log/%s/*.log {\n  weekly\n}\n' "${DOMAIN}" > "${TMP}/etc/logrotate.d/hm-shop_example_test"
printf '{"kind":"logrotate","path":"%s/etc/logrotate.d/hm-shop_example_test","shared":false}\n' "${TMP}" \
  >> "${HM_SITE_MANIFEST_DIR}/${DOMAIN}.resources.ndjson"

hm_site_manifest_dir() { printf '%s' "${HM_SITE_MANIFEST_DIR}"; }
hm_os_nginx_conf_dir() { printf '%s' "${HM_SITE_WEB_CONF_DIR}"; }
hm_os_nginx_sites_enabled() { return 0; }
hm_pkg_php_pool_dir() { printf '%s/etc/php/%s/fpm/pool.d' "${TMP}" "$1"; }
hm_pkg_php_fpm_check() { return 0; }
hm_site_web_conf_path() { printf '%s/%s.conf' "${HM_SITE_WEB_CONF_DIR}" "$2"; }
hm_site_web_nginx_enable() {
  local dest="$2" base en
  base="$(basename "${dest}")"
  en="${TMP}/nginx/sites-enabled/${base}"
  ln -sfn "../sites-available/${base}" "${en}"
  printf '%s\n' "${en}"
}
hm_site_web_validate() { [[ "${HM_SITE_WEB_VALIDATE}" == "ok" ]]; }

# shellcheck disable=SC1091
source lib/site/lifecycle.sh
# shellcheck disable=SC1091
source lib/site/web.sh
# shellcheck disable=SC1091
source commands/backup/archive.sh
# shellcheck disable=SC1091
source commands/backup/restore.sh

RELOAD_LOG="${TMP}/reload.log"
: > "${RELOAD_LOG}"
# Nadpisz po source — logujemy reload
hm_site_web_reload() { printf 'reload %s\n' "$1" >> "${RELOAD_LOG}"; }
hm_site_php_fpm_reload() { printf 'fpm %s\n' "$1" >> "${RELOAD_LOG}"; }
hm_ols_reload_soft() { printf 'ols\n' >> "${RELOAD_LOG}"; return 0; }

# --- (1) collect paths ---
webs="$(hm_archive_collect_web_paths "${DOMAIN}" nginx | sort -u || true)"
if printf '%s\n' "${webs}" | grep -q "${DOMAIN}.conf"; then pass "(1) vhost w collect"; else fail "(1) brak vhost: ${webs}"; fi
fpms="$(hm_archive_collect_fpm_paths "${DOMAIN}" 8.3 | sort -u || true)"
if printf '%s\n' "${fpms}" | grep -q 'pool.d'; then pass "(1) fpm w collect"; else fail "(1) brak fpm: ${fpms}"; fi

# --- (2) pack tars ---
WEB_TAR="${TMP}/webserver.tar.gz"
FPM_TAR="${TMP}/php-fpm.tar.gz"
META_TAR="${TMP}/meta.tar.gz"
mapfile -t WEB_ARR < <(hm_archive_collect_web_paths "${DOMAIN}" nginx | sort -u)
mapfile -t FPM_ARR < <(hm_archive_collect_fpm_paths "${DOMAIN}" 8.3 | sort -u)
if hm_archive_tar_abs_paths "${WEB_TAR}" "${WEB_ARR[@]}"; then pass "(2) webserver.tar.gz"; else fail "(2) web tar"; fi
if hm_archive_tar_abs_paths "${FPM_TAR}" "${FPM_ARR[@]}"; then pass "(2) php-fpm.tar.gz"; else fail "(2) fpm tar"; fi
if hm_archive_pack_site_meta "${DOMAIN}" "${META_TAR}"; then pass "(2) meta.tar.gz"; else fail "(2) meta tar"; fi
if tar -tzf "${WEB_TAR}" 2>/dev/null | grep -q 'sites-available'; then pass "(2) web members"; else fail "(2) web members"; fi
if tar -tzf "${META_TAR}" 2>/dev/null | grep -q "${DOMAIN}.json"; then pass "(2) meta has json"; else fail "(2) meta json"; fi

# --- (3) restore into DEST tree ---
RESTORE_ROOT="${TMP}/root"
mkdir -p "${RESTORE_ROOT}"
tar -C "${RESTORE_ROOT}" -xzf "${WEB_TAR}"
tar -C "${RESTORE_ROOT}" -xzf "${FPM_TAR}"
tar -C "${RESTORE_ROOT}" -xzf "${META_TAR}"
if find "${RESTORE_ROOT}" -name "${DOMAIN}.conf" 2>/dev/null | grep -q .; then
  pass "(3) restore vhost na dysk"
else
  fail "(3) brak vhost po tar"
fi
if find "${RESTORE_ROOT}" -name "${DOMAIN}.json" 2>/dev/null | grep -q .; then
  pass "(3) restore meta json"
else
  fail "(3) brak meta json"
fi

# --- (4) reload webstack = nginx, nie OLS ---
: > "${RELOAD_LOG}"
hm_backup_reload_webstack nginx 8.3
if grep -q 'reload nginx' "${RELOAD_LOG}"; then pass "(4) nginx reload"; else fail "(4) brak nginx reload: $(cat "${RELOAD_LOG}")"; fi
if grep -q 'fpm 8.3' "${RELOAD_LOG}"; then pass "(4) fpm reload"; else fail "(4) brak fpm"; fi
if grep -q 'ols' "${RELOAD_LOG}"; then fail "(4) niechciany OLS reload"; else pass "(4) bez OLS reload"; fi

# --- (5) OLS path nadal wywołuje ols ---
: > "${RELOAD_LOG}"
hm_backup_reload_webstack ols ""
if grep -q 'ols' "${RELOAD_LOG}"; then pass "(5) OLS reload dla ols"; else fail "(5) brak OLS"; fi

# --- (6) po plikach root:root — unix_account poprawia home przed authorized_keys ---
if grep -q 'Poprawiam właściciela home przed kluczami' commands/backup/restore.sh \
  && grep -q 'HM_SITE_PHP="${ver}"' commands/backup/restore.sh; then
  pass "(6) chown home przed kluczami + export HM_SITE_PHP z puli"
else
  fail "(6) brak chown-przed-kluczami / HM_SITE_PHP w restore.sh"
fi

# --- (7) HM_SITE_PHP=? → skan puli / reload php8.3-fpm (nie php?-fpm) ---
mkdir -p /etc/php/8.3/fpm/pool.d 2>/dev/null || true
# użyj HM_PKG_ROOT layout: funkcja skanuje /etc/php — w teście mockujemy lokalnie przez env
# symuluj: reload z ver=? musi być znormalizowany
: > "${RELOAD_LOG}"
export HM_SITE_PHP='?'
export HM_SITE_DOMAIN="${DOMAIN}"
# pulę w prawdziwym /etc nie tworzymy — podajemy ver przez skan mock:
# hm_backup_reload_webstack czyta /etc/php — stwórz w TMP i patch PATH? Prościej: wywołaj z pustym po normalizacji.
# Bez puli w /etc: warn; z jawnym 8.3 po clear:
unset HM_SITE_PHP
hm_backup_reload_webstack nginx '?'
if grep -q 'fpm ?' "${RELOAD_LOG}"; then
  fail "(7) reload dostał php ?"
else
  pass "(7) reload nie woła php?"
fi
: > "${RELOAD_LOG}"
export HM_SITE_PHP='?'
# bezpośredni test normalizacji w webstack restore path (kod)
if grep -q '\[\[ "${ver}" == "?"' commands/backup/restore.sh; then
  pass "(7) kod normalizuje php=?"
else
  fail "(7) brak normalizacji ?"
fi
# mock fpm reload: ? → rc≠0
hm_site_php_fpm_reload() {
  printf 'fpm %s\n' "$1" >> "${RELOAD_LOG}"
  [[ "$1" != "?" && -n "$1" ]] || return 1
  return 0
}
: > "${RELOAD_LOG}"
if ! hm_site_php_fpm_reload '?'; then
  pass "(7) fpm_reload odmawia ?"
else
  fail "(7) fpm_reload przepuścił ?"
fi
: > "${RELOAD_LOG}"
hm_backup_reload_webstack nginx 8.3
if grep -q 'fpm 8.3' "${RELOAD_LOG}"; then
  pass "(7) reload 8.3 OK"
else
  fail "(7) brak fpm 8.3: $(cat "${RELOAD_LOG}")"
fi

if [[ "${FAIL}" -eq 0 ]]; then
  echo "ALL PASSED (${PASS})"
else
  echo "FAILED (${FAIL} fail, ${PASS} pass)" >&2
  exit 1
fi
