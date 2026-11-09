#!/usr/bin/env bash
# dns — strefy PowerDNS (CyberPanel) + diagnostyka


_hm_cmd_help dns <<'EOF'
Użycie (globalnie):
  dns                         Strefy lokalne + status pdns
  dns check <domena>          A/AAAA vs IP VPS, NS, MX, SPF, DKIM, DMARC, CAA, propagacja

Użycie (kontekst [domena]>):
  dns | dns list [--type T]   Rekordy strefy (tylko lokalna)
  dns add <TYP> <nazwa> <wartość> [--ttl N] [--prio N] [--yes]
  dns edit <id> --value V [--ttl N] [--prio N] [--yes]
  dns delete <id> [--force] [--yes]
  dns export                  Format BIND (stdout)

Typy: A AAAA CNAME MX TXT SRV CAA NS.
Usunięcie NS/SOA wymaga --force. Zapis przez cyberpanel CLI (SOA serial).
EOF

_HM_DNS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=check.sh
source "${_HM_DNS_DIR}/check.sh"

# --- helpers ---------------------------------------------------------------

hm_dns_is_valid_ip() {
  if declare -F hm_is_valid_ip >/dev/null 2>&1; then
    hm_is_valid_ip "$@"
    return $?
  fi
  local ip="${1:-}"
  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local o
  IFS=. read -r -a _o <<< "${ip}"
  for o in "${_o[@]}"; do
    ((10#${o} <= 255)) || return 1
  done
  [[ "${ip}" != "0.0.0.0" ]]
}

hm_dns_require_cyberpanel_cli() {
  hm_detect_all 2>/dev/null || true
  if [[ "${PANEL:-}" != "cyberpanel" ]] && ! hm_have_cmd cyberpanel; then
    hm_err "Wymagany CyberPanel CLI (cyberpanel) — brak fallbacku SQL na zapis DNS."
    return 1
  fi
  if ! hm_have_cmd cyberpanel; then
    hm_err "Brak binary cyberpanel."
    return 1
  fi
  return 0
}

hm_dns_cp_db_ok() {
  local n
  n="$(hm_mysql_exec cyberpanel -N -e \
    "SELECT COUNT(*) FROM information_schema.tables
     WHERE table_schema='cyberpanel' AND table_name='domains';" 2>/dev/null | tr -d '[:space:]')"
  [[ "${n}" == "1" ]] || return 1
  n="$(hm_mysql_exec cyberpanel -N -e \
    "SELECT COUNT(*) FROM information_schema.tables
     WHERE table_schema='cyberpanel' AND table_name='records';" 2>/dev/null | tr -d '[:space:]')"
  [[ "${n}" == "1" ]]
}

hm_dns_pdns_status_line() {
  local st="unknown"
  if hm_have_cmd systemctl; then
    if systemctl is-active --quiet pdns 2>/dev/null; then
      st="active"
    elif systemctl is-enabled --quiet pdns 2>/dev/null; then
      st="inactive"
    else
      st="not-installed/disabled"
    fi
  elif hm_have_cmd pdns_control; then
    if pdns_control ping >/dev/null 2>&1; then
      st="alive (pdns_control)"
    else
      st="down (pdns_control)"
    fi
  fi
  printf '%s' "${st}"
}

hm_dns_normalize_type() {
  local t
  t="$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]')"
  case "${t}" in
    A|AAAA|CNAME|MX|TXT|SRV|CAA|NS) printf '%s' "${t}" ;;
    *) return 1 ;;
  esac
}

