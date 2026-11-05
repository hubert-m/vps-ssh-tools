#!/usr/bin/env bash
# ssl issue / hostname / mail / self-signed / diagnose — helpers

hm_ssl_find_acme() {
  local acme
  for acme in /root/.acme.sh/acme.sh "$(command -v acme.sh 2>/dev/null || true)"; do
    if [[ -n "${acme}" && -x "${acme}" ]]; then
      printf '%s' "${acme}"
      return 0
    fi
  done
  return 1
}

# Adresy IP tego VPS (IPv4 + IPv6) — jedna linia per adres.
hm_ssl_vps_ips() {
  local ip
  while IFS= read -r ip; do
    [[ -n "${ip}" ]] && printf '%s\n' "${ip}"
  done < <(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9a-fA-F:.]+$' || true)
  # fallback: primary default route
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true
  ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true
}

hm_ssl_resolve_a() {
  local host="$1"
  local out=""
  if hm_have_cmd dig; then
    out="$(dig +short A "${host}" 2>/dev/null | grep -E '^[0-9.]+$' || true)"
    out+=$'\n'"$(dig +short AAAA "${host}" 2>/dev/null | grep -E '^[0-9a-fA-F:]+$' || true)"
  elif hm_have_cmd getent; then
    out="$(getent ahosts "${host}" 2>/dev/null | awk '{print $1}' | sort -u || true)"
  fi
  printf '%s\n' "${out}" | awk 'NF && !seen[$0]++'
}

# 0 = DNS OK (przynajmniej jeden A/AAAA = IP VPS); 1 = fail
hm_ssl_precheck_dns() {
  local domain="$1"
  local want found=0 ip hit=0
  local -a vps=() resolved=()

  while IFS= read -r ip; do
    [[ -n "${ip}" ]] && vps+=("${ip}")
  done < <(hm_ssl_vps_ips | awk 'NF && !seen[$0]++')

  if [[ "${#vps[@]}" -eq 0 ]]; then
    hm_warn "DNS pre-check: nie ustalono IP VPS — pomijam porównanie A/AAAA."
    return 0
  fi

  while IFS= read -r ip; do
    [[ -n "${ip}" ]] && resolved+=("${ip}")
  done < <(hm_ssl_resolve_a "${domain}")

  if [[ "${#resolved[@]}" -eq 0 ]]; then
    hm_err "DNS: brak rekordu A/AAAA dla ${domain} (NXDOMAIN / pusty)."
    hm_info "Sprawdź: dns check ${domain}"
    return 1
  fi

  for ip in "${resolved[@]}"; do
    found=1
    for want in "${vps[@]}"; do
      if [[ "${ip}" == "${want}" ]]; then
        hit=1
        break
      fi
    done
  done

  if [[ "${hit}" -eq 0 ]]; then
    hm_err "DNS: ${domain} → $(IFS=', '; echo "${resolved[*]}") nie wskazuje na ten VPS ($(IFS=', '; echo "${vps[*]}"))."
    hm_info "Sprawdź: dns check ${domain}"
    return 1
  fi
  hm_ok "DNS: ${domain} wskazuje na ten VPS."
  return 0
}

