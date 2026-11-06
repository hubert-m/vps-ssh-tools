#!/usr/bin/env bash
# mail accounts — skrzynki CyberPanel (createEmail / changeEmailPassword / deleteEmail)

hm_mail_require_cyberpanel_cli() {
  hm_detect_all 2>/dev/null || true
  if [[ "${PANEL:-}" != "cyberpanel" ]] && ! hm_have_cmd cyberpanel; then
    hm_err "Wymagany CyberPanel CLI (cyberpanel) — bez niego nie zarządzam skrzynkami (brak fallbacku SQL na hasła)."
    return 1
  fi
  if ! hm_have_cmd cyberpanel; then
    hm_err "Brak binary cyberpanel."
    return 1
  fi
  return 0
}

hm_mail_cp_db_ok() {
  local n
  n="$(hm_mysql_exec cyberpanel -N -e \
    "SELECT COUNT(*) FROM information_schema.tables
     WHERE table_schema='cyberpanel' AND table_name='e_users';" 2>/dev/null | tr -d '[:space:]')"
  [[ "${n}" == "1" ]]
}

hm_mail_passfile_write() {
  local pass="$1" f
  f="$(hm_mktemp .mailpass)"
  umask 077
  printf '%s' "${pass}" > "${f}"
  chmod 600 "${f}" 2>/dev/null || true
  printf '%s' "${f}"
}

# createEmail / changeEmailPassword bez hasła w argv (CyberCP python czyta plik 0600).
hm_mail_cp_create_email() {
  local domain="$1" user="$2" passfile="$3"
  local py="/usr/local/CyberCP/bin/python"
  if [[ -x "${py}" && -d /usr/local/CyberCP ]]; then
    hm_run "${py}" - "${domain}" "${user}" "${passfile}" <<'PY'
import sys
sys.path.insert(0, "/usr/local/CyberCP")
domain, user, pf = sys.argv[1], sys.argv[2], sys.argv[3]
password = open(pf, "r", encoding="utf-8").read().rstrip("\n")
ok = False
try:
    from plogical.mailUtilities import mailUtilities
    mailUtilities.createEmailAccount(domain, user, password)
    ok = True
except Exception:
    try:
        from plogical import mailUtilities as mu
        mu.mailUtilities.createEmailAccount(domain, user, password)
        ok = True
    except Exception as e:
        sys.stderr.write("mailUtilities.createEmailAccount: %s\n" % e)
        sys.exit(1)
sys.exit(0 if ok else 1)
PY
    return $?
  fi
  # Fallback CLI — hasło chwilowo w argv cyberpanel (brak CyberCP python).
  local pass
  pass="$(tr -d '\n' < "${passfile}")"
  hm_run cyberpanel createEmail \
    --domainName "${domain}" \
    --userName "${user}" \
    --password "${pass}"
}

hm_mail_cp_change_password() {
  local email="$1" passfile="$2"
  local py="/usr/local/CyberCP/bin/python"
  if [[ -x "${py}" && -d /usr/local/CyberCP ]]; then
    hm_run "${py}" - "${email}" "${passfile}" <<'PY'
import sys
sys.path.insert(0, "/usr/local/CyberCP")
email, pf = sys.argv[1], sys.argv[2]
password = open(pf, "r", encoding="utf-8").read().rstrip("\n")
try:
    from plogical.mailUtilities import mailUtilities
    mailUtilities.changeEmailPassword(email, password)
except Exception:
    try:
        from plogical.mailUtilities import mailUtilities
        mailUtilities.changeEmailPassword(email, password, 1)
    except Exception as e:
        sys.stderr.write("mailUtilities.changeEmailPassword: %s\n" % e)
        sys.exit(1)
sys.exit(0)
PY
    return $?
  fi
  local pass
  pass="$(tr -d '\n' < "${passfile}")"
  if ! hm_run cyberpanel changeEmailPassword \
    --email "${email}" \
    --password "${pass}"; then
    hm_run cyberpanel changeEmailPass \
      --email "${email}" \
      --password "${pass}"
  fi
}

