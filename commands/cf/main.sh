#!/usr/bin/env bash
# cf — Cloudflare: token w pliku, real IP OLS, purge, DNS, Under Attack, reguły.

_hm_cmd_help cf <<'EOF'
Użycie:
  cf setup                         token ze stdin, plik 0600, nigdy w argumentach
  cf realip status|apply           zaufane zakresy CF w OLS (include), bez 0.0.0.0/0
  cf purge <domena> [--all|--url https://…]
  cf dns list|add|edit|delete <domena> [typ] [nazwa] [treść]
  cf attack on|off <domena>
  cf block <IP|kraj> <domena>
  cf status <domena>

Purge po deployu tylko przy HM_CF_PURGE_ON_DEPLOY=1.
EOF

hm_cf_token_file() { printf '%s\n' "${HM_CF_TOKEN_FILE:-/etc/hmtools/cloudflare.token}"; }
hm_cf_ols_file() { printf '%s\n' "${HM_CF_OLS:-/usr/local/lsws/conf/hmtools-cf-realip.conf}"; }
hm_cf_state_dir() { printf '%s\n' "${HM_CF_STATE:-/var/lib/hmtools/cloudflare}"; }
hm_cf_zone_cache() { printf '%s/zones.cache' "$(hm_cf_state_dir)"; }
hm_cf_attack_prev() { printf '%s/attack-prev.%s' "$(hm_cf_state_dir)" "$1"; }

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
  (
    umask 077
    printf '%s\n' "${token}" > "${file}"
    chmod 0600 "${file}" || true
  )
  unset token
  hm_ok "Token zapisany."
}

hm_cf_read_token() {
  local file
  file="$(hm_cf_token_file)"
  [[ -f "${file}" ]] || { hm_err "Brak tokenu. Uruchom cf setup."; return 1; }
  tr -d '\r\n' < "${file}"
}

hm_cf_json_escape() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "${s}"
}

hm_cf_request() {
  local method="$1" url="$2" data="${3:-}" token cfg body err code bin
  token="$(hm_cf_read_token)" || return 1
  cfg="$(mktemp)"
  body="$(mktemp)"
  err="$(mktemp)"
  chmod 0600 "${cfg}" || true
  printf 'header = "Authorization: Bearer %s"\n' "${token}" > "${cfg}"
  printf 'header = "Content-Type: application/json"\n' >> "${cfg}"
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

# Wyciągnij zone id z JSON odpowiedzi /zones.
hm_cf_parse_zone_id() {
  local body="$1" id
  id="$(printf '%s\n' "${body}" | grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
  if [[ -z "${id}" ]] && printf '%s\n' "${body}" | grep -q 'zone_id='; then
    id="$(printf '%s\n' "${body}" | sed -n 's/.*zone_id=\([^[:space:]]*\).*/\1/p' | head -1)"
  fi
  # pusta lista stref
  if [[ -z "${id}" ]] && printf '%s\n' "${body}" | grep -qE '"result"[[:space:]]*:[[:space:]]*\[\]'; then
    printf ''
    return 1
  fi
  printf '%s' "${id}"
  [[ -n "${id}" ]]
}

# Zone ID z cache albo GET /zones?name= (subdomena → parent, aż znajdzie strefę).
hm_cf_zone_id() {
  local domain="$1" cache id body cand
  mkdir -p "$(hm_cf_state_dir)"
  cache="$(hm_cf_zone_cache)"
  if [[ -f "${cache}" ]]; then
    # najdłuższy sufiks z cache (shop.example.com → example.com)
    id="$(awk -F '\t' -v d="${domain}" '
      $1 == d { print $2; found=1; exit }
      d ~ ("\\." $1 "$") { if (length($1) > bestlen) { best=$2; bestlen=length($1) } }
      END { if (!found && best != "") print best }
    ' "${cache}")"
    if [[ -n "${id}" ]]; then
      printf '%s\n' "${id}"
      return 0
    fi
  fi
  if [[ -n "${HM_CF_ZONE_ID:-}" ]]; then
    printf '%s\n' "${HM_CF_ZONE_ID}"
    return 0
  fi
  cand="${domain}"
  while [[ -n "${cand}" && "${cand}" == *.* ]]; do
    body="$(hm_cf_request GET "https://api.cloudflare.com/client/v4/zones?name=${cand}" 2>/dev/null)" || {
      # przy błędzie sieci/403 nie idź w górę w nieskończoność na tym samym błędzie
      if [[ "${cand}" == "${domain}" ]]; then
        return 1
      fi
      body=""
    }
    id=""
    if [[ -n "${body}" ]]; then
      id="$(hm_cf_parse_zone_id "${body}" 2>/dev/null || true)"
    fi
    if [[ -n "${id}" ]]; then
      printf '%s\t%s\n' "${domain}" "${id}" >> "${cache}"
      [[ "${cand}" != "${domain}" ]] && printf '%s\t%s\n' "${cand}" "${id}" >> "${cache}"
      printf '%s\n' "${id}"
      return 0
    fi
    cand="${cand#*.}"
    [[ "${cand}" == *.* ]] || break
  done
  hm_err "Nie znaleziono zone id dla ${domain}."
  return 1
}