# HTTP-01 smoke: plik w docroot/.well-known/acme-challenge/ (jako user strony gdy możliwe).
hm_ssl_precheck_http() {
  local domain="$1"
  local docroot="${2:-}"
  local user="${3:-}"
  local token="hmtools-acme-precheck-$$"
  local challenge_dir challenge_file url rc=0

  if [[ -z "${docroot}" || ! -d "${docroot}" ]]; then
    hm_warn "HTTP pre-check: brak docroot — pomijam."
    return 0
  fi

  challenge_dir="${docroot}/.well-known/acme-challenge"
  challenge_file="${challenge_dir}/${token}"
  url="http://${domain}/.well-known/acme-challenge/${token}"

  if [[ -n "${user}" ]] && id "${user}" >/dev/null 2>&1 && hm_have_cmd runuser; then
    runuser -u "${user}" -- mkdir -p "${challenge_dir}" 2>/dev/null \
      || mkdir -p "${challenge_dir}" 2>/dev/null || true
    if ! printf '%s\n' "hmtools-ok" | runuser -u "${user}" -- tee "${challenge_file}" >/dev/null 2>&1; then
      printf '%s\n' "hmtools-ok" > "${challenge_file}" 2>/dev/null || {
        hm_warn "HTTP pre-check: nie zapisano pliku challenge w ${challenge_dir}."
        return 0
      }
      chown "${user}:${user}" "${challenge_file}" 2>/dev/null || true
    fi
  else
    mkdir -p "${challenge_dir}" 2>/dev/null || true
    printf '%s\n' "hmtools-ok" > "${challenge_file}" 2>/dev/null || {
      hm_warn "HTTP pre-check: nie zapisano pliku challenge."
      return 0
    }
  fi

  if hm_have_cmd curl; then
    if curl -fsS --max-time 8 "${url}" 2>/dev/null | grep -q 'hmtools-ok'; then
      hm_ok "HTTP: ${url} dostępny."
    else
      hm_err "HTTP: challenge niedostępny pod ${url} (port 80 / rewrite / firewall?)."
      rc=1
    fi
  else
    hm_warn "HTTP pre-check: brak curl — pomijam."
  fi

  rm -f "${challenge_file}" 2>/dev/null || true
  return "${rc}"
}

hm_ssl_docroot_for_domain() {
  local domain="$1"
  local row docroot
  if [[ -n "${HM_SITE_DOCROOT:-}" && "${HM_SITE_DOMAIN:-}" == "${domain}" && -d "${HM_SITE_DOCROOT}" ]]; then
    printf '%s' "${HM_SITE_DOCROOT}"
    return 0
  fi
  row="$(hm_resolve_site_paths "${domain}" 2>/dev/null || true)"
  if [[ -n "${row}" ]]; then
    IFS=$'\t' read -r _ _ docroot _ <<<"${row}"
    docroot="$(hm_tsv_unfield "${docroot}")"
    if [[ -n "${docroot}" && -d "${docroot}" ]]; then
      printf '%s' "${docroot}"
      return 0
    fi
  fi
  if [[ -d "/home/${domain}/public_html" ]]; then
    printf '%s' "/home/${domain}/public_html"
    return 0
  fi
  return 1
}

hm_ssl_user_for_domain() {
  local domain="$1"
  local row rest user
  if [[ -n "${HM_SITE_USER:-}" && "${HM_SITE_DOMAIN:-}" == "${domain}" ]]; then
    printf '%s' "${HM_SITE_USER}"
    return 0
  fi
  row="$(hm_resolve_site_paths "${domain}" 2>/dev/null || true)"
  if [[ -n "${row}" ]]; then
    IFS=$'\t' read -r _ _ _ _ _ _ rest <<<"${row}"
    user="$(hm_tsv_unfield "${rest%%|*}")"
    [[ -n "${user}" ]] && { printf '%s' "${user}"; return 0; }
  fi
  return 1
}

