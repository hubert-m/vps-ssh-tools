#!/usr/bin/env bash
# Bazy kreatora serwisu: MySQL/MariaDB, PostgreSQL, Redis, SQLite.
# Hasła idą do shared/.env. Manifest i argv procesów ich nie zawierają.

if [[ -n "${HMTOOLS_SITE_DB_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_SITE_DB_LOADED=1

if ! declare -F hm_site_state_dir >/dev/null 2>&1; then
  hm_site_state_dir() {
    local base="${HM_SITE_STATE_DIR:-}"
    if [[ -z "${base}" && "${HMTOOLS_TEST:-}" == "1" ]]; then
      base="${TMPDIR:-/tmp}/hmtools-site-state"
    fi
    [[ -n "${base}" ]] || base="/var/lib/hmtools/sites"
    printf '%s/%s' "${base}" "${1:-}"
  }
fi
if ! declare -F hm_site_manifest_path >/dev/null 2>&1; then
  hm_site_manifest_path() {
    printf '%s/%s.json' "${HM_SITE_MANIFEST_DIR:-/etc/hmtools/sites}" "${1:-}"
  }
fi
if ! declare -F hm_site_write_nofollow >/dev/null 2>&1; then
  hm_site_path_has_symlink() {
    local path="$1" cur line
    [[ -n "${path}" ]] || return 1
    cur="${path}"
    while [[ -n "${cur}" && "${cur}" != "/" ]]; do
      if [[ -e "${cur}" || -L "${cur}" ]]; then
        line="$(ls -ld -- "${cur}" 2>/dev/null || true)"
        [[ "${line}" == *"->"* ]] && return 0
      fi
      cur="$(dirname "${cur}")"
    done
    return 1
  }
  hm_site_write_nofollow() {
    local path="$1" dir tmp
    dir="$(dirname "${path}")"
    if [[ -L "${path}" ]] || hm_site_path_has_symlink "${dir}"; then
      hm_err "Odmowa zapisu przez symlink: ${path}"
      return 1
    fi
    mkdir -p "${dir}"
    chmod 0700 "${dir}" 2>/dev/null || true
    tmp="$(mktemp "${dir}/.write.XXXXXX")"
    cat > "${tmp}"
    chmod 0600 "${tmp}" 2>/dev/null || true
    mv -f "${tmp}" "${path}"
  }
fi

hm_site_db_ident() {
  local user="$1" kind="${2:-app}" name
  name="${user}_${kind}"
  name="${name//-/_}"
  name="${name//./_}"
  hm_is_valid_db_name "${name}" || return 1
  printf '%s' "${name}"
}

hm_site_db_run() {
  if [[ -n "${HM_SITE_DB_ARGV_LOG:-}" ]]; then
    printf '%q ' "$@" >> "${HM_SITE_DB_ARGV_LOG}"
    printf '\n' >> "${HM_SITE_DB_ARGV_LOG}"
  fi
  if [[ "${HM_SITE_DB_MOCK:-0}" == "1" ]]; then
    if [[ -n "${HM_SITE_DB_SQL_LOG:-}" && ! -t 0 ]]; then
      cat >> "${HM_SITE_DB_SQL_LOG}" || true
    fi
    return 0
  fi
  "$@"
}

hm_site_db_apply_sql() {
  # $1 = SQL (nie trafia do argv). Dalsze argumenty = polecenie.
  local sql="$1"
  shift || true
  local sqlf rc=0
  sqlf="$(mktemp "${TMP_DIR:-/tmp}/hmtools-sql.XXXXXX")"
  chmod 600 "${sqlf}"
  printf '%s\n' "${sql}" > "${sqlf}"
  hm_site_db_run "$@" < "${sqlf}" || rc=$?
  rm -f "${sqlf}"
  return "${rc}"
}

hm_site_db_ledger_path() {
  printf '%s/db-created.tsv' "$(hm_site_state_dir "${1:-}")"
}

hm_site_db_ledger_add() {
  local domain="$1" typ="$2" name="$3" user="$4" extra="${5:-}"
  local path dir
  case "${extra}" in
    *password*|*secret*|*PASSWORD*|*SECRET*)
      hm_err "Ledger bazy nie przyjmuje haseł."
      return 1
      ;;
  esac
  path="$(hm_site_db_ledger_path "${domain}")"
  dir="$(dirname "${path}")"
  mkdir -p "${dir}"
  chmod 0750 "${dir}" || true
  printf '%s\t%s\t%s\t%s\n' "${typ}" "${name}" "${user}" "${extra}" >> "${path}"
  chmod 0640 "${path}" || true
  HM_SITE_DB_SESSION_LEDGER+="${typ}"$'\t'"${name}"$'\t'"${user}"$'\t'"${extra}"$'\n'
}

hm_site_manifest_add_db() {
  local domain="$1" typ="$2" name="$3" user="$4" host="$5" port="${6:-}" extra="${7:-}"
  local path nd dir line obj
  case "${extra}${port}${host}${name}${user}" in
    *password*|*secret*|*PASSWORD*|*SECRET*)
      hm_err "Manifest nie przyjmuje haseł."
      return 1
      ;;
  esac
  if declare -F hm_site_manifest_record_db >/dev/null 2>&1; then
    hm_site_manifest_record_db "${domain}" "${typ}" "${name}" "${user}" "${host}" "${port}" "${extra}"
    return $?
  fi
  path="$(hm_site_manifest_path "${domain}")"
  dir="$(dirname "${path}")"
  nd="${dir}/databases.ndjson"
  if [[ -L "${path}" || -L "${nd}" ]]; then
    hm_err "Odmowa zapisu manifestu przez symlink."
    return 1
  fi
  mkdir -p "${dir}"
  chmod 0700 "${dir}" || true
  obj="{\"type\":\"$(hm_json_escape_str "${typ}")\",\"name\":\"$(hm_json_escape_str "${name}")\",\"user\":\"$(hm_json_escape_str "${user}")\",\"host\":\"$(hm_json_escape_str "${host}")\",\"port\":\"$(hm_json_escape_str "${port}")\""
  if [[ -n "${extra}" ]]; then
    obj+=",\"extra\":\"$(hm_json_escape_str "${extra}")\""
  fi
  obj+="}"
  printf '%s\n' "${obj}" >> "${nd}"
  local tmpm first=1
  tmpm="$(mktemp "${dir}/.manifest.XXXXXX")"
  {
    printf '{\n  "databases": [\n'
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ -n "${line}" ]] || continue
      if [[ "${first}" -eq 0 ]]; then
        printf ',\n'
      fi
      first=0
      printf '    %s' "${line}"
    done < "${nd}"
    printf '\n  ]\n}\n'
  } > "${tmpm}"
  mv -f "${tmpm}" "${path}"
  chmod 0600 "${path}" "${nd}" || true
}

