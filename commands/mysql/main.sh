#!/usr/bin/env bash
# Komenda: mysql / dbs


_hm_cmd_help mysql <<'EOF'
Użycie:
  mysql | dbs [--json]        Lista baz (globalnie / w kontekście strony)
  mysql heavy [--min-size X]  Bazy ≥ X + tabele ≥ X (domyślnie 1G)
  mysql dump <db>             Zrzut → Google Drive
  mysql dump <db> --local [p] Lokalny .sql.gz (domyślnie <site>/backups/ lub ${TMP_DIR}/hmtools-db/ → zwykle /tmp/hmtools-backup/hmtools-db/)
  mysql dump-local [db] [p]   Alias lokalnego dumpa (p = plik lub katalog absolutny)
  mysql import <db> <plik>    Import .sql / .sql.gz (z potwierdzeniem)
  mysql cli [db]              Interaktywna konsola (dbs cli w kontekście)
  mysql top | processlist     Threads / Slow_queries / PROCESSLIST
  mysql optimize [db]         mysqlcheck --optimize + Data_free
  mysql create <db> [user]    Nowa baza + user@localhost + hasło
  mysql users                 Konta, hosty, puste hasła, host %
  mysql grant|revoke <user> <db> [--ro] [--host H]
  mysql passwd <user> [--host H] [--secret-file f]
  mysql slow [--since 24h] [--top 10] [--enable|--disable]
  mysql tune                  Porady (bez zapisu my.cnf)

W kontekście bez [db] — pierwsza wykryta baza strony.
--min-size: 1G, 1GB, 500M, 1024K lub bajty.
EOF

hm_mysql_user_protected() {
  case "${1:-}" in
    root|mysql.sys|mysql.session|mysql.infoschema|debian-sys-maint|cyberpanel|mariadb.sys)
      return 0 ;;
    *) return 1 ;;
  esac
}

cmd_mysql_users() {
  local line user host pwd flag
  echo "${C_BOLD}mysql users${C_RESET}"
  if [[ "${HMTOOLS_TEST:-}" == "1" && -n "${HM_MYSQL_USERS_FIXTURE:-}" ]]; then
    while IFS=$'\t' read -r user host pwd flag || [[ -n "${user}" ]]; do
      [[ -z "${user}" ]] && continue
      if [[ "${pwd}" == "EMPTY" ]]; then
        printf '%s\t%s\t%s%s%s\t%s\n' "${user}" "${host}" "${C_RED:-}" "EMPTY WARN" "${C_RESET:-}" "${flag:-}"
      else
        printf '%s\t%s\t%s\t%s\n' "${user}" "${host}" "${pwd}" "${flag:-}"
      fi
    done < "${HM_MYSQL_USERS_FIXTURE}"
    if [[ -n "${HM_MYSQL_GRANTS_FIXTURE:-}" && -f "${HM_MYSQL_GRANTS_FIXTURE}" ]]; then
      echo
      echo "${C_DIM}Granty (skrót):${C_RESET}"
      cat "${HM_MYSQL_GRANTS_FIXTURE}"
    fi
    return 0
  fi
  while IFS=$'\t' read -r user host pwd flag || [[ -n "${user}" ]]; do
    [[ -z "${user}" ]] && continue
    if [[ "${pwd}" == "EMPTY" ]]; then
      printf '%s\t%s\t%sEMPTY WARN%s\t%s\n' "${user}" "${host}" "${C_RED:-}" "${C_RESET:-}" "${flag}"
    else
      printf '%s\t%s\t%s\t%s\n' "${user}" "${host}" "${pwd}" "${flag}"
    fi
  done < <(hm_mysql_exec -N -e "
SELECT user, host,
  IF(authentication_string='' OR authentication_string IS NULL,'EMPTY','set') AS pwd,
  IF(host='%','WILDCARD','ok') AS host_flag
FROM mysql.user
ORDER BY user, host;" 2>/dev/null) || {
    hm_err "Nie odczytano mysql.user"
    return 1
  }
  echo
  echo "${C_DIM}Granty (skrót):${C_RESET}"
  # mysql.db — SCHEMA_PRIVILEGES bywa puste przy grantach per-DB w MariaDB
  hm_mysql_exec -N -e "
SELECT CONCAT(User,'@',Host) AS who, Db,
  CONCAT_WS(',',
    IF(Select_priv='Y','SELECT',NULL),
    IF(Insert_priv='Y','INSERT',NULL),
    IF(Update_priv='Y','UPDATE',NULL),
    IF(Delete_priv='Y','DELETE',NULL),
    IF(Create_priv='Y','CREATE',NULL),
    IF(Drop_priv='Y','DROP',NULL),
    IF(Index_priv='Y','INDEX',NULL),
    IF(Alter_priv='Y','ALTER',NULL),
    IF(Grant_priv='Y','GRANT',NULL)
  ) AS privs
FROM mysql.db
WHERE Db NOT IN ('information_schema','performance_schema','mysql','sys')
  AND Db NOT LIKE '\_\_%'
ORDER BY User, Host, Db
LIMIT 200;" 2>/dev/null || true
}

