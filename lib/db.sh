#!/usr/bin/env bash
# Wykrywanie i listowanie baz danych powiązanych ze stroną

if [[ -n "${HMTOOLS_DB_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_DB_LOADED=1

# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=detect.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/detect.sh"

hm_mysql_exec() {
  local cli
  cli="$(hm_mysql_cli)" || return 1
  if [[ -n "${MYSQL_SOCKET}" ]]; then
    "${cli}" --socket="${MYSQL_SOCKET}" -N -B "$@"
  else
    "${cli}" -N -B "$@"
  fi
}

hm_db_size_bytes() {
  local dbname="$1"
  hm_mysql_exec -e "
    SELECT COALESCE(SUM(data_length + index_length),0)
    FROM information_schema.tables
    WHERE table_schema='${dbname}';
  " 2>/dev/null || echo 0
}

hm_list_all_databases() {
  hm_mysql_exec -e "SHOW DATABASES;" 2>/dev/null | grep -Ev '^(Database|information_schema|performance_schema|mysql|sys)$' || true
}

# CyberPanel: aktualny schemat Django = websiteFunctions_websites.domain
# (stary/legacy: websites_website.domainName)
hm_cyberpanel_dbs_for_domain() {
  local domain="$1"
  local out=""

  # 1) aktualny schemat + child domains
  out="$(hm_mysql_exec cyberpanel -e "
SELECT d.dbName, COALESCE(d.dbUser,''), 'localhost'
FROM databases_databases d
INNER JOIN websiteFunctions_websites w ON d.website_id = w.id
WHERE w.domain = '${domain}'
UNION
SELECT d.dbName, COALESCE(d.dbUser,''), 'localhost'
FROM databases_databases d
INNER JOIN websiteFunctions_websites w ON d.website_id = w.id
INNER JOIN websiteFunctions_childdomains c ON c.master_id = w.id
WHERE c.domain = '${domain}';
" 2>/dev/null || true)"

  if [[ -n "${out}" ]]; then
    printf '%s\n' "${out}"
    return 0
  fi

  # 2) legacy
  hm_mysql_exec cyberpanel -e "
SELECT d.dbName, COALESCE(d.dbUser,''), COALESCE(d.dbHost,'localhost')
FROM databases_databases d
JOIN websites_website w ON d.website_id = w.id
WHERE w.domainName = '${domain}';
" 2>/dev/null || true
}

hm_cyberpanel_dbs_for_user() {
  # bazy po dbUser / prefiksie externalApp (CyberPanel często: user_xxxxx)
  local user="$1"
  [[ -n "${user}" && "${user}" != "root" ]] || return 0
  local esc
  esc="$(printf '%s' "${user}" | sed "s/'/\\\\'/g")"
  hm_mysql_exec cyberpanel -e "
SELECT dbName, COALESCE(dbUser,''), 'localhost'
FROM databases_databases
WHERE dbUser = '${esc}'
   OR dbUser LIKE '${esc}\\_%'
   OR dbName LIKE '${esc}\\_%'
   OR dbName = '${esc}';
" 2>/dev/null || true
}

# Heurystyka z plików aplikacji
hm_extract_db_from_file() {
  local file="$1"
  local kind="$2"
  [[ -f "${file}" ]] || return 0

  case "${kind}" in
    wp)
      grep -E "define[[:space:]]*\([[:space:]]*['\"]DB_NAME['\"]" "${file}" 2>/dev/null \
        | sed -E "s/.*DB_NAME['\"][[:space:]]*,[[:space:]]*['\"]([^'\"]+)['\"].*/\1\twp-config/" || true
      ;;
    env)
      # DB_DATABASE=...
      grep -E '^[[:space:]]*DB_DATABASE=' "${file}" 2>/dev/null \
        | sed -E 's/\r//g; s/^[[:space:]]*DB_DATABASE=//; s/^["'\'']//; s/["'\'']$//' \
        | awk 'NF{print $0 "\t.env"}' || true
      # DATABASE_URL=mysql://user:pass@host:3306/dbname
      grep -E '^[[:space:]]*DATABASE_URL=' "${file}" 2>/dev/null \
        | sed -E 's/\r//g; s/^[[:space:]]*DATABASE_URL=//; s/^["'\'']//; s/["'\'']$//' \
        | sed -E 's|.*/([^/?]+)(\?.*)?$|\1|' \
        | awk 'NF && $0 !~ /[:\/]/ {print $0 "\t.env-url"}' || true
      # MYSQL_DATABASE / POSTGRES_DB
      grep -E '^[[:space:]]*(MYSQL_DATABASE|POSTGRES_DB)=' "${file}" 2>/dev/null \
        | sed -E 's/\r//g; s/^[[:space:]]*[A-Z_]+=//; s/^["'\'']//; s/["'\'']$//' \
        | awk 'NF{print $0 "\t.env"}' || true
      ;;
    joomla)
      grep -E "^\s*public \\\$db\s*=" "${file}" 2>/dev/null \
        | sed -E "s/.*['\"]([^'\"]+)['\"].*/\1\tconfiguration.php/" || true
      ;;
  esac
}

