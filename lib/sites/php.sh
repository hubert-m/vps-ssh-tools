#!/usr/bin/env bash
# Sites: LSPHP — wersje z menedżera pakietów (+ opcjonalnie php.net)

hm_php_branch_of() {
  # 8.4.18 → 8.4
  local v="$1"
  printf '%s' "${v}" | grep -oE '^[0-9]+\.[0-9]+' | head -1
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

hm_pkg_cache_age_info() {
  local f="" mtime now age_s
  now="$(date +%s)"
  if [[ -f /var/cache/apt/pkgcache.bin ]]; then
    f="/var/cache/apt/pkgcache.bin"
  elif [[ -d /var/lib/apt/lists ]]; then
    f="$(find /var/lib/apt/lists -type f 2>/dev/null | head -1 || true)"
  elif [[ -d /var/cache/dnf ]]; then
    f="$(find /var/cache/dnf -type f 2>/dev/null | head -1 || true)"
  elif [[ -d /var/cache/yum ]]; then
    f="$(find /var/cache/yum -type f 2>/dev/null | head -1 || true)"
  fi
  [[ -n "${f}" && -e "${f}" ]] || { printf 'nieznany'; return 0; }
  mtime="$(stat -c %Y "${f}" 2>/dev/null || echo 0)"
  age_s=$((now - mtime))
  [[ "${age_s}" -lt 0 ]] && age_s=0
  if [[ "${age_s}" -lt 120 ]]; then
    printf 'przed chwilą'
  elif [[ "${age_s}" -lt 3600 ]]; then
    printf '%s min temu' "$((age_s / 60))"
  elif [[ "${age_s}" -lt 86400 ]]; then
    printf '%s godz. temu' "$((age_s / 3600))"
  else
    printf '%s dni temu' "$((age_s / 86400))"
  fi
}

hm_php_pkg_refresh() {
  local pm
  pm="$(hm_pkg_manager 2>/dev/null || true)"
  case "${pm}" in
    apt)
      hm_info "Odświeżanie list pakietów (apt-get update)…"
      hm_run apt-get update
      ;;
    dnf)
      hm_info "Odświeżanie cache (dnf makecache)…"
      hm_run dnf makecache -y || true
      ;;
    yum)
      hm_info "Odświeżanie cache (yum makecache)…"
      hm_run yum makecache -y || true
      ;;
    *)
      hm_err "Brak apt-get / dnf / yum — nie mogę odświeżyć indeksu."
      return 1
      ;;
  esac
}

# Wypisz: installed_pkg<TAB>candidate_pkg<TAB>candidate_clean<TAB>upgradable_count
hm_php_repo_info_for_suffix() {
  local suffix="$1"
  local pm
  pm="$(hm_pkg_manager 2>/dev/null || echo '')"

  case "${pm}" in
    apt)
      local -a pkgs=()
      local p
      while IFS= read -r p; do
        [[ -n "${p}" ]] && pkgs+=("${p}")
      done < <(hm_php_installed_packages "${suffix}")
      [[ "${#pkgs[@]}" -eq 0 ]] && pkgs=("lsphp${suffix}")

      local policy_out inst cand upg_count=0
      policy_out="$(LC_ALL=C apt-cache policy "${pkgs[@]}" 2>/dev/null || true)"
      IFS=$'\t' read -r inst cand upg_count < <(
        awk -v main="lsphp${suffix}:" '
          /^[^ ]/ { pkg=$1; inst=""; cand="" }
          /^[[:space:]]+Installed:/ { inst=$2 }
          /^[[:space:]]+Candidate:/ {
            cand=$2
            if (pkg == main || main_inst == "") {
              main_inst=inst; main_cand=cand
            }
            if (inst != "" && inst != "(none)" && cand != "" && cand != "(none)" && inst != cand) {
              upg++
            }
          }
          END {
            printf "%s\t%s\t%d\n", (main_inst ? main_inst : "-"), (main_cand ? main_cand : "-"), upg+0
          }
        ' <<<"${policy_out}"
      )
      [[ -n "${inst}" ]] || inst="-"
      [[ -n "${cand}" ]] || cand="-"
      [[ -n "${upg_count}" ]] || upg_count=0

      # dpkg: Candidate nowszy od Installed (rebuildy -1 → -2)
      if [[ "${inst}" != "-" && "${inst}" != "(none)" && "${cand}" != "-" && "${cand}" != "(none)" ]]; then
        if hm_have_cmd dpkg && dpkg --compare-versions "${cand}" gt "${inst}" 2>/dev/null; then
          [[ "${upg_count}" -eq 0 ]] && upg_count=1
        fi
      fi

      printf '%s\t%s\t%s\t%s\n' "${inst}" "${cand}" "$(hm_php_clean_pkg_ver "${cand}")" "${upg_count:-0}"
      ;;
    dnf|yum)
      local inst="-" cand="" clean_cand upg_count=0 chk
      if hm_have_cmd rpm; then
        inst="$(rpm -q --qf '%{VERSION}-%{RELEASE}' "lsphp${suffix}" 2>/dev/null || echo '-')"
        [[ "${inst}" == *"not installed"* ]] && inst="-"
      fi
      # lokalny cache (-C); check-update zwraca tylko pakiety do aktualizacji
      chk="$(LC_ALL=C "${pm}" -q -C check-update "lsphp${suffix}*" 2>/dev/null || true)"
      cand="$(printf '%s\n' "${chk}" | awk -v p="^lsphp${suffix}" '$1 ~ p { print $2; exit }')"
      upg_count="$(printf '%s\n' "${chk}" | awk -v p="^lsphp${suffix}" '$1 ~ p { c++ } END { print c+0 }')"
      if [[ -z "${cand}" ]]; then
        cand="${inst}"
      fi
      [[ -n "${cand}" ]] || cand="-"
      clean_cand="$(hm_php_clean_pkg_ver "${cand}")"
      printf '%s\t%s\t%s\t%s\n' "${inst}" "${cand}" "${clean_cand}" "${upg_count:-0}"
      ;;
    *)
      printf -- '-\t-\t-\t0\n'
      ;;
  esac
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
    return 0
  fi

  if [[ "${mode}" == "phpnet" ]]; then
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
    return 0
  fi

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
      if hm_have_cmd dpkg && dpkg --compare-versions "${cand_pkg}" gt "${inst_pkg}" 2>/dev/null; then
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
  pm_label="apt-cache"
  case "$(hm_pkg_manager 2>/dev/null || true)" in
    dnf) pm_label="dnf" ;;
    yum) pm_label="yum" ;;
  esac
  echo "  ${C_DIM}Źródło: repozytorium pakietów (${pm_label}, indeks sprzed ${age_info}). Odśwież: php --refresh${C_RESET}"
}
