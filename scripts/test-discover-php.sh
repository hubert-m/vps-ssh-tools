#!/usr/bin/env bash
# discover: PHP z manifestu / puli FPM (nie zawsze "?")
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
# shellcheck disable=SC1091
source lib/common/ui.sh
# shellcheck disable=SC1091
source commands/_shared/sites/discover.sh

fail=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fail=1; }

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

hm_vhost_conf_path() { printf ''; }
hm_ols_vhroot_for_domain() { printf ''; }
hm_parse_vhost_docroot() { printf ''; }
hm_parse_vhost_php() { printf '?'; }
hm_expand_ols_vars() { printf '%s' "$1"; }
hm_cyberpanel_site_meta() { printf ''; }
PANEL=""
OLS_ROOT=""

# stub manifestu
hm_site_manifest_path() { printf '%s/sites/%s.json' "${tmpdir}" "$1"; }
hm_site_runtime_version() {
  sed -n 's/.*"runtime":{"type":"[^"]*","version":"\([^"]*\)".*/\1/p' "$1" | head -1
}

mkdir -p "${tmpdir}/sites" "${tmpdir}/etc/php/8.3/fpm/pool.d" "${tmpdir}/etc/opt/remi/php82/php-fpm.d"

# 1) manifest → 8.3
printf '{"webserver":"nginx","runtime":{"type":"php","version":"8.3","manager":"php-fpm"}}' \
  > "${tmpdir}/sites/blog.other.test.json"
row="$(hm_resolve_site_paths "blog.other.test")"
IFS=$'\t' read -r _d _r _doc _l _v php rest <<<"${row}"
[[ "${php}" == "8.3" ]] && ok "manifest-php-8.3" || bad "manifest-php-8.3 got=${php}"

hm_set_site_context "blog.other.test"
[[ "${HM_SITE_PHP}" == "8.3" ]] && ok "context-php-8.3" || bad "context-php-8.3 got=${HM_SITE_PHP}"

# 2) bez manifestu → pula Debian
rm -f "${tmpdir}/sites/fpm.only.test.json"
# przekieruj globy przez chroot-like: helper czyta /etc — podmieniamy funkcję discover
# używamy prawdziwych ścieżek pod ${tmpdir} przez tymczasowy override helpera
hm_discover_site_php_version() {
  local domain="$1" man ver="" pool
  man="$(hm_site_manifest_path "${domain}")"
  if [[ -f "${man}" ]]; then
    ver="$(hm_site_runtime_version "${man}" 2>/dev/null || true)"
    [[ "${ver}" =~ ^[0-9]+\.[0-9]+$ ]] && { printf '%s' "${ver}"; return 0; }
  fi
  for pool in \
    "${tmpdir}/etc/php/"*/fpm/pool.d/"${domain}".conf \
    "${tmpdir}/etc/opt/remi/php"*/php-fpm.d/"${domain}".conf
  do
    [[ -f "${pool}" ]] || continue
    if [[ "${pool}" =~ /php/([0-9]+\.[0-9]+)/ ]]; then
      printf '%s' "${BASH_REMATCH[1]}"; return 0
    fi
    if [[ "${pool}" =~ /php([0-9])([0-9]+)/php-fpm\.d/ ]]; then
      printf '%s.%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"; return 0
    fi
  done
  printf ''
}

touch "${tmpdir}/etc/php/8.3/fpm/pool.d/fpm.only.test.conf"
row="$(hm_resolve_site_paths "fpm.only.test")"
IFS=$'\t' read -r _d _r _doc _l _v php rest <<<"${row}"
[[ "${php}" == "8.3" ]] && ok "fpm-pool-debian" || bad "fpm-pool-debian got=${php}"

# 3) Remi php82
touch "${tmpdir}/etc/opt/remi/php82/php-fpm.d/remi.only.test.conf"
row="$(hm_resolve_site_paths "remi.only.test")"
IFS=$'\t' read -r _d _r _doc _l _v php rest <<<"${row}"
[[ "${php}" == "8.2" ]] && ok "fpm-pool-remi" || bad "fpm-pool-remi got=${php}"

# 4) brak źródeł → ?
row="$(hm_resolve_site_paths "none.php.test")"
IFS=$'\t' read -r _d _r _doc _l _v php rest <<<"${row}"
[[ "${php}" == "?" ]] && ok "php-unknown" || bad "php-unknown got=${php}"

# 5) hm_parse_vhost_php — fixture nginx nie zwraca śmieci
# shellcheck disable=SC1091
source commands/_shared/sites/vhost.sh
got="$(hm_parse_vhost_php scripts/fixtures/vhost/nginx-php-fpm.conf)"
[[ "${got}" == "?" ]] && ok "parse-nginx-no-version" || bad "parse-nginx-no-version got=${got}"

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
exit 0