hm_dns_split_txt() {
  # stdout: jeden lub więcej chunków ≤255 (PowerDNS content bez zewnętrznych cudzysłowów)
  local raw="$1" chunk
  raw="${raw#\"}"
  raw="${raw%\"}"
  while [[ ${#raw} -gt 255 ]]; do
    chunk="${raw:0:255}"
    printf '%s\n' "${chunk}"
    raw="${raw:255}"
  done
  [[ -n "${raw}" ]] && printf '%s\n' "${raw}"
}

hm_dns_validate_value() {
  local typ="$1" value="$2" prio="${3:-0}"
  case "${typ}" in
    A)
      hm_dns_is_valid_ip "${value}" || { hm_err "A wymaga IPv4: ${value}"; return 1; }
      [[ "${value}" == *:* ]] && { hm_err "A nie przyjmuje IPv6"; return 1; }
      ;;
    AAAA)
      hm_dns_is_valid_ip "${value}" || { hm_err "AAAA wymaga IPv6: ${value}"; return 1; }
      [[ "${value}" == *.* && "${value}" != *:* ]] && { hm_err "AAAA nie przyjmuje IPv4"; return 1; }
      ;;
    CNAME|NS)
      [[ -n "${value}" ]] || { hm_err "${typ}: pusta wartość"; return 1; }
      ;;
    MX)
      [[ -n "${value}" ]] || { hm_err "MX: pusta wartość"; return 1; }
      [[ "${prio}" =~ ^[0-9]+$ ]] || { hm_err "MX: --prio musi być liczbą"; return 1; }
      ;;
    TXT|CAA|SRV)
      [[ -n "${value}" ]] || { hm_err "${typ}: pusta wartość"; return 1; }
      ;;
  esac
  return 0
}

hm_dns_normalize_name() {
  # relative (www) / @ / FQDN → nazwa względna względem strefy (dla CLI --name)
  local name="$1" domain="$2"
  local dom_l name_l
  dom_l="$(printf '%s' "${domain}" | tr '[:upper:]' '[:lower:]')"
  name="${name%.}"
  name_l="$(printf '%s' "${name}" | tr '[:upper:]' '[:lower:]')"
  if [[ -z "${name}" || "${name}" == "@" || "${name_l}" == "${dom_l}" ]]; then
    printf '%s' "${domain}"
    return 0
  fi
  if [[ "${name_l}" == *."${dom_l}" ]]; then
    printf '%s' "${name}"
    return 0
  fi
  # relative label
  if [[ "${name}" =~ ^[A-Za-z0-9._*@-]+$ ]]; then
    printf '%s.%s' "${name}" "${domain}"
    return 0
  fi
  hm_err "Nieprawidłowa nazwa rekordu: ${name}"
  return 1
}

