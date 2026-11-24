#!/usr/bin/env bash
# dns expiry / drift / dnssec — cache + fixture albo żywy RDAP/dig.

hm_dns_paths_init() {
  local base="${HM_DNS_DIR:-/var/lib/hmtools/dns}"
  HM_DNS_EXPIRY_CACHE="${HM_DNS_EXPIRY_CACHE:-${base}/expiry-cache}"
  HM_DNS_RDAP_DIR="${HM_DNS_RDAP_DIR:-${base}/rdap}"
  HM_DNS_RDAP_HITS="${HM_DNS_RDAP_HITS:-${base}/rdap.hits}"
  HM_DNS_BASELINE="${HM_DNS_BASELINE:-${base}/baseline}"
  HM_DNS_PUBLIC="${HM_DNS_PUBLIC:-${base}/public}"
  HM_DNS_DNSSEC="${HM_DNS_DNSSEC:-${base}/dnssec}"
  HM_DNS_DEDUP="${HM_DNS_DEDUP:-${base}/expiry.dedup}"
  mkdir -p "${HM_DNS_EXPIRY_CACHE}" "${HM_DNS_RDAP_DIR}" "${HM_DNS_BASELINE}" \
    "${HM_DNS_PUBLIC}" "${HM_DNS_DNSSEC}" "$(dirname "${HM_DNS_RDAP_HITS}")" 2>/dev/null || true
}

hm_dns_rdap_fetch() {
  local domain="$1" dest="$2" url
  url="https://rdap.org/domain/${domain}"
  if [[ -n "${HM_DNS_RDAP_URL:-}" ]]; then
    url="${HM_DNS_RDAP_URL}/${domain}"
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time 15 "${url}" -o "${dest}" 2>/dev/null && return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -q -O "${dest}" --timeout=15 "${url}" 2>/dev/null && return 0
  fi
  return 1
}

hm_dns_public_fetch() {
  local domain="$1" dest="$2" tmp
  command -v dig >/dev/null 2>&1 || return 1
  tmp="$(mktemp)"
  {
    dig +short A "${domain}" @1.1.1.1 2>/dev/null | awk '{print "A "$0}'
    dig +short AAAA "${domain}" @1.1.1.1 2>/dev/null | awk '{print "AAAA "$0}'
    dig +short MX "${domain}" @1.1.1.1 2>/dev/null | awk '{print "MX "$0}'
    dig +short NS "${domain}" @1.1.1.1 2>/dev/null | awk '{print "NS "$0}'
  } > "${tmp}"
  if [[ -s "${tmp}" ]]; then
    mv -f "${tmp}" "${dest}"
    return 0
  fi
  rm -f "${tmp}"
  return 1
}

hm_dns_dnssec_fetch() {
  local domain="$1" dest="$2" tmp ds key
  command -v dig >/dev/null 2>&1 || return 1
  tmp="$(mktemp)"
  ds="$(dig +short DS "${domain}" @1.1.1.1 2>/dev/null | awk '{print $4; exit}')"
  key="$(dig +short DNSKEY "${domain}" @1.1.1.1 2>/dev/null | awk '{print $4; exit}')"
  {
    printf 'DS %s\n' "${ds:-}"
    printf 'DNSKEY %s\n' "${key:-}"
    if dig +dnssec +short SOA "${domain}" @1.1.1.1 2>/dev/null | grep -q .; then
      printf 'valid yes\n'
    else
      printf 'valid no\n'
    fi
  } > "${tmp}"
  mv -f "${tmp}" "${dest}"
}

hm_dns_days_until() {
  local exp="$1" today="${HM_DNS_TODAY:-}" a b
  [[ -n "${today}" ]] || today="$(date +%Y-%m-%d)"
  a="$(date -d "${exp}" +%s)"
  b="$(date -d "${today}" +%s)"
  printf '%s\n' "$(( (a - b) / 86400 ))"
}

# Apex: www. → bez; .co.uk/.com.pl → 3 etykiety; inaczej 2.
hm_dns_apex() {
  local d n
  d="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  d="${d#www.}"
  d="${d%.}"
  [[ -n "${d}" ]] || return 0
  case "${d}" in
    *.co.uk|*.org.uk|*.ac.uk|*.gov.uk|*.com.pl|*.net.pl|*.org.pl|*.com.au|*.net.au|*.co.jp|*.com.br)
      n="$(printf '%s' "${d}" | awk -F. '{ if (NF>=3) print $(NF-2)"."$(NF-1)"."$NF; else print $0 }')"
      ;;
    *)
      n="$(printf '%s' "${d}" | awk -F. '{ if (NF>=2) print $(NF-1)"."$NF; else print $0 }')"
      ;;
  esac
  printf '%s\n' "${n}"
}

