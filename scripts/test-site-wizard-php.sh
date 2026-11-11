#!/usr/bin/env bash
# site new — runtime PHP: statusy, repo po zgodzie, pule FPM, Composer SHA-384.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1 HMTOOLS_TEST_NO_TTY=1
export FORCE_PKG_MANAGER=apt OS_FAMILY=debian OS_ID=debian

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }
hm_is_valid_domain() { [[ "$1" == *.* ]]; }
hm_confirm_plan() { return 0; }
hm_print_secret() { echo "SECRET:$*"; }
hm_gen_password() { printf 'GenPass12xYzAb99'; }
hm_run() { printf 'RUN:%s\n' "$*"; return 0; }

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
export HM_SITE_HOME_BASE="${root}/homes"
export HM_PKG_ROOT="${root}/pkg"
export HM_PKG_PHP_LOG="${root}/pkg.log"
export HM_PKG_PHP_KEY_FILE="${root}/key.gpg"
export HM_PHP_POLICY_FILE="${root}/policy.txt"
export HM_PHP_EXTRA_FILE="${root}/extra.txt"
export HM_PHP_SUPPORT_FILE="${root}/support.txt"
export HM_PHP_INSTALLED_LIST="${root}/installed.txt"
export HM_SITE_PHP_LOG="${root}/php.log"
export HM_SITE_PHP_RAM_MB=1024
export HM_SITE_PHP_WEB_GROUP=www-data
export HM_SITE_USER=shop
mkdir -p "${HM_SITE_HOME_BASE}"
printf 'gpg-fixture\n' > "${HM_PKG_PHP_KEY_FILE}"
: > "${HM_PKG_PHP_LOG}"
: > "${HM_SITE_PHP_LOG}"

cat > "${HM_PHP_POLICY_FILE}" <<'EOF'
php8.4-fpm:
  Installed: 8.4.14-1
  Candidate: 8.4.14-1
php8.3-fpm:
  Installed: 8.3.26-1
  Candidate: 8.3.26-1
php8.5-fpm:
  Installed: (none)
  Candidate: (none)
php8.2-fpm:
  Installed: (none)
  Candidate: (none)
EOF
printf '%s\n' 8.5 8.2 > "${HM_PHP_EXTRA_FILE}"
cat > "${HM_PHP_SUPPORT_FILE}" <<'EOF'
8.5 active
8.4 active
8.3 security 2027-12-31
8.2 security 2026-12-31
8.1 eol 2025-12-31
EOF
printf '%s\n' php8.4-fpm php8.4-cli php8.4-mysql > "${HM_PHP_INSTALLED_LIST}"

# shellcheck disable=SC1091
source lib/pkg.sh
# shellcheck disable=SC1091
source lib/site/env.sh
# shellcheck disable=SC1091
source lib/site/db.sh
# shellcheck disable=SC1091
source lib/site/php.sh
# shellcheck disable=SC1091
source commands/site-create/wizard-db.sh

hm_pkg_bind
_hm_pkg_do_install() { printf '%s\n' "$@" >> "${HM_PKG_PHP_LOG}"; }
_hm_pkg_do_refresh() { printf 'refresh\n' >> "${HM_PKG_PHP_LOG}"; }
_hm_pkg_do_list_installed() { return 0; }

cat="$(hm_site_php_print_catalog)"
printf '%s\n' "${cat}" | grep -q $'^8.4\tzainstalowana\tactive' && ok "status-installed" || bad "status-installed"
printf '%s\n' "${cat}" | grep -q $'^8.5\twymaga dodania repo\tactive' && ok "status-extra" || { bad "status-extra"; printf '%s\n' "${cat}" >&2; }
printf '%s\n' "${cat}" | grep -q '8.2' && printf '%s\n' "${cat}" | grep '8.2' | grep -q 'security (do 2026-12-31)' \
  && ok "status-security-until" || bad "status-security-until"
[[ "$(hm_site_php_default_version)" == "8.5" ]] && ok "default-active" || bad "default-active"

