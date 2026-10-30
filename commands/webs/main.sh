#!/usr/bin/env bash
# Moduł: webs


_hm_cmd_help webs <<'EOF'
Użycie:
  webs [--quick|-q]              Lista usług webowych
  webs delete <n|domena> […]     Całkowite usunięcie serwisu (aliasy: remove/destroy/rm)
  webs archive <n|domena>        Archiwum na Drive → weryfikacja → usunięcie z VPS

Opcje listy:
  --quick, -q   Pomiń liczenie rozmiaru (szybciej)

Opcje delete:
  --keep-db     Nie usuwaj baz MySQL
  --keep-ssl    Nie usuwaj certyfikatów Let's Encrypt / acme.sh
  --keep-user   Nie usuwaj użytkownika Unix strony

delete/archive wymagają wpisania yes oraz dokładnej nazwy domeny.
Następnie: use <numer|domena>
Tab: use / webs delete / webs archive / delete-site / archive-site
EOF

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