# Aliasów domeny (www + CP childdomains / OLS aliases) — jedna nazwa na linię.
hm_ssl_aliases_for_domain() {
  local domain="$1"
  local q a
  printf 'www.%s\n' "${domain}"
  if [[ "${PANEL:-}" == "cyberpanel" ]]; then
    q="$(hm_sql_quote "${domain}")"
    while IFS= read -r a; do
      [[ -n "${a}" && "${a}" != "${domain}" ]] && printf '%s\n' "${a}"
    done < <(hm_mysql_exec cyberpanel -N -e "
SELECT c.domain FROM websiteFunctions_childdomains c
INNER JOIN websiteFunctions_websites w ON c.master_id = w.id
WHERE w.domain = ${q};
" 2>/dev/null || true)
  fi
}

# Przetłumacz log ACME / komunikat na przyczynę (stdout).
hm_ssl_parse_acme_error() {
  local text="${1:-}"
  local lower
  lower="$(printf '%s' "${text}" | tr '[:upper:]' '[:lower:]')"
  case "${lower}" in
    *rate\ limit*|*too\ many\ certificates*|*429*)
      echo "Rate limit Let's Encrypt — odczekaj lub użyj staging / innego konta ACME."
      ;;
    *nxdomain*|*no\ such\ host*|*dns\ problem*|*servfail*)
      echo "Problem DNS (NXDOMAIN/SERVFAIL) — sprawdź A/AAAA i propagację."
      ;;
    *timeout*|*timed\ out*|*connection\ timed*)
      echo "Timeout ACME — port 80/443 lub DNS API niedostępne z zewnątrz."
      ;;
    *404*|*invalid\ response*|*unauthorized*|*http-01*)
      echo "HTTP-01 challenge failed (404/invalid) — .well-known, rewrite, Cloudflare proxy, firewall."
      ;;
    *caa*)
      echo "CAA blokuje wydanie — dodaj record CAA dla Let's Encrypt lub usuń blokujący."
      ;;
    *connection\ refused*|*firewall*)
      echo "Połączenie odrzucone — sprawdź firewall / listen :80."
      ;;
    *)
      if [[ -n "${text}" ]]; then
        echo "Nieznany błąd ACME — zobacz pełny log (ssl diagnose)."
      else
        echo "Brak treści błędu w logu."
      fi
      ;;
  esac
}

hm_ssl_acme_log_paths() {
  local domain="$1"
  local d
  for d in \
    "/root/.acme.sh/${domain}" \
    "/root/.acme.sh/${domain}_ecc" \
    "/root/.acme.sh"
  do
    [[ -d "${d}" ]] || continue
    find "${d}" -maxdepth 2 -type f \( -name '*.log' -o -name 'acme.log' -o -name "${domain}.log" \) 2>/dev/null
  done
  [[ -f /var/log/letsencrypt/letsencrypt.log ]] && echo /var/log/letsencrypt/letsencrypt.log
}

# Załaduj env DNS API z typowych lokalizacji CyberPanel / plików użytkownika (bez echo sekretów).
hm_ssl_load_dns_provider_env() {
  local provider="$1"
  local f
  case "${provider}" in
    pdns|powerdns)
      for f in \
        /root/.acme.sh/account.conf \
        /home/cyberpanel/.pdns_acme.env \
        /etc/cyberpanel/pdns_acme.env \
        "${HMTOOLS_ROOT:-}/etc/pdns_acme.env"
      do
        [[ -f "${f}" ]] || continue
        # shellcheck disable=SC1090
        set -a
        # tylko znane klucze — nie źródłuj całego pliku z dowolnym kodem
        while IFS= read -r line || [[ -n "${line}" ]]; do
          case "${line}" in
            PDNS_Url=*|PDNS_ServerId=*|PDNS_Token=*|PDNS_Ttl=*|SAVED_PDNS_*)
              # shellcheck disable=SC2163
              export "${line%%=*}=${line#*=}"
              ;;
          esac
        done < "${f}"
        set +a
      done
      if [[ -z "${PDNS_Url:-}${PDNS_Token:-}" ]]; then
        # CyberPanel często trzyma token PowerDNS lokalnie
        if [[ -f /etc/pdns/pdns.conf ]]; then
          local api_key
          api_key="$(grep -E '^api-key=' /etc/pdns/pdns.conf 2>/dev/null | head -1 | cut -d= -f2- || true)"
          if [[ -n "${api_key}" ]]; then
            export PDNS_Url="${PDNS_Url:-http://127.0.0.1:8081}"
            export PDNS_ServerId="${PDNS_ServerId:-localhost}"
            export PDNS_Token="${api_key}"
            export PDNS_Ttl="${PDNS_Ttl:-60}"
          fi
        fi
      fi
      [[ -n "${PDNS_Url:-}" && -n "${PDNS_Token:-}" ]]
      ;;
    cf|cloudflare)
      for f in \
        /root/.acme.sh/account.conf \
        /home/cyberpanel/.cloudflare_acme.env \
        /etc/cyberpanel/cloudflare_acme.env
      do
        [[ -f "${f}" ]] || continue
        while IFS= read -r line || [[ -n "${line}" ]]; do
          case "${line}" in
            CF_Token=*|CF_Key=*|CF_Email=*|CF_Account_ID=*|SAVED_CF_*)
              # shellcheck disable=SC2163
              export "${line%%=*}=${line#*=}"
              ;;
          esac
        done < "${f}"
      done
      [[ -n "${CF_Token:-}" || ( -n "${CF_Key:-}" && -n "${CF_Email:-}" ) ]]
      ;;
    *)
      return 1
      ;;
  esac
}

