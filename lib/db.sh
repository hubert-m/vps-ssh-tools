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

# CyberPanel: databases_databases powiązane z websites_website
hm_cyberpanel_dbs_for_domain() {
  local domain="$1"
  local sql
  sql="
SELECT d.dbName, COALESCE(d.dbUser,''), COALESCE(d.dbHost,'localhost')
FROM databases_databases d
JOIN websites_website w ON d.website_id = w.id
WHERE w.domainName = '${domain}';
"
  # CyberPanel zwykle używa DB 'cyberpanel'
  hm_mysql_exec cyberpanel -e "${sql}" 2>/dev/null || true
}

# Heurystyka z plików aplikacji
hm_extract_db_from_file() {
  local file="$1"
  local kind="$2"
  [[ -f "${file}" ]] || return 0

  case "${kind}" in
    wp)
      grep -E "define\s*\(\s*['\"]DB_NAME['\"]" "${file}" 2>/dev/null \
        | sed -E "s/.*DB_NAME['\"][[:space:]]*,[[:space:]]*['\"]([^'\"]+)['\"].*/\1\twp-config/" || true
      ;;
    env)
      grep -E '^DB_DATABASE=' "${file}" 2>/dev/null \
        | sed -E 's/\r//g; s/^DB_DATABASE=//; s/^["'\'']//; s/["'\'']$//' \
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
  local found=""

  [[ -n "${docroot}" && -d "${docroot}" ]] || return 0

  local line db
  while IFS= read -r line; do
    db="${line%%$'\t'*}"
    [[ -n "${db}" ]] || continue
    printf '%s\tdetected\n' "${db}"
  done < <({
    hm_extract_db_from_file "${docroot}/wp-config.php" wp
    hm_extract_db_from_file "${docroot}/.env" env
    hm_extract_db_from_file "${docroot}/configuration.php" joomla
    # także jeden poziom wyżej (np. Laravel poza public)
    local parent
    parent="$(dirname "${docroot}")"
    hm_extract_db_from_file "${parent}/.env" env
    hm_extract_db_from_file "${parent}/wp-config.php" wp
  } | awk 'NF' | sort -u)

  # Prefiks domeny w nazwach DB (CyberPanel: example_com)
  local prefix
  prefix="$(echo "${domain}" | tr '.' '_' | tr '-' '_')"
  local alldb
  while IFS= read -r alldb; do
    [[ -n "${alldb}" ]] || continue
    if [[ "${alldb}" == "${prefix}"* ]] || [[ "${alldb}" == *"${prefix}"* ]]; then
      printf '%s\tprefix-match\n' "${alldb}"
    fi
  done < <(hm_list_all_databases)
}

# Zwraca linie: name<TAB>user_or_source<TAB>size_bytes<TAB>origin
hm_dbs_for_site() {
  local domain="$1"
  local docroot="$2"
  local seen=""

  hm_detect_all

  if [[ "${PANEL}" == "cyberpanel" ]]; then
    local row name user host
    while IFS=$'\t' read -r name user host; do
      [[ -n "${name}" ]] || continue
      seen="${seen}|${name}|"
      printf '%s\t%s\t%s\tconfirmed\n' "${name}" "${user:-}" "$(hm_db_size_bytes "${name}")"
    done < <(hm_cyberpanel_dbs_for_domain "${domain}")
  fi

  local hname origin
  while IFS=$'\t' read -r hname origin; do
    [[ -n "${hname}" ]] || continue
    if [[ "${seen}" == *"|${hname}|"* ]]; then
      continue
    fi
    seen="${seen}|${hname}|"
    printf '%s\t%s\t%s\t%s\n' "${hname}" "" "$(hm_db_size_bytes "${hname}")" "${origin:-detected}"
  done < <(hm_heuristic_dbs_for_site "${docroot}" "${domain}" | sort -u)
}

hm_print_dbs_for_site() {
  local domain="$1"
  local docroot="$2"
  local any=0
  printf '%-32s %-18s %-12s %s\n' "DATABASE" "USER/ŹRÓDŁO" "ROZMIAR" "STATUS"
  printf '%-32s %-18s %-12s %s\n' "--------" "-----------" "-------" "------"
  local name user size origin
  while IFS=$'\t' read -r name user size origin; do
    [[ -n "${name}" ]] || continue
    any=1
    printf '%-32s %-18s %-12s %s\n' \
      "${name}" \
      "${user:--}" \
      "$(hm_human_size "${size}")" \
      "${origin}"
  done < <(hm_dbs_for_site "${domain}" "${docroot}")
  if [[ "${any}" -eq 0 ]]; then
    hm_warn "Brak wykrytych baz dla ${domain}."
  fi
}

hm_print_all_dbs() {
  printf '%-40s %s\n' "DATABASE" "ROZMIAR"
  printf '%-40s %s\n' "--------" "-------"
  local db
  while IFS= read -r db; do
    [[ -n "${db}" ]] || continue
    printf '%-40s %s\n' "${db}" "$(hm_human_size "$(hm_db_size_bytes "${db}")")"
  done < <(hm_list_all_databases)
}
