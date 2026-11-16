#!/usr/bin/env bash
# Komendy: ssl (renew-ssl = alias ssl renew)


_HM_SSL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=issue.sh
source "${_HM_SSL_DIR}/issue.sh"

_hm_cmd_help ssl <<'EOF'
Użycie:
  ssl [--json]
      Lista certyfikatów stron: status (OK / WKRÓTCE / WYGASŁ / SELF-SIGNED / BRAK),
      dni do wygaśnięcia i data. W kontekście strony bez podkomendy — szczegóły
      certu bieżącej domeny.

  ssl issue [domena] [--with-www] [--aliases]
      Pierwsze wystawienie Let's Encrypt (HTTP-01) albo zamiana self-signed na LE.
      Robi pre-check DNS i dostępności /.well-known; czyści stary self-signed
      przed issueSSL. Flagi: --with-www, --aliases (parked).
  ssl issue [domena] --wildcard --dns pdns|cloudflare
      Wildcard (*.domena) przez DNS-01 (PowerDNS albo Cloudflare).

  ssl renew [domena]
      Odnowienie już istniejącego certyfikatu Let's Encrypt (z potwierdzeniem).
      Ścieżka: cyberpanel issueSSL → acme.sh --renew → certbot renew.
      Nie zastępuje pre-checku ani ścieżki „od zera” z ssl issue — do nowej
      domeny / BRAK certu / SELF-SIGNED użyj ssl issue.

  ssl diagnose [domena]
      Ostatni błąd ACME (log) → czytelna przyczyna (DNS, rate limit, webroot…).

  ssl hostname [fqdn]
      Certyfikat hostname panelu (CyberPanel hostNameSSL).
  ssl mail [domena]
      Certyfikat poczty Postfix/Dovecot (mailServerSSL).
  ssl acme-update [--yes]
      Odśwież klienta acme.sh i ustaw domyślne CA na Let's Encrypt.

issue vs renew:
  • issue  — nowe wystawienie / zamiana (pre-check, HTTP-01 lub DNS-01 wildcard).
  • renew  — przedłużenie ważnego lub wygasłego LE (bez pełnego pre-checku issue).

W kontekście strony argument domeny jest opcjonalny (bierze bieżącą).
Alias historyczny: renew-ssl → to samo co ssl renew.
hmtools wydaje wyłącznie Let's Encrypt (bez self-signed jako celu).
EOF

_hm_cmd_help renew-ssl <<'EOF'
Użycie:
  ssl renew [domena]     Preferowane
  renew-ssl [domena]     Alias (to samo co ssl renew)

Odnawia istniejący certyfikat Let's Encrypt (potwierdzenie).
Dla nowej domeny, braku certu albo SELF-SIGNED: ssl issue [domena].
EOF

cmd_ssl() {
  case "${1:-}" in
    issue)
      shift || true
      cmd_ssl_issue "$@"
      return
      ;;
    hostname|host)
      shift || true
      cmd_ssl_hostname "$@"
      return
      ;;
    mail|mailserver)
      shift || true
      cmd_ssl_mail "$@"
      return
      ;;
    self-signed|selfsigned|self)
      shift || true
      cmd_ssl_self_signed "$@"
      return
      ;;
    acme-update|acme|acme-refresh|acme_update)
      shift || true
      cmd_ssl_acme_update "$@"
      return
      ;;
    diagnose|diag|doctor)
      shift || true
      cmd_ssl_diagnose "$@"
      return
      ;;
    renew|renewal)
      shift || true
      cmd_renew_ssl "$@"
      return
      ;;
    help|-h|--help)
      hm_help_topic ssl
      return
      ;;
  esac

  if hm_has_json_flag "$@"; then
    local a
    for a in "$@"; do
      case "${a}" in
        --json) ;;
        *)
          hm_err "Nieznana flaga: ${a}"
          return 1
          ;;
      esac
    done
    hm_json_emit ssl
    return $?
  fi

  # W kontekście strony bez podkomendy → szczegóły certu
  if [[ -n "${HM_SITE_DOMAIN:-}" && -z "${1:-}" ]]; then
    hm_print_site_ssl "${HM_SITE_DOMAIN}"
    return 0
  fi

  hm_discover_sites
  if [[ "${#HM_SITES_LIST[@]}" -eq 0 ]]; then
    hm_warn "Brak stron."
    return 0
  fi

  local domain cert expiry days status
  local total="${#HM_SITES_LIST[@]}" i=0
  hm_table_begin LLRL
  hm_table_row DOMAIN STATUS DNI EXPIRY
  for domain in "${HM_SITES_LIST[@]}"; do
    i=$((i + 1))
    hm_progress_bar "${i}" "${total}" "Sprawdzanie certyfikatu SSL: ${domain}"
    cert="$(hm_ssl_paths_for_domain "${domain}" 2>/dev/null || true)"
    if [[ -z "${cert}" ]]; then
      hm_table_row "${domain}" "${C_RED}BRAK${C_RESET}" "-" "-"
      continue
    fi
    status="$(hm_ssl_status "${cert}")"
    days="$(hm_ssl_days_left "${cert}" 2>/dev/null || echo "?")"
    expiry="$(hm_ssl_expiry "${cert}")"
    case "${status}" in
      expired)
        hm_table_row "${domain}" "${C_RED}WYGASŁ${C_RESET}" "${days}" "${expiry}"
        ;;
      soon)
        hm_table_row "${domain}" "${C_YELLOW}WKRÓTCE${C_RESET}" "${days}" "${expiry}"
        ;;
      selfsigned)
        hm_table_row "${domain}" "${C_RED}SELF-SIGNED${C_RESET}" "${days}" "${expiry}"
        ;;
      ok)
        hm_table_row "${domain}" "${C_GREEN}OK${C_RESET}" "${days}" "${expiry}"
        ;;
      *)
        hm_table_row "${domain}" "?" "${days}" "${expiry}"
        ;;
    esac
  done
  hm_progress_done
  hm_table_print
  echo
  echo "  ${C_DIM}Wydanie (nowy/LE zamiast self-signed): ssl issue [domena]${C_RESET}"
  echo "  ${C_DIM}Odnowienie (istniejący LE): ssl renew [domena]   |   Diagnoza ACME: ssl diagnose [domena]${C_RESET}"
  echo "  ${C_DIM}ACME klient: ssl acme-update [--yes]${C_RESET}"
}

