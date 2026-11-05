#!/usr/bin/env bash
# mail forward / catch-all — e_forwardings / e_catchall (brak CLI CyberPanel)

hm_mail_forward_tables_ok() {
  local n
  n="$(hm_mysql_exec cyberpanel -N -e \
    "SELECT COUNT(*) FROM information_schema.tables
     WHERE table_schema='cyberpanel' AND table_name='e_forwardings';" 2>/dev/null | tr -d '[:space:]')"
  [[ "${n}" == "1" ]]
}

hm_mail_catchall_table_ok() {
  local n
  n="$(hm_mysql_exec cyberpanel -N -e \
    "SELECT COUNT(*) FROM information_schema.tables
     WHERE table_schema='cyberpanel' AND table_name='e_catchall';" 2>/dev/null | tr -d '[:space:]')"
  [[ "${n}" == "1" ]]
}

hm_mail_postfix_reload() {
  if hm_have_cmd systemctl && systemctl is-active postfix >/dev/null 2>&1; then
    systemctl reload postfix 2>/dev/null || systemctl restart postfix 2>/dev/null || true
    return 0
  fi
  if hm_have_cmd postfix; then
    postfix reload 2>/dev/null || true
  fi
}

# Czy source należy do domeny (exact): user@domain lub @domain
hm_mail_source_in_domain() {
  local source="$1" domain="$2"
  local dom_l src_l
  dom_l="$(printf '%s' "${domain}" | tr '[:upper:]' '[:lower:]')"
  src_l="$(printf '%s' "${source}" | tr '[:upper:]' '[:lower:]')"
  if [[ "${src_l}" == "@${dom_l}" ]]; then
    return 0
  fi
  [[ "${src_l}" == *"@${dom_l}" && "${src_l#*@}" == "${dom_l}" ]]
}