hm_heuristic_dbs_for_site() {
  local docroot="$1"
  local domain="$2"
  local site_root="${3:-}"

  local -a search_dirs=()
  [[ -n "${docroot}" && -d "${docroot}" ]] && search_dirs+=("${docroot}")
  [[ -n "${site_root}" && -d "${site_root}" ]] && search_dirs+=("${site_root}")
  if [[ -n "${docroot}" && -d "${docroot}" ]]; then
    search_dirs+=("$(dirname "${docroot}")")
  fi
  if [[ -n "${domain}" && -d "/home/${domain}" ]]; then
    search_dirs+=("/home/${domain}")
  fi

  local dir parent
  local -A seen_dir=()
  for dir in "${search_dirs[@]}"; do
    [[ -n "${dir}" && -d "${dir}" ]] || continue
    [[ -n "${seen_dir[$dir]:-}" ]] && continue
    seen_dir[$dir]=1

    hm_extract_db_from_file "${dir}/wp-config.php" wp
    hm_extract_db_from_file "${dir}/.env" env
    hm_extract_db_from_file "${dir}/configuration.php" joomla
    # typowe podkatalogi app (Next/Laravel/Node)
    local sub
    for sub in app backend api server src public private; do
      hm_extract_db_from_file "${dir}/${sub}/.env" env
      hm_extract_db_from_file "${dir}/${sub}/wp-config.php" wp
    done
  done | awk -F'\t' 'NF && !seen[$1]++ {print $1 "\t" $2}'

  # Prefiks domeny w nazwach DB (CyberPanel: example_com)
  local prefix short
  prefix="$(echo "${domain}" | tr '.' '_' | tr '-' '_')"
  short="$(echo "${domain}" | cut -d. -f1 | tr '-' '_')"
  local alldb
  while IFS= read -r alldb; do
    [[ -n "${alldb}" ]] || continue
    if [[ "${alldb}" == "${prefix}"* ]] || [[ "${alldb}" == *"${prefix}"* ]]; then
      printf '%s\tprefix-match\n' "${alldb}"
    elif [[ -n "${short}" && ${#short} -ge 4 && "${alldb}" == "${short}"* ]]; then
      printf '%s\tprefix-match\n' "${alldb}"
    fi
  done < <(hm_list_all_databases)
}

# Zwraca linie: name<TAB>user_or_source<TAB>size_bytes<TAB>origin
hm_dbs_for_site() {
  local domain="$1"
  local docroot="$2"
  local site_root="${3:-${HM_SITE_ROOT:-}}"
  local site_user="${4:-${HM_SITE_USER:-}}"
  local seen="|"

  hm_detect_all

  _hm_dbs_emit() {
    local name="$1" user="$2" origin="$3" size
    [[ -n "${name}" ]] || return 0
    [[ "${seen}" == *"|${name}|"* ]] && return 0
    seen="${seen}${name}|"
    size="$(hm_db_size_bytes "${name}")"
    printf '%s\t%s\t%s\t%s\n' "${name}" "${user}" "${size}" "${origin}"
  }

  if [[ "${PANEL}" == "cyberpanel" ]]; then
    local name user host
    while IFS=$'\t' read -r name user host; do
      [[ -n "${name}" ]] || continue
      _hm_dbs_emit "${name}" "${user:-}" "confirmed"
    done < <(hm_cyberpanel_dbs_for_domain "${domain}")

    # dopisz bazy po externalApp / unix user strony
    if [[ -n "${site_user}" ]]; then
      while IFS=$'\t' read -r name user host; do
        [[ -n "${name}" ]] || continue
        _hm_dbs_emit "${name}" "${user:-}" "user-match"
      done < <(hm_cyberpanel_dbs_for_user "${site_user}")
    fi
  fi

  local hname origin
  while IFS=$'\t' read -r hname origin; do
    [[ -n "${hname}" ]] || continue
    _hm_dbs_emit "${hname}" "" "${origin:-detected}"
  done < <(hm_heuristic_dbs_for_site "${docroot}" "${domain}" "${site_root}")
}

hm_print_dbs_for_site() {
  local domain="$1"
  local docroot="$2"
  local site_root="${3:-${HM_SITE_ROOT:-}}"
  local site_user="${4:-${HM_SITE_USER:-}}"
  local any=0

  printf '  %s%-32s %-14s %-12s %s%s\n' \
    "${C_DIM}" "DATABASE" "USER/ŹRÓDŁO" "ROZMIAR" "STATUS" "${C_RESET}"
  printf '  %s%s%s\n' "${C_DIM}" "$(printf '%.0s─' {1..72})" "${C_RESET}"

  local name user size origin
  # sort malejąco po rozmiarze (kolumna 3)
  while IFS=$'\t' read -r name user size origin; do
    [[ -n "${name}" ]] || continue
    any=1
    printf '  %-32s %-14s %-12s %s\n' \
      "${name}" \
      "${user:--}" \
      "$(hm_human_size "${size}")" \
      "${origin}"
  done < <(hm_dbs_for_site "${domain}" "${docroot}" "${site_root}" "${site_user}" \
            | sort -t$'\t' -k3,3nr)

  if [[ "${any}" -eq 0 ]]; then
    hm_warn "Brak wykrytych baz dla ${domain}."
  fi
}

hm_print_all_dbs() {
  printf '  %s%-40s %s%s\n' "${C_DIM}" "DATABASE" "ROZMIAR" "${C_RESET}"
  printf '  %s%s%s\n' "${C_DIM}" "$(printf '%.0s─' {1..52})" "${C_RESET}"

  local db size any=0
  local -a rows=()
  while IFS= read -r db; do
    [[ -n "${db}" ]] || continue
    size="$(hm_db_size_bytes "${db}")"
    rows+=("${size}"$'\t'"${db}")
    any=1
  done < <(hm_list_all_databases)

  if [[ "${any}" -eq 0 ]]; then
    hm_warn "Brak baz danych (lub brak dostępu MySQL)."
    return 0
  fi

  while IFS=$'\t' read -r size db; do
    [[ -n "${db}" ]] || continue
    printf '  %-40s %s\n' "${db}" "$(hm_human_size "${size}")"
  done < <(printf '%s\n' "${rows[@]}" | sort -t$'\t' -k1,1nr)
  echo
  echo "  ${C_DIM}Sortowanie: rozmiar ↓${C_RESET}"
}
