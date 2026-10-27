#!/usr/bin/env bash
# Discovery i szczegóły stron webowych

if [[ -n "${HMTOOLS_SITES_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_SITES_LOADED=1

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_LIB_DIR}/common.sh"
# shellcheck source=detect.sh
source "${_LIB_DIR}/detect.sh"
# shellcheck source=size.sh
source "${_LIB_DIR}/size.sh"
# shellcheck source=db.sh
source "${_LIB_DIR}/db.sh"

# Tablica domen (kolejność listy)
declare -a HM_SITES_LIST=()

hm_vhost_conf_path() {
  local domain="$1"
  local d
  for d in \
    "${OLS_VHOSTS}/${domain}/vhconf.conf" \
    "${OLS_VHOSTS}/${domain}/vhost.conf" \
    "${OLS_VHOSTS}/${domain}/httpd.conf"
  do
    if [[ -f "${d}" ]]; then
      echo "${d}"
      return 0
    fi
  done
  return 1
}

hm_parse_vhost_docroot() {
  local conf="$1"
  [[ -f "${conf}" ]] || return 1
  # OLS: docRoot                   /home/example.com/public_html
  #      docRoot                   $VH_ROOT/public_html
  awk '
    tolower($1)=="docroot" {
      gsub(/\r/,"",$2);
      print $2;
      exit
    }
  ' "${conf}" 2>/dev/null
}

hm_ols_vhroot_for_domain() {
  # CyberPanel/OLS: vhRoot w vhconf lub w virtualHost { } w httpd_config
  local domain="$1"
  local conf vhroot=""
  conf="$(hm_vhost_conf_path "${domain}" 2>/dev/null || true)"
  if [[ -n "${conf}" && -f "${conf}" ]]; then
    vhroot="$(awk 'tolower($1)=="vhroot" { gsub(/\r/,"",$2); print $2; exit }' "${conf}" 2>/dev/null || true)"
  fi
  if [[ -z "${vhroot}" && -n "${OLS_CONF:-}" && -f "${OLS_CONF}" ]]; then
    vhroot="$(awk -v d="${domain}" '
      BEGIN { inv=0 }
      tolower($1)=="virtualhost" && $2==d { inv=1; next }
      inv && tolower($1)=="vhroot" { gsub(/\r/,"",$2); print $2; exit }
      inv && $0 ~ /^[ \t]*\}/ { inv=0 }
    ' "${OLS_CONF}" 2>/dev/null || true)"
  fi
  vhroot="${vhroot%/}"
  # nie zostawiaj nierozwiniętych zmiennych OLS
  if [[ -z "${vhroot}" || "${vhroot}" == *'$'* ]]; then
    if [[ -d "/home/${domain}" ]]; then
      vhroot="/home/${domain}"
    elif [[ -d "/home/${domain}/public_html" ]]; then
      vhroot="/home/${domain}"
    else
      vhroot=""
    fi
  fi
  printf '%s' "${vhroot}"
}

hm_expand_ols_vars() {
  # $VH_ROOT / $VH_NAME / $DOC_ROOT → realne ścieżki
  local path="$1"
  local domain="$2"
  local vhroot="${3:-}"
  [[ -n "${path}" ]] || { printf '%s' ""; return 0; }
  [[ -n "${vhroot}" ]] || vhroot="$(hm_ols_vhroot_for_domain "${domain}")"
  path="${path//\$VH_NAME/${domain}}"
  if [[ -n "${vhroot}" ]]; then
    path="${path//\$VH_ROOT/${vhroot}}"
    path="${path//\$DOC_ROOT/${vhroot}/public_html}"
  fi
  printf '%s' "${path}"
}

hm_parse_vhost_php() {
  local conf="$1"
  [[ -f "${conf}" ]] || return 0
  # szukaj lsphpXX w path / extProcessor
  local php
  php="$(grep -Eo 'lsphp[0-9]+' "${conf}" 2>/dev/null | head -1 || true)"
  if [[ -n "${php}" ]]; then
    # lsphp82 -> 8.2
    local ver="${php#lsphp}"
    if [[ "${#ver}" -eq 2 ]]; then
      echo "${ver:0:1}.${ver:1:1}"
      return
    fi
    echo "${php}"
    return
  fi
  php="$(grep -Ei 'php[ _]version|phpPath' "${conf}" 2>/dev/null | head -1 || true)"
  echo "${php:-?}"
}