hm_ssl_issue_via_cyberpanel() {
  local domain="$1"
  local mode="${2:-domain}" # domain|hostname|mail|selfsigned
  hm_have_cmd cyberpanel || return 1
  case "${mode}" in
    domain)
      hm_info "CyberPanel: issueSSL --domainName ${domain}"
      hm_run cyberpanel issueSSL --domainName "${domain}"
      ;;
    hostname)
      hm_info "CyberPanel: hostNameSSL --domainName ${domain}"
      hm_run cyberpanel hostNameSSL --domainName "${domain}"
      ;;
    mail)
      hm_info "CyberPanel: mailServerSSL --domainName ${domain}"
      hm_run cyberpanel mailServerSSL --domainName "${domain}"
      ;;
    selfsigned)
      hm_info "CyberPanel: issueSelfSignedSSL --domainName ${domain}"
      hm_run cyberpanel issueSelfSignedSSL --domainName "${domain}"
      ;;
    *)
      return 1
      ;;
  esac
}

hm_ssl_issue_via_acme_webroot() {
  local domain="$1"
  local webroot="$2"
  shift 2
  local -a names=("${domain}") extra
  local acme n rc
  for extra in "$@"; do
    [[ -n "${extra}" && "${extra}" != "${domain}" ]] && names+=("${extra}")
  done
  acme="$(hm_ssl_find_acme)" || return 1
  [[ -n "${webroot}" && -d "${webroot}" ]] || return 1
  mkdir -p "/etc/letsencrypt/live/${domain}" 2>/dev/null || true
  "${acme}" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
  local -a args=(--issue --force -w "${webroot}"
    --cert-file "/etc/letsencrypt/live/${domain}/cert.pem"
    --key-file "/etc/letsencrypt/live/${domain}/privkey.pem"
    --fullchain-file "/etc/letsencrypt/live/${domain}/fullchain.pem")
  for n in "${names[@]}"; do
    args+=(-d "${n}")
  done
  set +e
  hm_run "${acme}" "${args[@]}"
  rc=$?
  set -e
  # jeśli www/alias padł — retry tylko apex
  if [[ "${rc}" -ne 0 && "${#names[@]}" -gt 1 ]]; then
    hm_warn "acme.sh z aliasami nieudane — retry tylko ${domain}."
    set +e
    hm_run "${acme}" --issue --force -d "${domain}" -w "${webroot}" \
      --cert-file "/etc/letsencrypt/live/${domain}/cert.pem" \
      --key-file "/etc/letsencrypt/live/${domain}/privkey.pem" \
      --fullchain-file "/etc/letsencrypt/live/${domain}/fullchain.pem"
    rc=$?
    set -e
  fi
  return "${rc}"
}

