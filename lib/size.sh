#!/usr/bin/env bash
# Liczenie rozmiaru katalogów

if [[ -n "${HMTOOLS_SIZE_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_SIZE_LOADED=1

# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

hm_dir_size_bytes() {
  local path="$1"
  if [[ ! -e "${path}" ]]; then
    echo 0
    return
  fi
  # du -sb (GNU) lub fallback
  if du -sb "${path}" >/dev/null 2>&1; then
    du -sb "${path}" 2>/dev/null | awk '{print $1}'
  else
    du -sk "${path}" 2>/dev/null | awk '{print $1 * 1024}'
  fi
}

hm_format_size_from_path() {
  hm_human_size "$(hm_dir_size_bytes "$1")"
}
