#!/usr/bin/env bash
# Komenda: webs / use

cmd_webs() {
  local quick=0
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --quick|-q) quick=1 ;;
      --help|-h)
        echo "Użycie: webs [--quick]"
        echo "  Lista usług webowych. --quick pomija liczenie rozmiaru (szybciej)."
        return 0
        ;;
    esac
  done
  hm_list_sites "${quick}"
}

cmd_use() {
  local arg="$1"
  if [[ -z "${arg}" ]]; then
    hm_err "Użycie: use <numer|domena>"
    return 1
  fi
  local domain
  domain="$(hm_find_site_by_arg "${arg}")" || return 1
  hm_set_site_context "${domain}"
  hm_ok "Kontekst: ${domain}"
  hm_info "Komendy: info size dbs ssl php logs backup clean help exit"
}