hm_dns_zone_id() {
  local domain="$1" dq id
  hm_is_valid_domain "${domain}" || return 1
  dq="$(hm_sql_quote "${domain}")"
  id="$(hm_mysql_exec cyberpanel -N -e \
    "SELECT id FROM domains WHERE name=${dq} LIMIT 1;" 2>/dev/null | tr -d '[:space:]')"
  [[ -n "${id}" && "${id}" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "${id}"
}

hm_dns_record_row() {
  # stdout: id|name|type|content|ttl|prio  — tylko gdy rekord należy do strefy domain
  local domain="$1" rid="$2" zid dq
  zid="$(hm_dns_zone_id "${domain}")" || return 1
  dq="$(hm_sql_quote "${rid}")"
  hm_mysql_exec cyberpanel -N -e \
    "SELECT id, name, type, content, ttl, IFNULL(prio,0)
     FROM records
     WHERE id=${dq} AND domain_id=${zid}
     LIMIT 1;" 2>/dev/null | head -1
}

# --- global overview -------------------------------------------------------

hm_dns_zones_overview() {
  echo "${C_BOLD}DNS / PowerDNS${C_RESET}"
  echo "  pdns: $(hm_dns_pdns_status_line)"
  if ! hm_dns_cp_db_ok; then
    hm_warn "Brak tabel domains/records w bazie cyberpanel — strefy lokalne niedostępne."
    hm_info "Diagnostyka zewnętrzna: dns check <domena>"
    return 0
  fi
  echo
  echo "${C_BOLD}Strefy lokalne${C_RESET}"
  hm_table_begin
  hm_table_row ID NAZWA TYP
  local line
  while IFS=$'\t' read -r id name typ; do
    [[ -n "${id}" ]] || continue
    hm_table_row "${id}" "${name}" "${typ:-NATIVE}"
  done < <(hm_mysql_exec cyberpanel -N -e \
    "SELECT id, name, type FROM domains ORDER BY name;" 2>/dev/null || true)
  hm_table_print
  echo
  hm_info "W kontekście: use <domena> → dns list | add | edit | delete | export"
  hm_info "Globalnie: dns check <domena>"
}

# --- list / export ---------------------------------------------------------

hm_dns_list_records() {
  local domain="${1:-}" typ_filter=""
  shift || true
  local a
  while [[ $# -gt 0 ]]; do
    a="$1"; shift || true
    case "${a}" in
      --type|-t)
        typ_filter="$(hm_dns_normalize_type "${1:-}")" || { hm_err "Nieznany typ: ${1:-}"; return 1; }
        shift || true
        ;;
      help|-h|--help)
        echo "Użycie: dns list [--type A|MX|…]"
        return 0
        ;;
      *) hm_err "Nieznany argument: ${a}"; return 1 ;;
    esac
  done
  [[ -n "${domain}" ]] || { hm_err "Brak domeny"; return 1; }
  hm_is_valid_domain "${domain}" || { hm_err "Nieprawidłowa domena: ${domain}"; return 1; }

  if ! hm_dns_cp_db_ok; then
    hm_err "Brak tabel PowerDNS (domains/records) — nie mogę listować strefy lokalnej."
    return 1
  fi
  local zid
  if ! zid="$(hm_dns_zone_id "${domain}")"; then
    hm_err "Brak lokalnej strefy DNS dla ${domain} (exact match)."
    hm_info "Diagnostyka zewnętrzna: dns check ${domain}"
    return 1
  fi

  echo "${C_BOLD}Rekordy — ${domain}${C_RESET} (zone id=${zid})"
  hm_table_begin LLLRRL
  hm_table_row ID TYP NAZWA TTL PRIO "WARTOŚĆ"
  local sql type_clause=""
  if [[ -n "${typ_filter}" ]]; then
    type_clause=" AND type=$(hm_sql_quote "${typ_filter}")"
  fi
  sql="SELECT id, type, name, ttl, IFNULL(prio,0), content
       FROM records WHERE domain_id=${zid}${type_clause}
       ORDER BY type, name, id;"
  local id type name ttl prio content
  while IFS=$'\t' read -r id type name ttl prio content; do
    [[ -n "${id}" ]] || continue
    hm_table_row "${id}" "${type}" "${name}" "${ttl}" "${prio}" "${content}"
  done < <(hm_mysql_exec cyberpanel -N -e "${sql}" 2>/dev/null || true)
  hm_table_print
}

hm_dns_export_zone() {
  local domain="${1:-}"
  [[ -n "${domain}" ]] || { hm_err "Brak domeny"; return 1; }
  hm_dns_cp_db_ok || { hm_err "Brak tabel PowerDNS"; return 1; }
  local zid
  zid="$(hm_dns_zone_id "${domain}")" || { hm_err "Brak strefy: ${domain}"; return 1; }

  echo "; BIND dump — ${domain} (hmtools dns export)"
  echo "\$ORIGIN ${domain}."
  echo "\$TTL 3600"
  local id type name ttl prio content owner
  while IFS=$'\t' read -r id type name ttl prio content; do
    [[ -n "${id}" ]] || continue
    owner="${name%.}"
    case "${type}" in
      SOA)
        printf '%s.\t%s\tIN\tSOA\t%s\n' "${owner}" "${ttl}" "${content}"
        ;;
      MX)
        printf '%s.\t%s\tIN\tMX\t%s %s\n' "${owner}" "${ttl}" "${prio}" "${content}"
        ;;
      TXT)
        # dziel długie TXT na quoted chunks
        local chunks c first=1
        mapfile -t chunks < <(hm_dns_split_txt "${content}")
        printf '%s.\t%s\tIN\tTXT\t' "${owner}" "${ttl}"
        for c in "${chunks[@]}"; do
          [[ "${first}" -eq 1 ]] || printf ' '
          printf '"%s"' "${c}"
          first=0
        done
        printf '\n'
        ;;
      SRV)
        printf '%s.\t%s\tIN\tSRV\t%s %s\n' "${owner}" "${ttl}" "${prio}" "${content}"
        ;;
      *)
        printf '%s.\t%s\tIN\t%s\t%s\n' "${owner}" "${ttl}" "${type}" "${content}"
        ;;
    esac
  done < <(hm_mysql_exec cyberpanel -N -e \
    "SELECT id, type, name, ttl, IFNULL(prio,0), content
     FROM records WHERE domain_id=${zid} ORDER BY type, name, id;" 2>/dev/null || true)
}

# --- add / edit / delete ---------------------------------------------------

