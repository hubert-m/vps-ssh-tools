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
    config|path|root)
      # jednorazowe wskazanie katalogu root na Google Drive
      hm_backup_config_root
      ;;
    show|status)
      hm_load_config
      echo "${C_BOLD}Backup — Google Drive${C_RESET}"
      echo "  RCLONE_REMOTE : ${RCLONE_REMOTE:-brak}"
      echo "  Struktura:"
      echo "    ${RCLONE_REMOTE}/full/<stamp>/     — pełne kopie"
      echo "    ${RCLONE_REMOTE}/<domena>/<stamp>/ — kopie stron"
      echo "    ${RCLONE_REMOTE}/db-dumps/         — zrzuty mysql dump"
      if hm_have_cmd rclone && [[ -n "${RCLONE_REMOTE:-}" ]]; then
        echo
        hm_info "Zawartość root:"
        rclone lsd "${RCLONE_REMOTE}" 2>/dev/null | sed 's/^/  /' || hm_warn "Brak listingu (sprawdź połączenie)."
      fi
      ;;
    full|server)
      hm_load_config
      echo "Root Drive: ${RCLONE_REMOTE}"
      echo "Cel:       ${RCLONE_REMOTE}/full/<stamp>/"
      if ! hm_confirm "Uruchomić pełny backup serwera na Google Drive"; then
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
      hm_load_config
      echo "Root Drive: ${RCLONE_REMOTE}"
      echo "Cel:       ${RCLONE_REMOTE}/${domain}/<stamp>/"
      hm_backup_site "${domain}"
      ;;
    test)
      hm_load_config
      hm_rclone_test
      ;;
    ""|help|-h|--help)
      hm_help_topic backup
      ;;
    *)
      if [[ -n "${HM_SITE_DOMAIN}" && -z "${sub}" ]]; then
        hm_backup_site "${HM_SITE_DOMAIN}"
      else
        hm_err "Nieznana podkomenda: ${sub}. Zobacz: backup help"
        return 1
      fi
      ;;
  esac
}
