#!/usr/bin/env bash
# Komenda: health / php (global)

cmd_health() {
  hm_detect_all
  echo "${C_BOLD}Health check${C_RESET}"
  echo "Host     : $(hostname -f 2>/dev/null || hostname)"
  echo "Panel    : ${PANEL}"
  echo "Webserver: ${WEBSERVER}"
  echo "DB       : ${DB_ENGINE}"
  echo

  echo -n "Load     : "
  cat /proc/loadavg 2>/dev/null || uptime

  if hm_have_cmd free; then
    echo
    free -h
  fi

  echo
  echo "Dysk     : used $(hm_disk_used_percent /)%  free $(hm_disk_free_percent /)%"
  df -h / 2>/dev/null | tail -1

  echo
  local ols_ok="down" mysql_ok="down"
  if pgrep -x lshttpd >/dev/null 2>&1 || pgrep -x openlitespeed >/dev/null 2>&1; then
    ols_ok="up"
  elif [[ -x "${OLS_CTRL}" ]] && "${OLS_CTRL}" status 2>/dev/null | grep -qi running; then
    ols_ok="up"
  fi
  if hm_mysql_exec -e "SELECT 1;" >/dev/null 2>&1; then
    mysql_ok="up"
  fi
  echo "OLS      : ${ols_ok}"
  echo "MySQL    : ${mysql_ok}"

  echo
  echo "${C_BOLD}Certyfikaty wygasające < 14 dni${C_RESET}"
  hm_discover_sites
  local domain cert status days expiry found=0
  local total="${#HM_SITES_LIST[@]}" i=0
  local -a alerts=()
  for domain in "${HM_SITES_LIST[@]}"; do
    i=$((i + 1))
    hm_progress_bar "${i}" "${total}" "Sprawdzanie certyfikatu SSL: ${domain}"
    cert="$(hm_ssl_paths_for_domain "${domain}" 2>/dev/null || true)"
    [[ -n "${cert}" ]] || continue
    status="$(hm_ssl_status "${cert}" 14)"
    case "${status}" in
      expired|soon)
        found=1
        days="$(hm_ssl_days_left "${cert}" 2>/dev/null || echo "?")"
        expiry="$(hm_ssl_expiry "${cert}")"
        if [[ "${status}" == "expired" ]]; then
          alerts+=("EXPIRED|${domain}|${expiry}|${days}")
        else
          alerts+=("SOON|${domain}|${expiry}|${days}")
        fi
        ;;
    esac
  done
  hm_progress_done
  local a
  for a in "${alerts[@]}"; do
    IFS='|' read -r status domain expiry days <<<"${a}"
    if [[ "${status}" == "EXPIRED" ]]; then
      hm_err "  EXPIRED  ${domain}  (${expiry}, ${days} dni)"
    else
      hm_warn "  SOON     ${domain}  (${expiry}, ${days} dni)"
    fi
  done
  if [[ "${found}" -eq 0 ]]; then
    hm_ok "Brak certyfikatów wygasających w ciągu 14 dni."
  fi

  echo
  # skrócony audyt portów (pełny: security ports)
  if hm_have_cmd ss; then
    echo "${C_BOLD}Publiczne porty wrażliwe${C_RESET} ${C_DIM}(security ports)${C_RESET}"
    local hit=0
    while IFS= read -r line; do
      [[ -n "${line}" ]] || continue
      hit=1
      hm_warn "  ${line}"
    done < <(ss -lntup 2>/dev/null | awk '
      NR==1 { next }
      $4 ~ /^0\.0\.0\.0:|^\[::\]:|^\*:/ {
        n=split($4,a,":"); port=a[n]
        if (port ~ /^(3306|5432|6379|7080|8090|3000|3001|3002|3003)$/)
          print $4, $NF
      }
    ')
    if [[ "${hit}" -eq 0 ]]; then
      hm_ok "Brak typowych wrażliwych portów na 0.0.0.0."
    fi
  fi
}