hm_ssl_paths_for_domain() {
  local domain="$1"
  local candidates=(
    "/etc/letsencrypt/live/${domain}/fullchain.pem"
    "${OLS_ROOT}/conf/vhosts/${domain}/ssl/fullchain.pem"
    "/home/${domain}/ssl/fullchain.pem"
    "/etc/ssl/${domain}/fullchain.pem"
  )
  local p
  for p in "${candidates[@]}"; do
    if [[ -f "${p}" ]]; then
      echo "${p}"
      return 0
    fi
  done
  # cert/key w vhost
  local conf
  conf="$(hm_vhost_conf_path "${domain}" 2>/dev/null || true)"
  if [[ -n "${conf}" ]]; then
    local cert
    cert="$(awk 'tolower($1)=="keyfile" || tolower($1)=="certfile" || tolower($1)=="certfile" {print $2; exit}' "${conf}" 2>/dev/null || true)"
    # OLS uses keyFile / certFile
    cert="$(awk 'tolower($1)=="certfile"{print $2; exit}' "${conf}" 2>/dev/null || true)"
    if [[ -n "${cert}" && -f "${cert}" ]]; then
      echo "${cert}"
      return 0
    fi
  fi
  return 1
}

hm_ssl_expiry() {
  local cert="$1"
  [[ -f "${cert}" ]] || { echo "-"; return; }
  openssl x509 -enddate -noout -in "${cert}" 2>/dev/null | sed 's/notAfter=//' || echo "-"
}

hm_ssl_has() {
  local domain="$1"
  if hm_ssl_paths_for_domain "${domain}" >/dev/null 2>&1; then
    echo "yes"
  else
    echo "no"
  fi
}

hm_cyberpanel_list_domains() {
  if hm_have_cmd cyberpanel; then
    # różne wersje CLI — próbujemy JSON, potem tekst
    if cyberpanel listWebsitesJson >/dev/null 2>&1; then
      cyberpanel listWebsitesJson 2>/dev/null \
        | tr ',' '\n' \
        | grep -Eo '"domain"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | sed -E 's/.*"([^"]+)"$/\1/' \
        || true
      return
    fi
  fi
  # DB cyberpanel
  hm_mysql_exec cyberpanel -e "SELECT domainName FROM websites_website ORDER BY domainName;" 2>/dev/null || true
}

hm_cyberpanel_site_meta() {
  local domain="$1"
  # php, externalApp, state
  hm_mysql_exec cyberpanel -e "
    SELECT COALESCE(phpSelection,''), COALESCE(externalApp,''), COALESCE(state,1)
    FROM websites_website WHERE domainName='${domain}' LIMIT 1;
  " 2>/dev/null || true
}

hm_ols_list_vhost_dirs() {
  [[ -n "${OLS_VHOSTS}" && -d "${OLS_VHOSTS}" ]] || return 0
  local d name
  for d in "${OLS_VHOSTS}"/*; do
    [[ -d "${d}" ]] || continue
    name="$(basename "${d}")"
    case "${name}" in
      Example|Example2|DEFAULT|localhost) continue ;;
    esac
    echo "${name}"
  done
}

hm_home_public_html_domains() {
  local d
  for d in /home/*/public_html; do
    [[ -d "${d}" ]] || continue
    basename "$(dirname "${d}")"
  done
}

# Buduje unikalną listę domen do HM_SITES_LIST
hm_sites_add() {
  # $1 = domain, uses globals HM_SITES_LIST + HM_SITES_SEEN
  local d="$1"
  [[ -n "${d}" ]] || return 0
  [[ "${HM_SITES_SEEN}" == *"|${d}|"* ]] && return 0
  HM_SITES_SEEN="${HM_SITES_SEEN}${d}|"
  HM_SITES_LIST+=("${d}")
}

