#!/usr/bin/env bash
# cf — Cloudflare: token w pliku, real IP OLS, purge, DNS, Under Attack, reguły.

_hm_cmd_help cf <<'EOF'
Użycie:
  cf setup                         token ze stdin, plik 0600, nigdy w argumentach
  cf realip status|apply           zaufane zakresy CF w OLS, bez 0.0.0.0/0
  cf purge <domena> [--all|--url https://…]
  cf dns list|add|edit|delete <domena> …
  cf attack on|off <domena>
  cf block <IP|kraj> <domena>
  cf status <domena>

Purge po deployu tylko przy HM_CF_PURGE_ON_DEPLOY=1.
EOF

hm_cf_token_file() { printf '%s\n' "${HM_CF_TOKEN_FILE:-/etc/hmtools/cloudflare.token}"; }
hm_cf_ols_file() { printf '%s\n' "${HM_CF_OLS:-/usr/local/lsws/conf/hmtools-cf-realip.conf}"; }

hm_cf_show_redacted() {
  local token="$1" file="$2" line
  [[ -f "${file}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ -n "${token}" ]]; then
      line="${line//${token}/[redacted]}"
    fi
    printf '%s\n' "${line}"
  done < "${file}"
}

hm_cf_setup() {
  local token file
  if [[ $# -gt 0 ]]; then
    hm_err "Token nie może iść w argumentach. Wklej go na stdin: cf setup"
    return 1
  fi
  IFS= read -r token || true
  [[ "${token}" =~ ^[A-Za-z0-9_-]+$ ]] || { hm_err "Pusty albo niedozwolony token."; return 1; }
  file="$(hm_cf_token_file)"
  mkdir -p "$(dirname "${file}")"
  umask 077
  printf '%s\n' "${token}" > "${file}"
  chmod 0600 "${file}" || true
  unset token
  hm_ok "Token zapisany."
}

hm_cf_read_token() {
  local file
  file="$(hm_cf_token_file)"
  [[ -f "${file}" ]] || { hm_err "Brak tokenu. Uruchom cf setup."; return 1; }
  tr -d '\r\n' < "${file}"
}

hm_cf_request() {
  local method="$1" url="$2" data="${3:-}" token cfg body err code bin
  token="$(hm_cf_read_token)" || return 1
  cfg="$(mktemp)"
  body="$(mktemp)"
  err="$(mktemp)"
  chmod 0600 "${cfg}" || true
  printf 'header = "Authorization: Bearer %s"\n' "${token}" > "${cfg}"
  printf 'request = "%s"\n' "${method}" >> "${cfg}"
  bin="${HM_CF_CURL:-curl}"
  if [[ -n "${data}" ]]; then
    printf '%s' "${data}" > "${cfg}.data"
    code="$("${bin}" -K "${cfg}" --data-binary "@${cfg}.data" -o "${body}" -w '%{http_code}' -- "${url}" 2>"${err}" || true)"
  else
    code="$("${bin}" -K "${cfg}" -o "${body}" -w '%{http_code}' -- "${url}" 2>"${err}" || true)"
  fi
  rm -f "${cfg}" "${cfg}.data"
  hm_cf_show_redacted "${token}" "${err}" >&2
  case "${code}" in
    200|201)
      hm_cf_show_redacted "${token}" "${body}"
      rm -f "${body}" "${err}"
      unset token
      return 0
      ;;
    403)
      hm_err "Cloudflare odrzucił token (403)."
      hm_cf_show_redacted "${token}" "${body}" >&2
      ;;
    429)
      hm_err "Cloudflare ogranicza zapytania (429)."
      ;;
    *)
      hm_err "Cloudflare odpowiedział kodem ${code:-brak}."
      hm_cf_show_redacted "${token}" "${body}" >&2
      ;;
  esac
  rm -f "${body}" "${err}"
  unset token
  return 1
}

hm_cf_fetch_url() {
  local url="$1" body err code bin
  body="$(mktemp)"
  err="$(mktemp)"
  bin="${HM_CF_CURL:-curl}"
  code="$("${bin}" -o "${body}" -w '%{http_code}' -- "${url}" 2>"${err}" || true)"
  if [[ "${code}" != "200" ]]; then
    hm_err "Nie udało się pobrać listy zakresów Cloudflare."
    rm -f "${body}" "${err}"
    return 1
  fi
  cat "${body}"
  rm -f "${body}" "${err}"
}

hm_cf_cidr_ok() {
  local c="$1"
  [[ "${c}" == "0.0.0.0/0" || "${c}" == "::/0" ]] && return 1
  [[ "${c}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] && return 0
  [[ "${c}" =~ ^[0-9A-Fa-f:]+/[0-9]{1,3}$ ]] && return 0
  return 1
}

hm_cf_realip_apply() {
  local ols line tmp count=0
  hm_cf_read_token >/dev/null || return 1
  ols="$(hm_cf_ols_file)"
  tmp="$(mktemp)"
  {
    hm_cf_fetch_url "https://www.cloudflare.com/ips-v4" || true
    hm_cf_fetch_url "https://www.cloudflare.com/ips-v6" || true
  } | while IFS= read -r line; do
    line="${line//$'\r'/}"
    hm_cf_cidr_ok "${line}" || continue
    printf '%s\n' "${line}"
  done > "${tmp}"
  count="$(grep -c . "${tmp}" || true)"
  if [[ "${count}" -eq 0 ]]; then
    rm -f "${tmp}"
    hm_err "Lista zakresów Cloudflare jest pusta. Nie włączam zaufania do nagłówka."
    return 1
  fi
  mkdir -p "$(dirname "${ols}")"
  {
    printf '%s\n' '# hmtools-cloudflare-realip'
    printf '%s\n' 'useIpInProxyHeader 1'
    while IFS= read -r line; do
      printf 'trustedProxy %s\n' "${line}"
    done < "${tmp}"
  } > "${ols}"
  rm -f "${tmp}"
  hm_ok "Zapisano zaufane zakresy Cloudflare."
}

hm_cf_realip_status() {
  local ols
  ols="$(hm_cf_ols_file)"
  if [[ ! -f "${ols}" ]]; then
    hm_info "Brak konfiguracji real IP."
    return 0
  fi
  grep '^trustedProxy ' "${ols}" || true
}

hm_cf_domain_ok() {
  [[ "${1:-}" =~ ^[A-Za-z0-9.-]+$ ]] || { hm_err "Zła domena."; return 1; }
}

hm_cf_purge() {
  local domain="${1:-}" url=""
  shift || true
  hm_cf_domain_ok "${domain}" || return 1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all) shift ;;
      --url) url="${2:-}"; shift 2 || true ;;
      *) shift ;;
    esac
  done
  if [[ -n "${url}" && "${url}" != https://* ]]; then
    hm_err "Adres purge musi zaczynać się od https://"
    return 1
  fi
  hm_confirm_plan "cf purge ${domain}" "Czyści cache Cloudflare." "" "cf purge ${domain}" || return 1
  if [[ -n "${url}" ]]; then
    hm_cf_request POST "https://api.cloudflare.com/client/v4/zones/${domain}/purge_cache" "{\"files\":[\"${url}\"]}"
  else
    hm_cf_request POST "https://api.cloudflare.com/client/v4/zones/${domain}/purge_cache" '{"purge_everything":true}'
  fi
}

hm_cf_dns() {
  local action="${1:-list}" domain="${2:-}"
  hm_cf_domain_ok "${domain}" || return 1
  case "${action}" in
    list)
      hm_cf_request GET "https://api.cloudflare.com/client/v4/zones/${domain}/dns_records"
      ;;
    add|edit|delete)
      hm_confirm_plan "cf dns ${action} ${domain}" "Zmiana DNS w Cloudflare." "" "cf dns ${action} ${domain}" || return 1
      hm_cf_request POST "https://api.cloudflare.com/client/v4/zones/${domain}/dns_records" "{\"action\":\"${action}\"}"
      ;;
    *)
      hm_err "Użycie: cf dns list|add|edit|delete <domena>"
      return 1
      ;;
  esac
}

