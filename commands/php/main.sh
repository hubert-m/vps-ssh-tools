#!/usr/bin/env bash
# Moduł: php


_hm_cmd_help php <<'EOF'
Użycie:
  php                      Lista LSPHP + Candidate z repo (hm_pkg_*);
                           na dole: nowsze gałęzie dostępne do instalacji (stable/niepewna)
  php --refresh | -r       Odśwież indeks pakietów, potem lista
  php check-update         Alias: php --refresh
  php --phpnet             Opcjonalnie: porównanie z php.net (HTTP)
  php update <ver>         Alias: update-php <ver> (też instalacja nowej gałęzi)
  php set <ver>            W kontekście: przełącz LSPHP strony (vhost/CyberPanel)
  php ext [list] [ver]     Moduły php -m + status kluczowych rozszerzeń
  php ext install <n> [ver] Instalacja lsphpXX-<n> (apt/dnf/yum)
  php ini [ver]            Limity php.ini + nadpisania vhost / .user.ini
  php ini set <k> <v> [--vhost|--global]
  php restart [--global]   Kill workerów lsphp (Detached Mode) + ols reload
  php ps                   Procesy lsphp (CPU/RAM)

W kontekście (use <domena>): php set / ext / ini / restart działają na tej stronie.
EOF

_hm_cmd_help update-php <<'EOF'
Użycie:
  update-php <wersja>
  php update <wersja>

Przykłady:
  update-php 8.4
  update-php 84
  php update lsphp83

Działanie:
  1) pokazuje wersję lokalną vs Candidate z repozytorium
  2) przy braku nowszej wersji proponuje odświeżenie indeksu
  3) pyta o potwierdzenie [t/N]
  4) aktualizuje pakiety lsphpXX* (apt/dnf/yum)
  5) przeładowuje OpenLiteSpeed

Źródło: to samo repo LiteSpeed, z którego instaluje update-php (nie php.net).
EOF

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