hm_discover_sites() {
  hm_detect_all
  HM_SITES_LIST=()
  HM_SITES_SEEN="|"
  local domain

  if [[ "${PANEL}" == "cyberpanel" ]]; then
    while IFS= read -r domain; do
      hm_sites_add "${domain}"
    done < <(hm_cyberpanel_list_domains)
  fi

  if [[ "${#HM_SITES_LIST[@]}" -eq 0 ]] && [[ -n "${OLS_VHOSTS}" ]]; then
    while IFS= read -r domain; do
      hm_sites_add "${domain}"
    done < <(hm_ols_list_vhost_dirs)
  fi

  # uzupełnij / zbuduj z /home/*/public_html
  while IFS= read -r domain; do
    hm_sites_add "${domain}"
  done < <(hm_home_public_html_domains)
}

hm_resolve_site_paths() {
  local domain="$1"
  local root="" docroot="" logs="" vhost="" php="?" user="" status="active"
  local vhroot=""

  vhost="$(hm_vhost_conf_path "${domain}" 2>/dev/null || true)"
  vhroot="$(hm_ols_vhroot_for_domain "${domain}")"

  if [[ -n "${vhost}" ]]; then
    docroot="$(hm_parse_vhost_docroot "${vhost}" || true)"
    php="$(hm_parse_vhost_php "${vhost}" || true)"
  fi
  # OLS często ma docRoot $VH_ROOT/public_html
  if [[ -n "${docroot}" ]]; then
    docroot="$(hm_expand_ols_vars "${docroot}" "${domain}" "${vhroot}")"
  fi
  # nadal nierozwinięte / puste?
  if [[ -z "${docroot}" || "${docroot}" == *'$'* ]]; then
    docroot=""
  fi

  if [[ -z "${docroot}" && -n "${vhroot}" && -d "${vhroot}/public_html" ]]; then
    docroot="${vhroot}/public_html"
  fi
  if [[ -z "${docroot}" && -d "/home/${domain}/public_html" ]]; then
    docroot="/home/${domain}/public_html"
  fi
  if [[ -z "${docroot}" && -d "/var/www/${domain}/html" ]]; then
    docroot="/var/www/${domain}/html"
  fi
  if [[ -z "${docroot}" && -d "/var/www/${domain}" ]]; then
    docroot="/var/www/${domain}"
  fi

  if [[ -n "${vhroot}" && -d "${vhroot}" ]]; then
    root="${vhroot}"
  elif [[ -n "${docroot}" ]]; then
    root="$(dirname "${docroot}")"
    if [[ "$(basename "${docroot}")" == "public_html" ]]; then
      root="$(dirname "${docroot}")"
    fi
  elif [[ -d "/home/${domain}" ]]; then
    root="/home/${domain}"
    docroot="${root}/public_html"
  fi

  # ostatnia szansa: nie trzymaj literału $VH_ROOT
  if [[ "${root}" == *'$'* ]]; then
    root=""
    [[ -d "/home/${domain}" ]] && root="/home/${domain}"
  fi
  if [[ "${docroot}" == *'$'* ]]; then
    docroot=""
    [[ -n "${root}" && -d "${root}/public_html" ]] && docroot="${root}/public_html"
  fi

  if [[ -n "${root}" && -d "${root}/logs" ]]; then
    logs="${root}/logs"
  elif [[ -n "${OLS_ROOT}" && -d "${OLS_ROOT}/logs" ]]; then
    logs="${OLS_ROOT}/logs"
  fi

  if [[ "${PANEL}" == "cyberpanel" ]]; then
    local meta php_sel ext state
    meta="$(hm_cyberpanel_site_meta "${domain}")"
    if [[ -n "${meta}" ]]; then
      php_sel="$(echo "${meta}" | awk -F'\t' '{print $1}')"
      ext="$(echo "${meta}" | awk -F'\t' '{print $2}')"
      state="$(echo "${meta}" | awk -F'\t' '{print $3}')"
      [[ -n "${php_sel}" && "${php_sel}" != "NULL" ]] && php="${php_sel}"
      [[ -n "${ext}" && "${ext}" != "NULL" && "${ext}" != "" ]] && user="${ext}"
      if [[ "${state}" == "0" ]]; then
        status="suspended"
      fi
    fi
  fi

  # właściciel katalogu strony (CyberPanel externalApp bywa puste dla Node)
  if [[ -z "${user}" && -n "${root}" && -d "${root}" ]]; then
    user="$(stat -c '%U' "${root}" 2>/dev/null || true)"
  fi
  if [[ -z "${user}" && -d "/home/${domain}" ]]; then
    user="$(stat -c '%U' "/home/${domain}" 2>/dev/null || true)"
  fi
  # root/nobody nie są „userem strony”
  case "${user}" in
    root|nobody|www-data|apache|nginx|"") user="" ;;
  esac
  if [[ -z "${user}" && -d "/home/${domain}" ]]; then
    # CyberPanel: często user = skrót domeny jako nazwa systemu
    local cand
    cand="$(stat -c '%U' "/home/${domain}" 2>/dev/null || true)"
    if [[ -n "${cand}" && "${cand}" != "root" ]] && id "${cand}" >/dev/null 2>&1; then
      user="${cand}"
    fi
  fi

  # Normalizacja PHP (PHP 8.2 -> 8.2)
  php="$(echo "${php}" | sed -E 's/.*PHP[[:space:]]*//; s/lsphp//; s/^([0-9])([0-9])$/\1.\2/')"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "${domain}" \
    "${root}" \
    "${docroot}" \
    "${logs}" \
    "${vhost}" \
    "${php:-?}" \
    "${user}|${status}"
}