hm_confirm_plan() { return 1; }
if hm_site_php_ensure_repo 8.5 0 >/dev/null 2>&1; then
  bad "repo-needs-confirm"
else
  ok "repo-needs-confirm"
fi
[[ -f "${HM_PKG_ROOT}/etc/apt/keyrings/hmtools-sury.gpg" ]] && bad "repo-not-written" || ok "repo-not-written"
hm_confirm_plan() { return 0; }

if hm_site_php_ensure_repo 8.5 0 >/dev/null 2>&1 \
  && grep -q 'signed-by=' "${HM_PKG_ROOT}/etc/apt/sources.list.d/hmtools-php.list" \
  && [[ -f "${HM_PKG_ROOT}/etc/apt/keyrings/hmtools-sury.gpg" ]] \
  && ! grep -q 'apt-key' "${HM_PKG_PHP_LOG}"; then
  ok "repo-keyring"
else
  bad "repo-keyring"
fi
[[ "$(hm_pkg_php_repo_label)" == "sury" ]] && ok "label-sury" || bad "label-sury"

(
  OS_ID=ubuntu
  HM_PKG_BACKEND_KEY=""
  hm_pkg_bind
  [[ "$(hm_pkg_php_repo_label)" == "ondrej" ]]
) && ok "label-ondrej" || bad "label-ondrej"

(
  export FORCE_PKG_MANAGER=dnf OS_FAMILY=rhel OS_ID=almalinux
  HM_PKG_BACKEND_KEY=""
  hm_pkg_bind
  names="$(hm_pkg_php_package_names 8.4 fpm bcmath)"
  [[ "${names}" == *php84-php-fpm* && "${names}" != *php8.4-fpm* ]]
) && ok "remi-scl" || bad "remi-scl"

: > "${HM_PKG_PHP_LOG}"
hm_site_php_install_exts 8.4 fpm bcmath ctype curl intl mbstring pdo_mysql gd
if grep -qx 'php8.4-gd' "${HM_PKG_PHP_LOG}" && grep -qx 'php8.4-bcmath' "${HM_PKG_PHP_LOG}" \
  && ! grep -qx 'php8.4-fpm' "${HM_PKG_PHP_LOG}" && ! grep -qx 'php8.4-mysql' "${HM_PKG_PHP_LOG}"; then
  ok "ext-only-missing"
else
  bad "ext-only-missing"
  cat "${HM_PKG_PHP_LOG}" >&2
fi

home_a="${HM_SITE_HOME_BASE}/a.example.pl"
home_b="${HM_SITE_HOME_BASE}/b.example.pl"
mkdir -p "${home_a}" "${home_b}"
pa="$(hm_site_php_write_pool a.example.pl 8.4 shop "${home_a}" fpm)"
pb="$(hm_site_php_write_pool b.example.pl 8.4 api "${home_b}" fpm)"
if grep -q '^user = shop$' "${pa}" && grep -q '^user = api$' "${pb}" \
  && grep -q 'listen.mode = 0660' "${pa}" \
  && grep -q 'listen.owner = www-data' "${pa}" \
  && grep -q 'listen.group = www-data' "${pa}" \
  && ! grep -q 'listen.owner = nogroup' "${pa}" \
  && grep -q "open_basedir] = ${home_a}:/tmp" "${pa}" \
  && ! grep -q "${home_b}" "${pa}" \
  && grep -q 'pm.max_children = 8' "${pa}"; then
  ok "pools-separate"
else
  bad "pools-separate"
fi
printf '\n# keep\n' >> "${pa}"
HM_SITE_PHP_FPM_TEST=fail
HM_SITE_PHP_HARDEN=1
if hm_site_php_write_pool a.example.pl 8.4 shop "${home_a}" fpm >/dev/null 2>&1; then
  bad "fpm-test-fail"
else
  ok "fpm-test-fail"
fi
if grep -q '# keep' "${pa}" && ! grep -q 'disable_functions' "${pa}"; then
  ok "fpm-rollback"
else
  bad "fpm-rollback"
fi
unset HM_SITE_PHP_FPM_TEST
HM_SITE_PHP_HARDEN=0

