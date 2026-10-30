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
  if ! hm_is_valid_db_name "${dbname}"; then
    echo 0
    return 0
  fi
  hm_mysql_exec -e "
    SELECT COALESCE(SUM(data_length + index_length),0)
    FROM information_schema.tables
    WHERE table_schema=$(hm_sql_quote "${dbname}");
  " 2>/dev/null || echo 0
}

hm_list_all_databases() {
  hm_mysql_exec -e "SHOW DATABASES;" 2>/dev/null | grep -Ev '^(Database|information_schema|performance_schema|mysql|sys)$' || true
}

# CyberPanel: aktualny schemat Django = websiteFunctions_websites.domain
# (stary/legacy: websites_website.domainName)
hm_cyberpanel_dbs_for_domain() {
  local domain="$1"
  local out="" q
  hm_is_valid_domain "${domain}" || return 0
  q="$(hm_sql_quote "${domain}")"

  # 1) aktualny schemat + child domains
  out="$(hm_mysql_exec cyberpanel -e "
SELECT d.dbName, COALESCE(d.dbUser,''), 'localhost'
FROM databases_databases d
INNER JOIN websiteFunctions_websites w ON d.website_id = w.id
WHERE w.domain = ${q}
UNION
SELECT d.dbName, COALESCE(d.dbUser,''), 'localhost'
FROM databases_databases d
INNER JOIN websiteFunctions_websites w ON d.website_id = w.id
INNER JOIN websiteFunctions_childdomains c ON c.master_id = w.id
WHERE c.domain = ${q};
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
WHERE w.domainName = ${q};
" 2>/dev/null || true
}

hm_cyberpanel_dbs_for_user() {
  # bazy po dbUser / prefiksie externalApp (CyberPanel często: user_xxxxx)
  local user="$1"
  [[ -n "${user}" && "${user}" != "root" ]] || return 0
  hm_is_valid_unix_user "${user}" || return 0
  local q
  q="$(hm_sql_quote "${user}")"
  hm_mysql_exec cyberpanel -e "
SELECT dbName, COALESCE(dbUser,''), 'localhost'
FROM databases_databases
WHERE dbUser = ${q}
   OR dbUser LIKE CONCAT(${q}, '\\_%')
   OR dbName LIKE CONCAT(${q}, '\\_%')
   OR dbName = ${q};
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
    if ! hm_is_valid_db_name "${name}"; then
      hm_warn "Pominięto niebezpieczną/nieprawidłową nazwę bazy: ${name}"
      return 0
    fi
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
  local -a rows=() dbs=()
  while IFS= read -r db; do
    [[ -n "${db}" ]] && dbs+=("${db}")
  done < <(hm_list_all_databases)

  if [[ "${#dbs[@]}" -eq 0 ]]; then
    hm_warn "Brak baz danych (lub brak dostępu MySQL)."
    return 0
  fi

  local i=0 total="${#dbs[@]}"
  for db in "${dbs[@]}"; do
    i=$((i + 1))
    hm_progress_bar "${i}" "${total}" "Rozmiar bazy: ${db}"
    size="$(hm_db_size_bytes "${db}")"
    rows+=("${size}"$'\t'"${db}")
    any=1
  done
  hm_progress_done

  while IFS=$'\t' read -r size db; do
    [[ -n "${db}" ]] || continue
    printf '  %-40s %s\n' "${db}" "$(hm_human_size "${size}")"
  done < <(printf '%s\n' "${rows[@]}" | sort -t$'\t' -k1,1nr)
  echo
  echo "  ${C_DIM}Sortowanie: rozmiar ↓${C_RESET}"
}

# --- zarządzanie (dump lokalny, import, cli, top, optimize, create) ------------

hm_mysql_db_exists() {
  local dbname="$1"
  local n
  if ! hm_is_valid_db_name "${dbname}"; then
    return 1
  fi
  n="$(hm_mysql_exec -e "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME=$(hm_sql_quote "${dbname}");" 2>/dev/null | tr -d '[:space:]')"
  [[ "${n}" == "1" ]]
}

