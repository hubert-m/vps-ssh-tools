#!/usr/bin/env bash
# Sites: listowanie i szczegóły

hm_list_sites() {
  local quick="${1:-0}"
  hm_discover_sites

  if [[ "${#HM_SITES_LIST[@]}" -eq 0 ]]; then
    hm_warn "Nie wykryto żadnych usług webowych."
    return 0
  fi

  printf '%-4s %-36s %-8s %-5s %-12s %s\n' "#" "DOMAIN" "PHP" "SSL" "SIZE" "STATUS"
  printf '%-4s %-36s %-8s %-5s %-12s %s\n' "---" "------" "---" "---" "----" "------"

  local i=0 domain row root docroot logs vhost php rest user status size ssl
  for domain in "${HM_SITES_LIST[@]}"; do
    i=$((i + 1))
    row="$(hm_resolve_site_paths "${domain}")"
    IFS=$'\t' read -r _ root docroot logs vhost php rest <<<"${row}"
    status="${rest##*|}"
    ssl="$(hm_ssl_has "${domain}")"
    if [[ "${quick}" == "1" ]]; then
      size="-"
    else
      if [[ -n "${root}" && -d "${root}" ]]; then
        size="$(hm_format_size_from_path "${root}")"
      elif [[ -n "${docroot}" && -d "${docroot}" ]]; then
        size="$(hm_format_size_from_path "${docroot}")"
      else
        size="?"
      fi
    fi
    printf '%-4s %-36s %-8s %-5s %-12s %s\n' \
      "${i}" "${domain}" "${php:-?}" "${ssl}" "${size}" "${status}"
  done
  echo
  hm_info "Użyj: use <numer|domena>  aby wejść w kontekst."
}

hm_print_site_info() {
  local domain="${1:-${HM_SITE_DOMAIN}}"
  [[ -n "${domain}" ]] || { hm_err "Brak domeny w kontekście."; return 1; }

  hm_set_site_context "${domain}"

  local size_root=0 size_doc=0
  [[ -n "${HM_SITE_ROOT}" && -d "${HM_SITE_ROOT}" ]] && size_root="$(hm_dir_size_bytes "${HM_SITE_ROOT}")"
  [[ -n "${HM_SITE_DOCROOT}" && -d "${HM_SITE_DOCROOT}" ]] && size_doc="$(hm_dir_size_bytes "${HM_SITE_DOCROOT}")"

  local cert expiry
  cert="$(hm_ssl_paths_for_domain "${domain}" 2>/dev/null || true)"
  expiry="-"
  [[ -n "${cert}" ]] && expiry="$(hm_ssl_expiry "${cert}")"

  cat <<EOF
${C_BOLD}Szczegóły: ${domain}${C_RESET}
  Status      : ${HM_SITE_STATUS}
  User        : ${HM_SITE_USER:--}
  PHP         : ${HM_SITE_PHP:--}
  Site root   : ${HM_SITE_ROOT:--}
  Docroot     : ${HM_SITE_DOCROOT:--}
  Logs        : ${HM_SITE_LOGS:--}
  VHost conf  : ${HM_SITE_VHOST:--}
  Rozmiar env : $(hm_human_size "${size_root}")  (całe środowisko)
  Rozmiar www : $(hm_human_size "${size_doc}")  (docroot)
  SSL cert    : ${cert:--}
  SSL expiry  : ${expiry}
  Wolne dysk  : $(hm_disk_free_percent /)% free  (used $(hm_disk_used_percent /)%)

${C_BOLD}Bazy danych:${C_RESET}
EOF
  hm_print_dbs_for_site "${domain}" "${HM_SITE_DOCROOT}" "${HM_SITE_ROOT}" "${HM_SITE_USER}"
}