hm_mail_forward_list() {
  local domain="${1:-${HM_SITE_DOMAIN:-}}"
  [[ -n "${domain}" ]] || return 0
  if ! hm_mail_forward_tables_ok; then
    echo "  (brak e_forwardings)"
    return 0
  fi
  local dq any=0
  dq="$(hm_sql_quote "${domain}")"
  # exact: destination/source kończy się na @domain lub source=@domain
  while IFS=$'\t' read -r src dst; do
    [[ -n "${src}" ]] || continue
    hm_mail_source_in_domain "${src}" "${domain}" || continue
    echo "  ${src}  →  ${dst}"
    any=1
  done < <(hm_mysql_exec cyberpanel -N -e "
SELECT source, destination FROM e_forwardings
WHERE source = CONCAT('@', ${dq})
   OR SUBSTRING_INDEX(source, '@', -1) = ${dq}
ORDER BY source, destination;
" 2>/dev/null || true)
  [[ "${any}" -eq 1 ]] || echo "  (brak)"
}

hm_mail_forward_add() {
  local domain="${HM_SITE_DOMAIN:-}"
  local source="${1:-}" dest="${2:-}" yes=0
  shift 2 2>/dev/null || true
  [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && yes=1

  [[ -n "${domain}" ]] || { hm_err "Kontekst: use <domena>"; return 1; }
  [[ -n "${source}" && -n "${dest}" ]] || {
    hm_err "Użycie: mail forward add <source@domena|local> <dest@…>"
    return 1
  }
  if ! hm_mail_forward_tables_ok; then
    hm_err "Brak tabeli e_forwardings."
    return 1
  fi

  # source: local → local@domain
  if [[ "${source}" != *@* ]]; then
    source="$(hm_mail_email_addr "${source}" "${domain}")"
  fi
  hm_mail_source_in_domain "${source}" "${domain}" || {
    hm_err "Źródło ${source} nie należy do ${domain} (exact)."
    return 1
  }
  [[ "${dest}" == *@* ]] || { hm_err "Cel musi być pełnym adresem e-mail."; return 1; }

  local sq dq
  sq="$(hm_sql_quote "${source}")"
  local destq
  destq="$(hm_sql_quote "${dest}")"
  local exists
  exists="$(hm_mysql_exec cyberpanel -N -e \
    "SELECT COUNT(*) FROM e_forwardings WHERE source=${sq} AND destination=${destq};" \
    2>/dev/null | tr -d '[:space:]')"
  if [[ "${exists}" == "1" ]]; then
    hm_info "Przekierowanie już istnieje."
    return 0
  fi

  local -a plan=(
    "INSERT e_forwardings: ${source} → ${dest}"
    "postfix reload"
  )
  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "mail forward add — ${domain}" "" --yes "${plan[@]}" || return 1
  else
    hm_confirm_plan "mail forward add — ${domain}" "" "${plan[@]}" || return 1
  fi

  hm_mysql_exec cyberpanel -e \
    "INSERT INTO e_forwardings (source, destination) VALUES (${sq}, ${destq});" || {
    hm_err "INSERT e_forwardings nieudany."
    return 1
  }
  hm_mail_postfix_reload
  hm_ok "Dodano przekierowanie ${source} → ${dest}"
}

hm_mail_forward_remove() {
  local domain="${HM_SITE_DOMAIN:-}"
  local source="${1:-}" dest="${2:-}" yes=0
  shift 2 2>/dev/null || true
  [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && yes=1

  [[ -n "${domain}" ]] || { hm_err "Kontekst: use <domena>"; return 1; }
  [[ -n "${source}" && -n "${dest}" ]] || {
    hm_err "Użycie: mail forward remove <source> <dest>"
    return 1
  }
  if ! hm_mail_forward_tables_ok; then
    hm_err "Brak tabeli e_forwardings."
    return 1
  fi
  if [[ "${source}" != *@* ]]; then
    source="$(hm_mail_email_addr "${source}" "${domain}")"
  fi
  hm_mail_source_in_domain "${source}" "${domain}" || {
    hm_err "Źródło ${source} nie należy do ${domain}."
    return 1
  }

  local sq destq
  sq="$(hm_sql_quote "${source}")"
  destq="$(hm_sql_quote "${dest}")"

  local -a plan=("DELETE e_forwardings WHERE source=${source} AND destination=${dest} (tylko ta para)" "postfix reload")
  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "mail forward remove — ${domain}" "" --yes "${plan[@]}" || return 1
  else
    hm_confirm_plan "mail forward remove — ${domain}" "" "${plan[@]}" || return 1
  fi

  local n
  n="$(hm_mysql_exec cyberpanel -N -e \
    "SELECT COUNT(*) FROM e_forwardings WHERE source=${sq} AND destination=${destq};" \
    2>/dev/null | tr -d '[:space:]')"
  [[ "${n}" == "1" || "${n}" -gt 0 ]] || {
    hm_info "Brak takiej pary przekierowania."
    return 0
  }

  hm_mysql_exec cyberpanel -e \
    "DELETE FROM e_forwardings WHERE source=${sq} AND destination=${destq};" || {
    hm_err "DELETE nieudany."
    return 1
  }
  hm_mail_postfix_reload
  hm_ok "Usunięto przekierowanie ${source} → ${dest}"
}

hm_mail_forward_cmd() {
  local sub="${1:-list}"
  shift || true
  case "${sub}" in
    list|ls|"")
      echo "${C_BOLD}Przekierowania — ${HM_SITE_DOMAIN:-?}${C_RESET}"
      hm_mail_forward_list "${HM_SITE_DOMAIN:-}"
      ;;
    add)
      hm_mail_forward_add "$@"
      ;;
    remove|rm|del|delete)
      hm_mail_forward_remove "$@"
      ;;
    help|-h|--help)
      echo "Użycie: mail forward list|add <src> <dst>|remove <src> <dst>"
      ;;
    *)
      hm_err "Użycie: mail forward list|add|remove"
      return 1
      ;;
  esac
}

hm_mail_catchall_show() {
  local domain="${1:-${HM_SITE_DOMAIN:-}}"
  if ! hm_mail_catchall_table_ok; then
    echo "  (brak e_catchall)"
    return 0
  fi
  local dq row
  dq="$(hm_sql_quote "${domain}")"
  row="$(hm_mysql_exec cyberpanel -N -e \
    "SELECT ForwardTo FROM e_catchall WHERE domain=${dq} LIMIT 1;" 2>/dev/null | head -1)"
  if [[ -z "${row}" ]]; then
    row="$(hm_mysql_exec cyberpanel -N -e \
      "SELECT ForwardTo FROM e_catchall WHERE domainName=${dq} LIMIT 1;" 2>/dev/null | head -1)"
  fi
  if [[ -z "${row}" ]]; then
    echo "  (wyłączony / brak)"
  else
    echo "  ${domain}  →  ${row}"
  fi
}