cmd_mysql_grant() {
  local user="${1:-}" db="${2:-}" host="localhost" ro=0 a
  shift 2 || true
  while [[ $# -gt 0 ]]; do
    a="$1"; shift || true
    case "${a}" in
      --ro|--readonly) ro=1 ;;
      --host) host="${1:-localhost}"; shift || true ;;
      --host=*) host="${a#--host=}" ;;
      *) hm_err "Nieznane: ${a}"; return 1 ;;
    esac
  done
  [[ -n "${user}" && -n "${db}" ]] || { hm_err "Użycie: mysql grant <user> <db> [--ro] [--host H]"; return 1; }
  hm_mysql_user_protected "${user}" && { hm_err "Konto chronione: ${user}"; return 1; }
  local uq dq priv
  uq="$(hm_sql_quote "${user}")"
  dq="$(hm_sql_quote "${db}")"
  if [[ "${ro}" -eq 1 ]]; then
    priv="SELECT, SHOW VIEW"
  else
    priv="ALL PRIVILEGES"
  fi
  hm_mysql_exec -e "GRANT ${priv} ON \`${db//\`/}\`.* TO ${uq}@$(hm_sql_quote "${host}"); FLUSH PRIVILEGES;" \
    && hm_ok "GRANT ${user}@${host} → ${db} (${priv})"
}

cmd_mysql_revoke() {
  local user="${1:-}" db="${2:-}" host="localhost" a
  shift 2 || true
  while [[ $# -gt 0 ]]; do
    a="$1"; shift || true
    case "${a}" in
      --host) host="${1:-localhost}"; shift || true ;;
      --host=*) host="${a#--host=}" ;;
      *) hm_err "Nieznane: ${a}"; return 1 ;;
    esac
  done
  [[ -n "${user}" && -n "${db}" ]] || { hm_err "Użycie: mysql revoke <user> <db> [--host H]"; return 1; }
  hm_mysql_user_protected "${user}" && { hm_err "Konto chronione: ${user}"; return 1; }
  local uq
  uq="$(hm_sql_quote "${user}")"
  hm_confirm_plan "mysql revoke" "Odbiera uprawnienia ${user}@${host} do ${db}." \
    "REVOKE ALL ON \`${db}\`.* FROM ${user}@${host}" || return 0
  # GRANT OPTION nie łączy się z ALL PRIVILEGES na db.* — osobne REVOKE.
  local dbq hq
  dbq="${db//\`/}"
  hq="$(hm_sql_quote "${host}")"
  hm_mysql_exec -e "REVOKE ALL PRIVILEGES ON \`${dbq}\`.* FROM ${uq}@${hq};" || return 1
  hm_mysql_exec -e "REVOKE GRANT OPTION ON \`${dbq}\`.* FROM ${uq}@${hq};" 2>/dev/null || true
  hm_mysql_exec -e "FLUSH PRIVILEGES;" \
    && hm_ok "REVOKE ${user}@${host} ← ${db}"
}