hm_cf_fetch_url() {
  local url="$1" body err code bin
  body="$(mktemp)"
  err="$(mktemp)"
  bin="${HM_CF_CURL:-curl}"
  code="$("${bin}" -o "${body}" -w '%{http_code}' -- "${url}" 2>"${err}" || true)"
  if [[ "${code}" != "200" ]]; then
    hm_err "Nie udało się pobrać listy zakresów Cloudflare (${url})."
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
  local ols line tmp v4 v6 count=0 conf
  hm_cf_read_token >/dev/null || return 1
  ols="$(hm_cf_ols_file)"
  tmp="$(mktemp)"
  v4="$(mktemp)"
  v6="$(mktemp)"
  hm_cf_fetch_url "https://www.cloudflare.com/ips-v4" > "${v4}" || { rm -f "${tmp}" "${v4}" "${v6}"; return 1; }
  hm_cf_fetch_url "https://www.cloudflare.com/ips-v6" > "${v6}" || { rm -f "${tmp}" "${v4}" "${v6}"; return 1; }
  {
    cat "${v4}"
    cat "${v6}"
  } | while IFS= read -r line; do
    line="${line//$'\r'/}"
    hm_cf_cidr_ok "${line}" || continue
    printf '%s\n' "${line}"
  done > "${tmp}"
  count="$(grep -c . "${tmp}" || true)"
  if [[ "${count}" -eq 0 ]]; then
    rm -f "${tmp}" "${v4}" "${v6}"
    hm_err "Lista zakresów Cloudflare jest pusta. Nie włączam zaufania do nagłówka."
    return 1
  fi
  mkdir -p "$(dirname "${ols}")"
  # OLS: useClientIp / Access Control — plik dołączany z httpd_config (include)
  {
    printf '%s\n' '# hmtools-cloudflare-realip — include z httpd_config.conf'
    printf '%s\n' 'useIpInProxyHeader         1'
    while IFS= read -r line; do
      printf 'accessControl  {\n  allow                   %s\n}\n' "${line}"
    done < "${tmp}"
  } > "${ols}"
  rm -f "${tmp}" "${v4}" "${v6}"
  conf="${OLS_CONF:-/usr/local/lsws/conf/httpd_config.conf}"
  if [[ -f "${conf}" ]] && ! grep -qF "${ols}" "${conf}"; then
    printf '\n# hmtools cf realip\ninclude %s\n' "${ols}" >> "${conf}"
  fi
  if declare -F hm_ols_reload_soft >/dev/null 2>&1; then
    hm_ols_reload_soft || hm_warn "ols reload nieudany — dołącz ${ols} ręcznie i przeładuj."
  fi
  hm_ok "Zapisano zaufane zakresy Cloudflare (${count})."
}

hm_cf_realip_status() {
  local ols
  ols="$(hm_cf_ols_file)"
  if [[ ! -f "${ols}" ]]; then
    hm_info "Brak konfiguracji real IP."
    return 0
  fi
  grep -E 'allow |useIpInProxyHeader' "${ols}" || true
}

