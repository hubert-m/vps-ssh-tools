#!/usr/bin/env bash
# Moduł: webs

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

_hm_cmd_register webs cmd_webs 0 sites list