hm_site_mysql_harden() {
  local dir="${HM_SITE_MYSQL_CONF_DIR:-}" d
  if [[ -z "${dir}" ]]; then
    for d in /etc/mysql/mariadb.conf.d /etc/mysql/mysql.conf.d /etc/my.cnf.d; do
      [[ -d "${d}" ]] && dir="${d}" && break
    done
  fi
  [[ -n "${dir}" && -d "${dir}" ]] || return 0
  cat > "${dir}/99-hmtools-bind.cnf" <<'EOF'
[mysqld]
bind-address = 127.0.0.1
skip-name-resolve = 1
EOF
  chmod 0644 "${dir}/99-hmtools-bind.cnf" || true
  if [[ "${HM_SITE_DB_JUST_INSTALLED:-0}" == "1" ]]; then
    hm_site_db_apply_sql \
      "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1'); FLUSH PRIVILEGES;" \
      hm_mysql_exec || true
  fi
}

hm_site_pg_harden() {
  local hba="${HM_SITE_PG_HBA:-}" conf="${HM_SITE_PG_CONF_DIR:-}" d
  if [[ -z "${hba}" && "${HM_SITE_DB_JUST_INSTALLED:-0}" == "1" ]]; then
    hba="$(psql -d postgres -tAc 'SHOW hba_file' 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  if [[ -n "${hba}" ]]; then
    mkdir -p "$(dirname "${hba}")"
    cat > "${hba}" <<'EOF'
# hmtools — tylko local i loopback
local   all             all                                     scram-sha-256
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256
EOF
    chmod 0640 "${hba}" || true
  fi
  if [[ -z "${conf}" && "${HM_SITE_DB_JUST_INSTALLED:-0}" == "1" ]]; then
    for d in /etc/postgresql/*/main/conf.d; do
      [[ -d "${d}" ]] && conf="${d}" && break
    done
  fi
  if [[ -n "${conf}" && -d "${conf}" ]]; then
    cat > "${conf}/99-hmtools-listen.conf" <<'EOF'
listen_addresses = '127.0.0.1'
password_encryption = scram-sha-256
EOF
    chmod 0644 "${conf}/99-hmtools-listen.conf" || true
  fi
}

hm_site_db_offer_install() {
  local title="$1" yes="$2"
  shift 2 || true
  local -a pkgs=("$@")
  local -a plan=("Instalacja pakietów: ${pkgs[*]}" "Konfiguracja nasłuchu tylko na 127.0.0.1")
  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "Instalacja ${title}" "Silnika nie ma na serwerze." --yes "${plan[@]}" || return 1
  else
    hm_confirm_plan "Instalacja ${title}" "Silnika nie ma na serwerze." "${plan[@]}" || return 1
  fi
  local p ok=1
  for p in "${pkgs[@]}"; do
    if hm_pkg_install "${p}"; then
      ok=0
      break
    fi
  done
  [[ "${ok}" -eq 0 ]] || { hm_err "Nie udało się zainstalować: ${pkgs[*]}"; return 1; }
  HM_SITE_DB_JUST_INSTALLED=1
  return 0
}

hm_site_db_ensure_mysql() {
  local yes="${1:-0}"
  if hm_mysql_cli >/dev/null 2>&1; then
    return 0
  fi
  hm_site_db_offer_install "MariaDB" "${yes}" mariadb-server mariadb || return 1
  hm_site_mysql_harden
}

hm_site_db_ensure_postgres() {
  local ver="${1:-}" yes="${2:-0}"
  if hm_have_cmd psql; then
    return 0
  fi
  [[ "${ver}" =~ ^[0-9]+$ || -z "${ver}" ]] || { hm_err "Nieprawidłowa wersja PostgreSQL: ${ver}"; return 1; }
  if [[ -n "${ver}" ]]; then
    hm_site_db_offer_install "PostgreSQL ${ver}" "${yes}" "postgresql-${ver}" "postgresql${ver}" postgresql || return 1
  else
    hm_site_db_offer_install "PostgreSQL" "${yes}" postgresql || return 1
  fi
  hm_site_pg_harden
}

hm_site_db_ensure_redis() {
  local yes="${1:-0}"
  if hm_have_cmd redis-cli; then
    return 0
  fi
  hm_site_db_offer_install "Redis" "${yes}" redis-server redis || return 1
}

hm_site_mysql_provision() {
  local domain="$1" dbname="$2" dbuser="$3"
  local prev="${HM_MYSQL_CREATE_QUIET:-}"
  HM_MYSQL_CREATE_QUIET=1
  HM_MYSQL_CREATE_PASS=""
  if ! hm_mysql_create "${dbname}" "${dbuser}" quiet; then
    HM_MYSQL_CREATE_QUIET="${prev}"
    return 1
  fi
  HM_MYSQL_CREATE_QUIET="${prev}"
  [[ -n "${HM_MYSQL_CREATE_PASS}" ]] || { hm_err "MySQL: brak hasła po utworzeniu."; return 1; }
  hm_site_db_ledger_add "${domain}" mysql "${dbname}" "${dbuser}" "127.0.0.1"
  hm_site_manifest_add_db "${domain}" mysql "${dbname}" "${dbuser}" "127.0.0.1" "3306"
  if declare -F hm_tx_note_undo >/dev/null 2>&1; then
    hm_tx_note_undo "$(printf 'mysql-drop-user\t%s' "${dbuser}")"
    hm_tx_note_undo "$(printf 'mysql-drop-db\t%s' "${dbname}")"
  fi
}

hm_site_pg_provision() {
  local domain="$1" dbname="$2" dbuser="$3" pass sql
  pass="$(hm_gen_password)"
  [[ -n "${pass}" && ${#pass} -ge 12 ]] || { hm_err "Nie udało się wygenerować hasła PostgreSQL."; return 1; }
  sql="CREATE ROLE ${dbuser} LOGIN PASSWORD $(hm_sql_quote "${pass}");
CREATE DATABASE ${dbname} OWNER ${dbuser};
REVOKE ALL ON DATABASE ${dbname} FROM PUBLIC;"
  hm_site_db_apply_sql "${sql}" psql --no-psqlrc -v ON_ERROR_STOP=1 -d postgres || {
    hm_err "PostgreSQL: CREATE ROLE/DATABASE nieudany."
    return 1
  }
  HM_SITE_DB_PASS="${pass}"
  hm_site_db_ledger_add "${domain}" postgres "${dbname}" "${dbuser}" "127.0.0.1"
  hm_site_manifest_add_db "${domain}" postgres "${dbname}" "${dbuser}" "127.0.0.1" "5432"
  if declare -F hm_tx_note_undo >/dev/null 2>&1; then
    hm_tx_note_undo "$(printf 'pg-drop\t%s\t%s' "${dbname}" "${dbuser}")"
  fi
}

hm_site_sqlite_provision() {
  local domain="$1" path user
  path="$(hm_site_home "${domain}")/shared/app.sqlite"
  mkdir -p "$(dirname "${path}")"
  chmod 0750 "$(dirname "${path}")" || true
  if [[ -e "${path}" ]]; then
    hm_err "SQLite już istnieje: ${path}"
    return 1
  fi
  ( umask 077; : > "${path}"; )
  chmod 0600 "${path}"
  user="$(hm_site_unix_user "${domain}")"
  hm_site_env_chown "${user}" "$(dirname "${path}")" "${path}"
  HM_SITE_DB_PASS=""
  hm_site_db_ledger_add "${domain}" sqlite "${path}" "${user}" "file"
  hm_site_manifest_add_db "${domain}" sqlite "$(basename "${path}")" "${user}" "localhost" "" "${path}"
  printf '%s' "${path}"
}

hm_site_redis_major() {
  local v="${HM_REDIS_VERSION:-}"
  if [[ -z "${v}" && "${HM_SITE_DB_MOCK:-0}" != "1" ]] && hm_have_cmd redis-cli; then
    v="$(redis-cli INFO server 2>/dev/null | awk -F: '/^redis_version:/{gsub(/\r/,"",$2); print $2; exit}')"
  fi
  v="${v%%.*}"
  [[ "${v}" =~ ^[0-9]+$ ]] || v=0
  printf '%s' "${v}"
}

hm_site_redis_next_db() {
  local domain="$1" path used="|0|" n=1 line dbn
  path="$(hm_site_db_ledger_path "${domain}")"
  if [[ -f "${path}" ]]; then
    while IFS=$'\t' read -r _ _ _ extra; do
      [[ "${extra}" =~ ^db=([0-9]+)$ ]] || continue
      used+="${BASH_REMATCH[1]}|"
    done < "${path}"
  fi
  while [[ "${n}" -le 15 ]]; do
    [[ "${used}" == *"|${n}|"* ]] || { printf '%s' "${n}"; return 0; }
    n=$((n + 1))
  done
  return 1
}

hm_site_redis_provision() {
  local domain="$1" role="${2:-cache}"
  local user pass dbn major prefix sql
  user="$(hm_site_db_ident "$(hm_site_unix_user "${domain}")" "redis_${role}")" || {
    hm_err "Nieprawidłowa nazwa użytkownika Redis."
    return 1
  }
  dbn="$(hm_site_redis_next_db "${domain}")" || { hm_err "Brak wolnego numeru bazy Redis (1–15)."; return 1; }
  prefix="${domain}:${role}"
  major="$(hm_site_redis_major)"
  pass=""
  if [[ "${major}" -ge 6 ]]; then
    pass="$(hm_gen_password)"
    [[ -n "${pass}" ]] || { hm_err "Nie udało się wygenerować hasła Redis."; return 1; }
    sql="ACL SETUSER ${user} on >${pass} ~${prefix}:* +@all"
    hm_site_db_apply_sql "${sql}" redis-cli || {
      hm_err "Redis ACL SETUSER nieudany."
      return 1
    }
  fi
  HM_SITE_DB_PASS="${pass}"
  HM_SITE_REDIS_DB="${dbn}"
  hm_site_db_ledger_add "${domain}" redis "${user}" "${role}" "db=${dbn}"
  hm_site_manifest_add_db "${domain}" redis "${user}" "${role}" "127.0.0.1" "6379" "db=${dbn}"
}

hm_site_db_drop_mysql() {
  local dbname="$1" dbuser="$2"
  hm_is_valid_db_name "${dbname}" || return 1
  hm_is_valid_db_name "${dbuser}" || return 1
  local uq
  uq="$(hm_sql_quote "${dbuser}")"
  hm_mysql_exec -e "DROP DATABASE IF EXISTS \`${dbname}\`;" || return 1
  hm_site_db_apply_sql "DROP USER IF EXISTS ${uq}@'localhost';" hm_mysql_exec || true
}

hm_site_db_drop_postgres() {
  local dbname="$1" dbuser="$2" sql
  hm_is_valid_db_name "${dbname}" || return 1
  hm_is_valid_db_name "${dbuser}" || return 1
  sql="SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $(hm_sql_quote "${dbname}");
DROP DATABASE IF EXISTS ${dbname};
DROP ROLE IF EXISTS ${dbuser};"
  hm_site_db_apply_sql "${sql}" psql --no-psqlrc -v ON_ERROR_STOP=1 -d postgres
}

hm_site_db_drop_redis() {
  local user="$1"
  hm_is_valid_db_name "${user}" || return 1
  hm_site_db_apply_sql "ACL DELUSER ${user}" redis-cli || true
}

hm_site_db_rollback() {
  local domain="$1" path tmp typ name user extra home
  path="$(hm_site_db_ledger_path "${domain}")"
  [[ -f "${path}" ]] || return 0
  home="$(hm_site_home "${domain}")"
  tmp="$(mktemp "${TMP_DIR:-/tmp}/hmtools-ledger.XXXXXX")"
  while IFS=$'\t' read -r typ name user extra || [[ -n "${typ:-}" ]]; do
    [[ -n "${typ}" ]] || continue
    if declare -F hm_del_db_owned_by_other >/dev/null 2>&1; then
      if [[ "${typ}" == "mysql" || "${typ}" == "postgres" ]]; then
        if hm_del_db_owned_by_other "${name}" "${domain}"; then
          printf '%s\t%s\t%s\t%s\n' "${typ}" "${name}" "${user}" "${extra}" >> "${tmp}"
          hm_warn "Pominięto ${name} — należy do innej strony."
          continue
        fi
      fi
    fi
    case "${typ}" in
      mysql) hm_site_db_drop_mysql "${name}" "${user}" || hm_warn "Nie usunięto MySQL ${name}." ;;
      postgres) hm_site_db_drop_postgres "${name}" "${user}" || hm_warn "Nie usunięto PostgreSQL ${name}." ;;
      redis) hm_site_db_drop_redis "${name}" || true ;;
      sqlite)
        if [[ "${name}" == "${home}/"* && -f "${name}" ]]; then
          rm -f -- "${name}"
        fi
        ;;
    esac
  done < "${path}"
  if [[ -s "${tmp}" ]]; then
    cat "${tmp}" > "${path}"
  else
    : > "${path}"
  fi
  rm -f "${tmp}"
}

hm_site_db_ledger_remove() {
  local domain="$1" typ="$2" name="$3" path tmp t n rest
  path="$(hm_site_db_ledger_path "${domain}")"
  [[ -f "${path}" ]] || return 0
  tmp="$(mktemp "${TMP_DIR:-/tmp}/hmtools-ledger.XXXXXX")"
  while IFS=$'\t' read -r t n rest || [[ -n "${t:-}" ]]; do
    [[ -n "${t}" ]] || continue
    [[ "${t}" == "${typ}" && "${n}" == "${name}" ]] && continue
    printf '%s\t%s\t%s\n' "${t}" "${n}" "${rest}" >> "${tmp}"
  done < "${path}"
  mv -f "${tmp}" "${path}"
}

hm_site_db_rollback_session() {
  local domain="$1" typ name user extra
  [[ -n "${HM_SITE_DB_SESSION_LEDGER:-}" ]] || return 0
  while IFS=$'\t' read -r typ name user extra || [[ -n "${typ:-}" ]]; do
    [[ -n "${typ}" ]] || continue
    if declare -F hm_del_db_owned_by_other >/dev/null 2>&1; then
      if [[ "${typ}" == "mysql" || "${typ}" == "postgres" ]]; then
        if hm_del_db_owned_by_other "${name}" "${domain}"; then
          hm_warn "Pominięto ${name} — należy do innej strony."
          continue
        fi
      fi
    fi
    case "${typ}" in
      mysql) hm_site_db_drop_mysql "${name}" "${user}" || true ;;
      postgres) hm_site_db_drop_postgres "${name}" "${user}" || true ;;
      redis) hm_site_db_drop_redis "${name}" || true ;;
      sqlite)
        local home
        home="$(hm_site_home "${domain}")"
        if [[ "${name}" == "${home}/"* && -f "${name}" ]]; then
          rm -f -- "${name}"
        fi
        ;;
    esac
    hm_site_db_ledger_remove "${domain}" "${typ}" "${name}"
  done <<< "${HM_SITE_DB_SESSION_LEDGER}"
  HM_SITE_DB_SESSION_LEDGER=""
}

hm_site_db_provision() {
  local domain="$1" engine="$2" runtime="${3:-node}" framework="${4:-auto}" pg_ver="${5:-}" yes="${6:-0}" db_name="${7:-}"
  local -a redis_roles=()
  HM_SITE_DB_SESSION_LEDGER=""
  shift 7 || true
  redis_roles=("$@")
  local user ident pass port=0 envpath fw home sqlite_path role dbn shown=""

  hm_is_valid_domain "${domain}" || { hm_err "Nieprawidłowa domena: ${domain}"; return 1; }
  user="$(hm_site_unix_user "${domain}")"
  home="$(hm_site_home "${domain}")"
  mkdir -p "${home}"
  fw="$(hm_site_env_guess_framework "${runtime}" "${home}" "${framework}")"

  case "${engine}" in
    ""|none) ;;
    mysql|mariadb)
      hm_site_db_ensure_mysql "${yes}" || return 1
      ident="${db_name:-$(hm_site_db_ident "${user}" app)}" || { hm_err "Nieprawidłowa nazwa bazy."; return 1; }
      hm_site_mysql_provision "${domain}" "${ident}" "${ident}" || return 1
      pass="${HM_MYSQL_CREATE_PASS}"
      hm_site_env_apply_database "${domain}" "${fw}" mysql "${ident}" "${ident}" "${pass}" "127.0.0.1" "3306" || return 1
      shown="${pass}"
      HM_MYSQL_CREATE_PASS=""
      ;;
    postgres|postgresql)
      hm_site_db_ensure_postgres "${pg_ver}" "${yes}" || return 1
      ident="${db_name:-$(hm_site_db_ident "${user}" app)}" || { hm_err "Nieprawidłowa nazwa bazy."; return 1; }
      hm_site_pg_provision "${domain}" "${ident}" "${ident}" || return 1
      pass="${HM_SITE_DB_PASS}"
      hm_site_env_apply_database "${domain}" "${fw}" postgres "${ident}" "${ident}" "${pass}" "127.0.0.1" "5432" || return 1
      shown="${pass}"
      HM_SITE_DB_PASS=""
      ;;
    sqlite)
      sqlite_path="$(hm_site_sqlite_provision "${domain}")" || return 1
      hm_site_env_apply_database "${domain}" "${fw}" sqlite "${sqlite_path}" "${user}" "" "localhost" "0" || return 1
      ;;
    *)
      hm_err "Nieznany silnik: ${engine} (mysql|postgres|sqlite|none)"
      return 1
      ;;
  esac

  if [[ "${#redis_roles[@]}" -gt 0 ]]; then
    hm_site_db_ensure_redis "${yes}" || return 1
  fi
  for role in "${redis_roles[@]+"${redis_roles[@]}"}"; do
    [[ -n "${role}" ]] || continue
    hm_site_redis_provision "${domain}" "${role}" || return 1
    pass="${HM_SITE_DB_PASS}"
    dbn="${HM_SITE_REDIS_DB}"
    hm_site_env_apply_redis "${domain}" "${pass}" "${dbn}" "127.0.0.1" "6379" "${role}" || return 1
    if [[ -z "${shown}" && -n "${pass}" ]]; then
      shown="${pass}"
    fi
    HM_SITE_DB_PASS=""
  done

  hm_site_env_app_secrets "${domain}" "${fw}" || true
  envpath="$(hm_site_env_path "${domain}")"
  if [[ "${runtime}" == "node" ]]; then
    hm_site_env_write_pm2_stub "${home}/shared/ecosystem.config.cjs" "${envpath}" || true
  fi
  local unit
  unit="$(hm_site_state_dir "${domain}")/app.service"
  if [[ -L "${unit}" ]]; then
    hm_err "Odmowa: ${unit} jest symlinkiem."
    return 1
  fi
  if [[ ! -f "${unit}" ]]; then
    printf '%s\n' '[Service]' 'ExecStart=/usr/bin/true' | hm_site_write_nofollow "${unit}" || return 1
  fi
  hm_site_env_attach_systemd "${unit}" "${envpath}" || true

  hm_info "Dane dostępowe zapisano w ${envpath}"
  if [[ -n "${shown}" ]]; then
    hm_print_secret "  ${shown}"
  fi
  HM_SITE_LAST_NEW="${domain}"
}
