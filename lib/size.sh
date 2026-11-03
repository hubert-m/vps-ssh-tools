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

# Top wpisów z du w bajtach → format jak mysql (np. „6.44 GB”).
# hm_print_du_depth <path> [max-depth=1] [limit=25] [indent="  "]
hm_print_du_depth() {
  local path="$1" depth="${2:-1}" limit="${3:-25}" indent="${4:-  }"
  local sz p human
  [[ -e "${path}" ]] || return 0
  while IFS=$'\t' read -r sz p || [[ -n "${sz:-}" ]]; do
    [[ -n "${p}" ]] || continue
    [[ "${sz}" =~ ^[0-9]+$ ]] || continue
    human="$(hm_human_size "${sz}")"
    printf '%s%-12s %s\n' "${indent}" "${human}" "${p}"
  done < <(
    # GNU du: -a wszystkie, -b bajty, -d głębokość
    du -abd "${depth}" -- "${path}" 2>/dev/null \
      | awk '{
          sz = $1
          $1 = ""
          sub(/^ /, "")
          printf "%s\t%s\n", sz, $0
        }' \
      | sort -t $'\t' -nr -k1,1 \
      | head -n "${limit}"
  )
}
