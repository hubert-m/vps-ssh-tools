#!/usr/bin/env bash
# Moduł: health


_hm_cmd_help health <<'EOF'
Użycie: health

Szybki przegląd: load, RAM, dysk, status OLS i MySQL,
certyfikaty wygasające w ciągu 14 dni.
EOF

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
  local domain cert status days expiry found=0
  local total="${#HM_SITES_LIST[@]}" i=0
  local -a alerts=()
  for domain in "${HM_SITES_LIST[@]}"; do
    i=$((i + 1))
    hm_progress_bar "${i}" "${total}" "Sprawdzanie certyfikatu SSL: ${domain}"
    cert="$(hm_ssl_paths_for_domain "${domain}" 2>/dev/null || true)"
    [[ -n "${cert}" ]] || continue
    status="$(hm_ssl_status "${cert}" 14)"
    case "${status}" in
      expired|soon)
        found=1
        days="$(hm_ssl_days_left "${cert}" 2>/dev/null || echo "?")"
        expiry="$(hm_ssl_expiry "${cert}")"
        if [[ "${status}" == "expired" ]]; then
          alerts+=("EXPIRED|${domain}|${expiry}|${days}")
        else
          alerts+=("SOON|${domain}|${expiry}|${days}")
        fi
        ;;
    esac
  done
  hm_progress_done
  local a
  for a in "${alerts[@]}"; do
    IFS='|' read -r status domain expiry days <<<"${a}"
    if [[ "${status}" == "EXPIRED" ]]; then
      hm_err "  EXPIRED  ${domain}  (${expiry}, ${days} dni)"
    else
      hm_warn "  SOON     ${domain}  (${expiry}, ${days} dni)"
    fi
  done
  if [[ "${found}" -eq 0 ]]; then
    hm_ok "Brak certyfikatów wygasających w ciągu 14 dni."
  fi

  echo
  # skrócony audyt portów (pełny: security ports)
  if hm_have_cmd ss; then
    echo "${C_BOLD}Publiczne porty wrażliwe${C_RESET} ${C_DIM}(security ports)${C_RESET}"
    local hit=0
    while IFS= read -r line; do
      [[ -n "${line}" ]] || continue
      hit=1
      hm_warn "  ${line}"
    done < <(ss -lntup 2>/dev/null | awk '
      NR==1 { next }
      $4 ~ /^0\.0\.0\.0:|^\[::\]:|^\*:/ {
        n=split($4,a,":"); port=a[n]
        if (port ~ /^(3306|5432|6379|7080|8090|3000|3001|3002|3003)$/)
          print $4, $NF
      }
    ')
    if [[ "${hit}" -eq 0 ]]; then
      hm_ok "Brak typowych wrażliwych portów na 0.0.0.0."
    fi
  fi
}

_hm_cmd_register health cmd_health 0 status
