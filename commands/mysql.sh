#!/usr/bin/env bash
# Komenda: mysql / dbs

cmd_mysql() {
  local sub="${1:-list}"
  shift || true
  hm_detect_all

  case "${sub}" in
    list|ls|"")
      if [[ -n "${HM_SITE_DOMAIN}" ]]; then
        hm_print_dbs_for_site "${HM_SITE_DOMAIN}" "${HM_SITE_DOCROOT}" "${HM_SITE_ROOT}" "${HM_SITE_USER}"
      else
        echo "${C_BOLD}Bazy danych${C_RESET} ${C_DIM}(sort: rozmiar ↓)${C_RESET}"
        echo
        hm_print_all_dbs
      fi
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
      local db="${1:-}" user="${2:-}"
      [[ -n "${db}" ]] || { hm_err "Użycie: mysql create <db> [user]"; return 1; }
      hm_mysql_create "${db}" "${user}"
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