cmd_renew_ssl() {
  local domain="${1:-${HM_SITE_DOMAIN:-}}"
  [[ -n "${domain}" ]] || {
    hm_err "Użycie: ssl renew <domena>   (w kontekście strony: ssl renew)"
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
      expired)
        local ago="${days#-}"
        if [[ "${ago}" == "1" ]]; then
          hm_err "  Status : WYGASŁ (1 dzień temu)"
        else
          hm_err "  Status : WYGASŁ (${ago} dni temu)"
        fi
        ;;
      soon)
        if [[ "${days}" == "1" ]]; then
          hm_warn "  Status : wygasa za 1 dzień"
        else
          hm_warn "  Status : wygasa za ${days} dni"
        fi
        ;;
      selfsigned)
        hm_err "  Status : SELF-SIGNED — zamień przez ssl issue ${domain}"
        ;;
      ok)
        if [[ "${days}" == "1" ]]; then
          hm_ok "  Status : ważny (jeszcze 1 dzień)"
        else
          hm_ok "  Status : ważny (jeszcze ${days} dni)"
        fi
        ;;
      *)       echo "  Status : ${status}" ;;
    esac
  else
    hm_warn "  Brak lokalnego certyfikatu — spróbuję wystawić nowy (issueSSL / acme)."
    hm_info "  Dla nowej domeny preferuj: ssl issue ${domain} (pre-check DNS/HTTP)."
  fi
  echo

  if ! hm_confirm_plan "ssl renew — ${domain}" \
    "Odnowienie certyfikatu Let's Encrypt (nie pełne ssl issue z pre-checkiem)." \
    "Przy self-signed: usunięcie /etc/letsencrypt/{live,archive,renewal}/${domain}" \
    "Odnowienie certyfikatu dla ${domain} (cyberpanel issueSSL → acme.sh --renew → certbot renew)" \
    "Zapisanie plików w /etc/letsencrypt/live/${domain}/" \
    "Przeładowanie OpenLiteSpeed (ols reload)"; then
    return 1
  fi

  local ok=0 rc
  # 1) CyberPanel CLI
  if hm_have_cmd cyberpanel; then
    hm_ssl_clear_self_signed_before_issue "${domain}" || return 1
    hm_info "CyberPanel: issueSSL --domainName ${domain}"
    set +e
    hm_run cyberpanel issueSSL --domainName "${domain}"
    rc=$?
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
    acme="$(hm_ssl_find_acme 2>/dev/null || true)"
    if [[ -n "${acme}" ]]; then
      hm_ssl_clear_self_signed_before_issue "${domain}" || return 1
      hm_info "acme.sh renew/issue dla ${domain}…"
      "${acme}" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
      set +e
      if "${acme}" --list 2>/dev/null | grep -Fq -- "${domain}"; then
        hm_run "${acme}" --renew -d "${domain}" --force
        rc=$?
      else
        local webroot=""
        webroot="$(hm_ssl_docroot_for_domain "${domain}" 2>/dev/null || true)"
        mkdir -p "/etc/letsencrypt/live/${domain}" 2>/dev/null || true
        if [[ -n "${webroot}" ]]; then
          hm_run "${acme}" --issue -d "${domain}" -d "www.${domain}" -w "${webroot}" --force \
            --cert-file "/etc/letsencrypt/live/${domain}/cert.pem" \
            --key-file "/etc/letsencrypt/live/${domain}/privkey.pem" \
            --fullchain-file "/etc/letsencrypt/live/${domain}/fullchain.pem"
          rc=$?
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
    hm_info "Sprawdź: ssl diagnose ${domain}"
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