extf="$(hm_site_php_write_pool c.example.pl 8.4 shop "${HM_SITE_HOME_BASE}/c.example.pl" lsphp)"
grep -q 'extprocessor shop' "${extf}" && ok "lsphp-extprocessor" || bad "lsphp-extprocessor"

printf '#!/bin/sh\necho Composer version 2.8.4\n' > "${root}/composer.phar"
chmod 755 "${root}/composer.phar"
good="$(sha384sum "${root}/composer.phar" | awk '{print $1}')"
printf 'deadbeef\n' > "${root}/bad.sig"
printf '%s\n' "${good}" > "${root}/good.sig"
export HM_COMPOSER_PHAR="${root}/composer.phar"
export HM_COMPOSER_SIG="${root}/bad.sig"
if hm_site_php_composer bad.example.pl >/dev/null 2>&1; then
  bad "composer-bad-sig"
else
  ok "composer-bad-sig"
fi
[[ -e "${HM_SITE_HOME_BASE}/bad.example.pl/.local/bin/composer" ]] && bad "composer-removed" || ok "composer-removed"
export HM_COMPOSER_SIG="${root}/good.sig"
cbin="$(hm_site_php_composer ok.example.pl)"
if [[ -x "${cbin}" ]] && "${cbin}" --version | grep -q '2.8.4'; then
  ok "composer-ok"
else
  bad "composer-ok"
fi

out="${root}/new.out"
cmd_site_new shop.example.pl --runtime php --db none --php 8.4 --php-preset laravel \
  --php-skeleton laravel --yes >"${out}" 2>&1 || { bad "site-new"; cat "${out}" >&2; exit 1; }
ok "site-new"
envf="${HM_SITE_HOME_BASE}/shop.example.pl/shared/.env"
key="$(sed -n 's/^APP_KEY=//p' "${envf}" | head -1)"
if [[ -n "${key}" ]] && ! grep -q "${key}" "${out}" \
  && [[ -f "${HM_PKG_ROOT}/etc/php/8.4/fpm/pool.d/shop.example.pl.conf" ]] \
  && grep -q 'composer create-project laravel/laravel' "${HM_SITE_PHP_LOG}"; then
  ok "site-new-secret"
else
  bad "site-new-secret"
fi

probe="$(mktemp)"
chmod 0750 "${probe}" 2>/dev/null || true
mode="$(stat -c '%a' "${probe}" 2>/dev/null || echo '')"
if [[ "${mode}" == "750" ]]; then
  hmode="$(stat -c '%a' "${home_a}" 2>/dev/null || echo '')"
  [[ "${hmode}" == "750" ]] && ok "home-mode" || bad "home-mode"
else
  ok "home-mode-platform"
fi
rm -f "${probe}"

saved_policy="${HM_PHP_POLICY_FILE}"
unset HM_PHP_POLICY_FILE
_hm_pkg_do_php_fpm_query() { cat "${saved_policy}"; }
if [[ "$(hm_site_php_kind 8.3)" == "installed" && "$(hm_site_php_kind 8.5)" != "installed" ]]; then
  ok "live-os-installed"
else
  bad "live-os-installed 8.3=$(hm_site_php_kind 8.3) 8.5=$(hm_site_php_kind 8.5)"
fi
export HM_PHP_POLICY_FILE="${saved_policy}"

hm_have_cmd() {
  case "$1" in
    gpg) return 1 ;;
    *) command -v "$1" >/dev/null 2>&1 ;;
  esac
}
unset HM_PKG_PHP_KEY_FILE
: > "${HM_PKG_PHP_LOG}"
if hm_pkg_php_repo_add 8.4 >/dev/null 2>&1; then
  bad "gpg-missing-should-fail"
else
  grep -qx 'gnupg' "${HM_PKG_PHP_LOG}" && ok "gpg-installs-gnupg" || bad "gpg-installs-gnupg"
fi

if [[ "${fail}" -eq 0 ]]; then
  echo "ALL PASSED"
else
  echo "FAILED" >&2
  exit 1
fi