hm_mail_normalize_local() {
  # biuro | biuro@example.pl → lokalna część; weryfikacja domeny
  local arg="$1" domain="$2" localpart
  if [[ "${arg}" == *@* ]]; then
    localpart="${arg%%@*}"
    local d="${arg#*@}"
    d="$(printf '%s' "${d}" | tr '[:upper:]' '[:lower:]')"
    local dom_l
    dom_l="$(printf '%s' "${domain}" | tr '[:upper:]' '[:lower:]')"
    if [[ "${d}" != "${dom_l}" ]]; then
      hm_err "Adres ${arg} nie należy do domeny ${domain} (exact match)."
      return 1
    fi
  else
    localpart="${arg}"
  fi
  [[ -n "${localpart}" && "${localpart}" =~ ^[A-Za-z0-9._+-]+$ ]] || {
    hm_err "Nieprawidłowa lokalna część: ${localpart}"
    return 1
  }
  printf '%s' "${localpart}"
}

hm_mail_email_addr() {
  local localpart="$1" domain="$2"
  printf '%s@%s' "${localpart}" "${domain}"
}

hm_mail_maildir_path() {
  local domain="$1" localpart="$2"
  local mailcol path
  # kolumna mail w e_users (ścieżka względna domain/user) lub domyślna
  if hm_mail_cp_db_ok; then
    path="$(hm_mysql_exec cyberpanel -N -e \
      "SELECT mail FROM e_users WHERE email=$(hm_sql_quote "$(hm_mail_email_addr "${localpart}" "${domain}")") LIMIT 1;" \
      2>/dev/null | head -1 | tr -d '[:space:]')"
    if [[ -n "${path}" ]]; then
      if [[ "${path}" == /* ]]; then
        printf '%s' "${path}"
        return 0
      fi
      printf '/home/vmail/%s' "${path}"
      return 0
    fi
  fi
  printf '/home/vmail/%s/%s' "${domain}" "${localpart}"
}

hm_mail_du_kb() {
  local p="$1"
  [[ -d "${p}" ]] || { printf '0'; return 0; }
  du -sk "${p}" 2>/dev/null | awk '{print $1}'
}

hm_mail_list_domain_emails() {
  # stdout TSV: email|quota|mailpath
  local domain="$1"
  local dq
  dq="$(hm_sql_quote "${domain}")"
  if ! hm_mail_cp_db_ok; then
    return 1
  fi
  # exact match domeny: email LIKE '%@domain' z końcem = @domain
  # DiskQuota bywa w różnych wersjach CP — błąd kolumny → sam email+mail
  local rows
  rows="$(hm_mysql_exec cyberpanel -N -e "
SELECT email, IFNULL(DiskQuota,0), IFNULL(mail,'')
FROM e_users
WHERE SUBSTRING_INDEX(email, '@', -1) = ${dq}
ORDER BY email;
" 2>/dev/null || true)"
  if [[ -z "${rows}" ]]; then
    rows="$(hm_mysql_exec cyberpanel -N -e "
SELECT email, 0, IFNULL(mail,'')
FROM e_users
WHERE SUBSTRING_INDEX(email, '@', -1) = ${dq}
ORDER BY email;
" 2>/dev/null || true)"
  fi
  printf '%s\n' "${rows}" | while IFS=$'\t' read -r email quota mailp; do
    [[ -n "${email}" ]] || continue
    printf '%s\t%s\t%s\n' "${email}" "${quota:-0}" "${mailp}"
  done
}

hm_mail_account_belongs() {
  local email="$1" domain="$2"
  local d
  d="$(printf '%s' "${email#*@}" | tr '[:upper:]' '[:lower:]')"
  local dom_l
  dom_l="$(printf '%s' "${domain}" | tr '[:upper:]' '[:lower:]')"
  [[ "${d}" == "${dom_l}" ]]
}

hm_mail_accounts_list() {
  local domain="${1:-${HM_SITE_DOMAIN:-}}"
  [[ -n "${domain}" ]] || { hm_err "Podaj domenę lub: use <domena>"; return 1; }
  hm_is_valid_domain "${domain}" || { hm_err "Nieprawidłowa domena: ${domain}"; return 1; }

  if ! hm_mail_cp_db_ok; then
    hm_warn "Brak tabeli cyberpanel.e_users — czy poczta CyberPanel jest zainstalowana?"
    return 0
  fi

  echo "${C_BOLD}Skrzynki — ${domain}${C_RESET}"
  local any=0 email quota mailp localpart path kb
  printf '  %-36s %10s %10s  %s\n' "EMAIL" "QUOTA" "SIZE" "MAILDIR"
  while IFS=$'\t' read -r email quota mailp; do
    [[ -n "${email}" ]] || continue
    any=1
    localpart="${email%%@*}"
    path="$(hm_mail_maildir_path "${domain}" "${localpart}")"
    kb="$(hm_mail_du_kb "${path}")"
    printf '  %-36s %10s %10s  %s\n' \
      "${email}" "${quota}" "$(hm_human_size "$((kb * 1024))" 2>/dev/null || echo "${kb}K")" "${path}"
  done < <(hm_mail_list_domain_emails "${domain}")

  if [[ "${any}" -eq 0 ]]; then
    echo "  (brak skrzynek)"
  fi

  echo
  echo "${C_BOLD}Przekierowania${C_RESET}"
  if declare -F hm_mail_forward_list >/dev/null 2>&1; then
    hm_mail_forward_list "${domain}"
  fi
  echo
  echo "${C_BOLD}Catch-all${C_RESET}"
  if declare -F hm_mail_catchall_show >/dev/null 2>&1; then
    hm_mail_catchall_show "${domain}"
  fi
}

hm_mail_accounts_global() {
  if ! hm_mail_cp_db_ok; then
    hm_warn "Brak cyberpanel.e_users — diagnostyka: mail queue | mail check <d>"
    hm_help_topic mail
    return 0
  fi
  echo "${C_BOLD}Domeny pocztowe (CyberPanel)${C_RESET}"
  local domains
  domains="$(hm_mysql_exec cyberpanel -N -e "
SELECT DISTINCT SUBSTRING_INDEX(email, '@', -1) AS d
FROM e_users
ORDER BY d;
" 2>/dev/null || true)"
  if [[ -z "${domains}" ]]; then
    # e_domains
    domains="$(hm_mysql_exec cyberpanel -N -e "SELECT domainName FROM e_domains ORDER BY domainName;" 2>/dev/null || true)"
  fi
  if [[ -z "${domains}" ]]; then
    echo "  (brak)"
  else
    printf '%s\n' "${domains}" | sed 's/^/  /'
  fi
  echo
  echo "${C_BOLD}Top skrzynek wg rozmiaru Maildir${C_RESET}"
  local email localpart domain path kb
  local -a rows=()
  while IFS=$'\t' read -r email _ mailp; do
    [[ -n "${email}" ]] || continue
    domain="${email#*@}"
    localpart="${email%%@*}"
    path="$(hm_mail_maildir_path "${domain}" "${localpart}")"
    kb="$(hm_mail_du_kb "${path}")"
    rows+=("${kb}|${email}|${path}")
  done < <(hm_mysql_exec cyberpanel -N -e "SELECT email, 0, COALESCE(mail,'') FROM e_users;" 2>/dev/null || true)

  if [[ "${#rows[@]}" -eq 0 ]]; then
    echo "  (brak)"
    return 0
  fi
  local line
  printf '%s\n' "${rows[@]}" | sort -t'|' -k1,1nr | head -20 | while IFS='|' read -r kb email path; do
    printf '  %10s  %-40s  %s\n' "$(hm_human_size "$((kb * 1024))" 2>/dev/null || echo "${kb}K")" "${email}" "${path}"
  done
}

hm_mail_account_add() {
  local domain="${HM_SITE_DOMAIN:-}" local_arg="${1:-}" yes=0
  shift || true
  local a
  while [[ $# -gt 0 ]]; do
    a="$1"; shift || true
    case "${a}" in
      --password-gen|--gen-password) ;;
      --yes|-y) yes=1 ;;
      help|-h|--help)
        echo "Użycie: mail add <local|user@domena> [--password-gen] [--yes]"
        return 0
        ;;
      -*) hm_err "Nieznana flaga: ${a}"; return 1 ;;
      *) hm_err "Za dużo argumentów"; return 1 ;;
    esac
  done
  [[ -n "${domain}" ]] || { hm_err "Kontekst: use <domena> → mail add …"; return 1; }
  [[ -n "${local_arg}" ]] || { hm_err "Użycie: mail add <local>"; return 1; }
  hm_mail_require_cyberpanel_cli || return 1

  local localpart email pass
  localpart="$(hm_mail_normalize_local "${local_arg}" "${domain}")" || return 1
  email="$(hm_mail_email_addr "${localpart}" "${domain}")"

  if hm_mail_cp_db_ok; then
    local exists
    exists="$(hm_mysql_exec cyberpanel -N -e \
      "SELECT COUNT(*) FROM e_users WHERE email=$(hm_sql_quote "${email}");" 2>/dev/null | tr -d '[:space:]')"
    if [[ "${exists}" == "1" ]]; then
      hm_err "Skrzynka już istnieje: ${email}"
      return 1
    fi
  fi

  pass="$(hm_gen_password)"
  [[ ${#pass} -ge 12 ]] || { hm_err "Nie udało się wygenerować hasła."; return 1; }

  local -a plan=(
    "cyberpanel createEmail — ${email}"
    "Hasło wygenerowane (pokazane raz, nie w applog)"
  )
  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "mail add — ${email}" "Nowe konto pocztowe." --yes "${plan[@]}" || return 1
  else
    hm_confirm_plan "mail add — ${email}" "Nowe konto pocztowe." "${plan[@]}" || return 1
  fi

  local passfile
  passfile="$(hm_mail_passfile_write "${pass}")"
  if ! hm_mail_cp_create_email "${domain}" "${localpart}" "${passfile}"; then
    rm -f -- "${passfile}"
    hm_err "cyberpanel createEmail nieudane."
    return 1
  fi
  rm -f -- "${passfile}"

  hm_ok "Utworzono ${email}"
  hm_print_secret "" \
    "  ${C_BOLD}Email:${C_RESET} ${email}" \
    "  ${C_BOLD}Hasło:${C_RESET} ${pass}" \
    "  ${C_DIM}Zapisz hasło — nie będzie ponownie pokazane.${C_RESET}"
  if hm_have_cmd doveadm; then
    hm_info "Weryfikacja: doveadm auth test ${email}  (wpisz hasło)"
  fi
}

hm_mail_account_passwd() {
  local domain="${HM_SITE_DOMAIN:-}" local_arg="${1:-}" yes=0
  shift || true
  [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && yes=1
  [[ -n "${domain}" ]] || { hm_err "Kontekst: use <domena>"; return 1; }
  [[ -n "${local_arg}" ]] || { hm_err "Użycie: mail passwd <local>"; return 1; }
  hm_mail_require_cyberpanel_cli || return 1

  local localpart email pass
  localpart="$(hm_mail_normalize_local "${local_arg}" "${domain}")" || return 1
  email="$(hm_mail_email_addr "${localpart}" "${domain}")"

  if hm_mail_cp_db_ok; then
    local exists
    exists="$(hm_mysql_exec cyberpanel -N -e \
      "SELECT COUNT(*) FROM e_users WHERE email=$(hm_sql_quote "${email}");" 2>/dev/null | tr -d '[:space:]')"
    [[ "${exists}" == "1" ]] || { hm_err "Brak skrzynki: ${email}"; return 1; }
  fi

  pass="$(hm_gen_password)"
  [[ ${#pass} -ge 12 ]] || { hm_err "Nie udało się wygenerować hasła."; return 1; }

  local -a plan=("cyberpanel changeEmailPassword — ${email}")
  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "mail passwd — ${email}" "Nowe hasło zostanie wypisane raz." --yes "${plan[@]}" || return 1
  else
    hm_confirm_plan "mail passwd — ${email}" "Nowe hasło zostanie wypisane raz." "${plan[@]}" || return 1
  fi

  local passfile
  passfile="$(hm_mail_passfile_write "${pass}")"
  if ! hm_mail_cp_change_password "${email}" "${passfile}"; then
    rm -f -- "${passfile}"
    hm_err "cyberpanel changeEmailPassword nieudane."
    return 1
  fi
  rm -f -- "${passfile}"

  hm_ok "Hasło zmienione: ${email}"
  hm_print_secret "" \
    "  ${C_BOLD}Email:${C_RESET} ${email}" \
    "  ${C_BOLD}Hasło:${C_RESET} ${pass}"
}

hm_mail_account_delete() {
  local domain="${HM_SITE_DOMAIN:-}" local_arg="${1:-}"
  shift || true
  local keep=1 purge=0 yes=0 a
  while [[ $# -gt 0 ]]; do
    a="$1"; shift || true
    case "${a}" in
      --keep-maildir) keep=1; purge=0 ;;
      --purge) purge=1; keep=0 ;;
      --yes|-y) yes=1 ;;
      help|-h|--help)
        echo "Użycie: mail delete <local> [--keep-maildir|--purge] [--yes]"
        return 0
        ;;
      -*) hm_err "Nieznana flaga: ${a}"; return 1 ;;
      *) hm_err "Za dużo argumentów"; return 1 ;;
    esac
  done
  [[ -n "${domain}" ]] || { hm_err "Kontekst: use <domena>"; return 1; }
  [[ -n "${local_arg}" ]] || { hm_err "Użycie: mail delete <local>"; return 1; }
  hm_mail_require_cyberpanel_cli || return 1

  local localpart email path
  localpart="$(hm_mail_normalize_local "${local_arg}" "${domain}")" || return 1
  email="$(hm_mail_email_addr "${localpart}" "${domain}")"
  path="$(hm_mail_maildir_path "${domain}" "${localpart}")"

  if hm_mail_cp_db_ok; then
    local exists
    exists="$(hm_mysql_exec cyberpanel -N -e \
      "SELECT COUNT(*) FROM e_users WHERE email=$(hm_sql_quote "${email}");" 2>/dev/null | tr -d '[:space:]')"
    [[ "${exists}" == "1" ]] || { hm_err "Brak skrzynki: ${email}"; return 1; }
  fi

  local trash stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  trash="/home/vmail/.hmtools-trash/${stamp}-${localpart}@${domain}"

  local -a plan=("cyberpanel deleteEmail — ${email}")
  if [[ "${purge}" -eq 1 ]]; then
    plan+=("PURGE Maildir ${path} (bezpowrotne)")
  else
    plan+=("Archiwizacja Maildir → ${trash} (domyślnie; --purge kasuje)")
  fi

  if [[ "${purge}" -eq 1 ]]; then
    if [[ "${yes}" -eq 1 ]]; then
      hm_confirm_plan_critical "${domain}" "mail delete --purge — ${email}" \
        "Usunięcie skrzynki i Maildir." --yes "${plan[@]}" || return 1
    else
      hm_confirm_plan_critical "${domain}" "mail delete --purge — ${email}" \
        "Usunięcie skrzynki i Maildir." "${plan[@]}" || return 1
    fi
  else
    if [[ "${yes}" -eq 1 ]]; then
      hm_confirm_plan "mail delete — ${email}" \
        "Konto usuwane z CP; Maildir archiwizowany." --yes "${plan[@]}" || return 1
    else
      hm_confirm_plan "mail delete — ${email}" \
        "Konto usuwane z CP; Maildir archiwizowany." "${plan[@]}" || return 1
    fi
  fi

  # najpierw archiwum / purge plików, potem deleteEmail (żeby znać ścieżkę)
  if [[ -d "${path}" ]]; then
    if [[ "${purge}" -eq 1 ]]; then
      rm -rf -- "${path}" || hm_warn "Nie usunięto ${path}"
    else
      mkdir -p "$(dirname "${trash}")"
      mv -- "${path}" "${trash}" 2>/dev/null || {
        hm_warn "mv Maildir nieudany — kopiuję."
        mkdir -p "${trash}"
        cp -a "${path}/." "${trash}/" 2>/dev/null || true
      }
      hm_info "Maildir → ${trash}"
    fi
  fi

  if ! hm_run cyberpanel deleteEmail --email "${email}" 2>/dev/null \
    && ! hm_run cyberpanel deleteEmail --domainName "${domain}" --userName "${localpart}" 2>/dev/null; then
    hm_err "cyberpanel deleteEmail nieudane."
    return 1
  fi
  hm_ok "Usunięto konto ${email}"
}
