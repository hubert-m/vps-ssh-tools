#!/usr/bin/env bash
# Komenda: ssl (globalna lista)

cmd_ssl() {
  hm_discover_sites
  if [[ "${#HM_SITES_LIST[@]}" -eq 0 ]]; then
    hm_warn "Brak stron."
    return 0
  fi
  printf '%-36s %-5s %-32s %s\n' "DOMAIN" "SSL" "EXPIRY" "CERT"
  printf '%-36s %-5s %-32s %s\n' "------" "---" "------" "----"
  local domain cert expiry has
  for domain in "${HM_SITES_LIST[@]}"; do
    cert="$(hm_ssl_paths_for_domain "${domain}" 2>/dev/null || true)"
    if [[ -n "${cert}" ]]; then
      has="yes"
      expiry="$(hm_ssl_expiry "${cert}")"
    else
      has="no"
      expiry="-"
      cert="-"
    fi
    printf '%-36s %-5s %-32s %s\n' "${domain}" "${has}" "${expiry}" "${cert}"
  done
}