hm_ssl_issue_via_acme_dns() {
  local domain="$1"
  local provider="$2" # pdns|cloudflare
  local acme dns_hook rc wild="*.${domain}"
  acme="$(hm_ssl_find_acme)" || {
    hm_err "Brak acme.sh — wymagany do wildcard DNS-01."
    return 1
  }
  case "${provider}" in
    pdns|powerdns)
      hm_ssl_load_dns_provider_env pdns || {
        hm_err "Brak konfiguracji PowerDNS API (PDNS_Url / PDNS_Token). Ustaw env lub /etc/pdns/pdns.conf api-key."
        return 1
      }
      dns_hook="dns_pdns"
      ;;
    cf|cloudflare)
      hm_ssl_load_dns_provider_env cloudflare || {
        hm_err "Brak konfiguracji Cloudflare (CF_Token lub CF_Key+CF_Email)."
        return 1
      }
      dns_hook="dns_cf"
      ;;
    *)
      hm_err "Nieznany provider DNS: ${provider} (oczekiwano pdns|cloudflare)."
      return 1
      ;;
  esac
  mkdir -p "/etc/letsencrypt/live/${domain}" 2>/dev/null || true
  "${acme}" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
  set +e
  hm_run "${acme}" --issue --force --dns "${dns_hook}" \
    -d "${domain}" -d "${wild}" \
    --cert-file "/etc/letsencrypt/live/${domain}/cert.pem" \
    --key-file "/etc/letsencrypt/live/${domain}/privkey.pem" \
    --fullchain-file "/etc/letsencrypt/live/${domain}/fullchain.pem"
  rc=$?
  set -e
  return "${rc}"
}

hm_ssl_self_signed_openssl() {
  local domain="$1"
  local outdir key cert
  outdir="/etc/letsencrypt/live/${domain}"
  mkdir -p "${outdir}"
  key="${outdir}/privkey.pem"
  cert="${outdir}/fullchain.pem"
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout "${key}" -out "${cert}" \
    -subj "/CN=${domain}" \
    -addext "subjectAltName=DNS:${domain},DNS:www.${domain}" 2>/dev/null \
    || openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
      -keyout "${key}" -out "${cert}" \
      -subj "/CN=${domain}"
  chmod 600 "${key}" 2>/dev/null || true
  cp -f "${cert}" "${outdir}/cert.pem" 2>/dev/null || true
  [[ -s "${cert}" && -s "${key}" ]]
}

# --- komendy ---

