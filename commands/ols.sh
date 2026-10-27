#!/usr/bin/env bash
# Komenda: ols

cmd_ols() {
  hm_detect_all
  local sub="${1:-status}"

  if [[ -z "${OLS_ROOT}" && "${WEBSERVER}" != "openlitespeed" && "${WEBSERVER}" != "litespeed" ]]; then
    hm_warn "OpenLiteSpeed nie wykryty (WEBSERVER=${WEBSERVER})."
  fi

  case "${sub}" in
    status)
      echo "OLS_ROOT : ${OLS_ROOT:--}"
      echo "WEBSERVER: ${WEBSERVER}"
      if [[ -x "${OLS_CTRL}" ]]; then
        "${OLS_CTRL}" status 2>/dev/null || true
      fi
      if hm_have_cmd systemctl; then
        systemctl is-active lshttpd 2>/dev/null || systemctl is-active lsws 2>/dev/null || true
      fi
      if [[ -x "${OLS_BIN}" ]]; then
        "${OLS_BIN}" -v 2>/dev/null || true
      fi
      pgrep -a lshttpd 2>/dev/null | head -5 || true
      ;;
    reload)
      if [[ -x "${OLS_CTRL}" ]]; then
        "${OLS_CTRL}" reload && hm_ok "OLS reload OK."
      else
        hm_err "Brak lswsctrl."
        return 1
      fi
      ;;
    restart)
      if ! hm_confirm "Zrestartować OpenLiteSpeed?"; then
        return 0
      fi
      if [[ -x "${OLS_CTRL}" ]]; then
        "${OLS_CTRL}" restart && hm_ok "OLS restart OK."
      else
        hm_err "Brak lswsctrl."
        return 1
      fi
      ;;
    log|logs|error)
      local logf="${OLS_ROOT}/logs/error.log"
      if [[ -f "${logf}" ]]; then
        tail -n "${2:-50}" "${logf}"
      else
        hm_err "Brak ${logf}"
        return 1
      fi
      ;;
    help|-h|--help)
      echo "Użycie: ols [status|reload|restart|log]"
      ;;
    *)
      hm_err "Nieznane: ${sub}. ols help"
      return 1
      ;;
  esac
}
