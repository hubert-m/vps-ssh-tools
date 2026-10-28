#!/usr/bin/env bash
# Sites: zarządzanie LSPHP per strona (set / ext / ini / restart / ps)

hm_php_normalize_branch() {
  # 8.4 | 84 | lsphp84 | PHP8.4 → 8.4
  local raw="$1"
  raw="$(printf '%s' "${raw}" | tr '[:upper:]' '[:lower:]')"
  raw="${raw#php}"
  raw="${raw#lsphp}"
  raw="$(printf '%s' "${raw}" | tr -cd '0-9.')"
  if [[ "${raw}" =~ ^[0-9]+\.[0-9]+$ ]]; then
    printf '%s' "${raw}"
    return 0
  fi
  if [[ "${raw}" =~ ^[0-9][0-9]$ ]]; then
    printf '%s.%s' "${raw:0:1}" "${raw:1:1}"
    return 0
  fi
  return 1
}

hm_php_lsphp_suffix() {
  # 8.4 → 84
  local branch="$1"
  local maj="${branch%%.*}"
  local min="${branch#*.}"
  printf '%s%s' "${maj}" "${min}"
}

hm_pkg_manager() {
  if hm_have_cmd apt-get; then
    echo apt
  elif hm_have_cmd dnf; then
    echo dnf
  elif hm_have_cmd yum; then
    echo yum
  else
    return 1
  fi
}

hm_php_installed_packages() {
  local suffix="$1"
  if hm_have_cmd dpkg-query; then
    dpkg-query -W -f='${Package}\n' "lsphp${suffix}*" 2>/dev/null | grep -E "^lsphp${suffix}" || true
    return 0
  fi
  if hm_have_cmd rpm; then
    rpm -qa --qf '%{NAME}\n' "lsphp${suffix}*" 2>/dev/null | grep -E "^lsphp${suffix}" || true
    return 0
  fi
  return 1
}

# hm_ols_reload_soft — w lib/detect.sh

hm_php_root_for_branch() {
  local branch="$1" suffix
  suffix="$(hm_php_lsphp_suffix "${branch}")"
  echo "${OLS_ROOT:-/usr/local/lsws}/lsphp${suffix}"
}

hm_php_bin_for_branch() {
  local branch="$1" root
  root="$(hm_php_root_for_branch "${branch}")"
  if [[ -x "${root}/bin/php" ]]; then
    echo "${root}/bin/php"
    return 0
  fi
  if [[ -x "${root}/bin/lsphp" ]]; then
    echo "${root}/bin/lsphp"
    return 0
  fi
  return 1
}

hm_php_branch_for_site() {
  # bieżąca gałąź strony lub argument
  local arg="${1:-}"
  local branch
  if [[ -n "${arg}" ]]; then
    hm_php_normalize_branch "${arg}"
    return
  fi
  if [[ -n "${HM_SITE_PHP:-}" && "${HM_SITE_PHP}" != "?" ]]; then
    if branch="$(hm_php_normalize_branch "${HM_SITE_PHP}" 2>/dev/null)"; then
      printf '%s' "${branch}"
      return 0
    fi
  fi
  return 1
}

hm_php_ini_path() {
  local branch="$1" bin ini
  bin="$(hm_php_bin_for_branch "${branch}")" || return 1
  ini="$("${bin}" -i 2>/dev/null | awk -F': ' '/^Loaded Configuration File/{print $2; exit}' | tr -d '[:space:]')"
  if [[ -n "${ini}" && "${ini}" != "(none)" && -f "${ini}" ]]; then
    echo "${ini}"
    return 0
  fi
  # typowe ścieżki LiteSpeed
  local root suffix
  root="$(hm_php_root_for_branch "${branch}")"
  suffix="$(hm_php_lsphp_suffix "${branch}")"
  for ini in \
    "${root}/etc/php/${branch}/litespeed/php.ini" \
    "${root}/etc/php.ini" \
    "/usr/local/lsws/lsphp${suffix}/etc/php/${branch}/litespeed/php.ini"
  do
    if [[ -f "${ini}" ]]; then
      echo "${ini}"
      return 0
    fi
  done
  return 1
}

# --- php set -----------------------------------------------------------------