hm_print_site_ssl() {
  local domain="${1:-${HM_SITE_DOMAIN}}"
  [[ -n "${domain}" ]] || { hm_err "Brak domeny."; return 1; }
  local cert days status
  cert="$(hm_ssl_paths_for_domain "${domain}" 2>/dev/null || true)"
  if [[ -z "${cert}" ]]; then
    hm_err "BRAK CERTYFIKATU SSL dla ${domain}."
    hm_info "Wystaw / odnów: renew-ssl ${domain}"
    return 0
  fi
  status="$(hm_ssl_status "${cert}")"
  days="$(hm_ssl_days_left "${cert}" 2>/dev/null || echo "?")"

  echo "Cert   : ${cert}"
  echo "Expiry : $(hm_ssl_expiry "${cert}")"
  case "${status}" in
    expired)
      echo
      hm_err "════════════════════════════════════════════"
      hm_err "  CERTYFIKAT WYGASŁ (${days} dni temu)"
      hm_err "  Domena: ${domain}"
      hm_err "  Odnów:  renew-ssl   lub   ssl renew"
      hm_err "════════════════════════════════════════════"
      echo
      ;;
    soon)
      echo
      hm_warn "Certyfikat wygasa za ${days} dni — rozważ: renew-ssl"
      echo
      ;;
    ok)
      hm_ok "Certyfikat ważny (jeszcze ${days} dni)."
      ;;
    *)
      hm_warn "Nie udało się ocenić ważności certyfikatu."
      ;;
  esac
  openssl x509 -in "${cert}" -noout -subject -issuer -dates 2>/dev/null || true
}

hm_site_log_candidates() {
  # wypisz istniejące ścieżki logów dla domeny (access/error/stderr)
  local domain="${1:-${HM_SITE_DOMAIN}}"
  local kind="${2:-all}" # all|access|error
  local -a c=()
  [[ -n "${HM_SITE_LOGS}" ]] && c+=(
    "${HM_SITE_LOGS}/access.log"
    "${HM_SITE_LOGS}/error.log"
    "${HM_SITE_LOGS}/${domain}.access_log"
    "${HM_SITE_LOGS}/${domain}.error_log"
  )
  [[ -n "${OLS_ROOT}" ]] && c+=(
    "${OLS_ROOT}/logs/error.log"
    "${OLS_ROOT}/logs/access.log"
    "${OLS_ROOT}/logs/stderr.log"
  )
  # CyberPanel często: /usr/local/lsws/logs/<domain>.access_log
  [[ -n "${OLS_ROOT}" && -n "${domain}" ]] && c+=(
    "${OLS_ROOT}/logs/${domain}.access_log"
    "${OLS_ROOT}/logs/${domain}.error_log"
  )
  local f
  for f in "${c[@]}"; do
    [[ -f "${f}" ]] || continue
    case "${kind}" in
      access)
        [[ "${f}" == *access* ]] || continue
        ;;
      error)
        [[ "${f}" == *error* || "${f}" == *stderr* ]] || continue
        ;;
    esac
    printf '%s\n' "${f}"
  done | awk '!seen[$0]++'
}

hm_print_site_logs() {
  local domain="${1:-${HM_SITE_DOMAIN}}"
  local lines="${2:-40}"
  hm_detect_all 2>/dev/null || true
  hm_set_site_context "${domain}"
  local f found=0
  while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    found=1
    echo "==== ${f} (ostatnie ${lines}) ===="
    tail -n "${lines}" "${f}" 2>/dev/null || true
    echo
  done < <(hm_site_log_candidates "${domain}" all)
  if [[ "${found}" -eq 0 ]]; then
    hm_warn "Nie znaleziono plików logów."
    [[ -n "${HM_SITE_LOGS}" ]] && ls -la "${HM_SITE_LOGS}" 2>/dev/null || true
  fi
}

