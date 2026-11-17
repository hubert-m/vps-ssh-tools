#!/usr/bin/env bash
# Wspólne ładowanie lib/site/* w kolejności jak bin/hmtools — dla skryptów test-site-*.
# Użycie: source scripts/lib-test-site.sh && hm_test_site_load

hm_test_site_root() {
  if [[ -n "${HMTOOLS_ROOT:-}" ]]; then
    printf '%s\n' "${HMTOOLS_ROOT}"
    return 0
  fi
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

# Stuby pakietów / OS — bez instalacji w harnessie.
hm_test_site_stub_pkg() {
  if ! declare -F hm_pkg_install >/dev/null 2>&1; then
    hm_pkg_install() { :; }
  fi
  if ! declare -F hm_pkg_refresh >/dev/null 2>&1; then
    hm_pkg_refresh() { :; }
  fi
  if ! declare -F hm_pkg_ensure >/dev/null 2>&1; then
    hm_pkg_ensure() { :; }
  fi
  if ! declare -F hm_os_web_group >/dev/null 2>&1; then
    hm_os_web_group() { printf '%s\n' "${HM_SITE_WEB_GROUP:-www-data}"; }
  fi
}

hm_test_site_load() {
  local root
  root="$(hm_test_site_root)"
  export HMTOOLS_ROOT="${root}"
  hm_test_site_stub_pkg
  # shellcheck disable=SC1091
  source "${root}/lib/site/env.sh"
  # shellcheck disable=SC1091
  source "${root}/lib/site/base.sh"
  # shellcheck disable=SC1091
  source "${root}/lib/site/tx.sh"
  # shellcheck disable=SC1091
  source "${root}/lib/site/db.sh"
  # shellcheck disable=SC1091
  source "${root}/lib/site/web.sh"
  # shellcheck disable=SC1091
  source "${root}/lib/site/node.sh"
  # shellcheck disable=SC1091
  source "${root}/lib/site/php.sh"
  # shellcheck disable=SC1091
  source "${root}/lib/site/dotnet.sh"
  # shellcheck disable=SC1091
  source "${root}/lib/site/python.sh"
  # shellcheck disable=SC1091
  source "${root}/lib/site/docker.sh"
  # shellcheck disable=SC1091
  source "${root}/lib/site/catalog.sh"
  # shellcheck disable=SC1091
  source "${root}/lib/site/lifecycle.sh"
  # shellcheck disable=SC1091
  source "${root}/lib/site/ops.sh"
}
