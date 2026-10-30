#!/usr/bin/env bash
# Sites: LSPHP — wersje z menedżera pakietów (+ opcjonalnie php.net)

hm_php_branch_of() {
  # 8.4.18 → 8.4
  local v="$1"
  printf '%s' "${v}" | grep -oE '^[0-9]+\.[0-9]+' | head -1
}

hm_php_suffix_to_branch() {
  # 84 → 8.4 ; 74 → 7.4 (LiteSpeed: zawsze 2 cyfry)
  local s="$1"
  if [[ "${s}" =~ ^([0-9])([0-9])$ ]]; then
    printf '%s.%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

# Lista bazowych pakietów lsphpNN z lokalnego indeksu: suffix<TAB>candidate_raw
hm_php_repo_list_available_bases() {
  hm_pkg_list_available_bases "lsphp"
}

# Kanał wersji: stable | niepewna (…)
hm_php_branch_channel() {
  local branch="$1" pkg_ver="${2:-}"
  local low remote
  low="$(printf '%s' "${pkg_ver}" | tr '[:upper:]' '[:lower:]')"
  if [[ "${low}" =~ (rc[0-9]|-rc|alpha|beta|snapshot|\.dev) ]]; then
    printf 'niepewna (RC/beta w pakiecie)'
    return 0
  fi
  if remote="$(hm_php_latest_remote "${branch}" 2>/dev/null)" && [[ -n "${remote}" ]]; then
    printf 'stable'
    return 0
  fi
  printf 'niepewna (brak release na php.net)'
}

# Sekcja: nowsze gałęzie LSPHP dostępne w repo, jeszcze niezainstalowane.
# Args: lista zainstalowanych branchy (np. 8.4 8.5); puste → próg 8.0
hm_php_print_installable_newer() {
  local -a installed_branches=("$@")
  local max_branch="7.9" b sfx cand cand_clean channel line
  local -A have_branch=()
  local -a avail_lines=() show_branches=()

  for b in "${installed_branches[@]}"; do
    [[ -n "${b}" && "${b}" != "-" ]] || continue
    have_branch["${b}"]=1
    if hm_version_is_newer "${max_branch}" "${b}" 2>/dev/null; then
      max_branch="${b}"
    elif [[ "${max_branch}" == "7.9" ]]; then
      max_branch="${b}"
    fi
  done

  local -A best_cand=() best_sfx=()
  while IFS=$'\t' read -r sfx cand; do
    [[ -n "${sfx}" ]] || continue
    b="$(hm_php_suffix_to_branch "${sfx}" 2>/dev/null || true)"
    [[ -n "${b}" ]] || continue
    [[ -z "${have_branch[$b]:-}" ]] || continue
    # tylko nowsze niż najwyższa zainstalowana
    hm_version_is_newer "${max_branch}" "${b}" 2>/dev/null || continue
    if [[ -n "${best_cand[$b]:-}" ]]; then
      hm_version_is_newer "$(hm_php_clean_pkg_ver "${best_cand[$b]}")" "$(hm_php_clean_pkg_ver "${cand}")" 2>/dev/null \
        || [[ "$(hm_php_clean_pkg_ver "${cand}")" == "$(hm_php_clean_pkg_ver "${best_cand[$b]}")" ]] \
        || continue
    fi
    best_cand["${b}"]="${cand}"
    best_sfx["${b}"]="${sfx}"
  done < <(hm_php_repo_list_available_bases | sort -t$'\t' -k1,1V)

  for b in $(printf '%s\n' "${!best_sfx[@]}" | sort -V); do
    avail_lines+=("${best_sfx[$b]}"$'\t'"${b}"$'\t'"${best_cand[$b]}")
    show_branches+=("${b}")
  done

  [[ "${#avail_lines[@]}" -gt 0 ]] || return 0

  if [[ "${#show_branches[@]}" -gt 0 ]]; then
    hm_status_line "Sprawdzanie kanału nowych gałęzi (php.net)..."
    hm_php_prefetch_latests "${show_branches[@]}"
    hm_progress_done
  fi

  echo
  echo "  ${C_BOLD}Nowsze PHP dostępne do instalacji${C_RESET} ${C_DIM}(brak lokalnego lsphp*)${C_RESET}"
  printf '  %s%-12s %-18s %s%s\n' \
    "${C_DIM}" "LSPHP" "W REPO" "KANAŁ / INSTALACJA" "${C_RESET}"
  printf '  %s%s%s\n' "${C_DIM}" "$(printf '%.0s─' {1..76})" "${C_RESET}"

  for line in "${avail_lines[@]}"; do
    IFS=$'\t' read -r sfx b cand <<<"${line}"
    cand_clean="$(hm_php_clean_pkg_ver "${cand}")"
    channel="$(hm_php_branch_channel "${b}" "${cand}")"
    if [[ "${channel}" == "stable" ]]; then
      channel="${C_GREEN}stable${C_RESET} → update-php ${b}"
    else
      channel="${C_YELLOW}${channel}${C_RESET} → update-php ${b}"
    fi
    printf '  %-12s %-18s %b\n' \
      "lsphp${sfx}" \
      "${cand_clean}" \
      "${channel}"
  done
  echo
  echo "  ${C_DIM}Instalacja nowej gałęzi: update-php <ver> (to samo repo LiteSpeed). Po instalacji: php set <ver> na stronie.${C_RESET}"
}

hm_php_clean_pkg_ver() {
  # '1:8.3.14-1+noble' → '8.3.14' ; '8.2.27-1.el9' → '8.2.27'
  # Puste / brak → "-" (nigdy pusty string — IFS=$'\t' read zlewa sąsiadujące tabulatory)
  local raw="${1:-}"
  [[ -n "${raw}" && "${raw}" != "(none)" && "${raw}" != "-" ]] || { printf '-'; return 0; }
  raw="${raw#*:}"
  raw="${raw%%-*}"
  [[ -n "${raw}" ]] || raw="-"
  printf '%s' "${raw}"
}

# hm_pkg_cache_age_info — w lib/pkg.sh

hm_php_pkg_refresh() {
  hm_pkg_refresh
}

# Wypisz: installed_pkg<TAB>candidate_pkg<TAB>candidate_clean<TAB>upgradable_count
hm_php_repo_info_for_suffix() {
  local suffix="$1"
  local main="lsphp${suffix}"
  local -a pkgs=()
  local p inst cand upg_count
  while IFS= read -r p; do
    [[ -n "${p}" ]] && pkgs+=("${p}")
  done < <(hm_php_installed_packages "${suffix}")
  if [[ "${#pkgs[@]}" -eq 0 ]]; then
    IFS=$'\t' read -r inst cand upg_count < <(hm_pkg_status_for "${main}")
  else
    IFS=$'\t' read -r inst cand upg_count < <(hm_pkg_status_for "${main}" "${pkgs[@]}")
  fi
  [[ -n "${inst}" ]] || inst="-"
  [[ -n "${cand}" ]] || cand="-"
  [[ -n "${upg_count}" ]] || upg_count=0
  printf '%s\t%s\t%s\t%s\n' "${inst}" "${cand}" "$(hm_php_clean_pkg_ver "${cand}")" "${upg_count}"
}

hm_php_latest_remote() {
  # najnowszy patch dla gałęzi (np. 8.4 → 8.4.27) z php.net; cache 1h
  local branch="$1"
  [[ -n "${branch}" ]] || return 1
  local cache_dir="${TMP_DIR:-/tmp}/hmtools-php-cache"
  mkdir -m 0700 -p "${cache_dir}" 2>/dev/null || mkdir -p "${cache_dir}" 2>/dev/null || true
  chmod 0700 "${cache_dir}" 2>/dev/null || true
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
  local mode="repo"
  [[ "${1:-}" == "--phpnet" ]] && mode="phpnet"

  local p ver branch latest status
  local root="${OLS_ROOT:-/usr/local/lsws}"
  local -a rows=() branches=()
  local oldnull
  oldnull="$(shopt -p nullglob || true)"
  shopt -s nullglob
  local -a lsphp_dirs=("${root}"/lsphp*)
  eval "${oldnull}" 2>/dev/null || shopt -u nullglob
  local di=0 dtotal="${#lsphp_dirs[@]}"
  for p in "${lsphp_dirs[@]}"; do
    [[ -d "${p}" ]] || continue
    di=$((di + 1))
    hm_progress_bar "${di}" "${dtotal}" "Sprawdzanie $(basename "${p}")..."
    if [[ -x "${p}/bin/php" ]]; then
      ver="$(${p}/bin/php -r 'echo PHP_VERSION;' 2>/dev/null || true)"
      [[ -n "${ver}" ]] || ver="?"
      branch="$(hm_php_branch_of "${ver}")"
      [[ -n "${branch}" ]] || branch="-"
      rows+=("${p}"$'\t'"${ver}"$'\t'"${branch}")
      [[ "${branch}" != "-" ]] && branches+=("${branch}")
    fi
  done

  if [[ "${#rows[@]}" -eq 0 ]]; then
    hm_progress_done
    echo "  (brak lsphp* w ${root})"
  elif [[ "${mode}" == "phpnet" ]]; then
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
      hm_status_line "Pobieranie wersji z php.net..."
      hm_php_prefetch_latests "${uniq[@]}"
    fi
    hm_progress_done

    printf '  %s%-28s %-14s %-14s %s%s\n' \
      "${C_DIM}" "LSPHP" "ZAINSTALOWANA" "NAJNOWSZA" "STATUS" "${C_RESET}"
    printf '  %s%s%s\n' "${C_DIM}" "$(printf '%.0s─' {1..72})" "${C_RESET}"

    local path
    for row in "${rows[@]}"; do
      IFS=$'\t' read -r path ver branch <<<"${row}"
      latest=""
      status="?"
      if [[ -n "${branch}" && "${branch}" != "-" ]]; then
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
    echo "  ${C_DIM}Źródło: php.net (cache ~1h). Domyślnie użyj: php (repo lokalne)${C_RESET}"
  else
    # Tryb domyślny: lokalny menedżer pakietów (apt-cache / dnf -C)
    local path base suffix inst_pkg cand_pkg cand_clean upg_count repo_col
    local -a repo_rows=()
    di=0
    dtotal="${#rows[@]}"
    for row in "${rows[@]}"; do
      di=$((di + 1))
      IFS=$'\t' read -r path ver branch <<<"${row}"
      base="$(basename "${path}")"
      suffix="${base#lsphp}"
      hm_progress_bar "${di}" "${dtotal}" "Repo: ${base}..."
      IFS=$'\t' read -r inst_pkg cand_pkg cand_clean upg_count < <(hm_php_repo_info_for_suffix "${suffix}")
      [[ -n "${inst_pkg}" ]] || inst_pkg="-"
      [[ -n "${cand_pkg}" ]] || cand_pkg="-"
      [[ -n "${cand_clean}" ]] || cand_clean="-"
      [[ -n "${upg_count}" ]] || upg_count=0
      [[ -n "${branch}" ]] || branch="-"
      repo_rows+=("${path}"$'\t'"${ver}"$'\t'"${branch}"$'\t'"${inst_pkg}"$'\t'"${cand_pkg}"$'\t'"${cand_clean}"$'\t'"${upg_count}")
    done
    hm_progress_done

    printf '  %s%-12s %-15s %-18s %s%s\n' \
      "${C_DIM}" "LSPHP" "ZAINSTALOWANA" "W REPO (UPDATE)" "STATUS" "${C_RESET}"
    printf '  %s%s%s\n' "${C_DIM}" "$(printf '%.0s─' {1..76})" "${C_RESET}"

    for row in "${repo_rows[@]}"; do
      IFS=$'\t' read -r path ver branch inst_pkg cand_pkg cand_clean upg_count <<<"${row}"
      base="$(basename "${path}")"
      [[ -n "${upg_count}" ]] || upg_count=0
      [[ -n "${cand_clean}" ]] || cand_clean="-"
      [[ -n "${branch}" ]] || branch="-"
      repo_col="—"
      if [[ "${cand_clean}" != "-" ]]; then
        repo_col="${cand_clean}"
      fi
      if [[ "${upg_count}" -gt 0 && "${cand_clean}" != "-" && "${cand_clean}" == "${ver}" ]]; then
        repo_col="${cand_clean} (+${upg_count} pakiety)"
      fi

      status="${C_GREEN}aktualna${C_RESET}"
      if [[ "${cand_clean}" == "-" || "${cand_pkg}" == "-" || "${cand_pkg}" == "(none)" ]]; then
        status="${C_DIM}brak danych repo${C_RESET}"
        repo_col="—"
      elif [[ "${cand_clean}" != "-" && "${ver}" != "${cand_clean}" ]] && hm_version_is_newer "${ver}" "${cand_clean}" 2>/dev/null; then
        if [[ "${branch}" != "-" ]]; then
          status="${C_YELLOW}dostępna aktualizacja → ${cand_clean} (update-php ${branch})${C_RESET}"
        else
          status="${C_YELLOW}dostępna aktualizacja → ${cand_clean}${C_RESET}"
        fi
      elif [[ "${upg_count}" -gt 0 && "${inst_pkg}" != "${cand_pkg}" ]]; then
        status="${C_YELLOW}dostępna aktualizacja pakietów → ${cand_pkg}${C_RESET}"
      elif [[ "${inst_pkg}" != "-" && "${inst_pkg}" != "(none)" && "${cand_pkg}" != "-" && "${cand_pkg}" != "(none)" && "${inst_pkg}" != "${cand_pkg}" ]]; then
        if hm_pkg_version_gt "${cand_pkg}" "${inst_pkg}" 2>/dev/null; then
          status="${C_YELLOW}dostępna aktualizacja pakietów → ${cand_pkg}${C_RESET}"
        fi
      fi

      printf '  %-12s %-15s %-18s %b\n' \
        "${base}" \
        "${ver}" \
        "${repo_col}" \
        "${status}"
      printf '  %s%s%s\n' "${C_DIM}" "${path}" "${C_RESET}"
    done
    echo
    local age_info pm_label
    age_info="$(hm_pkg_cache_age_info)"
    pm_label="$(hm_pkg_label)"
    echo "  ${C_DIM}Źródło: repozytorium pakietów (${pm_label}, indeks sprzed ${age_info}). Odśwież: php --refresh${C_RESET}"
  fi

  # Nowsze gałęzie w repo (np. lsphp86), których jeszcze nie ma lokalnie
  local -a uniq_inst=()
  local -A seen_inst=()
  local ib
  for ib in "${branches[@]}"; do
    [[ -n "${ib}" && "${ib}" != "-" ]] || continue
    [[ -z "${seen_inst[$ib]:-}" ]] || continue
    seen_inst[$ib]=1
    uniq_inst+=("${ib}")
  done
  hm_php_print_installable_newer "${uniq_inst[@]}"
}
