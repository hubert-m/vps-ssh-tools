#!/usr/bin/env bash
# Discovery i szczegóły stron webowych (loader). Implementacja: lib/sites/*.sh

if [[ -n "${HMTOOLS_SITES_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_SITES_LOADED=1

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_LIB_DIR}/common.sh"
# shellcheck source=detect.sh
source "${_LIB_DIR}/detect.sh"
# shellcheck source=size.sh
source "${_LIB_DIR}/size.sh"
# shellcheck source=db.sh
source "${_LIB_DIR}/db.sh"

# Tablica domen (kolejność listy)
declare -a HM_SITES_LIST=()

_SITES_DIR="${_LIB_DIR}/sites"
# shellcheck source=sites/vhost.sh
source "${_SITES_DIR}/vhost.sh"
# shellcheck source=sites/ssl.sh
source "${_SITES_DIR}/ssl.sh"
# shellcheck source=sites/discover.sh
source "${_SITES_DIR}/discover.sh"
# shellcheck source=sites/print.sh
source "${_SITES_DIR}/print.sh"
# shellcheck source=sites/php.sh
source "${_SITES_DIR}/php.sh"