hm_site_logs_errors() {
  local domain="${1:-${HM_SITE_DOMAIN}}"
  local lines="${2:-80}"
  hm_detect_all 2>/dev/null || true
  hm_set_site_context "${domain}"
  local tmp pattern
  tmp="$(mktemp "${TMP_DIR:-/tmp}/hmtools-err.XXXXXX")"
  pattern='\[ERROR\]|\[CRIT\]|\[ALERT\]|PHP Fatal|PHP Parse|PHP Warning| 500 | 502 | 503 | 504 |" 500 |" 502 |" 503 |" 504 |upstream|segfault|Out of memory'

  echo "${C_BOLD}Logi błędów — ${domain}${C_RESET} ${C_DIM}(ostatnie ~${lines} trafień)${C_RESET}"
  local f any=0
  while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    any=1
    echo "---- ${f} ----"
    grep -Eih "${pattern}" "${f}" 2>/dev/null | tail -n "${lines}" || echo "  (brak dopasowań)"
    echo
    grep -Eih "${pattern}" "${f}" 2>/dev/null >> "${tmp}" || true
  done < <(hm_site_log_candidates "${domain}" error)

  # też access ze statusami 5xx
  while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    grep -Eh ' (500|502|503|504) ' "${f}" 2>/dev/null | tail -n 40 >> "${tmp}" || true
  done < <(hm_site_log_candidates "${domain}" access)

  if [[ "${any}" -eq 0 && ! -s "${tmp}" ]]; then
    hm_warn "Brak plików error/stderr."
    rm -f "${tmp}"
    return 0
  fi

  echo "${C_BOLD}Powtarzające się wzorce (top 15)${C_RESET}"
  if [[ -s "${tmp}" ]]; then
    # uproszczenie linii: wytnij daty/PID aby zgrupować
    sed -E 's/\[[0-9]{2}-[A-Za-z]{3}-[0-9]{4}[^]]*\]//g; s/[0-9]{1,3}(\.[0-9]{1,3}){3}//g' "${tmp}" \
      | sed -E 's/[[:space:]]+/ /g' \
      | awk 'NF{print}' \
      | sort | uniq -c | sort -nr | head -15 \
      | awk '{printf "  %5s  %s\n", $1, substr($0, index($0,$2))}'
  else
    echo "  (brak)"
  fi
  rm -f "${tmp}"
}

hm_site_logs_stats() {
  local domain="${1:-${HM_SITE_DOMAIN}}"
  hm_detect_all 2>/dev/null || true
  hm_set_site_context "${domain}"
  local access="" f
  while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    access="${f}"
    break
  done < <(hm_site_log_candidates "${domain}" access)

  if [[ -z "${access}" || ! -f "${access}" ]]; then
    hm_err "Brak access.log dla ${domain}."
    return 1
  fi

  echo "${C_BOLD}Access stats — ${domain}${C_RESET}"
  echo "  Plik: ${access}"
  local total
  total="$(wc -l < "${access}" 2>/dev/null | tr -d ' ')"
  echo "  Linie: ${total}"
  echo

  # Combined / OLS: IP ... "METHOD URL PROTO" STATUS
  echo "${C_BOLD}Kody HTTP${C_RESET}"
  awk -F'"' '
    NF >= 3 {
      split($3, a, " ")
      code=a[1]
      if (code !~ /^[1-5][0-9][0-9]$/) next
      c[code]++
      if (code ~ /^2/) s2++
      else if (code ~ /^3/) s3++
      else if (code ~ /^4/) s4++
      else if (code ~ /^5/) s5++
      total++
    }
    END {
      printf "  2xx: %d   3xx: %d   4xx: %d   5xx: %d   (zmapowano %d)\n", s2+0,s3+0,s4+0,s5+0,total+0
    }
  ' "${access}"
  echo "  Szczegóły (top statusy):"
  awk -F'"' '
    NF >= 3 {
      split($3, a, " ")
      code=a[1]
      if (code ~ /^[1-5][0-9][0-9]$/) c[code]++
    }
    END { for (k in c) print c[k], k }
  ' "${access}" | sort -nr | head -12 | awk '{printf "    %s  %s\n", $2, $1}'

  echo
  echo "${C_BOLD}Top 15 IP${C_RESET}"
  awk '{print $1}' "${access}" | grep -E '^[0-9a-fA-F.:]+$' | sort | uniq -c | sort -nr | head -15 \
    | awk '{printf "  %6s  %s\n", $1, $2}'

  echo
  echo "${C_BOLD}Top 15 URL${C_RESET}"
  awk -F'"' 'NF>=2 { split($2,a," "); if (a[2]!="") print a[2] }' "${access}" \
    | sort | uniq -c | sort -nr | head -15 \
    | awk '{printf "  %6s  %s\n", $1, substr($0, index($0,$2))}'
}

hm_site_logs_follow() {
  local domain="${1:-${HM_SITE_DOMAIN}}"
  hm_detect_all 2>/dev/null || true
  hm_set_site_context "${domain}"
  local -a files=()
  local f
  while IFS= read -r f; do
    [[ -n "${f}" ]] && files+=("${f}")
  done < <(hm_site_log_candidates "${domain}" all)
  if [[ "${#files[@]}" -eq 0 ]]; then
    hm_err "Brak plików logów do śledzenia."
    return 1
  fi
  hm_info "tail -F (${#files[@]} plików) — Ctrl+C wraca do hmtools"
  hm_run_on_tty tail -n 20 -F "${files[@]}"
}