hm_cf_attack() {
  local mode="${1:-}" domain="${2:-}" level=""
  hm_cf_domain_ok "${domain}" || return 1
  case "${mode}" in
    on) level="under_attack" ;;
    off) level="medium" ;;
    *) hm_err "Użycie: cf attack on|off <domena>"; return 1 ;;
  esac
  hm_confirm_plan "cf attack ${mode} ${domain}" "Zmienia tryb Under Attack." "" "cf attack ${mode} ${domain}" || return 1
  hm_cf_request PATCH "https://api.cloudflare.com/client/v4/zones/${domain}/settings/security_level" "{\"value\":\"${level}\"}"
}

hm_cf_block() {
  local target="${1:-}" domain="${2:-}" kind=""
  hm_cf_domain_ok "${domain}" || return 1
  if [[ "${target}" =~ ^[A-Za-z]{2}$ ]]; then
    kind="country"
  elif [[ "${target}" =~ ^[0-9.]+$ || "${target}" =~ ^[0-9A-Fa-f:]+$ ]]; then
    kind="ip"
  else
    hm_err "Podaj adres IP albo dwuliterowy kod kraju."
    return 1
  fi
  hm_confirm_plan "cf block ${target}" "Reguła blokady Cloudflare." "" "cf block ${target} ${domain}" || return 1
  hm_cf_request POST "https://api.cloudflare.com/client/v4/zones/${domain}/firewall/access_rules/rules" "{\"mode\":\"block\",\"kind\":\"${kind}\",\"value\":\"${target}\"}"
}

hm_cf_status() {
  local domain="${1:-}" out
  hm_cf_domain_ok "${domain}" || return 1
  out="$(hm_cf_request GET "https://api.cloudflare.com/client/v4/zones/${domain}")" || return 1
  printf '%s\n' "${out}"
  if printf '%s\n' "${out}" | grep -q 'ssl=flexible'; then
    hm_warn "SSL Flexible nie szyfruje ruchu do serwera."
  fi
}

hm_cf_after_deploy() {
  [[ "${HM_CF_PURGE_ON_DEPLOY:-}" == "1" ]] || return 0
  [[ -n "${HM_SITE_DOMAIN:-}" ]] || return 0
  hm_cf_purge "${HM_SITE_DOMAIN}" --all >/dev/null || hm_warn "Purge Cloudflare nieudany."
}

cmd_cf() {
  local sub="${1:-}"
  shift || true
  case "${sub}" in
    setup) hm_cf_setup "$@" ;;
    realip)
      case "${1:-status}" in
        status|"") hm_cf_realip_status ;;
        apply) hm_cf_realip_apply ;;
        *) hm_err "Użycie: cf realip status|apply"; return 1 ;;
      esac
      ;;
    purge) hm_cf_purge "$@" ;;
    dns) hm_cf_dns "$@" ;;
    attack) hm_cf_attack "$@" ;;
    block) hm_cf_block "$@" ;;
    status) hm_cf_status "$@" ;;
    help|-h|--help|"") hm_help_topic cf ;;
    *) hm_err "Nieznane: cf ${sub}"; return 1 ;;
  esac
}

_hm_cmd_register cf cmd_cf 0 cloudflare