hm_dns_add_record() {
  local domain="${HM_SITE_DOMAIN:-}"
  local typ_raw="${1:-}" name_raw="${2:-}"
  shift 2 || true
  local value="" ttl=3600 prio=0 yes=0 a
  # wartość = tokeny aż do znanych flag / `--` (TXT ze spacjami i -all w SPF)
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --) shift || true; break ;;
      --ttl|--prio|--priority|--yes|-y|help|-h|--help) break ;;
      *) value="${value}${value:+ }$1"; shift || true ;;
    esac
  done
  while [[ $# -gt 0 ]]; do
    a="$1"; shift || true
    case "${a}" in
      --ttl) ttl="${1:-}"; shift || true ;;
      --prio|--priority) prio="${1:-}"; shift || true ;;
      --yes|-y) yes=1 ;;
      help|-h|--help)
        echo "Użycie: dns add <TYP> <nazwa> <wartość> [--ttl N] [--prio N] [--yes]"
        return 0
        ;;
      -*) hm_err "Nieznana flaga: ${a}"; return 1 ;;
      *) value="${value}${value:+ }${a}" ;;
    esac
  done
  # zdejmij zewnętrzne cudzysłowy z wartości (REPL / hmtools -c)
  case "${value}" in
    \"*\") value="${value#\"}"; value="${value%\"}" ;;
    \'*\') value="${value#\'}"; value="${value%\'}" ;;
  esac

  [[ -n "${domain}" ]] || { hm_err "Kontekst: use <domena> → dns add …"; return 1; }
  [[ -n "${typ_raw}" && -n "${name_raw}" && -n "${value}" ]] || {
    hm_err "Użycie: dns add <TYP> <nazwa> <wartość> [--ttl N] [--prio N]"
    return 1
  }
  [[ "${ttl}" =~ ^[0-9]+$ && "${ttl}" -ge 60 ]] || { hm_err "TTL musi być ≥60"; return 1; }
  [[ "${prio}" =~ ^[0-9]+$ ]] || { hm_err "prio musi być liczbą"; return 1; }

  local typ name
  typ="$(hm_dns_normalize_type "${typ_raw}")" || { hm_err "Nieobsługiwany typ: ${typ_raw}"; return 1; }
  hm_dns_validate_value "${typ}" "${value}" "${prio}" || return 1
  name="$(hm_dns_normalize_name "${name_raw}" "${domain}")" || return 1

  if [[ "${typ}" == "TXT" && ${#value} -gt 255 ]]; then
    hm_info "TXT >255 znaków — PowerDNS/CLI zwykle dzieli automatycznie; eksport BIND używa chunków."
  fi

  hm_dns_require_cyberpanel_cli || return 1
  if hm_dns_cp_db_ok; then
    hm_dns_zone_id "${domain}" >/dev/null || {
      hm_err "Brak lokalnej strefy dla ${domain}."
      return 1
    }
  fi

  local -a plan=(
    "cyberpanel createDNSRecord — ${typ} ${name} → ${value:0:60}"
    "TTL=${ttl} prio=${prio} (SOA serial ↑)"
  )
  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "dns add — ${domain}" "" --yes "${plan[@]}" || return 1
  else
    hm_confirm_plan "dns add — ${domain}" "" "${plan[@]}" || return 1
  fi

  if ! hm_run cyberpanel createDNSRecord \
    --domainName "${domain}" \
    --name "${name}" \
    --recordType "${typ}" \
    --value "${value}" \
    --priority "${prio}" \
    --ttl "${ttl}"; then
    hm_err "cyberpanel createDNSRecord nieudane."
    return 1
  fi
  hm_ok "Dodano ${typ} ${name}"
  hm_file_log INFO "dns add domain=${domain} type=${typ} name=${name} ttl=${ttl}"
}

hm_dns_edit_record() {
  local domain="${HM_SITE_DOMAIN:-}" rid="${1:-}"
  shift || true
  local value="" ttl="" prio="" yes=0 a set_value=0 set_ttl=0 set_prio=0
  while [[ $# -gt 0 ]]; do
    a="$1"; shift || true
    case "${a}" in
      --value|--content) value="${1:-}"; set_value=1; shift || true ;;
      --ttl) ttl="${1:-}"; set_ttl=1; shift || true ;;
      --prio|--priority) prio="${1:-}"; set_prio=1; shift || true ;;
      --yes|-y) yes=1 ;;
      help|-h|--help)
        echo "Użycie: dns edit <id> --value V [--ttl N] [--prio N] [--yes]"
        return 0
        ;;
      -*) hm_err "Nieznana flaga: ${a}"; return 1 ;;
      *) hm_err "Za dużo argumentów: ${a}"; return 1 ;;
    esac
  done

  [[ -n "${domain}" ]] || { hm_err "Kontekst: use <domena>"; return 1; }
  [[ "${rid}" =~ ^[0-9]+$ ]] || { hm_err "Użycie: dns edit <id> --value …"; return 1; }
  [[ "${set_value}" -eq 1 || "${set_ttl}" -eq 1 || "${set_prio}" -eq 1 ]] || {
    hm_err "Podaj --value i/lub --ttl / --prio"
    return 1
  }

  hm_dns_require_cyberpanel_cli || return 1
  hm_dns_cp_db_ok || { hm_err "Brak tabel PowerDNS — edycja wymaga odczytu rekordu."; return 1; }

  local row id name type content old_ttl old_prio
  row="$(hm_dns_record_row "${domain}" "${rid}")" || true
  [[ -n "${row}" ]] || { hm_err "Brak rekordu id=${rid} w strefie ${domain}"; return 1; }
  IFS=$'\t' read -r id name type content old_ttl old_prio <<< "${row}"

  [[ "${set_value}" -eq 1 ]] || value="${content}"
  [[ "${set_ttl}" -eq 1 ]] || ttl="${old_ttl}"
  [[ "${set_prio}" -eq 1 ]] || prio="${old_prio}"
  [[ "${ttl}" =~ ^[0-9]+$ && "${ttl}" -ge 60 ]] || { hm_err "TTL musi być ≥60"; return 1; }
  [[ "${prio}" =~ ^[0-9]+$ ]] || { hm_err "prio musi być liczbą"; return 1; }

  case "${type}" in
    SOA)
      hm_err "Edycja SOA zablokowana (użyj panelu / nie ręcznie)."
      return 1
      ;;
    NS)
      hm_err "Edycja NS wymaga delete+add z --force na delete."
      return 1
      ;;
  esac

  hm_dns_validate_value "${type}" "${value}" "${prio}" || return 1

  local -a plan=(
    "Pokaż: ${type} ${name} = ${content} (ttl=${old_ttl} prio=${old_prio})"
    "cyberpanel deleteDNSRecord --recordID ${id}"
    "cyberpanel createDNSRecord — ${type} ${name} → ${value:0:60} (ttl=${ttl} prio=${prio})"
    "Przy błędzie create: próba rollback (odtworzenie starego rekordu)"
  )
  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "dns edit ${id} — ${domain}" "Edycja = delete+create." --yes "${plan[@]}" || return 1
  else
    hm_confirm_plan "dns edit ${id} — ${domain}" "Edycja = delete+create." "${plan[@]}" || return 1
  fi

  if ! hm_run cyberpanel deleteDNSRecord --recordID "${id}"; then
    hm_err "deleteDNSRecord nieudane — nic nie zmieniono dalej."
    return 1
  fi

  if ! hm_run cyberpanel createDNSRecord \
    --domainName "${domain}" \
    --name "${name}" \
    --recordType "${type}" \
    --value "${value}" \
    --priority "${prio}" \
    --ttl "${ttl}"; then
    hm_err "createDNSRecord nieudane — próbuję rollback starego rekordu."
    if hm_run cyberpanel createDNSRecord \
      --domainName "${domain}" \
      --name "${name}" \
      --recordType "${type}" \
      --value "${content}" \
      --priority "${old_prio}" \
      --ttl "${old_ttl}"; then
      hm_warn "Rollback OK — przywrócono poprzedni rekord (nowe id)."
    else
      hm_err "Rollback NIEUDANY — sprawdź dns list i ewentualnie dodaj ręcznie."
    fi
    return 1
  fi
  hm_ok "Zaktualizowano rekord (było id=${id})"
  hm_file_log INFO "dns edit domain=${domain} old_id=${id} type=${type} name=${name}"
}

