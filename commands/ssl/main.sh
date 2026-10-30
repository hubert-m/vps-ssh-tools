#!/usr/bin/env bash
# Komendy: ssl / renew-ssl


_hm_cmd_help ssl <<'EOF'
Użycie:
  ssl                 Lista certyfikatów (status / dni do wygaśnięcia)
  ssl renew [domena]  Alias: renew-ssl
  renew-ssl [domena]  Odnów Let's Encrypt (potwierdzenie [t/N])

W kontekście strony: ssl = szczegóły certu; renew-ssl = odnowienie.
Wygasły cert → wyraźny komunikat na czerwono + podpowiedź renew-ssl.

Kolejność odnawiania: cyberpanel issueSSL → acme.sh → certbot.
EOF

_hm_cmd_help renew-ssl <<'EOF'
Użycie:
  ssl                 Lista certyfikatów (status / dni do wygaśnięcia)
  ssl renew [domena]  Alias: renew-ssl
  renew-ssl [domena]  Odnów Let's Encrypt (potwierdzenie [t/N])

W kontekście strony: ssl = szczegóły certu; renew-ssl = odnowienie.
Wygasły cert → wyraźny komunikat na czerwono + podpowiedź renew-ssl.

Kolejność odnawiania: cyberpanel issueSSL → acme.sh → certbot.
EOF

cmd_ssl() {
  case "${1:-}" in
    renew|renewal|issue)
      shift || true
      cmd_renew_ssl "$@"
      return
      ;;
    help|-h|--help)
      hm_help_topic ssl
      return
      ;;
  esac

  hm_discover_sites
  if [[ "${#HM_SITES_LIST[@]}" -eq 0 ]]; then
    hm_warn "Brak stron."
    return 0
  fi

  printf '  %s%-36s %-8s %6s  %-28s%s\n' \
    "${C_DIM}" "DOMAIN" "STATUS" "DNI" "EXPIRY" "${C_RESET}"
  printf '  %s%s%s\n' "${C_DIM}" "$(printf '%.0s─' {1..78})" "${C_RESET}"

  local domain cert expiry days status
  local total="${#HM_SITES_LIST[@]}" i=0
  local -a rows=()
  for domain in "${HM_SITES_LIST[@]}"; do
    i=$((i + 1))
    hm_progress_bar "${i}" "${total}" "Sprawdzanie certyfikatu SSL: ${domain}"
    cert="$(hm_ssl_paths_for_domain "${domain}" 2>/dev/null || true)"
    if [[ -z "${cert}" ]]; then
      rows+=("$(printf '  %-36s %s%-8s%s %6s  %s' \
        "${domain}" "${C_RED}" "BRAK" "${C_RESET}" "-" "-")")
      continue
    fi
    status="$(hm_ssl_status "${cert}")"
    days="$(hm_ssl_days_left "${cert}" 2>/dev/null || echo "?")"
    expiry="$(hm_ssl_expiry "${cert}")"
    case "${status}" in
      expired)
        rows+=("$(printf '  %-36s %s%-8s%s %6s  %s' \
          "${domain}" "${C_RED}" "WYGASŁ" "${C_RESET}" "${days}" "${expiry}")")
        ;;
      soon)
        rows+=("$(printf '  %-36s %s%-8s%s %6s  %s' \
          "${domain}" "${C_YELLOW}" "WKRÓTCE" "${C_RESET}" "${days}" "${expiry}")")
        ;;
      ok)
        rows+=("$(printf '  %-36s %s%-8s%s %6s  %s' \
          "${domain}" "${C_GREEN}" "OK" "${C_RESET}" "${days}" "${expiry}")")
        ;;
      *)
        rows+=("$(printf '  %-36s %-8s %6s  %s' "${domain}" "?" "${days}" "${expiry}")")
        ;;
    esac
  done
  hm_progress_done
  printf '%s\n' "${rows[@]}"
  echo
  echo "  ${C_DIM}Odnawianie: renew-ssl [domena]   |   ssl renew [domena]${C_RESET}"
}

