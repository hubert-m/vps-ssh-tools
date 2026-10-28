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

hm_print_site_logs() {
  local domain="${1:-${HM_SITE_DOMAIN}}"
  local lines="${2:-40}"
  hm_set_site_context "${domain}"
  local candidates=()
  [[ -n "${HM_SITE_LOGS}" ]] && candidates+=(
    "${HM_SITE_LOGS}/access.log"
    "${HM_SITE_LOGS}/error.log"
    "${HM_SITE_LOGS}/${domain}.access_log"
    "${HM_SITE_LOGS}/${domain}.error_log"
  )
  [[ -n "${OLS_ROOT}" ]] && candidates+=(
    "${OLS_ROOT}/logs/error.log"
    "${OLS_ROOT}/logs/access.log"
  )
  local f found=0
  for f in "${candidates[@]}"; do
    if [[ -f "${f}" ]]; then
      found=1
      echo "==== ${f} (ostatnie ${lines}) ===="
      tail -n "${lines}" "${f}" 2>/dev/null || true
      echo
    fi
  done
  if [[ "${found}" -eq 0 ]]; then
    hm_warn "Nie znaleziono plików logów."
    [[ -n "${HM_SITE_LOGS}" ]] && ls -la "${HM_SITE_LOGS}" 2>/dev/null || true
  fi
}