cmd_ssl_issue() {
  local domain="" with_www=0 with_aliases=0 wildcard=0 dns_provider=""
  local -a raw=("$@")
  local i=0 a
  while [[ "${i}" -lt "${#raw[@]}" ]]; do
    a="${raw[i]}"
    case "${a}" in
      --with-www) with_www=1 ;;
      --aliases) with_aliases=1 ;;
      --wildcard) wildcard=1 ;;
      --dns)
        i=$((i + 1))
        dns_provider="${raw[i]:-}"
        if [[ -z "${dns_provider}" || "${dns_provider}" == -* ]]; then
          hm_err "Użycie: --dns pdns|cloudflare"
          return 1
        fi
        ;;
      --dns=*)
        dns_provider="${a#--dns=}"
        ;;
      -*)
        hm_err "Nieznana flaga: ${a}"
        hm_info "Użycie: ssl issue [domena] [--with-www] [--aliases] | --wildcard --dns pdns|cloudflare"
        return 1
        ;;
      *)
        if [[ -z "${domain}" ]]; then
          domain="${a}"
        else
          hm_err "Za dużo argumentów: ${a}"
          return 1
        fi
        ;;
    esac
    i=$((i + 1))
  done

  domain="${domain:-${HM_SITE_DOMAIN:-}}"
  [[ -n "${domain}" ]] || {
    hm_err "Użycie: ssl issue <domena> [--with-www] [--aliases]  |  ssl issue <domena> --wildcard --dns pdns|cloudflare"
    return 1
  }
  if ! hm_is_valid_domain "${domain}"; then
    hm_err "Nieprawidłowa domena: ${domain}"
    return 1
  fi
  # exact match jeśli strona lokalna
  local resolved
  resolved="$(hm_find_site_by_arg_exact "${domain}" 2>/dev/null || true)"
  [[ -n "${resolved}" ]] && domain="${resolved}"

  if [[ "${wildcard}" -eq 1 ]]; then
    [[ -n "${dns_provider}" ]] || {
      hm_err "Wildcard wymaga --dns pdns|cloudflare."
      return 1
    }
    if ! hm_confirm_plan "ssl issue --wildcard — ${domain}" \
      "Wydanie certyfikatu wildcard *.${domain} przez DNS-01 (${dns_provider})." \
      "Pre-check strefy DNS (apex A/AAAA → ten VPS, jeśli możliwe)" \
      "acme.sh --dns dla ${domain} + *.${domain}" \
      "Zapis /etc/letsencrypt/live/${domain}/ + ols reload"; then
      return 1
    fi
    hm_ssl_precheck_dns "${domain}" || hm_warn "DNS apex nieidealny — kontynuuję wildcard (TXT w strefie)."
    if hm_ssl_issue_via_acme_dns "${domain}" "${dns_provider}"; then
      hm_ols_reload_soft || hm_warn "ols reload nieudany"
      hm_ok "Wildcard SSL dla ${domain} / *.${domain}."
      hm_print_site_ssl "${domain}" 2>/dev/null || true
      return 0
    fi
    hm_err "Nie udało się wydać wildcard dla ${domain}."
    cmd_ssl_diagnose "${domain}" || true
    return 1
  fi

  local docroot user
  docroot="$(hm_ssl_docroot_for_domain "${domain}" 2>/dev/null || true)"
  user="$(hm_ssl_user_for_domain "${domain}" 2>/dev/null || true)"

  local -a plan_names=("${domain}")
  local -a extras=()
  if [[ "${with_www}" -eq 1 || "${with_aliases}" -eq 1 ]]; then
    extras+=("www.${domain}")
  fi
  if [[ "${with_aliases}" -eq 1 ]]; then
    local al
    while IFS= read -r al; do
      [[ -n "${al}" && "${al}" != "${domain}" && "${al}" != "www.${domain}" ]] && extras+=("${al}")
    done < <(hm_ssl_aliases_for_domain "${domain}")
  fi
  # uniq extras
  local e seen="|${domain}|"
  for e in "${extras[@]:-}"; do
    [[ "${seen}" == *"|${e}|"* ]] && continue
    seen+="${e}|"
    plan_names+=("${e}")
  done

  local names_csv
  names_csv="$(IFS=', '; echo "${plan_names[*]}")"

  if ! hm_confirm_plan "ssl issue — ${domain}" \
    "Wydanie certyfikatu Let's Encrypt (HTTP-01)." \
    "Pre-check DNS A/AAAA → IP VPS dla: ${names_csv}" \
    "Pre-check HTTP .well-known w ${docroot:-?}" \
    "cyberpanel issueSSL / acme.sh --issue" \
    "ols reload"; then
    return 1
  fi

  local d
  for d in "${plan_names[@]}"; do
    hm_ssl_precheck_dns "${d}" || {
      hm_err "Pre-check DNS nieudany — przerywam przed ACME (oszczędność limitów LE)."
      hm_info "Sprawdź: dns check ${d}"
      return 1
    }
  done
  hm_ssl_precheck_http "${domain}" "${docroot}" "${user}" || {
    hm_err "Pre-check HTTP nieudany — przerywam przed ACME."
    return 1
  }

  local ok=0
  if hm_ssl_issue_via_cyberpanel "${domain}" domain; then
    ok=1
    hm_ok "cyberpanel issueSSL OK."
  else
    hm_warn "cyberpanel issueSSL niedostępne/nieudane — próbuję acme.sh."
  fi

  if [[ "${ok}" -eq 0 ]]; then
    if [[ -z "${docroot}" ]]; then
      hm_err "Brak docroot dla acme.sh HTTP-01."
      return 1
    fi
    local -a more=()
    for e in "${plan_names[@]}"; do
      [[ "${e}" != "${domain}" ]] && more+=("${e}")
    done
    if hm_ssl_issue_via_acme_webroot "${domain}" "${docroot}" "${more[@]:-}"; then
      ok=1
      hm_ok "acme.sh issue OK."
    fi
  fi

  if [[ "${ok}" -eq 0 ]]; then
    hm_err "Nie udało się wydać SSL dla ${domain}."
    cmd_ssl_diagnose "${domain}" || true
    return 1
  fi

  hm_ols_reload_soft || hm_warn "ols reload nieudany — zrób ręcznie: ols reload"
  echo
  hm_print_site_ssl "${domain}"
}