hm_cf_domain_ok() {
  [[ "${1:-}" =~ ^[A-Za-z0-9.-]+$ ]] || { hm_err "Zła domena."; return 1; }
}

hm_cf_purge() {
  local domain="${1:-}" url="" zone data
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
  # ochrona przed wstrzyknięciem JSON w --url
  case "${url}" in
    *\"*|*"'"*|*\\*|*$'\n'* ) hm_err "Niedozwolone znaki w --url."; return 1 ;;
  esac
  zone="$(hm_cf_zone_id "${domain}")" || return 1
  hm_confirm_plan "cf purge ${domain}" "Czyści cache Cloudflare." "" "cf purge ${domain}" || return 1
  if [[ -n "${url}" ]]; then
    if command -v jq >/dev/null 2>&1; then
      data="$(jq -n --arg u "${url}" '{files:[$u]}')"
    else
      data="$(printf '{"files":["%s"]}' "$(hm_cf_json_escape "${url}")")"
    fi
    hm_cf_request POST "https://api.cloudflare.com/client/v4/zones/${zone}/purge_cache" "${data}"
  else
    hm_cf_request POST "https://api.cloudflare.com/client/v4/zones/${zone}/purge_cache" '{"purge_everything":true}'
  fi
}

hm_cf_dns() {
  local action="${1:-list}" domain="${2:-}" typ="${3:-A}" name="${4:-}" content="${5:-}" zone data rid body n
  hm_cf_domain_ok "${domain}" || return 1
  zone="$(hm_cf_zone_id "${domain}")" || return 1
  case "${action}" in
    list)
      hm_cf_request GET "https://api.cloudflare.com/client/v4/zones/${zone}/dns_records"
      ;;
    add)
      [[ -n "${name}" && -n "${content}" ]] || { hm_err "Użycie: cf dns add <domena> <typ> <nazwa> <treść>"; return 1; }
      hm_confirm_plan "cf dns add ${domain}" "Dodanie rekordu DNS." "" "cf dns add ${domain}" || return 1
      if command -v jq >/dev/null 2>&1; then
        data="$(jq -n --arg t "${typ}" --arg n "${name}" --arg c "${content}" '{type:$t,name:$n,content:$c,ttl:1}')"
      else
        data="$(printf '{"type":"%s","name":"%s","content":"%s","ttl":1}' \
          "$(hm_cf_json_escape "${typ}")" "$(hm_cf_json_escape "${name}")" "$(hm_cf_json_escape "${content}")")"
      fi
      hm_cf_request POST "https://api.cloudflare.com/client/v4/zones/${zone}/dns_records" "${data}"
      ;;
    edit|delete)
      [[ -n "${name}" ]] || { hm_err "Użycie: cf dns ${action} <domena> <typ> <nazwa> [treść]"; return 1; }
      body="$(hm_cf_request GET "https://api.cloudflare.com/client/v4/zones/${zone}/dns_records?type=${typ}&name=${name}" 2>/dev/null)" || return 1
      n="$(printf '%s\n' "${body}" | grep -cE '"id"[[:space:]]*:' || true)"
      if [[ "${n}" -gt 1 ]]; then
        hm_err "Wiele rekordów ${typ} ${name} — doprecyzuj ręcznie w panelu."
        return 1
      fi
      rid="$(printf '%s\n' "${body}" | grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
      [[ -n "${rid}" ]] || { hm_err "Brak rekordu ${typ} ${name}."; return 1; }
      hm_confirm_plan "cf dns ${action} ${domain}" "Zmiana DNS." "" "cf dns ${action} ${domain}" || return 1
      if [[ "${action}" == "delete" ]]; then
        hm_cf_request DELETE "https://api.cloudflare.com/client/v4/zones/${zone}/dns_records/${rid}"
      else
        [[ -n "${content}" ]] || { hm_err "edit wymaga treści."; return 1; }
        if command -v jq >/dev/null 2>&1; then
          data="$(jq -n --arg t "${typ}" --arg n "${name}" --arg c "${content}" '{type:$t,name:$n,content:$c}')"
        else
          data="$(printf '{"type":"%s","name":"%s","content":"%s"}' \
            "$(hm_cf_json_escape "${typ}")" "$(hm_cf_json_escape "${name}")" "$(hm_cf_json_escape "${content}")")"
        fi
        hm_cf_request PATCH "https://api.cloudflare.com/client/v4/zones/${zone}/dns_records/${rid}" "${data}"
      fi
      ;;
    *)
      hm_err "Użycie: cf dns list|add|edit|delete <domena>"
      return 1
      ;;
  esac
}

