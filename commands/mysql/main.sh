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

W kontekście bez [db] — pierwsza wykryta baza strony.
--min-size: 1G, 1GB, 500M, 1024K lub bajty.
EOF

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
