#!/usr/bin/env bash
# dns expiry / drift / dnssec — odczyt fixture albo cache, bez żywego RDAP.

hm_dns_days_until() {
  local exp="$1" today="${HM_DNS_TODAY:-}" a b
  [[ -n "${today}" ]] || today="$(date +%Y-%m-%d)"
  a="$(date -d "${exp}" +%s)"
  b="$(date -d "${today}" +%s)"
  printf '%s\n' "$(( (a - b) / 86400 ))"
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
  cache="${HM_DNS_EXPIRY_CACHE:?}/${domain}"
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
    src="${HM_DNS_RDAP_DIR:?}/${domain}"
    [[ -f "${src}" ]] || { hm_err "Brak danych RDAP/WHOIS dla ${domain}."; return 1; }
    printf '%s\n' "${domain}" >> "${HM_DNS_RDAP_HITS:?}"
    raw="$(awk 'match($0, /[0-9]{4}[.-][0-9]{2}[.-][0-9]{2}/) { print substr($0, RSTART, RLENGTH); exit }' "${src}")"
    date="${raw//./-}"
    [[ -n "${date}" ]] || { hm_err "Nie odczytano daty dla ${domain}."; return 1; }
    printf '%s\n' "${date}" > "${cache}"
  fi
  days="$(hm_dns_days_until "${date}")"
  printf '%s\t%s\n' "${domain}" "${days}"
  if [[ "${days}" -le 30 ]]; then
    hm_dns_expiry_alert "${domain}" "${days}" "${date}"
  fi
}

hm_dns_expiry_cmd() {
  local target="${1:-${HM_SITE_DOMAIN:-}}" domain
  if [[ "${target}" == "--all" ]]; then
    [[ -f "${HM_DNS_DOMAINS:-}" ]] || { hm_err "Brak listy domen."; return 1; }
    while IFS= read -r domain; do
      [[ -n "${domain}" ]] || continue
      hm_dns_expiry_one "${domain}" || return 1
    done < "${HM_DNS_DOMAINS}"
    return 0
  fi
  [[ -n "${target}" ]] || { hm_err "Użycie: dns expiry <domena|--all>"; return 1; }
  hm_dns_expiry_one "${target}"
}

hm_dns_drift_one() {
  local domain="$1" base pub diff=0
  base="${HM_DNS_BASELINE:?}/${domain}"
  pub="${HM_DNS_PUBLIC:?}/${domain}"
  [[ -f "${base}" && -f "${pub}" ]] || { hm_err "Brak baseline albo publicznego odczytu dla ${domain}."; return 1; }
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
  local domain
  if [[ "${1:-}" == "baseline" ]]; then
    domain="${2:-${HM_SITE_DOMAIN:-}}"
    [[ -n "${domain}" && -f "${HM_DNS_PUBLIC:?}/${domain}" ]] || { hm_err "Brak publicznego odczytu."; return 1; }
    mkdir -p "${HM_DNS_BASELINE:?}"
    cp -f "${HM_DNS_PUBLIC}/${domain}" "${HM_DNS_BASELINE}/${domain}"
    hm_ok "Baseline ${domain}."
    return 0
  fi
  domain="${1:-${HM_SITE_DOMAIN:-}}"
  if [[ "${domain}" == "--all" ]]; then
    [[ -f "${HM_DNS_DOMAINS:-}" ]] || { hm_err "Brak listy domen."; return 1; }
    while IFS= read -r domain; do
      [[ -n "${domain}" ]] || continue
      hm_dns_drift_one "${domain}" || return 1
    done < "${HM_DNS_DOMAINS}"
    return 0
  fi
  [[ -n "${domain}" ]] || { hm_err "Użycie: dns drift [baseline] <domena|--all>"; return 1; }
  hm_dns_drift_one "${domain}"
}

hm_dns_dnssec_cmd() {
  local domain="${1:-${HM_SITE_DOMAIN:-}}" file ds="" key="" valid=""
  [[ -n "${domain}" ]] || { hm_err "Użycie: dns dnssec <domena>"; return 1; }
  file="${HM_DNS_DNSSEC:?}/${domain}"
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
  local domain line days
  [[ -f "${HM_DNS_DOMAINS:-}" ]] || return 0
  while IFS= read -r domain; do
    [[ -n "${domain}" ]] || continue
    line="$(hm_dns_expiry_one "${domain}" 2>/dev/null || true)"
    [[ -n "${line}" ]] || continue
    days="${line##*$'\t'}"
    if [[ "${days}" =~ ^-?[0-9]+$ && "${days}" -le 30 ]]; then
      printf 'dns:expiry:%s:%s\n' "${domain}" "${days}"
    fi
  done < "${HM_DNS_DOMAINS}"
}

hm_dns_watch_summary() {
  local domain
  [[ -f "${HM_DNS_DOMAINS:-}" ]] || return 0
  hm_dns_expiry_cmd --all || true
  if declare -F hm_mail_check_cmd >/dev/null 2>&1; then
    while IFS= read -r domain; do
      [[ -n "${domain}" ]] || continue
      hm_mail_check_cmd "${domain}" >/dev/null 2>&1 || true
      printf 'mail diag: %s\n' "${domain}"
    done < "${HM_DNS_DOMAINS}"
  fi
}
