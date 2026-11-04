#!/usr/bin/env bash
# Regresja: update check / pkg list stubs (bez prawdziwego apt/dnf)
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
# shellcheck disable=SC1091
source lib/common/ui.sh
hm_file_log_ui() { :; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }
hm_run() { "$@"; }
_hm_cmd_help() { cat >/dev/null; }
_hm_cmd_register() { :; }

fail=0

# Minimalny stub pkg API (bez bind do prawdziwego apt)
hm_pkg_bind() { return 0; }
hm_pkg_cache_age_info() { printf 'przed chwilą'; }
hm_pkg_list_upgradable() {
  printf 'curl\t7.0\t7.1\n'
  printf 'openssl\t3.0\t3.1\n'
}
hm_pkg_list_security() {
  printf 'openssl\t3.0\t3.1\n'
}
hm_pkg_auto_security_status() { printf 'off\n'; }

PANEL=cyberpanel
OLS_ROOT=/tmp/hmtools-no-ols-$$

# shellcheck disable=SC1091
source commands/update/main.sh

# OLS/CP versions — nie crashują bez plików
v="$(hm_update_ols_local_version)"
[[ -n "${v}" ]] && echo "OK   ols-local-version" || { echo "FAIL ols-local"; fail=1; }
v="$(hm_update_cyberpanel_local_version)"
[[ -n "${v}" ]] && echo "OK   cp-local-version" || { echo "FAIL cp-local"; fail=1; }

out="$(cmd_update_check 2>&1)" || true
case "${out}" in
  *"Pakiety do aktualizacji : 2"*) echo "OK   check-upgradable-count" ;;
  *) echo "FAIL check-upgradable: ${out}"; fail=1 ;;
esac
case "${out}" in
  *"security"*|*"Z tego security"*) echo "OK   check-security-section" ;;
  *) echo "FAIL check-security"; fail=1 ;;
esac
case "${out}" in
  *update-hmtools*) echo "OK   check-disambiguation" ;;
  *) echo "FAIL disambiguation hint"; fail=1 ;;
esac

# dispatch: update hmtools → błąd
if cmd_update hmtools 2>/dev/null; then
  echo "FAIL update-hmtools-redirect"
  fail=1
else
  echo "OK   update-hmtools-redirect"
fi

# auto-security bez arg
if cmd_update_auto_security 2>/dev/null; then
  echo "FAIL auto-security-no-arg"
  fail=1
else
  echo "OK   auto-security-usage"
fi

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL OK"
exit 0