hm_php_set_vhost() {
  local vhost="$1" newsuffix="$2"
  [[ -f "${vhost}" ]] || return 1
  if ! grep -Eq 'lsphp[0-9]{2}' "${vhost}"; then
    hm_warn "Vhost nie zawiera odwołań lsphpXX — pomijam edycję pliku."
    return 1
  fi
  cp -a "${vhost}" "${vhost}.bak.hmtools" 2>/dev/null || cp "${vhost}" "${vhost}.bak.hmtools"
  sed -E -i "s/lsphp[0-9]{2}/lsphp${newsuffix}/g" "${vhost}"
  hm_ok "Zaktualizowano vhost: ${vhost} (backup: .bak.hmtools)"
}

hm_php_set_cyberpanel() {
  local domain="$1" branch="$2" suffix
  suffix="$(hm_php_lsphp_suffix "${branch}")"
  if hm_have_cmd cyberpanel; then
    # warianty CLI CyberPanel
    if cyberpanel changePHP --domainName "${domain}" --php "PHP ${branch}" >/dev/null 2>&1 \
      || cyberpanel changePHP --domainName "${domain}" --php "lsphp${suffix}" >/dev/null 2>&1 \
      || cyberpanel changePHP --domainName "${domain}" --php "${branch}" >/dev/null 2>&1; then
      hm_ok "CyberPanel changePHP → PHP ${branch}"
      return 0
    fi
    hm_warn "cyberpanel changePHP nie powiódł się — próbuję SQL."
  fi
  if ! hm_is_valid_domain "${domain}"; then
    hm_err "Nieprawidłowa domena: ${domain}"
    return 1
  fi
  local q sel
  q="$(hm_sql_quote "${domain}")"
  sel="$(hm_sql_quote "PHP ${branch}")"
  if hm_mysql_exec cyberpanel -e \
    "UPDATE websiteFunctions_websites SET phpSelection=${sel} WHERE domain=${q} LIMIT 1;" >/dev/null 2>&1; then
    hm_ok "Zaktualizowano phpSelection w CyberPanel DB."
    return 0
  fi
  hm_mysql_exec cyberpanel -e \
    "UPDATE websites_website SET phpSelection=${sel} WHERE domainName=${q} LIMIT 1;" >/dev/null 2>&1 || true
}

hm_php_set_site() {
  local arg="${1:-}"
  [[ -n "${HM_SITE_DOMAIN}" ]] || { hm_err "php set wymaga kontekstu: use <domena>"; return 1; }
  [[ -n "${arg}" ]] || { hm_err "Użycie: php set <wersja>   np. php set 8.3"; return 1; }

  local branch suffix root bin
  if ! branch="$(hm_php_normalize_branch "${arg}")"; then
    hm_err "Nieprawidłowa wersja: ${arg}"
    return 1
  fi
  suffix="$(hm_php_lsphp_suffix "${branch}")"
  root="$(hm_php_root_for_branch "${branch}")"
  if ! bin="$(hm_php_bin_for_branch "${branch}")"; then
    hm_err "Brak zainstalowanego LSPHP: ${root}/bin/php (lub lsphp)"
    hm_info "Zainstaluj: update-php ${branch}"
    return 1
  fi

  local -a plan_steps=(
    "Kopia ${HM_SITE_VHOST:-vhost}.bak.hmtools i podmiana handlera lsphp* na lsphp${suffix} w ${HM_SITE_VHOST:--}"
    "Aktualizacja phpSelection w bazie CyberPanel (jeśli dotyczy)"
    "Przeładowanie OpenLiteSpeed (ols reload)"
    "Zatrzymanie starych procesów workerów lsphp użytkownika ${HM_SITE_USER:--} (pkill)"
  )
  if ! hm_confirm_plan "php set — ${HM_SITE_DOMAIN} → ${branch}" \
    "Było: ${HM_SITE_PHP:--}; będzie: ${branch} (${bin})." \
    "${plan_steps[@]}"; then
    return 0
  fi

  local ok=0
  if [[ -n "${HM_SITE_VHOST}" && -f "${HM_SITE_VHOST}" ]]; then
    hm_php_set_vhost "${HM_SITE_VHOST}" "${suffix}" && ok=1
  else
    hm_warn "Brak pliku vhost w kontekście."
  fi

  hm_detect_all 2>/dev/null || true
  if [[ "${PANEL:-}" == "cyberpanel" ]]; then
    hm_php_set_cyberpanel "${HM_SITE_DOMAIN}" "${branch}" && ok=1
  fi

  if [[ "${ok}" -eq 0 ]]; then
    hm_err "Nie udało się zmienić wersji PHP (brak vhost / CyberPanel)."
    return 1
  fi

  hm_info "Reload OLS…"
  hm_ols_reload_soft || hm_warn "ols reload nieudany"
  # kill workerów użytkownika strony — Detached Mode
  if [[ -n "${HM_SITE_USER:-}" ]]; then
    pkill -u "${HM_SITE_USER}" -f 'lsphp' 2>/dev/null || true
  fi

  HM_SITE_PHP="${branch}"
  hm_ok "PHP strony ${HM_SITE_DOMAIN} → ${branch}"
}

