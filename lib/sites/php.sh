#!/usr/bin/env bash
# Sites: LSPHP / php.net

hm_php_branch_of() {
  # 8.4.18 → 8.4
  local v="$1"
  printf '%s' "${v}" | grep -oE '^[0-9]+\.[0-9]+' | head -1
}

hm_php_latest_remote() {
  # najnowszy patch dla gałęzi (np. 8.4 → 8.4.27) z php.net; cache 1h
  local branch="$1"
  [[ -n "${branch}" ]] || return 1
  local cache_dir="${TMP_DIR:-/tmp}/hmtools-php-cache"
  mkdir -p "${cache_dir}" 2>/dev/null || true
  local cache="${cache_dir}/latest-${branch}.txt"
  local max_age=3600
  if [[ -f "${cache}" ]]; then
    local age mtime now
    mtime="$(stat -c %Y "${cache}" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    age=$((now - mtime))
    if [[ "${age}" -ge 0 && "${age}" -lt "${max_age}" ]]; then
      tr -d '[:space:]' < "${cache}"
      return 0
    fi
  fi
  local json ver
  json="$(curl -fsSL --connect-timeout 2 --max-time 6 --retry 0 \
    "https://www.php.net/releases/index.php?json&version=${branch}&max=1" 2>/dev/null || true)"
  if [[ -z "${json}" || "${json}" == "[]" || "${json}" == "{}" ]]; then
    if [[ -f "${cache}" ]]; then
      tr -d '[:space:]' < "${cache}"
      return 0
    fi
    return 1
  fi
  if hm_have_cmd jq; then
    ver="$(printf '%s' "${json}" | jq -r 'keys_unsorted[0] // keys[0] // empty' 2>/dev/null || true)"
  else
    ver="$(printf '%s' "${json}" | grep -oE '"[0-9]+\.[0-9]+\.[0-9]+"' | head -1 | tr -d '"' || true)"
  fi
  [[ -n "${ver}" && "${ver}" != "null" ]] || return 1
  printf '%s\n' "${ver}" > "${cache}" 2>/dev/null || true
  printf '%s' "${ver}"
}

hm_php_prefetch_latests() {
  # równoległy prefetch dla listy gałęzi (stdin lub args)
  local b
  if [[ $# -gt 0 ]]; then
    for b in "$@"; do
      ( hm_php_latest_remote "${b}" >/dev/null 2>&1 || true ) &
    done
  else
    while IFS= read -r b; do
      [[ -n "${b}" ]] || continue
      ( hm_php_latest_remote "${b}" >/dev/null 2>&1 || true ) &
    done
  fi
  wait 2>/dev/null || true
}

hm_list_available_php() {
  local p ver branch latest status
  local root="${OLS_ROOT:-/usr/local/lsws}"
  local -a rows=() branches=()
  local oldnull
  oldnull="$(shopt -p nullglob || true)"
  shopt -s nullglob
  for p in "${root}"/lsphp*; do
    [[ -d "${p}" ]] || continue
    if [[ -x "${p}/bin/php" ]]; then
      ver="$(${p}/bin/php -r 'echo PHP_VERSION;' 2>/dev/null || true)"
      [[ -n "${ver}" ]] || ver="?"
      branch="$(hm_php_branch_of "${ver}")"
      rows+=("${p}"$'\t'"${ver}"$'\t'"${branch}")
      [[ -n "${branch}" ]] && branches+=("${branch}")
    fi
  done
  eval "${oldnull}" 2>/dev/null || shopt -u nullglob

  if [[ "${#rows[@]}" -eq 0 ]]; then
    echo "  (brak lsphp* w ${root})"
    return 0
  fi

  # unikalne gałęzie → prefetch z php.net
  local -A seen_b=()
  local -a uniq=()
  local b
  for b in "${branches[@]}"; do
    [[ -n "${b}" ]] || continue
    [[ -n "${seen_b[$b]:-}" ]] && continue
    seen_b[$b]=1
    uniq+=("${b}")
  done
  if [[ "${#uniq[@]}" -gt 0 ]]; then
    hm_php_prefetch_latests "${uniq[@]}"
  fi

  printf '  %s%-28s %-14s %-14s %s%s\n' \
    "${C_DIM}" "LSPHP" "ZAINSTALOWANA" "NAJNOWSZA" "STATUS" "${C_RESET}"
  printf '  %s%s%s\n' "${C_DIM}" "$(printf '%.0s─' {1..72})" "${C_RESET}"

  local path
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r path ver branch <<<"${row}"
    latest=""
    status="?"
    if [[ -n "${branch}" ]]; then
      latest="$(hm_php_latest_remote "${branch}" 2>/dev/null || true)"
    fi
    if [[ -z "${latest}" ]]; then
      latest="—"
      status="${C_DIM}brak danych php.net${C_RESET}"
    elif [[ "${ver}" == "${latest}" ]]; then
      status="${C_GREEN}aktualna${C_RESET}"
    elif hm_version_is_newer "${ver}" "${latest}" 2>/dev/null; then
      status="${C_YELLOW}dostępna nowsza${C_RESET}"
    else
      # zainstalowana nowsza niż php.net? (np. snapshot) albo równość nie złapana
      status="${C_GREEN}aktualna${C_RESET}"
    fi
    printf '  %-28s %-14s %-14s %b\n' \
      "$(basename "${path}")" \
      "${ver}" \
      "${latest}" \
      "${status}"
    printf '  %s%s%s\n' "${C_DIM}" "${path}" "${C_RESET}"
  done
  echo
  echo "  ${C_DIM}Najnowsze wersje: php.net (cache ~1h w ${TMP_DIR:-/tmp}/hmtools-php-cache)${C_RESET}"
}
