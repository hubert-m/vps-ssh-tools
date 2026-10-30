#!/usr/bin/env bash
# PHP: update-php

cmd_update_php() {
  local arg="${1:-}"
  [[ -n "${arg}" ]] || {
    hm_err "Użycie: update-php <wersja>   np. update-php 8.4"
    hm_info "Alias: php update 8.4"
    return 1
  }

  local branch suffix root path cur="?"
  local inst_pkg cand_pkg cand_clean upg_count
  if ! branch="$(hm_php_normalize_branch "${arg}")"; then
    hm_err "Nieprawidłowa wersja: ${arg} (oczekiwane np. 8.4, 84, lsphp84)"
    return 1
  fi
  suffix="$(hm_php_lsphp_suffix "${branch}")"
  root="${OLS_ROOT:-/usr/local/lsws}"
  path="${root}/lsphp${suffix}"

  if [[ -x "${path}/bin/php" ]]; then
    cur="$("${path}/bin/php" -r 'echo PHP_VERSION;' 2>/dev/null || echo "?")"
  else
    cur="(brak ${path})"
  fi
  IFS=$'\t' read -r inst_pkg cand_pkg cand_clean upg_count < <(hm_php_repo_info_for_suffix "${suffix}")
  [[ -n "${upg_count}" ]] || upg_count=0

  echo "${C_BOLD}Aktualizacja LSPHP ${branch}${C_RESET}"
  echo "  Katalog         : ${path}"
  echo "  Zainstalowana   : ${cur} (pakiet: ${inst_pkg:-—})"
  echo "  Dostępna w repo : ${cand_clean:-—} (pakiet: ${cand_pkg:-—})"
  echo "  Pakiety         : lsphp${suffix}*"
  echo

  local -a pkgs=()
  local p
  while IFS= read -r p; do
    [[ -n "${p}" ]] && pkgs+=("${p}")
  done < <(hm_php_installed_packages "${suffix}")

  if [[ "${#pkgs[@]}" -gt 0 ]]; then
    echo "  Znalezione pakiety (${#pkgs[@]}):"
    local i=0
    for p in "${pkgs[@]}"; do
      i=$((i + 1))
      [[ "${i}" -le 12 ]] && echo "    - ${p}"
    done
    [[ "${#pkgs[@]}" -gt 12 ]] && echo "    … (+$(( ${#pkgs[@]} - 12 )) więcej)"
    echo
  else
    hm_warn "Brak zainstalowanych pakietów lsphp${suffix}* — spróbuję instalacji z repozytorium."
    echo
  fi

  local already_current=0
  if [[ "${inst_pkg}" != "-" && "${inst_pkg}" != "(none)" && "${cand_pkg}" != "-" && "${cand_pkg}" != "(none)" && "${inst_pkg}" == "${cand_pkg}" && "${upg_count}" -eq 0 ]]; then
    already_current=1
  fi

  if [[ "${already_current}" -eq 1 ]]; then
    hm_ok "W lokalnym indeksie pakiet lsphp${suffix} jest już w najnowszej wersji (${cur})."
    if hm_confirm "Odświeżyć indeks repozytoriów i sprawdzić ponownie?"; then
      hm_php_pkg_refresh || return $?
      IFS=$'\t' read -r inst_pkg cand_pkg cand_clean upg_count < <(hm_php_repo_info_for_suffix "${suffix}")
      [[ -n "${upg_count}" ]] || upg_count=0
      echo
      echo "  Zainstalowana   : ${cur} (pakiet: ${inst_pkg:-—})"
      echo "  Dostępna w repo : ${cand_clean:-—} (pakiet: ${cand_pkg:-—})"
      echo
      if [[ "${inst_pkg}" == "${cand_pkg}" && "${upg_count}" -eq 0 ]]; then
        hm_ok "Po odświeżeniu nadal brak nowszej wersji w repo (${cur})."
      fi
    else
      hm_info "Anulowano."
      return 0
    fi
  fi

  if ! hm_confirm_plan "update-php — LSPHP ${branch}" \
    "Aktualizacja pakietów z repozytorium LiteSpeed." \
    "Odświeżenie repozytorium pakietów" \
    "Aktualizacja pakietów lsphp${suffix}* z wersji ${inst_pkg:-${cur}} do ${cand_pkg:-${cand_clean:-?}}" \
    "Przeładowanie OpenLiteSpeed (ols reload)"; then
    return 0
  fi

  if ! hm_pkg_id >/dev/null 2>&1; then
    hm_err "Nie wykryto apt-get / dnf / yum."
    return 1
  fi

  set +e
  hm_pkg_refresh
  if [[ "${#pkgs[@]}" -gt 0 ]]; then
    hm_info "Aktualizacja pakietów lsphp${suffix}* (${#pkgs[@]})…"
    hm_pkg_upgrade "${pkgs[@]}"
  else
    hm_info "Instalacja lsphp${suffix} z repozytorium…"
    hm_php_install_branch_packages "${suffix}"
  fi
  local rc=$?
  set -e

  if [[ "${rc}" -ne 0 ]]; then
    hm_err "Aktualizacja pakietów zakończyła się kodem ${rc}."
    hm_info "Sprawdź repozytorium LiteSpeed (repo.litespeed.sh) i logi apt/dnf."
    return "${rc}"
  fi

  hm_info "Reload OpenLiteSpeed…"
  if hm_ols_reload_soft; then
    hm_ok "OLS przeładowany."
  else
    hm_warn "Nie udało się przeładować OLS — zrób ręcznie: ols reload"
  fi

  local newv="?"
  local new_inst new_cand new_clean new_upg
  if [[ -x "${path}/bin/php" ]]; then
    newv="$("${path}/bin/php" -r 'echo PHP_VERSION;' 2>/dev/null || echo "?")"
  fi
  IFS=$'\t' read -r new_inst new_cand new_clean new_upg < <(hm_php_repo_info_for_suffix "${suffix}")
  echo
  echo "  Było : ${cur} (${inst_pkg:-—})"
  echo "  Jest : ${newv} (${new_inst:-—})"
  echo "  Repo : ${new_clean:-—} (${new_cand:-—})"
  if [[ -n "${new_cand}" && "${new_cand}" != "-" && "${new_inst}" == "${new_cand}" ]]; then
    hm_ok "PHP ${branch} jest aktualne względem repozytorium."
  else
    hm_ok "Aktualizacja zakończona."
  fi
}
