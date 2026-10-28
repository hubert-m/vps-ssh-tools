#!/usr/bin/env bash
# Komenda: ols / lsws (+ htaccess/proxy w kontekście strony)

cmd_ols() {
  hm_detect_all
  local sub="${1:-status}"
  shift || true

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
      if hm_ols_reload_soft; then
        hm_ok "OLS reload OK."
      else
        hm_err "Nie udało się przeładować OLS (lswsctrl / systemctl)."
        return 1
      fi
      ;;
    restart)
      if ! hm_confirm_plan "ols restart" \
        "Chwilowe przerwanie połączeń HTTP/HTTPS dla wszystkich vhostów." \
        "Zatrzymanie i ponowne uruchomienie procesu głównego OpenLiteSpeed (${OLS_CTRL} restart)"; then
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
        tail -n "${1:-50}" "${logf}"
      else
        hm_err "Brak ${logf}"
        return 1
      fi
      ;;
    stats|stat)
      hm_ols_stats_print
      ;;
    top)
      hm_ols_top
      ;;
    htaccess|hta)
      cmd_ols_htaccess "$@"
      ;;
    cache|lscache)
      cmd_ols_cache "$@"
      ;;
    proxy)
      cmd_ols_proxy "$@"
      ;;
    admin|webadmin)
      cmd_ols_admin "$@"
      ;;
    help|-h|--help)
      cat <<'EOF'
Użycie: ols [status|reload|restart|log|stats|top|htaccess|cache|proxy|admin]

  status              Stan / wersja / proces
  reload              Przeładowanie konfiguracji
  restart             Restart (z potwierdzeniem)
  log [N]             Ostatnie N linii error.log (domyślnie 50)
  stats | top         Live .rtreport (RPS, vhosty, WAITQUE LSAPI); top = odświeżanie
  htaccess [enable]   Diagnostyka .htaccess / autoLoadHtaccess (kontekst lub domena)
  cache [status|flush [domena|all]]
  proxy [set-port PORT [nazwa]]
  admin [status|pass] WebAdmin (port, tunel SSH, admpass.sh)
EOF
      ;;
    *)
      hm_err "Nieznane: ${sub}. ols help"
      return 1
      ;;
  esac
}

cmd_ols_htaccess() {
  local sub="${1:-}"
  case "${sub}" in
    enable|on)
      shift || true
      hm_ols_htaccess_enable "${1:-${HM_SITE_DOMAIN:-}}"
      ;;
    ""|check|status)
      shift || true
      hm_ols_htaccess_check "${1:-${HM_SITE_DOMAIN:-}}"
      ;;
    help|-h|--help)
      echo "Użycie: ols htaccess [check|enable] [domena]"
      echo "  W kontekście strony: htaccess / htaccess enable"
      ;;
    *)
      # traktuj jako domenę
      hm_ols_htaccess_check "${sub}"
      ;;
  esac
}

cmd_ols_cache() {
  local sub="${1:-status}"
  shift || true
  case "${sub}" in
    status|show|"")
      hm_ols_cache_status "${1:-${HM_SITE_DOMAIN:-}}"
      ;;
    flush|clear|purge)
      hm_ols_cache_flush "${1:-}"
      ;;
    help|-h|--help)
      echo "Użycie: ols cache [status|flush [domena|all]]"
      ;;
    *)
      # status dla podanej domeny
      hm_ols_cache_status "${sub}"
      ;;
  esac
}

cmd_ols_proxy() {
  local sub="${1:-}"
  case "${sub}" in
    ""|status|check|list)
      shift || true
      hm_ols_proxy_status "${1:-${HM_SITE_DOMAIN:-}}"
      ;;
    set-port|port|setport)
      shift || true
      local port="${1:-}" name="${2:-}"
      [[ -n "${port}" ]] || { hm_err "Użycie: ols proxy set-port <port> [nazwa]"; return 1; }
      hm_ols_proxy_set_port "${HM_SITE_DOMAIN:-}" "${port}" "${name}"
      ;;
    help|-h|--help)
      echo "Użycie: ols proxy [status] [domena]"
      echo "        ols proxy set-port <port> [nazwa]   (w kontekście strony)"
      echo "  W kontekście: proxy / proxy set-port <port>"
      ;;
    *)
      if hm_is_valid_domain "${sub}"; then
        hm_ols_proxy_status "${sub}"
      else
        hm_err "Nieznane: ${sub}. ols proxy help"
        return 1
      fi
      ;;
  esac
}

cmd_ols_admin() {
  local sub="${1:-status}"
  case "${sub}" in
    status|"" )
      hm_ols_admin_status
      ;;
    pass|password|passwd|admpass)
      hm_ols_admin_pass
      ;;
    help|-h|--help)
      echo "Użycie: ols admin [status|pass]"
      ;;
    *)
      hm_err "Nieznane: ${sub}. ols admin help"
      return 1
      ;;
  esac
}

# Aliasy w kontekście strony
cmd_site_htaccess() {
  cmd_ols_htaccess "$@"
}

cmd_site_proxy() {
  # bez domeny — zawsze bieżący kontekst
  local sub="${1:-}"
  case "${sub}" in
    set-port|port|setport)
      shift || true
      local port="${1:-}" name="${2:-}"
      [[ -n "${port}" ]] || { hm_err "Użycie: proxy set-port <port> [nazwa]"; return 1; }
      hm_ols_proxy_set_port "${HM_SITE_DOMAIN}" "${port}" "${name}"
      ;;
    ""|status|check)
      hm_ols_proxy_status_domain "${HM_SITE_DOMAIN}"
      ;;
    help|-h|--help)
      echo "Użycie: proxy [status|set-port <port> [nazwa]]"
      ;;
    *)
      hm_err "Nieznane: ${sub}. proxy help"
      return 1
      ;;
  esac
}
