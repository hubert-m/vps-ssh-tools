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
      local db="${1:-}"
      [[ -n "${db}" ]] || { hm_err "Użycie: mysql dump <nazwa_bazy>"; return 1; }
      if ! hm_is_valid_db_name "${db}"; then
        hm_err "Nieprawidłowa nazwa bazy: ${db}"
        return 1
      fi
      hm_load_config
      hm_rclone_check || return 1
      hm_backup_check_space || return 1
      local dest
      dest="$(hm_backup_dest_dbdump "${db}" "$(hm_backup_stamp)")"
      hm_stream_mysqldump "${db}" "${dest}"
      ;;
    help|-h|--help)
      cat <<'EOF'
Użycie: mysql|dbs [list|dump <db>]
  list   Lista baz (w kontekście: tylko powiązane ze stroną)
  dump   Zrzut jednej bazy → Google Drive (stream)
EOF
      ;;
    *)
      hm_err "Nieznane: ${sub}"
      return 1
      ;;
  esac
}

cmd_dbs() {
  cmd_mysql "$@"
}