# --- php ext -----------------------------------------------------------------

HM_PHP_KEY_EXTS=(imagick redis memcached intl zip soap gd mbstring bcmath opcache apcu curl mysqlnd mysqli pdo_mysql)

hm_php_ext_list() {
  local arg="${1:-}" branch bin
  if ! branch="$(hm_php_branch_for_site "${arg}")"; then
    hm_err "Podaj wersję (php ext 8.3) lub wejdź w kontekst strony."
    return 1
  fi
  bin="$(hm_php_bin_for_branch "${branch}")" || {
    hm_err "Brak binariów dla PHP ${branch}"
    return 1
  }

  echo "${C_BOLD}PHP modules — ${branch}${C_RESET}"
  echo "  Bin: ${bin}"
  echo

  local -A loaded=()
  local m
  while IFS= read -r m; do
    [[ -n "${m}" ]] || continue
    [[ "${m}" == "["* ]] && continue
    loaded["${m}"]=1
  done < <("${bin}" -m 2>/dev/null || true)

  echo "  ${C_BOLD}Kluczowe rozszerzenia${C_RESET}"
  local ext st
  for ext in "${HM_PHP_KEY_EXTS[@]}"; do
    if [[ -n "${loaded[$ext]:-}" ]]; then
      st="${C_GREEN}OK${C_RESET}"
    else
      st="${C_RED}BRAK${C_RESET}"
    fi
    printf '    %-14s %b\n' "${ext}" "${st}"
  done
  echo
  echo "  ${C_BOLD}Wszystkie (${#loaded[@]})${C_RESET}"
  "${bin}" -m 2>/dev/null | sed 's/^/    /' || true
}

hm_php_ext_install() {
  local name="${1:-}" ver="${2:-}"
  [[ -n "${name}" ]] || { hm_err "Użycie: php ext install <nazwa> [wersja]"; return 1; }

  local branch suffix pkg pm
  if ! branch="$(hm_php_branch_for_site "${ver}")"; then
    hm_err "Podaj wersję lub wejdź w kontekst (php ext install redis 8.3)."
    return 1
  fi
  suffix="$(hm_php_lsphp_suffix "${branch}")"
  # nazwa pakietu: lsphp84-redis (bez php- prefix)
  name="$(printf '%s' "${name}" | sed -E 's/^php-//; s/^lsphp[0-9]+-//')"
  pkg="lsphp${suffix}-${name}"

  if ! pm="$(hm_pkg_manager)"; then
    hm_err "Brak apt-get / dnf / yum."
    return 1
  fi
  local refresh_step="Odświeżenie indeksów pakietów (dnf/yum)"
  [[ "${pm}" == "apt" ]] && refresh_step="Odświeżenie indeksów pakietów (apt-get update)"
  if ! hm_confirm_plan "php ext install — ${pkg}" \
    "Instalacja rozszerzenia PHP z repozytorium LiteSpeed." \
    "${refresh_step}" \
    "Instalacja pakietu ${pkg}" \
    "Przeładowanie OpenLiteSpeed (ols reload)" \
    "Restart workerów lsphp"; then
    return 0
  fi

  set +e
  case "${pm}" in
    apt)
      hm_run apt-get update
      DEBIAN_FRONTEND=noninteractive hm_run apt-get install -y "${pkg}"
      ;;
    dnf) hm_run dnf install -y "${pkg}" ;;
    yum) hm_run yum install -y "${pkg}" ;;
  esac
  local rc=$?
  set -e
  [[ "${rc}" -eq 0 ]] || { hm_err "Instalacja ${pkg} nieudana (rc=${rc})."; return "${rc}"; }

  hm_ols_reload_soft || true
  hm_php_restart_workers
  hm_ok "Zainstalowano ${pkg}"
  hm_php_ext_list "${branch}"
}