hm_mail_catchall_cmd() {
  local domain="${HM_SITE_DOMAIN:-}"
  local action="${1:-}"
  shift || true
  [[ -n "${domain}" ]] || { hm_err "Kontekst: use <domena>"; return 1; }

  case "${action}" in
    ""|show|status)
      echo "${C_BOLD}Catch-all — ${domain}${C_RESET}"
      hm_mail_catchall_show "${domain}"
      return 0
      ;;
    off|disable|remove|rm)
      ;;
    set)
      local dest="${1:-}"
      shift || true
      [[ -n "${dest}" ]] || { hm_err "Użycie: mail catchall set <email@domena>"; return 1; }
      if [[ "${dest}" != *@* ]]; then
        dest="$(hm_mail_email_addr "${dest}" "${domain}")"
      fi
      # dest może być poza domeną (OK) lub w domenie
      hm_mail_catchall_set "${domain}" "${dest}" "$@"
      return $?
      ;;
    help|-h|--help)
      echo "Użycie: mail catchall [set <email> | off]"
      return 0
      ;;
    *)
      # mail catchall biuro@… jako skrót set?
      if [[ "${action}" == *@* || "${action}" =~ ^[A-Za-z0-9._+-]+$ ]]; then
        local dest="${action}"
        [[ "${dest}" != *@* ]] && dest="$(hm_mail_email_addr "${dest}" "${domain}")"
        hm_mail_catchall_set "${domain}" "${dest}" "$@"
        return $?
      fi
      hm_err "Użycie: mail catchall [set <email> | off]"
      return 1
      ;;
  esac

  # off
  local yes=0
  [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && yes=1
  if ! hm_mail_catchall_table_ok; then
    hm_err "Brak e_catchall."
    return 1
  fi
  local dq
  dq="$(hm_sql_quote "${domain}")"
  local -a plan=("DELETE catch-all dla ${domain}" "postfix reload")
  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "mail catchall off — ${domain}" "" --yes "${plan[@]}" || return 1
  else
    hm_confirm_plan "mail catchall off — ${domain}" "" "${plan[@]}" || return 1
  fi
  hm_mysql_exec cyberpanel -e "DELETE FROM e_catchall WHERE domain=${dq};" 2>/dev/null \
    || hm_mysql_exec cyberpanel -e "DELETE FROM e_catchall WHERE domainName=${dq};" || true
  hm_mail_postfix_reload
  hm_ok "Catch-all wyłączony dla ${domain}"
}

hm_mail_catchall_set() {
  local domain="$1" dest="$2" yes=0
  shift 2 || true
  [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && yes=1
  if ! hm_mail_catchall_table_ok; then
    hm_err "Brak e_catchall."
    return 1
  fi
  local dq destq
  dq="$(hm_sql_quote "${domain}")"
  destq="$(hm_sql_quote "${dest}")"
  local -a plan=("Ustaw catch-all ${domain} → ${dest}" "postfix reload")
  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "mail catchall set — ${domain}" "" --yes "${plan[@]}" || return 1
  else
    hm_confirm_plan "mail catchall set — ${domain}" "" "${plan[@]}" || return 1
  fi

  # upsert
  hm_mysql_exec cyberpanel -e "DELETE FROM e_catchall WHERE domain=${dq};" 2>/dev/null || true
  if ! hm_mysql_exec cyberpanel -e \
    "INSERT INTO e_catchall (domain, ForwardTo) VALUES (${dq}, ${destq});" 2>/dev/null; then
    # alternatywny schemat
    if ! hm_mysql_exec cyberpanel -e \
      "INSERT INTO e_catchall (domainName, ForwardTo) VALUES (${dq}, ${destq});" 2>/dev/null; then
      hm_err "INSERT e_catchall nieudany (sprawdź schemat kolumn)."
      return 1
    fi
  fi
  hm_mail_postfix_reload
  hm_ok "Catch-all: ${domain} → ${dest}"
}
