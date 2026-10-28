#!/usr/bin/env bash
# Sites: discovery, resolve, kontekst

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
  # aktualny schemat Django
  local out
  out="$(hm_mysql_exec cyberpanel -e "SELECT domain FROM websiteFunctions_websites ORDER BY domain;" 2>/dev/null || true)"
  if [[ -n "${out}" ]]; then
    printf '%s\n' "${out}"
    return 0
  fi
  # legacy
  hm_mysql_exec cyberpanel -e "SELECT domainName FROM websites_website ORDER BY domainName;" 2>/dev/null || true
}

hm_cyberpanel_site_meta() {
  local domain="$1"
  local out q
  hm_is_valid_domain "${domain}" || return 0
  q="$(hm_sql_quote "${domain}")"
  # php, externalApp, state — aktualny schemat
  out="$(hm_mysql_exec cyberpanel -e "
    SELECT COALESCE(phpSelection,''), COALESCE(externalApp,''), COALESCE(state,1)
    FROM websiteFunctions_websites WHERE domain=${q} LIMIT 1;
  " 2>/dev/null || true)"
  if [[ -n "${out}" ]]; then
    printf '%s\n' "${out}"
    return 0
  fi
  # legacy
  hm_mysql_exec cyberpanel -e "
    SELECT COALESCE(phpSelection,''), COALESCE(externalApp,''), COALESCE(state,1)
    FROM websites_website WHERE domainName=${q} LIMIT 1;
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

  # zawsze skanuj vhosty OLS (hm_sites_add deduplikuje) — także przy CyberPanelu
  if [[ -n "${OLS_VHOSTS}" ]]; then
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
    # dirname public_html → site root; inaczej parent docroot
    root="$(dirname "${docroot}")"
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
