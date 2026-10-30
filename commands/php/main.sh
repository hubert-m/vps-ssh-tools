#!/usr/bin/env bash
# Moduł: php

_HM_PHP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=repo.sh
source "${_HM_PHP_DIR}/repo.sh"
# shellcheck source=manage.sh
source "${_HM_PHP_DIR}/manage.sh"
# shellcheck source=update.sh
source "${_HM_PHP_DIR}/update.sh"

cmd_php() {
  local sub="${1:-}"
  case "${sub}" in
    update|upgrade)
      shift || true
      cmd_update_php "$@"
      ;;
    set|use-version|switch)
      shift || true
      hm_php_set_site "$@"
      ;;
    ext|modules|module|extensions)
      shift || true
      hm_php_ext_cmd "$@"
      ;;
    ini|conf)
      shift || true
      hm_php_ini_cmd "$@"
      ;;
    restart|reload-workers|kill)
      shift || true
      hm_php_restart "$@"
      ;;
    ps|proc|procs|processes)
      shift || true
      hm_php_ps "$@"
      ;;
    --refresh|-r|check-update)
      hm_php_pkg_refresh || return $?
      echo
      echo "${C_BOLD}Dostępne LSPHP${C_RESET} ${C_DIM}(+ porównanie z repozytorium)${C_RESET}"
      echo
      hm_list_available_php
      ;;
    --phpnet)
      echo "${C_BOLD}Dostępne LSPHP${C_RESET} ${C_DIM}(+ porównanie z php.net)${C_RESET}"
      echo
      hm_list_available_php --phpnet
      ;;
    help|-h|--help)
      hm_help_topic php
      ;;
    "")
      if [[ -n "${HM_SITE_DOMAIN}" ]]; then
        cmd_site_php
      else
        echo "${C_BOLD}Dostępne LSPHP${C_RESET} ${C_DIM}(+ porównanie z repozytorium)${C_RESET}"
        echo
        hm_list_available_php
      fi
      ;;
    *)
      # php 8.3 → traktuj jak listing dla wersji? nie — tylko znane sub
      hm_err "Nieznana podkomenda: ${sub}. Zobacz: php help"
      return 1
      ;;
  esac
}

_hm_cmd_register php cmd_php 0
_hm_cmd_register update-php cmd_update_php 0 php-update