hm_mysql_default_db_for_site() {
  # pierwsza baza powiązana ze stroną (confirmed → reszta)
  local domain="${1:-${HM_SITE_DOMAIN:-}}"
  local docroot="${2:-${HM_SITE_DOCROOT:-}}"
  local root="${3:-${HM_SITE_ROOT:-}}"
  local user="${4:-${HM_SITE_USER:-}}"
  [[ -n "${domain}" ]] || return 1
  local name
  name="$(hm_dbs_for_site "${domain}" "${docroot}" "${root}" "${user}" \
    | sort -t$'\t' -k4,4 -k3,3nr \
    | head -1 | cut -f1)"
  [[ -n "${name}" ]] || return 1
  printf '%s' "${name}"
}

hm_mysql_resolve_db_arg() {
  # $1 opcjonalna nazwa; pusty → default ze strony
  local db="${1:-}"
  if [[ -n "${db}" ]]; then
    if ! hm_is_valid_db_name "${db}"; then
      hm_err "Nieprawidłowa nazwa bazy: ${db}"
      return 1
    fi
    printf '%s' "${db}"
    return 0
  fi
  if [[ -n "${HM_SITE_DOMAIN:-}" ]]; then
    db="$(hm_mysql_default_db_for_site)" || {
      hm_err "Brak wykrytej bazy dla ${HM_SITE_DOMAIN}. Podaj: mysql … <db>"
      return 1
    }
    printf '%s' "${db}"
    return 0
  fi
  hm_err "Podaj nazwę bazy lub wejdź w kontekst strony (use)."
  return 1
}