cmd_mysql_passwd() {
  local user="${1:-}" host="localhost" secret_file="" a pass
  shift || true
  while [[ $# -gt 0 ]]; do
    a="$1"; shift || true
    case "${a}" in
      --host) host="${1:-localhost}"; shift || true ;;
      --host=*) host="${a#--host=}" ;;
      --secret-file) secret_file="${1:-}"; shift || true ;;
      --secret-file=*) secret_file="${a#--secret-file=}" ;;
      *) hm_err "Nieznane: ${a}"; return 1 ;;
    esac
  done
  [[ -n "${user}" ]] || { hm_err "Użycie: mysql passwd <user> [--host H] [--secret-file f]"; return 1; }
  hm_mysql_user_protected "${user}" && { hm_err "Konto chronione: ${user}"; return 1; }
  # Bez TTY i bez --secret-file: nie generuj hasła, którego nie da się bezpiecznie pokazać.
  if [[ -z "${secret_file}" ]] && declare -F hm_secret_require_delivery >/dev/null 2>&1; then
    hm_secret_require_delivery || return 1
  fi
  if [[ -n "${secret_file}" ]]; then
    [[ -f "${secret_file}" && ! -L "${secret_file}" ]] || { hm_err "Brak pliku sekretu."; return 1; }
    pass="$(tr -d '\r\n' < "${secret_file}")"
  else
    pass="$(openssl rand -base64 24 2>/dev/null | tr -d '/+=' | head -c 24)"
    [[ -n "${pass}" ]] || pass="$(head -c 24 /dev/urandom | base64 | tr -d '/+=\n' | head -c 24)"
  fi
  local sqlf uq hq
  uq="$(hm_sql_quote "${user}")"
  hq="$(hm_sql_quote "${host}")"
  sqlf="$(mktemp)"
  chmod 0600 "${sqlf}"
  printf "ALTER USER %s@%s IDENTIFIED BY %s; FLUSH PRIVILEGES;\n" \
    "${uq}" "${hq}" "$(hm_sql_quote "${pass}")" > "${sqlf}"
  if hm_mysql_exec < "${sqlf}"; then
    hm_ok "Hasło zmienione dla ${user}@${host}"
    hm_print_secret "${pass}"
  else
    hm_err "ALTER USER nieudany"
    rm -f "${sqlf}"
    return 1
  fi
  rm -f "${sqlf}"
}

hm_mysql_slow_log_path() {
  if [[ -n "${HM_MYSQL_SLOW_LOG:-}" ]]; then
    printf '%s' "${HM_MYSQL_SLOW_LOG}"
    return 0
  fi
  hm_mysql_exec -N -e "SHOW VARIABLES LIKE 'slow_query_log_file';" 2>/dev/null \
    | awk '{print $2; exit}'
}