hm_dns_delete_record() {
  local domain="${HM_SITE_DOMAIN:-}" rid="${1:-}"
  shift || true
  local force=0 yes=0 a
  while [[ $# -gt 0 ]]; do
    a="$1"; shift || true
    case "${a}" in
      --force) force=1 ;;
      --yes|-y) yes=1 ;;
      help|-h|--help)
        echo "Użycie: dns delete <id> [--force] [--yes]"
        return 0
        ;;
      -*) hm_err "Nieznana flaga: ${a}"; return 1 ;;
      *) hm_err "Za dużo argumentów"; return 1 ;;
    esac
  done

  [[ -n "${domain}" ]] || { hm_err "Kontekst: use <domena>"; return 1; }
  [[ "${rid}" =~ ^[0-9]+$ ]] || { hm_err "Użycie: dns delete <id>"; return 1; }

  hm_dns_require_cyberpanel_cli || return 1
  hm_dns_cp_db_ok || { hm_err "Brak tabel PowerDNS — nie zweryfikuję rekordu przed delete."; return 1; }

  local row id name type content old_ttl old_prio
  row="$(hm_dns_record_row "${domain}" "${rid}")" || true
  [[ -n "${row}" ]] || { hm_err "Brak rekordu id=${rid} w strefie ${domain}"; return 1; }
  IFS=$'\t' read -r id name type content old_ttl old_prio <<< "${row}"

  echo
  echo "  Rekord do usunięcia:"
  printf '  id=%s  %s  %s  ttl=%s prio=%s\n  content: %s\n' \
    "${id}" "${type}" "${name}" "${old_ttl}" "${old_prio}" "${content}"

  if [[ "${type}" == "SOA" || "${type}" == "NS" ]]; then
    if [[ "${force}" -ne 1 ]]; then
      hm_err "Usunięcie ${type} zablokowane bez --force (ryzyko rozbicia strefy)."
      return 1
    fi
  fi

  local -a plan=("cyberpanel deleteDNSRecord --recordID ${id}")
  if [[ "${type}" == "SOA" || "${type}" == "NS" ]]; then
    if [[ "${yes}" -eq 1 ]]; then
      hm_confirm_plan_critical "${domain}" "dns delete ${type} id=${id}" \
        "Usunięcie ${type} może rozbić strefę." --yes "${plan[@]}" || return 1
    else
      hm_confirm_plan_critical "${domain}" "dns delete ${type} id=${id}" \
        "Usunięcie ${type} może rozbić strefę." "${plan[@]}" || return 1
    fi
  else
    if [[ "${yes}" -eq 1 ]]; then
      hm_confirm_plan "dns delete id=${id} — ${domain}" "Nieodwracalne (poza ręcznym add)." --yes "${plan[@]}" || return 1
    else
      hm_confirm_plan "dns delete id=${id} — ${domain}" "Nieodwracalne (poza ręcznym add)." "${plan[@]}" || return 1
    fi
  fi

  if ! hm_run cyberpanel deleteDNSRecord --recordID "${id}"; then
    hm_err "deleteDNSRecord nieudane."
    return 1
  fi
  hm_ok "Usunięto id=${id} (${type} ${name})"
  hm_file_log INFO "dns delete domain=${domain} id=${id} type=${type} name=${name}"
}