hm_gen_password() {
  local p=""
  if hm_have_cmd openssl; then
    p="$(openssl rand -base64 24 2>/dev/null | tr -d '/+=' | head -c 20)"
  fi
  if [[ -z "${p}" || ${#p} -lt 12 ]]; then
    p="$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 20)"
  fi
  printf '%s' "${p}"
}

hm_is_safe_fs_path() {
  # absolutna ścieżka bez .. i metaznaków shella
  local p="${1:-}"
  [[ "${p}" == /* ]] || return 1
  [[ "${p}" != *..* ]] || return 1
  [[ "${p}" =~ ^/[a-zA-Z0-9._/-]+$ ]]
}

hm_mysql_dump_local() {
  local dbname="$1"
  local outpath="${2:-}"
  local dumpcli sock_args=() stamp dest dir
  hm_is_valid_db_name "${dbname}" || { hm_err "Nieprawidłowa nazwa bazy: ${dbname}"; return 1; }
  hm_mysql_db_exists "${dbname}" || { hm_err "Baza nie istnieje: ${dbname}"; return 1; }
  dumpcli="$(hm_mysqldump_cli)" || { hm_err "Brak mysqldump/mariadb-dump."; return 1; }

  stamp="$(date +%Y%m%d-%H%M%S)"
  if [[ -z "${outpath}" ]]; then
    if [[ -n "${HM_SITE_ROOT:-}" && -d "${HM_SITE_ROOT}" ]]; then
      dir="${HM_SITE_ROOT}/backups"
    elif [[ -n "${HM_SITE_DOMAIN:-}" && -d "/home/${HM_SITE_DOMAIN}" ]]; then
      dir="/home/${HM_SITE_DOMAIN}/backups"
    else
      dir="${TMP_DIR:-/tmp}/hmtools-db"
    fi
    mkdir -p "${dir}"
    chmod 0700 "${dir}" 2>/dev/null || true
    outpath="${dir}/${dbname}-${stamp}.sql.gz"
  fi

  if ! hm_is_safe_fs_path "${outpath}"; then
    hm_err "Niebezpieczna/nieprawidłowa ścieżka: ${outpath}"
    return 1
  fi
  dir="$(dirname "${outpath}")"
  mkdir -p "${dir}"

  [[ -n "${MYSQL_SOCKET:-}" ]] && sock_args=(--socket="${MYSQL_SOCKET}")

  hm_info "Lokalny dump ${dbname} → ${outpath}"
  hm_status_line "mysqldump ${dbname}..."
  set +e
  set +o pipefail
  "${dumpcli}" "${sock_args[@]}" --single-transaction --quick --routines --triggers \
    -- "${dbname}" 2>/dev/null | gzip -c > "${outpath}"
  local -a _ps=( "${PIPESTATUS[@]}" )
  local dump_rc=${_ps[0]:-1} gzip_rc=${_ps[1]:-1}
  set -o pipefail
  set -e
  hm_status_clear
  if [[ "${dump_rc}" -ne 0 || "${gzip_rc}" -ne 0 || ! -s "${outpath}" ]]; then
    rm -f "${outpath}"
    hm_err "Dump lokalny nieudany (mysqldump rc=${dump_rc})."
    return 1
  fi
  chmod 0600 "${outpath}" 2>/dev/null || true
  hm_ok "Zapisano $(hm_human_size "$(stat -c%s "${outpath}" 2>/dev/null || echo 0)"): ${outpath}"
}

hm_mysql_import() {
  local dbname="$1"
  local file="$2"
  local cli sock_args=()
  hm_is_valid_db_name "${dbname}" || { hm_err "Nieprawidłowa nazwa bazy: ${dbname}"; return 1; }
  hm_mysql_db_exists "${dbname}" || { hm_err "Baza nie istnieje: ${dbname}"; return 1; }
  [[ -n "${file}" && -f "${file}" ]] || { hm_err "Brak pliku: ${file}"; return 1; }
  local abs
  abs="$(realpath -m "${file}" 2>/dev/null || readlink -f "${file}" 2>/dev/null || true)"
  [[ -n "${abs}" && -f "${abs}" ]] || { hm_err "Nie można rozwiązać ścieżki: ${file}"; return 1; }
  if ! hm_is_safe_fs_path "${abs}"; then
    hm_err "Niebezpieczna ścieżka pliku."
    return 1
  fi
  file="${abs}"

  case "${file}" in
    *.sql|*.sql.gz) ;;
    *) hm_err "Obsługiwane: .sql lub .sql.gz"; return 1 ;;
  esac

  cli="$(hm_mysql_cli)" || { hm_err "Brak mysql/mariadb."; return 1; }
  [[ -n "${MYSQL_SOCKET:-}" ]] && sock_args=(--socket="${MYSQL_SOCKET}")

  local fsize
  fsize="$(hm_human_size "$(stat -c%s "${file}" 2>/dev/null || echo 0)")"
  if ! hm_confirm_plan "mysql import — ${dbname}" \
    "Import NADPISZE dane w bazie ${dbname}." \
    "Rozpakowanie (jeśli .gz) i wykonanie skryptu SQL z pliku ${file} (${fsize})" \
    "Nadpisanie istniejących tabel/danych w bazie ${dbname}"; then
    return 0
  fi

  hm_status_line "Import do ${dbname}..."
  if [[ "${file}" == *.sql.gz ]]; then
    if ! gunzip -c -- "${file}" | "${cli}" "${sock_args[@]}" -- "${dbname}"; then
      hm_status_clear
      hm_err "Import .sql.gz nieudany."
      return 1
    fi
  else
    if ! "${cli}" "${sock_args[@]}" -- "${dbname}" < "${file}"; then
      hm_status_clear
      hm_err "Import .sql nieudany."
      return 1
    fi
  fi
  hm_status_clear
  hm_ok "Import do ${dbname} zakończony."
}

hm_mysql_cli_session() {
  local dbname="${1:-}"
  local cli sock_args=()
  cli="$(hm_mysql_cli)" || { hm_err "Brak mysql/mariadb."; return 1; }
  if [[ -n "${dbname}" ]]; then
    hm_is_valid_db_name "${dbname}" || { hm_err "Nieprawidłowa nazwa bazy: ${dbname}"; return 1; }
    hm_mysql_db_exists "${dbname}" || { hm_err "Baza nie istnieje: ${dbname}"; return 1; }
  fi
  [[ -n "${MYSQL_SOCKET:-}" ]] && sock_args=(--socket="${MYSQL_SOCKET}")
  hm_info "Konsola ${cli}${dbname:+ → ${dbname}} (exit / \\q aby wyjść)"
  if [[ -n "${dbname}" ]]; then
    "${cli}" "${sock_args[@]}" -- "${dbname}"
  else
    "${cli}" "${sock_args[@]}"
  fi
}

hm_mysql_top() {
  local cli sock_args=()
  cli="$(hm_mysql_cli)" || { hm_err "Brak mysql/mariadb."; return 1; }
  [[ -n "${MYSQL_SOCKET:-}" ]] && sock_args=(--socket="${MYSQL_SOCKET}")

  echo "${C_BOLD}MySQL / MariaDB — status${C_RESET}"
  local tc maxc slow buf
  tc="$(hm_mysql_exec -e "SHOW GLOBAL STATUS LIKE 'Threads_connected';" 2>/dev/null | awk '{print $2}')"
  maxc="$(hm_mysql_exec -e "SHOW GLOBAL VARIABLES LIKE 'max_connections';" 2>/dev/null | awk '{print $2}')"
  slow="$(hm_mysql_exec -e "SHOW GLOBAL STATUS LIKE 'Slow_queries';" 2>/dev/null | awk '{print $2}')"
  buf="$(hm_mysql_exec -e "SHOW GLOBAL VARIABLES LIKE 'innodb_buffer_pool_size';" 2>/dev/null | awk '{print $2}')"
  echo "  Threads_connected : ${tc:--} / max_connections ${maxc:--}"
  echo "  Slow_queries      : ${slow:--}"
  if [[ -n "${buf}" && "${buf}" =~ ^[0-9]+$ ]]; then
    echo "  innodb_buffer_pool: $(hm_human_size "${buf}")"
  else
    echo "  innodb_buffer_pool: ${buf:--}"
  fi
  echo
  echo "${C_BOLD}SHOW FULL PROCESSLIST${C_RESET}"
  # pełny output z nagłówkami (nie -N)
  if [[ -n "${MYSQL_SOCKET:-}" ]]; then
    "${cli}" --socket="${MYSQL_SOCKET}" -e "SHOW FULL PROCESSLIST;" 2>/dev/null || hm_err "PROCESSLIST nieudany"
  else
    "${cli}" -e "SHOW FULL PROCESSLIST;" 2>/dev/null || hm_err "PROCESSLIST nieudany"
  fi
}

hm_mysql_optimize() {
  local dbname="$1"
  local before after freed
  hm_is_valid_db_name "${dbname}" || { hm_err "Nieprawidłowa nazwa bazy: ${dbname}"; return 1; }
  hm_mysql_db_exists "${dbname}" || { hm_err "Baza nie istnieje: ${dbname}"; return 1; }

  before="$(hm_db_size_bytes "${dbname}")"
  echo "${C_BOLD}Optimize — ${dbname}${C_RESET}"
  echo "  Rozmiar przed: $(hm_human_size "${before}")"

  # Data_free top (fragmentacja)
  echo "  Tabele z Data_free > 0 (top 10):"
  hm_mysql_exec -e "
SELECT table_name, data_free, data_length
FROM information_schema.tables
WHERE table_schema=$(hm_sql_quote "${dbname}") AND data_free > 0
ORDER BY data_free DESC LIMIT 10;
" 2>/dev/null | awk 'NF{printf "    %-40s free=%s\n", $1, $2}' || echo "    (brak / brak dostępu)"

  if ! hm_confirm_plan "mysql optimize — ${dbname}" \
    "Defragmentacja tabel (Data_free)." \
    "Uruchomienie mysqlcheck --optimize dla wszystkich tabel w bazie ${dbname} (rozmiar przed: $(hm_human_size "${before}"))"; then
    return 0
  fi

  local checkcli=""
  if hm_have_cmd mysqlcheck; then
    checkcli=mysqlcheck
  elif hm_have_cmd mariadb-check; then
    checkcli=mariadb-check
  fi
  if [[ -z "${checkcli}" ]]; then
    hm_err "Brak mysqlcheck/mariadb-check."
    return 1
  fi

  local sock_args=()
  [[ -n "${MYSQL_SOCKET:-}" ]] && sock_args=(--socket="${MYSQL_SOCKET}")
  hm_status_line "mysqlcheck --optimize ${dbname}..."
  "${checkcli}" "${sock_args[@]}" --optimize --databases "${dbname}" || {
    hm_warn "mysqlcheck zakończył się z ostrzeżeniem/błędem."
  }
  hm_status_clear

  after="$(hm_db_size_bytes "${dbname}")"
  freed=$(( before - after ))
  [[ "${freed}" -lt 0 ]] && freed=0
  echo "  Rozmiar po   : $(hm_human_size "${after}")"
  echo "  Odzyskane ≈  : $(hm_human_size "${freed}") (orientacyjnie)"
  hm_ok "Optimize ${dbname} zakończony."
}

hm_mysql_create() {
  local dbname="$1"
  local dbuser="${2:-}"
  local pass
  hm_is_valid_db_name "${dbname}" || { hm_err "Nieprawidłowa nazwa bazy: ${dbname}"; return 1; }
  if hm_mysql_db_exists "${dbname}"; then
    hm_err "Baza już istnieje: ${dbname}"
    return 1
  fi
  if [[ -z "${dbuser}" ]]; then
    dbuser="${dbname}"
  fi
  # user MySQL — ta sama biała lista co nazwa DB
  if ! hm_is_valid_db_name "${dbuser}"; then
    hm_err "Nieprawidłowa nazwa użytkownika DB: ${dbuser}"
    return 1
  fi
  pass="$(hm_gen_password)"
  [[ -n "${pass}" && ${#pass} -ge 12 ]] || { hm_err "Nie udało się wygenerować hasła."; return 1; }

  if ! hm_confirm_plan "mysql create — ${dbname}" \
    "Hasło użytkownika zostanie wyświetlone po utworzeniu." \
    "Utworzenie bazy danych \`${dbname}\` (utf8mb4_unicode_ci)" \
    "Utworzenie użytkownika '${dbuser}'@'localhost' z wygenerowanym hasłem" \
    "Nadanie pełnych uprawnień (GRANT ALL PRIVILEGES) do \`${dbname}\`.* i FLUSH PRIVILEGES"; then
    return 0
  fi

  # nazwy już na białej liście — backtick / quote bezpieczne
  local uq pq
  uq="$(hm_sql_quote "${dbuser}")"
  pq="$(hm_sql_quote "${pass}")"
  hm_mysql_exec -e "CREATE DATABASE \`${dbname}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || {
    hm_err "CREATE DATABASE nieudany."
    return 1
  }
  hm_mysql_exec -e "CREATE USER ${uq}@'localhost' IDENTIFIED BY ${pq};" || {
    hm_err "CREATE USER nieudany (baza ${dbname} już istnieje — usuń ręcznie jeśli trzeba)."
    return 1
  }
  hm_mysql_exec -e "GRANT ALL PRIVILEGES ON \`${dbname}\`.* TO ${uq}@'localhost'; FLUSH PRIVILEGES;" || {
    hm_err "GRANT nieudany."
    return 1
  }

  hm_ok "Utworzono bazę ${dbname} + użytkownika ${dbuser}@localhost"
  echo
  echo "  ${C_BOLD}Hasło (zapisz — nie będzie pokazane ponownie):${C_RESET}"
  echo "  ${pass}"
  echo
  if [[ "${PANEL:-}" == "cyberpanel" ]]; then
    hm_warn "CyberPanel może nie widzieć tej bazy w panelu — ewentualnie dodaj ją też w CP."
  fi
}