cmd_mysql_slow() {
  local since="24h" top=10 enable="" a
  while [[ $# -gt 0 ]]; do
    a="$1"; shift || true
    case "${a}" in
      --since) since="${1:-24h}"; shift || true ;;
      --since=*) since="${a#--since=}" ;;
      --top) top="${1:-10}"; shift || true ;;
      --top=*) top="${a#--top=}" ;;
      --enable) enable=1 ;;
      --disable) enable=0 ;;
      help|-h|--help)
        echo "Użycie: mysql slow [--since 24h] [--top 10] [--enable|--disable]"
        return 0
        ;;
      *) hm_err "Nieznane: ${a}"; return 1 ;;
    esac
  done
  if [[ -n "${enable}" ]]; then
    if [[ "${enable}" -eq 1 ]]; then
      hm_confirm_plan "mysql slow --enable" "Włącza slow_query_log." "SET GLOBAL slow_query_log=ON" || return 0
      hm_mysql_exec -e "SET GLOBAL slow_query_log=ON; SET GLOBAL long_query_time=1;" && hm_ok "slow_query_log ON"
    else
      hm_confirm_plan "mysql slow --disable" "Wyłącza slow_query_log." "SET GLOBAL slow_query_log=OFF" || return 0
      hm_mysql_exec -e "SET GLOBAL slow_query_log=OFF;" && hm_ok "slow_query_log OFF"
    fi
    return 0
  fi
  local path
  path="$(hm_mysql_slow_log_path)"
  [[ -n "${path}" && -f "${path}" ]] || { hm_err "Brak slow logu (${path:-pusto}). Użyj --enable."; return 1; }
  echo "${C_BOLD}mysql slow — top ${top}${C_RESET} (${path})"
  # Normalizacja: usuń liczby, zlicz fingerprinty (uprośczenie pt-query-digest)
  awk '
    /^# Query_time:/{
      qt=$3; getline
      while ($0 ~ /^#/ || $0 ~ /^SET / || $0=="") { if (!getline) exit }
      q=$0
      gsub(/[0-9]+/,"N",q)
      gsub(/[ \t]+/," ",q)
      t[q]+=qt; c[q]++
    }
    END{
      for (q in t) printf "%10.3f  %5d  %s\n", t[q], c[q], q
    }
  ' "${path}" 2>/dev/null | sort -nr | head -n "${top}"
}

cmd_mysql_tune() {
  echo "${C_BOLD}mysql tune — porady (bez zapisu my.cnf)${C_RESET}"
  if [[ "${HMTOOLS_TEST:-}" == "1" && -n "${HM_MYSQL_TUNE_FIXTURE:-}" ]]; then
    cat "${HM_MYSQL_TUNE_FIXTURE}"
    return 0
  fi
  local ram_kb pool maxc data_mb hit tmp_disk frag
  ram_kb="$(awk '/MemTotal/{print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)"
  pool="$(hm_mysql_exec -N -e "SHOW VARIABLES LIKE 'innodb_buffer_pool_size';" 2>/dev/null | awk '{print $2; exit}')"
  maxc="$(hm_mysql_exec -N -e "SHOW VARIABLES LIKE 'max_connections';" 2>/dev/null | awk '{print $2; exit}')"
  data_mb="$(hm_mysql_exec -N -e "SELECT ROUND(SUM(data_length+index_length)/1024/1024) FROM information_schema.tables WHERE engine='InnoDB';" 2>/dev/null | tr -d '[:space:]')"
  hit="$(hm_mysql_exec -N -e "SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool_read_requests'; SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool_reads';" 2>/dev/null | awk 'NR==1{r=$2} NR==2{b=$2} END{ if(r+0>0) printf "%.1f", 100*(1-b/r); else print "?" }')"
  tmp_disk="$(hm_mysql_exec -N -e "SHOW GLOBAL STATUS LIKE 'Created_tmp_disk_tables';" 2>/dev/null | awk '{print $2; exit}')"
  frag="$(hm_mysql_exec -N -e "SELECT ROUND(SUM(data_free)/1024/1024) FROM information_schema.tables WHERE engine='InnoDB';" 2>/dev/null | tr -d '[:space:]')"
  local ram_mb=$((ram_kb / 1024))
  local pool_mb=0
  [[ "${pool}" =~ ^[0-9]+$ ]] && pool_mb=$((pool / 1024 / 1024))
  echo "  RAM ≈ ${ram_mb}M · innodb_buffer_pool_size ≈ ${pool_mb}M · dane InnoDB ≈ ${data_mb:-?}M"
  if [[ "${ram_mb}" -gt 0 && "${pool_mb}" -gt 0 ]]; then
    local sug=$((ram_mb * 50 / 100))
    [[ "${sug}" -gt 256 ]] || sug=256
    if [[ -n "${data_mb}" && "${data_mb}" =~ ^[0-9]+$ && "${data_mb}" -lt "${sug}" ]]; then
      sug=$((data_mb + 64))
    fi
    if [[ "${pool_mb}" -lt $((sug * 8 / 10)) ]]; then
      echo "  → Rozważ innodb_buffer_pool_size ≈ ${sug}M (obecnie ${pool_mb}M)."
    else
      echo "  → Buffer pool wygląda sensownie względem RAM."
    fi
  fi
  echo "  max_connections=${maxc:-?} · InnoDB buffer hit≈${hit}% · tmp_disk_tables=${tmp_disk:-?} · data_free≈${frag:-?}M"
  if [[ "${tmp_disk}" =~ ^[0-9]+$ && "${tmp_disk}" -gt 1000 ]]; then
    echo "  → Dużo Created_tmp_disk_tables — sprawdź tmp_table_size / zapytania."
  fi
  if [[ "${frag}" =~ ^[0-9]+$ && "${frag}" -gt 500 ]]; then
    echo "  → Duża fragmentacja (data_free) — rozważ OPTIMIZE TABLE dla największych tabel."
  fi
  echo "  ${C_DIM}(tylko doradztwo — bez zmian w my.cnf)${C_RESET}"
}