# --- entry -----------------------------------------------------------------

cmd_dns() {
  local sub="${1:-}"
  shift || true

  case "${sub}" in
    check|diag|diagnose)
      hm_dns_check_cmd "$@"
      return $?
      ;;
    help|-h|--help)
      hm_help_topic dns
      return 0
      ;;
  esac

  if [[ -n "${HM_SITE_DOMAIN:-}" ]]; then
    case "${sub}" in
      ""|list|ls|status|show)
        hm_dns_list_records "${HM_SITE_DOMAIN}" "$@"
        ;;
      add|create|new)
        hm_dns_add_record "$@"
        ;;
      edit|update|set)
        hm_dns_edit_record "$@"
        ;;
      delete|del|rm|remove)
        hm_dns_delete_record "$@"
        ;;
      export|dump|bind)
        hm_dns_export_zone "${HM_SITE_DOMAIN}"
        ;;
      *)
        hm_err "Nieznane: dns ${sub}.  help: dns help"
        return 1
        ;;
    esac
    return $?
  fi

  case "${sub}" in
    ""|list|ls|zones|status)
      hm_dns_zones_overview
      ;;
    *)
      hm_err "Nieznane: dns ${sub}.  Globalnie: dns | dns check <domena>.  W use: list/add/edit/delete/export."
      return 1
      ;;
  esac
}

_hm_cmd_register dns cmd_dns 0
_hm_cmd_register_site dns cmd_dns
