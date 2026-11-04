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

# Cache du (TTL sekundy, domyślnie 300). Plik: ${TMP_DIR}/du-cache/<hash>
# hm_dir_size_bytes_cached <path> [ttl_sec]
hm_dir_size_bytes_cached() {
  local path="$1" ttl="${2:-300}"
  local dir key cachef now mtime age sz
  if [[ ! -e "${path}" ]]; then
    echo 0
    return 0
  fi
  dir="${TMP_DIR:-/tmp}/hmtools-du-cache"
  mkdir -p "${dir}" 2>/dev/null || true
  key="$(printf '%s' "$(realpath -m "${path}" 2>/dev/null || echo "${path}")" | md5sum 2>/dev/null | awk '{print $1}')"
  [[ -n "${key}" ]] || key="$(printf '%s' "${path}" | cksum | awk '{print $1}')"
  cachef="${dir}/${key}"
  now="$(date +%s)"
  if [[ -f "${cachef}" ]]; then
    mtime="$(stat -c '%Y' "${cachef}" 2>/dev/null || echo 0)"
    age=$((now - mtime))
    if [[ "${age}" -ge 0 && "${age}" -lt "${ttl}" ]]; then
      sz="$(awk 'NR==1{print $1; exit}' "${cachef}" 2>/dev/null || true)"
      if [[ "${sz}" =~ ^[0-9]+$ ]]; then
        printf '%s' "${sz}"
        return 0
      fi
    fi
  fi
  sz="$(hm_dir_size_bytes "${path}")"
  [[ "${sz}" =~ ^[0-9]+$ ]] || sz=0
  printf '%s %s\n' "${sz}" "${path}" > "${cachef}" 2>/dev/null || true
  printf '%s' "${sz}"
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