hm_cf_attack() {
  local mode="${1:-}" domain="${2:-}" level="" zone prev prevf cur
  hm_cf_domain_ok "${domain}" || return 1
  zone="$(hm_cf_zone_id "${domain}")" || return 1
  prevf="$(hm_cf_attack_prev "${domain}")"
  mkdir -p "$(dirname "${prevf}")"
  case "${mode}" in
    on)
      cur="$(hm_cf_request GET "https://api.cloudflare.com/client/v4/zones/${zone}/settings/security_level" 2>/dev/null || true)"
      prev="$(printf '%s\n' "${cur}" | grep -oE '"value"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
      [[ -n "${prev}" ]] || prev="medium"
      printf '%s\n' "${prev}" > "${prevf}"
      level="under_attack"
      ;;
    off)
      if [[ -f "${prevf}" ]]; then
        level="$(tr -d '\r\n' < "${prevf}")"
      else
        level="medium"
      fi
      rm -f "${prevf}"
      ;;
    *) hm_err "Użycie: cf attack on|off <domena>"; return 1 ;;
  esac
  hm_confirm_plan "cf attack ${mode} ${domain}" "Zmienia tryb Under Attack." "" "cf attack ${mode} ${domain}" || return 1
  hm_cf_request PATCH "https://api.cloudflare.com/client/v4/zones/${zone}/settings/security_level" "{\"value\":\"${level}\"}"
}

hm_cf_block() {
  local target="${1:-}" domain="${2:-}" kind="" zone data selfip
  hm_cf_domain_ok "${domain}" || return 1
  zone="$(hm_cf_zone_id "${domain}")" || return 1
  if [[ "${target}" =~ ^[A-Za-z]{2}$ ]]; then
    kind="country"
  elif [[ "${target}" =~ ^[0-9.]+$ || "${target}" =~ ^[0-9A-Fa-f:]+$ ]]; then
    kind="ip"
  else
    hm_err "Podaj adres IP albo dwuliterowy kod kraju."
    return 1
  fi
  selfip="${SSH_CLIENT:-}"
  selfip="${selfip%% *}"
  if [[ "${kind}" == "ip" && -n "${selfip}" && "${target}" == "${selfip}" ]]; then
    hm_err "Nie blokuję własnego IP sesji SSH (${selfip})."
    return 1
  fi
  hm_confirm_plan "cf block ${target}" "Reguła blokady Cloudflare." "" "cf block ${target} ${domain}" || return 1
  if command -v jq >/dev/null 2>&1; then
    data="$(jq -n --arg k "${kind}" --arg v "${target}" '{mode:"block",configuration:{target:$k,value:$v}}')"
  else
    data="$(printf '{"mode":"block","configuration":{"target":"%s","value":"%s"}}' \
      "$(hm_cf_json_escape "${kind}")" "$(hm_cf_json_escape "${target}")")"
  fi
  hm_cf_request POST "https://api.cloudflare.com/client/v4/zones/${zone}/firewall/access_rules/rules" "${data}"
}

hm_cf_status() {
  local domain="${1:-}" out zone
  hm_cf_domain_ok "${domain}" || return 1
  zone="$(hm_cf_zone_id "${domain}")" || return 1
  out="$(hm_cf_request GET "https://api.cloudflare.com/client/v4/zones/${zone}")" || return 1
  printf '%s\n' "${out}"
  if printf '%s\n' "${out}" | grep -qi 'flexible'; then
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