cmd_ssl_hostname() {
  local host="${1:-}"
  if [[ -z "${host}" ]]; then
    host="$(hostname -f 2>/dev/null || hostname 2>/dev/null || true)"
  fi
  [[ -n "${host}" ]] || { hm_err "Użycie: ssl hostname [fqdn]"; return 1; }
  if ! hm_is_valid_domain "${host}"; then
    hm_err "Nieprawidłowy hostname: ${host}"
    return 1
  fi

  if ! hm_have_cmd cyberpanel && ! hm_ssl_find_acme >/dev/null; then
    hm_err "Brak cyberpanel i acme.sh — nie wydam certyfikatu hostname."
    return 1
  fi

  if ! hm_confirm_plan "ssl hostname — ${host}" \
    "Certyfikat SSL dla hostname panelu (zwykle :8090)." \
    "Pre-check DNS A/AAAA → ten VPS" \
    "cyberpanel hostNameSSL (lub acme.sh HTTP-01)" \
    "ols reload / restart panelu wg CyberPanel"; then
    return 1
  fi

  hm_ssl_precheck_dns "${host}" || {
    hm_err "Pre-check DNS nieudany — przerywam."
    return 1
  }

  if hm_ssl_issue_via_cyberpanel "${host}" hostname; then
    hm_ok "hostNameSSL OK."
    hm_print_site_ssl "${host}" 2>/dev/null || true
    return 0
  fi

  local docroot
  docroot="$(hm_ssl_docroot_for_domain "${host}" 2>/dev/null || true)"
  [[ -z "${docroot}" && -d /usr/local/lsws/Example/html ]] && docroot="/usr/local/lsws/Example/html"
  if [[ -n "${docroot}" ]] && hm_ssl_issue_via_acme_webroot "${host}" "${docroot}"; then
    hm_ols_reload_soft || true
    hm_ok "Certyfikat hostname przez acme.sh."
    hm_print_site_ssl "${host}" 2>/dev/null || true
    return 0
  fi
  hm_err "Nie udało się wydać SSL dla hostname ${host}."
  cmd_ssl_diagnose "${host}" || true
  return 1
}

cmd_ssl_mail() {
  local domain="${1:-${HM_SITE_DOMAIN:-}}"
  [[ -n "${domain}" ]] || { hm_err "Użycie: ssl mail <domena>"; return 1; }
  if ! hm_is_valid_domain "${domain}"; then
    hm_err "Nieprawidłowa domena: ${domain}"
    return 1
  fi
  local resolved
  resolved="$(hm_find_site_by_arg_exact "${domain}" 2>/dev/null || true)"
  [[ -n "${resolved}" ]] && domain="${resolved}"

  local mail_host="mail.${domain}"
  if ! hm_have_cmd cyberpanel; then
    hm_err "ssl mail wymaga CyberPanel (mailServerSSL) — panel nie wykryty."
    return 1
  fi

  if ! hm_confirm_plan "ssl mail — ${domain}" \
    "Certyfikat SSL dla poczty (Postfix/Dovecot / mail.${domain})." \
    "Pre-check DNS dla ${mail_host} (i apex)" \
    "cyberpanel mailServerSSL --domainName ${domain}" \
    "Bez globalnego restartu usług innych domen"; then
    return 1
  fi

  hm_ssl_precheck_dns "${domain}" || hm_warn "DNS apex problematyczny."
  hm_ssl_precheck_dns "${mail_host}" || {
    hm_err "Pre-check DNS dla ${mail_host} nieudany — przerywam przed ACME."
    return 1
  }

  if hm_ssl_issue_via_cyberpanel "${domain}" mail; then
    hm_ok "mailServerSSL OK."
    if hm_ssl_paths_for_domain "${mail_host}" >/dev/null 2>&1; then
      hm_print_site_ssl "${mail_host}"
    elif hm_ssl_paths_for_domain "${domain}" >/dev/null 2>&1; then
      hm_print_site_ssl "${domain}"
    else
      hm_info "Certyfikat mail wydany — sprawdź ścieżki Postfix/Dovecot w panelu."
    fi
    return 0
  fi
  hm_err "mailServerSSL nieudane dla ${domain}."
  cmd_ssl_diagnose "${domain}" || true
  return 1
}