hm_php_ext_cmd() {
  local sub="${1:-list}"
  shift || true
  case "${sub}" in
    ""|list|ls|modules|m) hm_php_ext_list "$@" ;;
    install|add|i) hm_php_ext_install "$@" ;;
    help|-h|--help)
      echo "Użycie: php ext [list] [wersja] | php ext install <nazwa> [wersja]"
      ;;
    *)
      # php ext 8.3 → list dla wersji
      if hm_php_normalize_branch "${sub}" >/dev/null 2>&1; then
        hm_php_ext_list "${sub}"
      else
        hm_err "Nieznane: php ext ${sub}. Zobacz: php help"
        return 1
      fi
      ;;
  esac
}

# --- php ini -----------------------------------------------------------------

hm_php_ini_show_overrides() {
  local domain="${HM_SITE_DOMAIN:-}" docroot="${HM_SITE_DOCROOT:-}" vhost="${HM_SITE_VHOST:-}"
  echo "  ${C_BOLD}Nadpisania strony${C_RESET}"
  if [[ -n "${vhost}" && -f "${vhost}" ]]; then
    if grep -qi 'phpinioverride\|php_admin\|php_value\|php_flag' "${vhost}" 2>/dev/null; then
      echo "  Vhost phpIniOverride / php_*:"
      awk 'BEGIN{ign=0}
        tolower($0) ~ /phpinioverride/ {ign=1}
        ign { print "    " $0 }
        ign && /\}/ { ign=0 }
        tolower($1) ~ /^php_(value|flag|admin)/ { print "    " $0 }
      ' "${vhost}" 2>/dev/null | head -40
    else
      echo "  Vhost: brak phpIniOverride"
    fi
  else
    echo "  Vhost: —"
  fi
  if [[ -n "${docroot}" ]]; then
    if [[ -f "${docroot}/.user.ini" ]]; then
      echo "  .user.ini:"
      sed 's/^/    /' "${docroot}/.user.ini" | head -30
    else
      echo "  .user.ini: brak"
    fi
    if [[ -f "${docroot}/.htaccess" ]] && grep -Eqi 'php_value|php_flag|php_admin' "${docroot}/.htaccess" 2>/dev/null; then
      echo "  .htaccess php_*:"
      grep -Ei 'php_value|php_flag|php_admin' "${docroot}/.htaccess" | sed 's/^/    /' | head -20
    fi
  fi
}

hm_php_ini_show() {
  local arg="${1:-}" branch bin ini
  if ! branch="$(hm_php_branch_for_site "${arg}")"; then
    hm_err "Podaj wersję (php ini 8.3) lub wejdź w kontekst strony."
    return 1
  fi
  bin="$(hm_php_bin_for_branch "${branch}")" || { hm_err "Brak PHP ${branch}"; return 1; }
  ini="$(hm_php_ini_path "${branch}" 2>/dev/null || true)"

  echo "${C_BOLD}PHP ini — ${branch}${C_RESET}"
  echo "  Bin     : ${bin}"
  echo "  php.ini : ${ini:-nie znaleziono}"
  echo
  printf '  %-28s %s\n' "DYREKTYWA" "WARTOŚĆ"
  printf '  %-28s %s\n' "---------" "-------"
  local keys=(
    memory_limit upload_max_filesize post_max_size
    max_execution_time max_input_time max_input_vars
    opcache.enable opcache.memory_consumption
    expose_php display_errors
  )
  local k v
  for k in "${keys[@]}"; do
    v="$("${bin}" -r "echo ini_get('${k}');" 2>/dev/null || echo "?")"
    printf '  %-28s %s\n' "${k}" "${v}"
  done
  echo
  if [[ -n "${HM_SITE_DOMAIN:-}" ]]; then
    hm_php_ini_show_overrides
  fi
}

