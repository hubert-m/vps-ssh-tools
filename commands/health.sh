#!/usr/bin/env bash
# Komenda: health / php (global)

cmd_health() {
  hm_detect_all
  echo "${C_BOLD}Health check${C_RESET}"
  echo "Host     : $(hostname -f 2>/dev/null || hostname)"
  echo "Panel    : ${PANEL}"
  echo "Webserver: ${WEBSERVER}"
  echo "DB       : ${DB_ENGINE}"
  echo

  echo -n "Load     : "
  cat /proc/loadavg 2>/dev/null || uptime

  if hm_have_cmd free; then
    echo
    free -h
  fi

  echo
  echo "Dysk     : used $(hm_disk_used_percent /)%  free $(hm_disk_free_percent /)%"
  df -h / 2>/dev/null | tail -1

  echo
  local ols_ok="down" mysql_ok="down"
  if pgrep -x lshttpd >/dev/null 2>&1 || pgrep -x openlitespeed >/dev/null 2>&1; then
    ols_ok="up"
  elif [[ -x "${OLS_CTRL}" ]] && "${OLS_CTRL}" status 2>/dev/null | grep -qi running; then
    ols_ok="up"
  fi
  if hm_mysql_exec -e "SELECT 1;" >/dev/null 2>&1; then
    mysql_ok="up"
  fi
  echo "OLS      : ${ols_ok}"
  echo "MySQL    : ${mysql_ok}"

  echo
  echo "${C_BOLD}Certyfikaty wygasające < 14 dni${C_RESET}"
  hm_discover_sites
  local domain cert expiry exp_epoch now soon found=0
  now="$(date +%s)"
  soon=$((now + 14*86400))
  for domain in "${HM_SITES_LIST[@]}"; do
    cert="$(hm_ssl_paths_for_domain "${domain}" 2>/dev/null || true)"
    [[ -n "${cert}" ]] || continue
    enddate="$(openssl x509 -enddate -noout -in "${cert}" 2>/dev/null | sed 's/notAfter=//')"
    exp_epoch="$(date -d "${enddate}" +%s 2>/dev/null || echo "")"
    if [[ -n "${exp_epoch}" && "${exp_epoch}" -lt "${soon}" ]]; then
      found=1
      expiry="$(hm_ssl_expiry "${cert}")"
      if [[ "${exp_epoch}" -lt "${now}" ]]; then
        hm_err "  EXPIRED  ${domain}  (${expiry})"
      else
        hm_warn "  SOON     ${domain}  (${expiry})"
      fi
    fi
  done
  if [[ "${found}" -eq 0 ]]; then
    hm_ok "Brak certyfikatów wygasających w ciągu 14 dni."
  fi
}

cmd_php() {
  if [[ -n "${HM_SITE_DOMAIN}" ]]; then
    cmd_site_php
  else
    echo "Dostępne LSPHP:"
    hm_list_available_php
  fi
}