cmd_php() {
  local sub="${1:-}"
  case "${sub}" in
    update|upgrade)
      shift || true
      cmd_update_php "$@"
      ;;
    set|use-version|switch)
      shift || true
      hm_php_set_site "$@"
      ;;
    ext|modules|module|extensions)
      shift || true
      hm_php_ext_cmd "$@"
      ;;
    ini|conf)
      shift || true
      hm_php_ini_cmd "$@"
      ;;
    restart|reload-workers|kill)
      shift || true
      hm_php_restart "$@"
      ;;
    ps|proc|procs|processes)
      shift || true
      hm_php_ps "$@"
      ;;
    --refresh|-r|check-update)
      hm_php_pkg_refresh || return $?
      echo
      echo "${C_BOLD}Dostępne LSPHP${C_RESET} ${C_DIM}(+ porównanie z repozytorium)${C_RESET}"
      echo
      hm_list_available_php
      ;;
    --phpnet)
      echo "${C_BOLD}Dostępne LSPHP${C_RESET} ${C_DIM}(+ porównanie z php.net)${C_RESET}"
      echo
      hm_list_available_php --phpnet
      ;;
    help|-h|--help)
      hm_help_topic php
      ;;
    "")
      if [[ -n "${HM_SITE_DOMAIN}" ]]; then
        cmd_site_php
      else
        echo "${C_BOLD}Dostępne LSPHP${C_RESET} ${C_DIM}(+ porównanie z repozytorium)${C_RESET}"
        echo
        hm_list_available_php
      fi
      ;;
    *)
      # php 8.3 → traktuj jak listing dla wersji? nie — tylko znane sub
      hm_err "Nieznana podkomenda: ${sub}. Zobacz: php help"
      return 1
      ;;
  esac
}

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

  local pm
  if ! pm="$(hm_pkg_manager)"; then
    hm_err "Nie wykryto apt-get / dnf / yum."
    return 1
  fi

  set +e
  case "${pm}" in
    apt)
      hm_info "apt-get update…"
      hm_run apt-get update
      if [[ "${#pkgs[@]}" -gt 0 ]]; then
        hm_info "apt-get install --only-upgrade (${#pkgs[@]} pakietów)…"
        DEBIAN_FRONTEND=noninteractive hm_run apt-get install --only-upgrade -y "${pkgs[@]}"
      else
        hm_info "apt-get install lsphp${suffix} (+ typowe rozszerzenia)…"
        DEBIAN_FRONTEND=noninteractive hm_run apt-get install -y \
          "lsphp${suffix}" \
          "lsphp${suffix}-common" \
          "lsphp${suffix}-mysql" \
          "lsphp${suffix}-curl" \
          "lsphp${suffix}-opcache" \
          "lsphp${suffix}-imap" \
          "lsphp${suffix}-msgpack" \
          "lsphp${suffix}-redis" \
          "lsphp${suffix}-intl" \
          "lsphp${suffix}-pgsql" \
          "lsphp${suffix}-sqlite3" \
          "lsphp${suffix}-ldap" || \
        DEBIAN_FRONTEND=noninteractive hm_run apt-get install -y "lsphp${suffix}" "lsphp${suffix}-common" "lsphp${suffix}-mysql"
      fi
      ;;
    dnf)
      hm_info "dnf makecache…"
      hm_run dnf makecache -y || true
      if [[ "${#pkgs[@]}" -gt 0 ]]; then
        hm_info "dnf update lsphp${suffix}*…"
        hm_run dnf update -y "lsphp${suffix}*"
      else
        hm_info "dnf install lsphp${suffix}*…"
        hm_run dnf install -y "lsphp${suffix}*"
      fi
      ;;
    yum)
      hm_info "yum makecache…"
      hm_run yum makecache -y || true
      if [[ "${#pkgs[@]}" -gt 0 ]]; then
        hm_info "yum update lsphp${suffix}*…"
        hm_run yum update -y "lsphp${suffix}*"
      else
        hm_info "yum install lsphp${suffix}*…"
        hm_run yum install -y "lsphp${suffix}*"
      fi
      ;;
  esac
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