cmd_ssl_self_signed() {
  local domain="${1:-${HM_SITE_DOMAIN:-}}"
  [[ -n "${domain}" ]] || { hm_err "Użycie: ssl self-signed <domena>"; return 1; }
  if ! hm_is_valid_domain "${domain}"; then
    hm_err "Nieprawidłowa domena: ${domain}"
    return 1
  fi
  local resolved
  resolved="$(hm_find_site_by_arg_exact "${domain}" 2>/dev/null || true)"
  [[ -n "${resolved}" ]] && domain="${resolved}"

  if ! hm_confirm_plan "ssl self-signed — ${domain}" \
    "Awaryjny certyfikat self-signed (przeglądarki będą ostrzegać)." \
    "cyberpanel issueSelfSignedSSL lub openssl req -x509" \
    "Zapis /etc/letsencrypt/live/${domain}/ + ols reload"; then
    return 1
  fi

  if hm_ssl_issue_via_cyberpanel "${domain}" selfsigned; then
    hm_ok "issueSelfSignedSSL OK."
  elif hm_ssl_self_signed_openssl "${domain}"; then
    hm_ok "Wygenerowano self-signed (openssl)."
  else
    hm_err "Nie udało się utworzyć self-signed dla ${domain}."
    return 1
  fi
  hm_ols_reload_soft || hm_warn "ols reload nieudany"
  hm_print_site_ssl "${domain}" 2>/dev/null || true
}

cmd_ssl_diagnose() {
  local domain="${1:-${HM_SITE_DOMAIN:-}}"
  [[ -n "${domain}" ]] || { hm_err "Użycie: ssl diagnose [domena]"; return 1; }
  if ! hm_is_valid_domain "${domain}"; then
    hm_err "Nieprawidłowa domena: ${domain}"
    return 1
  fi

  echo "${C_BOLD}Diagnostyka SSL / ACME — ${domain}${C_RESET}"
  echo

  local cert status days
  cert="$(hm_ssl_paths_for_domain "${domain}" 2>/dev/null || true)"
  if [[ -n "${cert}" ]]; then
    status="$(hm_ssl_status "${cert}")"
    days="$(hm_ssl_days_left "${cert}" 2>/dev/null || echo "?")"
    echo "  Cert   : ${cert}"
    echo "  Status : ${status} (dni: ${days})"
    echo "  Expiry : $(hm_ssl_expiry "${cert}")"
  else
    hm_warn "Brak lokalnego certyfikatu dla ${domain}."
  fi
  echo

  hm_info "DNS…"
  hm_ssl_precheck_dns "${domain}" || true
  local docroot user
  docroot="$(hm_ssl_docroot_for_domain "${domain}" 2>/dev/null || true)"
  user="$(hm_ssl_user_for_domain "${domain}" 2>/dev/null || true)"
  hm_info "HTTP challenge…"
  hm_ssl_precheck_http "${domain}" "${docroot}" "${user}" || true
  echo

  local logf snippet cause
  local found_log=0
  while IFS= read -r logf; do
    [[ -n "${logf}" && -f "${logf}" ]] || continue
    found_log=1
    snippet="$(tail -n 80 "${logf}" 2>/dev/null | grep -iE 'error|fail|nxdomain|rate.?limit|timeout|unauthorized|invalid|caa|404' | tail -n 15 || true)"
    if [[ -n "${snippet}" ]]; then
      echo "  Log: ${logf}"
      printf '%s\n' "${snippet}" | sed 's/^/    /'
      cause="$(hm_ssl_parse_acme_error "${snippet}")"
      hm_warn "Przyczyna (heurystyka): ${cause}"
      echo
    fi
  done < <(hm_ssl_acme_log_paths "${domain}")

  if [[ "${found_log}" -eq 0 ]]; then
    hm_info "Brak logów acme.sh / letsencrypt dla ${domain}."
  fi
  return 0
}