cmd_mysql_heavy() {
  local min_raw="1G" a
  while [[ $# -gt 0 ]]; do
    a="${1}"
    case "${a}" in
      --min-size)
        shift
        [[ -n "${1:-}" ]] || {
          hm_err "Użycie: mysql heavy --min-size <X>  (np. 1G, 1GB, 500M)"
          return 1
        }
        min_raw="${1}"
        shift
        ;;
      --min-size=*)
        min_raw="${a#--min-size=}"
        [[ -n "${min_raw}" ]] || {
          hm_err "Użycie: mysql heavy --min-size <X>  (np. 1G, 1GB, 500M)"
          return 1
        }
        shift
        ;;
      help|-h|--help)
        hm_help_topic mysql
        return 0
        ;;
      *)
        hm_err "Nieznane: mysql heavy ${a}. Użycie: mysql heavy [--min-size X]"
        return 1
        ;;
    esac
  done

  local min_bytes
  min_bytes="$(hm_parse_size_bytes "${min_raw}")" || {
    hm_err "Nieprawidłowy --min-size: '${min_raw}' (np. 1G, 1GB, 500M)."
    return 1
  }
  hm_mysql_heavy "${min_bytes}"
}

cmd_mysql() {
  local sub="${1:-list}"
  shift || true
  hm_detect_all

  case "${sub}" in
    list|ls|""|--json)
      if [[ "${sub}" == "--json" ]] || hm_has_json_flag "$@"; then
        hm_json_emit mysql
        return $?
      fi
      if [[ -n "${HM_SITE_DOMAIN}" ]]; then
        hm_print_dbs_for_site "${HM_SITE_DOMAIN}" "${HM_SITE_DOCROOT}" "${HM_SITE_ROOT}" "${HM_SITE_USER}"
      else
        echo "${C_BOLD}Bazy danych${C_RESET} ${C_DIM}(sort: rozmiar ↓)${C_RESET}"
        echo
        hm_print_all_dbs
      fi
      ;;
    heavy)
      cmd_mysql_heavy "$@"
      ;;
    dump)
      cmd_mysql_dump "$@"
      ;;
    dump-local|local-dump)
      local db path
      db="$(hm_mysql_resolve_db_arg "${1:-}")" || return 1
      shift || true
      path="${1:-}"
      hm_mysql_dump_local "${db}" "${path}"
      ;;
    import)
      local db file
      db="${1:-}"
      file="${2:-}"
      if [[ -z "${db}" || -z "${file}" ]]; then
        # w kontekście: mysql import <plik> → default db
        if [[ -n "${HM_SITE_DOMAIN}" && -n "${1:-}" && -f "${1}" ]]; then
          file="$1"
          db="$(hm_mysql_resolve_db_arg "")" || return 1
        else
          hm_err "Użycie: mysql import <db> <plik.sql|plik.sql.gz>"
          return 1
        fi
      else
        shift 2 || true
        db="$(hm_mysql_resolve_db_arg "${db}")" || return 1
      fi
      hm_mysql_import "${db}" "${file}"
      ;;
    cli|console|shell)
      local db=""
      if [[ -n "${1:-}" ]]; then
        db="$(hm_mysql_resolve_db_arg "$1")" || return 1
      elif [[ -n "${HM_SITE_DOMAIN}" ]]; then
        db="$(hm_mysql_resolve_db_arg "")" || true
      fi
      hm_mysql_cli_session "${db}"
      ;;
    top|processlist|ps)
      hm_mysql_top
      ;;
    optimize|optimise)
      local db
      db="$(hm_mysql_resolve_db_arg "${1:-}")" || return 1
      hm_mysql_optimize "${db}"
      ;;
    create)
      local db="" user="" secret_file="" a
      while [[ $# -gt 0 ]]; do
        a="$1"
        shift
        case "${a}" in
          --secret-file)
            secret_file="${1:-}"
            shift || true
            ;;
          --secret-file=*) secret_file="${a#--secret-file=}" ;;
          *)
            if [[ -z "${db}" ]]; then
              db="${a}"
            elif [[ -z "${user}" ]]; then
              user="${a}"
            else
              hm_err "Użycie: mysql create <db> [user] [--secret-file plik]"
              return 1
            fi
            ;;
        esac
      done
      [[ -n "${db}" ]] || { hm_err "Użycie: mysql create <db> [user] [--secret-file plik]"; return 1; }
      if [[ -n "${secret_file}" ]]; then
        HM_SECRET_FILE="${secret_file}" hm_mysql_create "${db}" "${user}"
      else
        hm_mysql_create "${db}" "${user}"
      fi
      ;;
    users|user)
      cmd_mysql_users "$@"
      ;;
    grant)
      cmd_mysql_grant "$@"
      ;;
    revoke)
      cmd_mysql_revoke "$@"
      ;;
    passwd|password)
      cmd_mysql_passwd "$@"
      ;;
    slow)
      cmd_mysql_slow "$@"
      ;;
    tune|tuner)
      cmd_mysql_tune "$@"
      ;;
    help|-h|--help)
      hm_help_topic mysql
      ;;
    *)
      hm_err "Nieznane: ${sub}. mysql help"
      return 1
      ;;
  esac
}

cmd_mysql_dump() {
  local db="" local_mode=0 path="" a
  local -a rest=()
  for a in "$@"; do
    case "${a}" in
      --local|-l) local_mode=1 ;;
      *)
        if [[ -z "${db}" ]]; then
          db="${a}"
        elif [[ "${local_mode}" -eq 1 && -z "${path}" && "${a}" == /* ]]; then
          path="${a}"
        elif [[ "${local_mode}" -eq 1 && -z "${path}" ]]; then
          path="${a}"
        else
          rest+=("${a}")
        fi
        ;;
    esac
  done

  db="$(hm_mysql_resolve_db_arg "${db}")" || return 1

  if [[ "${local_mode}" -eq 1 ]]; then
    hm_mysql_dump_local "${db}" "${path}"
    return $?
  fi

  hm_load_config
  hm_rclone_check || return 1
  hm_backup_check_space || return 1
  local dest
  dest="$(hm_backup_dest_dbdump "${db}" "$(hm_backup_stamp)")"
  hm_stream_mysqldump "${db}" "${dest}"
}

cmd_dbs() {
  cmd_mysql "$@"
}

_hm_cmd_register mysql cmd_mysql 0 dbs db
