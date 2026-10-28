#!/usr/bin/env bash
# Komenda: webs / use / delete-site

cmd_webs() {
  local sub="${1:-}"
  case "${sub}" in
    delete|remove|destroy|rm)
      shift || true
      hm_site_delete "$@"
      return $?
      ;;
    archive)
      shift || true
      hm_backup_archive_site "${1:-${HM_SITE_DOMAIN}}"
      return $?
      ;;
    --help|-h|help)
      hm_help_topic webs
      return 0
      ;;
  esac

  local quick=0
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --quick|-q) quick=1 ;;
      --help|-h)
        hm_help_topic webs
        return 0
        ;;
    esac
  done
  hm_list_sites "${quick}"
}

cmd_use() {
  local arg="${1:-}"
  if [[ -z "${arg}" ]]; then
    hm_err "Użycie: use <numer|domena>"
    return 1
  fi
  local domain
  domain="$(hm_find_site_by_arg "${arg}")" || return 1
  hm_set_site_context "${domain}"
  hm_ok "Kontekst: ${domain}"
  hm_info "Komendy: info size dbs ssl renew-ssl php logs cron pm2 backup clean delete-site help exit"
}