hm_php_ini_set_file() {
  local ini="$1" key="$2" val="$3"
  [[ -f "${ini}" ]] || return 1
  cp -a "${ini}" "${ini}.bak.hmtools" 2>/dev/null || cp "${ini}" "${ini}.bak.hmtools"
  if grep -Eq "^[;[:space:]]*${key}[[:space:]]*=" "${ini}"; then
    sed -E -i "s|^[;[:space:]]*${key}[[:space:]]*=.*|${key} = ${val}|" "${ini}"
  else
    printf '\n; hmtools\n%s = %s\n' "${key}" "${val}" >> "${ini}"
  fi
}

hm_php_ini_set_vhost_override() {
  local vhost="$1" key="$2" val="$3"
  [[ -f "${vhost}" ]] || return 1
  cp -a "${vhost}" "${vhost}.bak.hmtools" 2>/dev/null || cp "${vhost}" "${vhost}.bak.hmtools"
  if grep -qi 'phpIniOverride' "${vhost}"; then
    if grep -Eq "^[[:space:]]*${key}" "${vhost}"; then
      sed -E -i "s|^([[:space:]]*)${key}[[:space:]]+.*|\1${key} ${val}|" "${vhost}"
    else
      # wstaw przed zamykającym } bloku — uproszczenie: dopisz przed pierwszym phpIniOverride }
      awk -v k="${key}" -v v="${val}" '
        BEGIN{done=0}
        tolower($0) ~ /phpinioverride/ {inb=1}
        inb && /^[[:space:]]*\}/ && !done {
          print "  " k " " v
          done=1
        }
        {print}
      ' "${vhost}" > "${vhost}.tmp.hmtools" && mv "${vhost}.tmp.hmtools" "${vhost}"
    fi
  else
    cat >> "${vhost}" <<EOF

phpIniOverride  {
  ${key} ${val}
}
EOF
  fi
}

hm_php_ini_set() {
  local key="${1:-}" val="${2:-}" scope="${3:-}"
  [[ -n "${key}" && -n "${val}" ]] || {
    hm_err "Użycie: php ini set <klucz> <wartość> [--global|--vhost]"
    return 1
  }
  local branch ini use_vhost=0
  case "${scope}" in
    --vhost|--site) use_vhost=1 ;;
    --global|"") ;;
    *)
      if [[ "${scope}" == --* ]]; then
        hm_err "Nieznana flaga: ${scope}"
        return 1
      fi
      ;;
  esac

  if ! branch="$(hm_php_branch_for_site "")"; then
    hm_err "Nie ustalono wersji PHP. Wejdź w kontekst: use <domena>"
    return 1
  fi

  local target_desc
  if [[ "${use_vhost}" -eq 1 ]]; then
    target_desc="phpIniOverride w ${HM_SITE_VHOST:--}"
  else
    ini="$(hm_php_ini_path "${branch}" 2>/dev/null || true)"
    target_desc="${ini:--}"
  fi
  if ! hm_confirm_plan "php ini set — ${key}=${val}" \
    "Zmiana konfiguracji PHP ${branch}." \
    "Kopia zapasowa pliku docelowego (.bak.hmtools)" \
    "Zapis dyrektywy ${key} = ${val} w ${target_desc}" \
    "Przeładowanie OpenLiteSpeed i restart workerów lsphp"; then
    return 0
  fi

  if [[ "${use_vhost}" -eq 1 ]]; then
    [[ -n "${HM_SITE_VHOST}" && -f "${HM_SITE_VHOST}" ]] || { hm_err "Brak vhost."; return 1; }
    hm_php_ini_set_vhost_override "${HM_SITE_VHOST}" "${key}" "${val}" || return 1
  else
    ini="$(hm_php_ini_path "${branch}")" || { hm_err "Nie znaleziono php.ini"; return 1; }
    hm_php_ini_set_file "${ini}" "${key}" "${val}" || return 1
  fi

  hm_ols_reload_soft || true
  hm_php_restart_workers
  hm_ok "Ustawiono ${key}=${val}"
}