cmd_renew_ssl() {
  local domain="${1:-${HM_SITE_DOMAIN}}"
  [[ -n "${domain}" ]] || {
    hm_err "Użycie: renew-ssl <domena>   (w kontekście: renew-ssl)"
    return 1
  }
  domain="$(hm_find_site_by_arg "${domain}")" || return 1

  local cert days status expiry
  cert="$(hm_ssl_paths_for_domain "${domain}" 2>/dev/null || true)"
  echo "${C_BOLD}Odnawianie SSL — ${domain}${C_RESET}"
  if [[ -n "${cert}" ]]; then
    status="$(hm_ssl_status "${cert}")"
    days="$(hm_ssl_days_left "${cert}" 2>/dev/null || echo "?")"
    expiry="$(hm_ssl_expiry "${cert}")"
    echo "  Cert   : ${cert}"
    echo "  Expiry : ${expiry}"
    case "${status}" in
      expired) hm_err "  Status : WYGASŁ (${days} dni temu)" ;;
      soon)    hm_warn "  Status : wygasa za ${days} dni" ;;
      ok)      hm_ok "  Status : ważny (jeszcze ${days} dni)" ;;
      *)       echo "  Status : ${status}" ;;
    esac
  else
    hm_warn "  Brak lokalnego certyfikatu — spróbuję wystawić nowy (issueSSL / acme)."
  fi
  echo

  if ! hm_confirm_plan "renew-ssl — ${domain}" \
    "Wystawienie/odnowienie certyfikatu Let's Encrypt." \
    "Odnowienie/wystawienie certyfikatu Let's Encrypt dla ${domain} (cyberpanel issueSSL → acme.sh → certbot)" \
    "Zapisanie plików certyfikatu w /etc/letsencrypt/live/${domain}/" \
    "Przeładowanie OpenLiteSpeed (ols reload)"; then
    return 0
  fi

  local ok=0
  # 1) CyberPanel CLI
  if hm_have_cmd cyberpanel; then
    hm_info "CyberPanel: issueSSL --domainName ${domain}"
    set +e
    hm_run cyberpanel issueSSL --domainName "${domain}"
    local rc=$?
    set -e
    if [[ "${rc}" -eq 0 ]]; then
      ok=1
      hm_ok "cyberpanel issueSSL zakończone (kod 0)."
    else
      hm_warn "cyberpanel issueSSL kod ${rc} — próbuję fallback."
    fi
  fi

  # 2) acme.sh --renew / --issue
  if [[ "${ok}" -eq 0 ]]; then
    local acme=""
    for acme in /root/.acme.sh/acme.sh "$(command -v acme.sh 2>/dev/null || true)"; do
      [[ -n "${acme}" && -x "${acme}" ]] && break
      acme=""
    done
    if [[ -n "${acme}" ]]; then
      hm_info "acme.sh renew/issue dla ${domain}…"
      # upewnij się LE production
      "${acme}" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
      set +e
      if "${acme}" --list 2>/dev/null | grep -Fq -- "${domain}"; then
        hm_run "${acme}" --renew -d "${domain}" --force
        rc=$?
      else
        local webroot=""
        if [[ -n "${HM_SITE_DOCROOT:-}" && -d "${HM_SITE_DOCROOT}" && "${HM_SITE_DOMAIN:-}" == "${domain}" ]]; then
          webroot="${HM_SITE_DOCROOT}"
        elif [[ -d "/home/${domain}/public_html" ]]; then
          webroot="/home/${domain}/public_html"
        else
          # poza use — docRoot z OLS / CyberPanel (nie tylko /home/.../public_html)
          local _row _docroot
          _row="$(hm_resolve_site_paths "${domain}")"
          IFS=$'\t' read -r _ _ _docroot _ <<<"${_row}"
          [[ -n "${_docroot}" && -d "${_docroot}" ]] && webroot="${_docroot}"
        fi
        mkdir -p "/etc/letsencrypt/live/${domain}" 2>/dev/null || true
        if [[ -n "${webroot}" ]]; then
          hm_run "${acme}" --issue -d "${domain}" -d "www.${domain}" -w "${webroot}" --force \
            --cert-file "/etc/letsencrypt/live/${domain}/cert.pem" \
            --key-file "/etc/letsencrypt/live/${domain}/privkey.pem" \
            --fullchain-file "/etc/letsencrypt/live/${domain}/fullchain.pem"
          rc=$?
          # www może nie istnieć — retry bez www
          if [[ "${rc}" -ne 0 ]]; then
            hm_run "${acme}" --issue -d "${domain}" -w "${webroot}" --force \
              --cert-file "/etc/letsencrypt/live/${domain}/cert.pem" \
              --key-file "/etc/letsencrypt/live/${domain}/privkey.pem" \
              --fullchain-file "/etc/letsencrypt/live/${domain}/fullchain.pem"
            rc=$?
          fi
        else
          hm_warn "Brak webroot dla acme.sh issue."
          rc=1
        fi
      fi
      set -e
      if [[ "${rc}" -eq 0 ]]; then
        ok=1
        hm_ok "acme.sh zakończone powodzeniem."
      else
        hm_warn "acme.sh kod ${rc}."
      fi
    fi
  fi

  # 3) certbot
  if [[ "${ok}" -eq 0 ]] && hm_have_cmd certbot; then
    hm_info "certbot renew --cert-name ${domain}…"
    set +e
    hm_run certbot renew --cert-name "${domain}" --force-renewal
    rc=$?
    set -e
    if [[ "${rc}" -eq 0 ]]; then
      ok=1
      hm_ok "certbot renew OK."
    else
      hm_warn "certbot kod ${rc}."
    fi
  fi

  if [[ "${ok}" -eq 0 ]]; then
    hm_err "Nie udało się odnowić SSL dla ${domain}."
    hm_info "Sprawdź DNS (A), port 80, oraz logi CyberPanel / acme.sh."
    return 1
  fi

  hm_info "Reload OLS…"
  hm_ols_reload_soft || hm_warn "ols reload nieudany — zrób ręcznie: ols reload"

  echo
  hm_ok "Gotowe — stan certyfikatu po odnowieniu:"
  echo
  hm_print_site_ssl "${domain}"
}

_hm_cmd_register ssl cmd_ssl 0
_hm_cmd_register renew-ssl cmd_renew_ssl 0 ssl-renew
