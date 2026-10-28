#!/usr/bin/env bash
# Tab-complete w interaktywnym REPL (loader). Implementacja: lib/complete/*.sh

if [[ -n "${HMTOOLS_COMPLETE_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_COMPLETE_LOADED=1

_COMPLETE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/complete"
# shellcheck source=complete/helpers.sh
source "${_COMPLETE_DIR}/helpers.sh"
# shellcheck source=complete/tab.sh
source "${_COMPLETE_DIR}/tab.sh"