hm_php_ini_cmd() {
  local sub="${1:-}"
  shift || true
  case "${sub}" in
    ""|show|list|ls)
      hm_php_ini_show "$@"
      ;;
    set)
      hm_php_ini_set "$@"
      ;;
    help|-h|--help)
      echo "Użycie: php ini [wersja] | php ini set <klucz> <wartość> [--vhost|--global]"
      ;;
    *)
      if hm_php_normalize_branch "${sub}" >/dev/null 2>&1; then
        hm_php_ini_show "${sub}"
      else
        hm_err "Nieznane: php ini ${sub}"
        return 1
      fi
      ;;
  esac
}

# --- php restart / ps --------------------------------------------------------

hm_php_restart_workers() {
  if [[ -n "${HM_SITE_DOMAIN:-}" && -n "${HM_SITE_USER:-}" ]] && id "${HM_SITE_USER}" >/dev/null 2>&1; then
    hm_info "Restart lsphp użytkownika ${HM_SITE_USER}…"
    pkill -u "${HM_SITE_USER}" -f 'lsphp' 2>/dev/null || true
  else
    hm_info "Restart wszystkich procesów lsphp…"
    if hm_have_cmd killall; then
      killall lsphp 2>/dev/null || true
    fi
    pkill -f 'lsphp' 2>/dev/null || true
  fi
  return 0
}

hm_php_restart() {
  local scope="auto"
  case "${1:-}" in
    --global|all|global) scope="global" ;;
    --site|site|"") ;;
  esac

  if [[ "${scope}" == "global" ]] || [[ -z "${HM_SITE_DOMAIN:-}" ]]; then
    if ! hm_confirm_plan "php restart — globalnie" \
      "Dotknie wszystkich workerów lsphp na serwerze." \
      "Wysłanie sygnału SIGTERM (pkill) do wszystkich procesów lsphp na serwerze" \
      "Przeładowanie OpenLiteSpeed (nowe workery wystartują przy kolejnym żądaniu)"; then
      return 0
    fi
    HM_SITE_DOMAIN="" HM_SITE_USER="" hm_php_restart_workers
  else
    if [[ -z "${HM_SITE_USER}" ]]; then
      hm_warn "Brak HM_SITE_USER — restart globalny workerów niebezpieczny; użyj: php restart --global"
      return 1
    fi
    if ! hm_confirm_plan "php restart — ${HM_SITE_DOMAIN}" \
      "User: ${HM_SITE_USER}." \
      "Wysłanie sygnału SIGTERM (pkill) do workerów lsphp użytkownika ${HM_SITE_USER}" \
      "Przeładowanie OpenLiteSpeed (nowe workery wystartują przy kolejnym żądaniu)"; then
      return 0
    fi
    hm_php_restart_workers
  fi
  hm_ols_reload_soft || hm_warn "ols reload nieudany"
  hm_ok "Restart lsphp zlecony (Detached Mode — nowe workery przy kolejnym requeście)."
}

hm_php_ps() {
  echo "${C_BOLD}Procesy lsphp${C_RESET}"
  echo
  printf '  %-16s %6s %5s %5s  %s\n' "USER" "PID" "%CPU" "%MEM" "CMD"
  local found=0 line
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    echo "  ${line}"
    found=1
  done < <(ps -eo user:16,pid,pcpu,pmem,args 2>/dev/null | awk 'NR>1 && $0 ~ /lsphp/ && $0 !~ /awk/ {printf "%-16s %6s %5s %5s  %s\n", $1,$2,$3,$4,substr($0, index($0,$5))}')

  if [[ "${found}" -eq 0 ]]; then
    hm_warn "Brak procesów lsphp."
    return 0
  fi
  if [[ -n "${HM_SITE_USER:-}" ]]; then
    echo
    echo "  ${C_DIM}Filtr user=${HM_SITE_USER}:${C_RESET}"
    ps -u "${HM_SITE_USER}" -o pid,pcpu,pmem,args 2>/dev/null | awk 'NR==1 || /lsphp/' | sed 's/^/  /' || echo "    (brak)"
  fi
  local n
  n="$(pgrep -c -f 'lsphp' 2>/dev/null || echo 0)"
  echo
  hm_info "Łącznie procesów lsphp (pgrep): ${n}"
}
