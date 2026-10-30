#!/usr/bin/env bash
# Moduł: use

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

_hm_cmd_register use cmd_use 0 enter cd
