#!/usr/bin/env bash
# access — CyberPanel FTP (CLI + MySQL ftp_ftp)

# stdout: website id w cyberpanel (websiteFunctions_websites.id) lub pusto
hm_access_cp_website_id() {
  local domain="$1"
  local q id
  q="$(hm_sql_quote "${domain}")"
  id="$(hm_mysql_exec cyberpanel -N -e \
    "SELECT id FROM websiteFunctions_websites WHERE domain=${q} LIMIT 1;" 2>/dev/null | tr -d '[:space:]')"
  if [[ -z "${id}" ]]; then
    id="$(hm_mysql_exec cyberpanel -N -e \
      "SELECT id FROM websites_website WHERE domainName=${q} LIMIT 1;" 2>/dev/null | tr -d '[:space:]')"
  fi
  printf '%s' "${id}"
}

# Czy tabela ftp_ftp istnieje
hm_access_cp_ftp_table_ok() {
  local n
  n="$(hm_mysql_exec cyberpanel -N -e \
    "SELECT COUNT(*) FROM information_schema.TABLES
     WHERE table_schema='cyberpanel' AND table_name='ftp_ftp';" 2>/dev/null | tr -d '[:space:]')"
  [[ "${n}" == "1" ]]
}

# List: user<TAB>path (konta FTP domeny)
hm_access_cp_ftp_list() {
  local domain="$1"
  local wid q
  wid="$(hm_access_cp_website_id "${domain}")"
  [[ -n "${wid}" ]] || return 0
  hm_access_cp_ftp_table_ok || return 0
  hm_mysql_exec cyberpanel -N -e \
    "SELECT user, path FROM ftp_ftp WHERE owner_id=${wid} ORDER BY user;" 2>/dev/null \
    | awk -F'\t' 'NF{print}'
}

hm_access_cp_ftp_exists() {
  local ftp_user="$1"
  local n q
  q="$(hm_sql_quote "${ftp_user}")"
  n="$(hm_mysql_exec cyberpanel -N -e \
    "SELECT COUNT(*) FROM ftp_ftp WHERE user=${q} OR user LIKE CONCAT('%\\_', ${q});" 2>/dev/null | tr -d '[:space:]')"
  [[ "${n}" =~ ^[1-9] ]]
}

# CyberPanel często tworzy login `{owner}_{user}` — zwróć faktyczną nazwę z DB.
hm_access_cp_ftp_actual_user() {
  local domain="$1" want="$2"
  local wid q found
  wid="$(hm_access_cp_website_id "${domain}" 2>/dev/null || true)"
  q="$(hm_sql_quote "${want}")"
  if [[ -n "${wid}" ]]; then
    found="$(hm_mysql_exec cyberpanel -N -e "
SELECT user FROM ftp_ftp
WHERE owner_id=${wid} AND (user=${q} OR user LIKE CONCAT('%\\_', ${q}))
ORDER BY (user=${q}) DESC, CHAR_LENGTH(user) DESC
LIMIT 1;" 2>/dev/null | head -1 | tr -d '[:space:]')"
  fi
  if [[ -z "${found}" ]]; then
    found="$(hm_mysql_exec cyberpanel -N -e "
SELECT user FROM ftp_ftp
WHERE user=${q} OR user LIKE CONCAT('%\\_', ${q})
ORDER BY (user=${q}) DESC, CHAR_LENGTH(user) DESC
LIMIT 1;" 2>/dev/null | head -1 | tr -d '[:space:]')"
  fi
  printf '%s' "${found:-${want}}"
}

# Utwórz konto FTP — wyłącznie CLI CyberPanel (bez SQL INSERT hasła plaintext)
hm_access_cp_ftp_create() {
  local domain="$1"
  local ftp_user="$2"
  local pass="$3"
  local path="${4:-/}"

  if ! hm_have_cmd cyberpanel; then
    hm_err "Brak binary cyberpanel — nie tworzę FTP przez SQL (hasło byłoby plaintext)."
    return 1
  fi
  if hm_run cyberpanel createFTPAccount \
    --domainName "${domain}" \
    --userName "${ftp_user}" \
    --password "${pass}" \
    --path "${path}" 2>/dev/null; then
    return 0
  fi
  hm_err "cyberpanel createFTPAccount nieudane — bez fallbacku SQL (plaintext)."
  return 1
}

hm_access_cp_ftp_set_password() {
  local ftp_user="$1"
  local pass="$2"

  if ! hm_have_cmd cyberpanel; then
    hm_err "Brak binary cyberpanel — nie ustawiam hasła FTP przez SQL (plaintext)."
    return 1
  fi
  # nowsze CP: changeFTPPassword; starsze: changeFTPPass — bez UPDATE plaintext
  if cyberpanel changeFTPPassword --ftpUserName "${ftp_user}" --password "${pass}" >/dev/null 2>&1 \
    || cyberpanel changeFTPPass --ftpUserName "${ftp_user}" --password "${pass}" >/dev/null 2>&1; then
    return 0
  fi
  hm_err "cyberpanel changeFTPPassword nieudane — bez fallbacku SQL (plaintext)."
  return 1
}

hm_access_cp_ftp_delete() {
  local ftp_user="$1"

  if hm_have_cmd cyberpanel; then
    if hm_run cyberpanel deleteFTPAccount --ftpUserName "${ftp_user}" 2>/dev/null; then
      return 0
    fi
    hm_warn "cyberpanel deleteFTPAccount nieudane — próbuję SQL."
  fi
  local uq
  uq="$(hm_sql_quote "${ftp_user}")"
  hm_mysql_exec cyberpanel -e "DELETE FROM ftp_ftp WHERE user=${uq};" || return 1
}

# Konto należy do domeny?
hm_access_cp_ftp_belongs_to_domain() {
  local ftp_user="$1"
  local domain="$2"
  local wid q n
  wid="$(hm_access_cp_website_id "${domain}")"
  [[ -n "${wid}" ]] || return 1
  q="$(hm_sql_quote "${ftp_user}")"
  n="$(hm_mysql_exec cyberpanel -N -e \
    "SELECT COUNT(*) FROM ftp_ftp WHERE user=${q} AND owner_id=${wid};" 2>/dev/null | tr -d '[:space:]')"
  [[ "${n}" =~ ^[1-9] ]]
}