hm_set_site_context() {
  local domain="$1"
  local row root docroot logs vhost php rest user status
  row="$(hm_resolve_site_paths "${domain}")"
  IFS=$'\t' read -r domain root docroot logs vhost php rest <<<"${row}"
  user="${rest%%|*}"
  status="${rest##*|}"

  HM_SITE_DOMAIN="${domain}"
  HM_SITE_ROOT="${root}"
  HM_SITE_DOCROOT="${docroot}"
  HM_SITE_LOGS="${logs}"
  HM_SITE_VHOST="${vhost}"
  HM_SITE_PHP="${php}"
  HM_SITE_USER="${user}"
  HM_SITE_STATUS="${status}"
}

hm_find_site_by_arg() {
  # arg = numer (1-based) lub domena
  local arg="$1"
  hm_discover_sites
  if [[ "${arg}" =~ ^[0-9]+$ ]]; then
    local idx=$((arg - 1))
    if [[ "${idx}" -lt 0 || "${idx}" -ge "${#HM_SITES_LIST[@]}" ]]; then
      hm_err "Numer poza zakresem (1–${#HM_SITES_LIST[@]})."
      return 1
    fi
    echo "${HM_SITES_LIST[$idx]}"
    return 0
  fi
  local d
  for d in "${HM_SITES_LIST[@]}"; do
    if [[ "${d}" == "${arg}" ]]; then
      echo "${d}"
      return 0
    fi
  done
  # częściowe dopasowanie
  local matches=()
  for d in "${HM_SITES_LIST[@]}"; do
    if [[ "${d}" == *"${arg}"* ]]; then
      matches+=("${d}")
    fi
  done
  if [[ "${#matches[@]}" -eq 1 ]]; then
    echo "${matches[0]}"
    return 0
  fi
  if [[ "${#matches[@]}" -gt 1 ]]; then
    hm_err "Ambiguous: ${matches[*]}"
    return 1
  fi
  hm_err "Nie znaleziono strony: ${arg}"
  return 1
}

hm_list_sites() {
  local quick="${1:-0}"
  hm_discover_sites

  if [[ "${#HM_SITES_LIST[@]}" -eq 0 ]]; then
    hm_warn "Nie wykryto żadnych usług webowych."
    return 0
  fi

  printf '%-4s %-36s %-8s %-5s %-12s %s\n' "#" "DOMAIN" "PHP" "SSL" "SIZE" "STATUS"
  printf '%-4s %-36s %-8s %-5s %-12s %s\n' "---" "------" "---" "---" "----" "------"

  local i=0 domain row root docroot logs vhost php rest user status size ssl
  for domain in "${HM_SITES_LIST[@]}"; do
    i=$((i + 1))
    row="$(hm_resolve_site_paths "${domain}")"
    IFS=$'\t' read -r _ root docroot logs vhost php rest <<<"${row}"
    status="${rest##*|}"
    ssl="$(hm_ssl_has "${domain}")"
    if [[ "${quick}" == "1" ]]; then
      size="-"
    else
      if [[ -n "${root}" && -d "${root}" ]]; then
        size="$(hm_format_size_from_path "${root}")"
      elif [[ -n "${docroot}" && -d "${docroot}" ]]; then
        size="$(hm_format_size_from_path "${docroot}")"
      else
        size="?"
      fi
    fi
    printf '%-4s %-36s %-8s %-5s %-12s %s\n' \
      "${i}" "${domain}" "${php:-?}" "${ssl}" "${size}" "${status}"
  done
  echo
  hm_info "Użyj: use <numer|domena>  aby wejść w kontekst."
}

