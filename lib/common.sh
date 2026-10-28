#!/usr/bin/env bash
# Wspólne helpery hmtools (loader). Implementacja: lib/common/*.sh

if [[ -n "${HMTOOLS_COMMON_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_COMMON_LOADED=1

# Katalog instalacji (nadpisywany przez entrypoint)
: "${HMTOOLS_ROOT:=/hm-tools}"
: "${HMTOOLS_CONF:=${HMTOOLS_ROOT}/config/hmtools.conf}"

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=logging.sh
source "${_LIB_DIR}/logging.sh"

_COMMON_DIR="${_LIB_DIR}/common"
# shellcheck source=common/ui.sh
source "${_COMMON_DIR}/ui.sh"
# shellcheck source=common/config.sh
source "${_COMMON_DIR}/config.sh"
# shellcheck source=common/context.sh
source "${_COMMON_DIR}/context.sh"
# shellcheck source=common/self.sh
source "${_COMMON_DIR}/self.sh"
