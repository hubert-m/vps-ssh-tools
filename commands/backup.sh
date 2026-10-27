#!/usr/bin/env bash
# Komenda globalna: backup

cmd_backup() {
  local sub="${1:-}"
  shift || true
  case "${sub}" in
    setup)
      local script="${HMTOOLS_ROOT}/scripts/setup-rclone.sh"
      if [[ -x "${script}" ]]; then
        bash "${script}"
      else
        hm_err "Brak ${script}"
        return 1
      fi
      ;;
    full|server)
      if ! hm_confirm "Uruchomić pełny backup serwera na Google Drive?"; then
        hm_info "Anulowano."
        return 0
      fi
      hm_backup_full
      ;;
    site)
      local domain="${1:-${HM_SITE_DOMAIN}}"
      if [[ -z "${domain}" ]]; then
        hm_err "Użycie: backup site <domena>  (lub wejdź w kontekst)"
        return 1
      fi
      if [[ -z "${HM_SITE_DOMAIN}" || "${HM_SITE_DOMAIN}" != "${domain}" ]]; then
        domain="$(hm_find_site_by_arg "${domain}")" || return 1
      fi
      hm_backup_site "${domain}"
      ;;
    test)
      hm_load_config
      hm_rclone_test
      ;;
    ""|help|-h|--help)
      cat <<'EOF'
Użycie: backup <setup|full|site|test>
  setup   Konfiguracja rclone + Google Drive
  full    Pełna kopia serwera (konfigi + DB + wszystkie strony)
  site    Kopia jednej strony (wymaga domeny lub kontekstu)
  test    Test połączenia rclone
EOF
      ;;
    *)
      # jeśli jesteśmy w kontekście i podano nic sensownego — backup site
      if [[ -n "${HM_SITE_DOMAIN}" && -z "${sub}" ]]; then
        hm_backup_site "${HM_SITE_DOMAIN}"
      else
        hm_err "Nieznana podkomenda: ${sub}. Zobacz: backup help"
        return 1
      fi
      ;;
  esac
}