hm_print_site_info() {
  local domain="${1:-${HM_SITE_DOMAIN}}"
  [[ -n "${domain}" ]] || { hm_err "Brak domeny w kontekście."; return 1; }

  hm_set_site_context "${domain}"

  local size_root=0 size_doc=0
  [[ -n "${HM_SITE_ROOT}" && -d "${HM_SITE_ROOT}" ]] && size_root="$(hm_dir_size_bytes "${HM_SITE_ROOT}")"
  [[ -n "${HM_SITE_DOCROOT}" && -d "${HM_SITE_DOCROOT}" ]] && size_doc="$(hm_dir_size_bytes "${HM_SITE_DOCROOT}")"

  local cert expiry
  cert="$(hm_ssl_paths_for_domain "${domain}" 2>/dev/null || true)"
  expiry="-"
  [[ -n "${cert}" ]] && expiry="$(hm_ssl_expiry "${cert}")"

  cat <<EOF
${C_BOLD}Szczegóły: ${domain}${C_RESET}
  Status      : ${HM_SITE_STATUS}
  User        : ${HM_SITE_USER:--}
  PHP         : ${HM_SITE_PHP:--}
  Site root   : ${HM_SITE_ROOT:--}
  Docroot     : ${HM_SITE_DOCROOT:--}
  Logs        : ${HM_SITE_LOGS:--}
  VHost conf  : ${HM_SITE_VHOST:--}
  Rozmiar env : $(hm_human_size "${size_root}")  (całe środowisko)
  Rozmiar www : $(hm_human_size "${size_doc}")  (docroot)
  SSL cert    : ${cert:--}
  SSL expiry  : ${expiry}
  Wolne dysk  : $(hm_disk_free_percent /)% free  (used $(hm_disk_used_percent /)%)

${C_BOLD}Bazy danych:${C_RESET}
EOF
  hm_print_dbs_for_site "${domain}" "${HM_SITE_DOCROOT}"
}

hm_print_site_ssl() {
  local domain="${1:-${HM_SITE_DOMAIN}}"
  [[ -n "${domain}" ]] || { hm_err "Brak domeny."; return 1; }
  local cert
  cert="$(hm_ssl_paths_for_domain "${domain}" 2>/dev/null || true)"
  if [[ -z "${cert}" ]]; then
    hm_warn "Brak certyfikatu dla ${domain}."
    return 0
  fi
  echo "Cert: ${cert}"
  echo "Expiry: $(hm_ssl_expiry "${cert}")"
  openssl x509 -in "${cert}" -noout -subject -issuer -dates 2>/dev/null || true
}

hm_print_site_logs() {
  local domain="${1:-${HM_SITE_DOMAIN}}"
  local lines="${2:-40}"
  hm_set_site_context "${domain}"
  local candidates=()
  [[ -n "${HM_SITE_LOGS}" ]] && candidates+=(
    "${HM_SITE_LOGS}/access.log"
    "${HM_SITE_LOGS}/error.log"
    "${HM_SITE_LOGS}/${domain}.access_log"
    "${HM_SITE_LOGS}/${domain}.error_log"
  )
  [[ -n "${OLS_ROOT}" ]] && candidates+=(
    "${OLS_ROOT}/logs/error.log"
    "${OLS_ROOT}/logs/access.log"
  )
  local f found=0
  for f in "${candidates[@]}"; do
    if [[ -f "${f}" ]]; then
      found=1
      echo "==== ${f} (ostatnie ${lines}) ===="
      tail -n "${lines}" "${f}" 2>/dev/null || true
      echo
    fi
  done
  if [[ "${found}" -eq 0 ]]; then
    hm_warn "Nie znaleziono plików logów."
    [[ -n "${HM_SITE_LOGS}" ]] && ls -la "${HM_SITE_LOGS}" 2>/dev/null || true
  fi
}

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