# Lista domen: HM_DNS_DOMAINS → manifessty → webs (HM_SITES_LIST), zredukowane do apex.
hm_dns_list_domains() {
  local d apex dir f seen="" out=""
  hm_dns_paths_init
  if [[ -n "${HM_DNS_DOMAINS:-}" && -f "${HM_DNS_DOMAINS}" ]]; then
    while IFS= read -r d; do
      [[ -n "${d}" && "${d}" != \#* ]] || continue
      apex="$(hm_dns_apex "${d}")"
      [[ -n "${apex}" ]] || continue
      case " ${seen} " in
        *" ${apex} "*) continue ;;
      esac
      seen="${seen} ${apex}"
      out="${out}${apex}"$'\n'
    done < "${HM_DNS_DOMAINS}"
    printf '%s' "${out}"
    return 0
  fi
  dir="${HM_SITE_MANIFEST_DIR:-/etc/hmtools/sites}"
  if [[ -d "${dir}" ]]; then
    shopt -s nullglob
    for f in "${dir}"/*.json; do
      d="$(basename "${f}" .json)"
      [[ "${d}" == *.resources ]] && continue
      apex="$(hm_dns_apex "${d}")"
      [[ -n "${apex}" ]] || continue
      case " ${seen} " in
        *" ${apex} "*) continue ;;
      esac
      seen="${seen} ${apex}"
      out="${out}${apex}"$'\n'
    done
    shopt -u nullglob
  fi
  if declare -F hm_discover_sites >/dev/null 2>&1; then
    hm_discover_sites 2>/dev/null || true
    for d in "${HM_SITES_LIST[@]:-}"; do
      [[ -n "${d}" ]] || continue
      apex="$(hm_dns_apex "${d}")"
      [[ -n "${apex}" ]] || continue
      case " ${seen} " in
        *" ${apex} "*) continue ;;
      esac
      seen="${seen} ${apex}"
      out="${out}${apex}"$'\n'
    done
  fi
  if [[ -z "${out}" ]]; then
    return 1
  fi
  printf '%s' "${out}"
}

# Data wygaśnięcia z RDAP/WHOIS: eventAction=expiration, nie registration.
hm_dns_parse_expiry_date() {
  local src="$1" date=""
  [[ -f "${src}" ]] || return 1
  if command -v jq >/dev/null 2>&1; then
    date="$(jq -r '
      ([.events[]? | select(.eventAction == "expiration") | .eventDate] | first)
      // empty
    ' "${src}" 2>/dev/null || true)"
    date="${date%%T*}"
    date="${date%% *}"
    [[ "${date}" == "null" ]] && date=""
  fi
  if [[ -z "${date}" ]]; then
    date="$(awk '
      function date_from(s,   m) {
        if (match(s, /"eventDate"[[:space:]]*:[[:space:]]*"[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) {
          m = substr(s, RSTART, RLENGTH)
          if (match(m, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) return substr(m, RSTART, 10)
        }
        return ""
      }
      function last_date_from(s,   tmp, m, last) {
        tmp = s; last = ""
        while (match(tmp, /"eventDate"[[:space:]]*:[[:space:]]*"[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) {
          m = substr(tmp, RSTART, RLENGTH)
          if (match(m, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) last = substr(m, RSTART, 10)
          tmp = substr(tmp, RSTART + RLENGTH)
        }
        return last
      }
      {
        data = data $0
      }
      END {
        rest = data
        while (match(rest, /"eventAction"[[:space:]]*:[[:space:]]*"[^"]+"/)) {
          act = substr(rest, RSTART, RLENGTH)
          after = substr(rest, RSTART + RLENGTH)
          if (act ~ /"expiration"/) {
            # najpierw eventDate PO action (typowe RDAP)
            d = date_from(substr(after, 1, 400))
            if (d == "") {
              # albo ostatnie eventDate tuż PRZED action (odwrotna kolejność pól)
              ws = RSTART - 200; if (ws < 1) ws = 1
              d = last_date_from(substr(rest, ws, RSTART - ws))
            }
            if (d != "") { print d; exit }
          }
          rest = after
        }
        # WHOIS
        if (match(data, /[Rr]egistry [Ee]xpiry [Dd]ate:[[:space:]]*[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) {
          m = substr(data, RSTART, RLENGTH)
          if (match(m, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) { print substr(m, RSTART, 10); exit }
        }
        if (match(data, /[Ee]xpiry [Dd]ate:[[:space:]]*[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) {
          m = substr(data, RSTART, RLENGTH)
          if (match(m, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) { print substr(m, RSTART, 10); exit }
        }
        # .pl style
        if (match(data, /renewal date:[[:space:]]*[0-9][0-9][0-9][0-9][.-][0-9][0-9][.-][0-9][0-9]/)) {
          m = substr(data, RSTART, RLENGTH)
          if (match(m, /[0-9][0-9][0-9][0-9][.-][0-9][0-9][.-][0-9][0-9]/)) {
            d = substr(m, RSTART, 10); gsub(/\./, "-", d); print d; exit
          }
        }
      }
    ' "${src}")"
  fi
  [[ -n "${date}" ]] || return 1
  printf '%s\n' "${date}"
}

hm_dns_expiry_alert() {
  local domain="$1" days="$2" date="$3" dedup key
  dedup="${HM_DNS_DEDUP:-/var/lib/hmtools/dns-expiry.dedup}"
  key="${domain} ${date}"
  if [[ -f "${dedup}" ]] && grep -qxF "${key}" "${dedup}"; then
    return 0
  fi
  if [[ "${days}" -le 7 ]]; then
    hm_warn "Domena ${domain} wygasa za ${days} dni."
  else
    hm_warn "Domena ${domain} wygasa za ${days} dni (próg 30)."
  fi
  if declare -F hm_notify >/dev/null 2>&1; then
    hm_notify error "DNS expiry" "${domain} ${days}" "dns.expiry.${domain}"
  fi
  mkdir -p "$(dirname "${dedup}")"
  printf '%s\n' "${key}" >> "${dedup}"
}

hm_dns_expiry_one() {
  local domain="$1" cache src raw="" date="" days="" age=0 now=0 mtime=0
  hm_dns_paths_init
  cache="${HM_DNS_EXPIRY_CACHE}/${domain}"
  mkdir -p "${HM_DNS_EXPIRY_CACHE}"
  if [[ -f "${cache}" ]]; then
    now="$(date +%s)"
    mtime="$(date -d "@$(date -r "${cache}" +%s)" +%s 2>/dev/null || date -r "${cache}" +%s)"
    age="$(( now - mtime ))"
    if [[ "${age}" -lt "${HM_DNS_CACHE_TTL:-86400}" ]]; then
      date="$(tr -d '\r\n' < "${cache}")"
    fi
  fi
  if [[ -z "${date}" ]]; then
    src="${HM_DNS_RDAP_DIR}/${domain}"
    if [[ ! -f "${src}" ]]; then
      mkdir -p "${HM_DNS_RDAP_DIR}"
      if ! hm_dns_rdap_fetch "${domain}" "${src}"; then
        hm_err "Brak danych RDAP/WHOIS dla ${domain} (ustaw fixture HM_DNS_RDAP_DIR albo dostęp do rdap.org)."
        return 1
      fi
    fi
    printf '%s\n' "${domain}" >> "${HM_DNS_RDAP_HITS}"
    date="$(hm_dns_parse_expiry_date "${src}")" || {
      hm_err "Nie odczytano daty wygaśnięcia dla ${domain}."
      return 1
    }
    printf '%s\n' "${date}" > "${cache}"
  fi
  days="$(hm_dns_days_until "${date}")"
  printf '%s\t%s\n' "${domain}" "${days}"
  if [[ "${days}" -le 30 ]]; then
    hm_dns_expiry_alert "${domain}" "${days}" "${date}"
  fi
}

hm_dns_expiry_cmd() {
  local target="${1:-${HM_SITE_DOMAIN:-}}" domain list
  if [[ "${target}" == "--all" ]]; then
    list="$(hm_dns_list_domains)" || { hm_err "Brak listy domen (HM_DNS_DOMAINS, manifessty lub webs)."; return 1; }
    while IFS= read -r domain; do
      [[ -n "${domain}" ]] || continue
      hm_dns_expiry_one "${domain}" || return 1
    done <<< "${list}"
    return 0
  fi
  [[ -n "${target}" ]] || { hm_err "Użycie: dns expiry <domena|--all>"; return 1; }
  hm_dns_expiry_one "${target}"
}

hm_dns_drift_one() {
  local domain="$1" base pub diff=0
  hm_dns_paths_init
  base="${HM_DNS_BASELINE}/${domain}"
  pub="${HM_DNS_PUBLIC}/${domain}"
  if [[ ! -f "${pub}" ]]; then
    mkdir -p "${HM_DNS_PUBLIC}"
    hm_dns_public_fetch "${domain}" "${pub}" || true
  fi
  [[ -f "${base}" && -f "${pub}" ]] || { hm_err "Brak baseline albo publicznego odczytu dla ${domain} (dns drift baseline <domena>)."; return 1; }
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    if ! grep -qxF "${line}" "${pub}"; then
      printf 'oczekiwane\t%s\n' "${line}"
      diff=1
    fi
  done < "${base}"
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    if ! grep -qxF "${line}" "${base}"; then
      printf 'publiczne\t%s\n' "${line}"
      diff=1
    fi
  done < "${pub}"
  if [[ "${diff}" -eq 0 ]]; then
    printf 'brak dryfu\t%s\n' "${domain}"
  fi
}

hm_dns_drift_cmd() {
  local domain list
  if [[ "${1:-}" == "baseline" ]]; then
    hm_dns_paths_init
    domain="${2:-${HM_SITE_DOMAIN:-}}"
    if [[ -n "${domain}" && ! -f "${HM_DNS_PUBLIC}/${domain}" ]]; then
      mkdir -p "${HM_DNS_PUBLIC}"
      hm_dns_public_fetch "${domain}" "${HM_DNS_PUBLIC}/${domain}" || true
    fi
    [[ -n "${domain}" && -f "${HM_DNS_PUBLIC}/${domain}" ]] || { hm_err "Brak publicznego odczytu."; return 1; }
    mkdir -p "${HM_DNS_BASELINE}"
    cp -f "${HM_DNS_PUBLIC}/${domain}" "${HM_DNS_BASELINE}/${domain}"
    hm_ok "Baseline ${domain}."
    return 0
  fi
  domain="${1:-${HM_SITE_DOMAIN:-}}"
  if [[ "${domain}" == "--all" ]]; then
    list="$(hm_dns_list_domains)" || { hm_err "Brak listy domen (HM_DNS_DOMAINS, manifessty lub webs)."; return 1; }
    while IFS= read -r domain; do
      [[ -n "${domain}" ]] || continue
      hm_dns_drift_one "${domain}" || return 1
    done <<< "${list}"
    return 0
  fi
  [[ -n "${domain}" ]] || { hm_err "Użycie: dns drift [baseline] <domena|--all>"; return 1; }
  hm_dns_drift_one "${domain}"
}

hm_dns_dnssec_cmd() {
  local domain="${1:-${HM_SITE_DOMAIN:-}}" file ds="" key="" valid=""
  hm_dns_paths_init
  [[ -n "${domain}" ]] || { hm_err "Użycie: dns dnssec <domena>"; return 1; }
  file="${HM_DNS_DNSSEC}/${domain}"
  if [[ ! -f "${file}" ]]; then
    mkdir -p "${HM_DNS_DNSSEC}"
    hm_dns_dnssec_fetch "${domain}" "${file}" || {
      hm_err "Brak odczytu DNSSEC dla ${domain} (dig +dnssec albo fixture HM_DNS_DNSSEC)."
      return 1
    }
  fi
  [[ -f "${file}" ]] || { hm_err "Brak odczytu DNSSEC dla ${domain}."; return 1; }
  ds="$(awk '/^DS / { print $2 }' "${file}")"
  key="$(awk '/^DNSKEY / { print $2 }' "${file}")"
  valid="$(awk '/^valid / { print $2 }' "${file}")"
  printf 'DS=%s\tDNSKEY=%s\tvalid=%s\n' "${ds}" "${key}" "${valid}"
  if [[ "${ds}" != "${key}" || "${valid}" == "no" ]]; then
    hm_warn "DNSSEC rozjechany dla ${domain}."
    return 1
  fi
}

hm_health_dns_alerts() {
  local domain line days list
  list="$(hm_dns_list_domains 2>/dev/null)" || return 0
  while IFS= read -r domain; do
    [[ -n "${domain}" ]] || continue
    line="$(hm_dns_expiry_one "${domain}" 2>/dev/null || true)"
    [[ -n "${line}" ]] || continue
    days="${line##*$'\t'}"
    if [[ "${days}" =~ ^-?[0-9]+$ && "${days}" -le 30 ]]; then
      printf 'dns:expiry:%s:%s\n' "${domain}" "${days}"
    fi
  done <<< "${list}"
}

hm_dns_watch_summary() {
  local domain list
  list="$(hm_dns_list_domains 2>/dev/null)" || return 0
  hm_dns_expiry_cmd --all || true
  if declare -F hm_mail_check_cmd >/dev/null 2>&1; then
    while IFS= read -r domain; do
      [[ -n "${domain}" ]] || continue
      hm_mail_check_cmd "${domain}" >/dev/null 2>&1 || true
      printf 'mail diag: %s\n' "${domain}"
    done <<< "${list}"
  fi
}
