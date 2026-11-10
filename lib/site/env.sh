#!/usr/bin/env bash
# Sekrety serwisu: shared/.env 0600, maskowanie, EnvironmentFile bez haseł w unitach.

if [[ -n "${HMTOOLS_SITE_ENV_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_SITE_ENV_LOADED=1

hm_site_home() {
  local domain="${1:-}"
  if [[ -n "${HM_SITE_ROOT:-}" && "${HM_SITE_DOMAIN:-}" == "${domain}" ]]; then
    printf '%s' "${HM_SITE_ROOT}"
    return 0
  fi
  if [[ -n "${HM_SITE_HOME_BASE:-}" ]]; then
    printf '%s/%s' "${HM_SITE_HOME_BASE%/}" "${domain}"
    return 0
  fi
  printf '/home/%s' "${domain}"
}

hm_site_unix_user() {
  local domain="${1:-}" home
  if [[ -n "${HM_SITE_USER:-}" && ( -z "${HM_SITE_DOMAIN:-}" || "${HM_SITE_DOMAIN}" == "${domain}" ) ]]; then
    printf '%s' "${HM_SITE_USER}"
    return 0
  fi
  home="$(hm_site_home "${domain}")"
  if [[ -d "${home}" ]]; then
    local u
    u="$(stat -c '%U' "${home}" 2>/dev/null || true)"
    if [[ -n "${u}" && "${u}" != "root" && "${u}" != "UNKNOWN" ]]; then
      printf '%s' "${u}"
      return 0
    fi
  fi
  local short="${domain%%.*}"
  short="${short//-/_}"
  printf '%s' "${short}"
}

hm_site_env_path() {
  printf '%s/shared/.env' "$(hm_site_home "${1:-}")"
}

hm_site_env_chown() {
  local user="$1"
  shift || true
  [[ -n "${user}" ]] || return 0
  id "${user}" >/dev/null 2>&1 || return 0
  chown "${user}:${user}" "$@" 2>/dev/null || chown "${user}" "$@" 2>/dev/null || true
}

hm_site_env_ensure() {
  local domain="$1" user path dir
  path="$(hm_site_env_path "${domain}")"
  dir="$(dirname "${path}")"
  mkdir -p "${dir}" || return 1
  chmod 0750 "${dir}" || return 1
  if [[ ! -e "${path}" ]]; then
    ( umask 077; : > "${path}"; )
  fi
  chmod 0600 "${path}" || return 1
  user="$(hm_site_unix_user "${domain}")"
  hm_site_env_chown "${user}" "${dir}" "${path}"
  printf '%s' "${path}"
}

hm_site_env_key_ok() {
  [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

hm_site_env_quote() {
  local v="${1:-}"
  if [[ "${v}" =~ ^[A-Za-z0-9:/@._~%+-]*$ ]]; then
    printf '%s' "${v}"
    return 0
  fi
  v="${v//\\/\\\\}"
  v="${v//\"/\\\"}"
  v="${v//\$/\\\$}"
  v="${v//\`/\\\`}"
  printf '"%s"' "${v}"
}

hm_site_env_get() {
  local path="$1" key="$2" line k v
  [[ -f "${path}" ]] || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    k="${line%%=*}"
    [[ "${k}" == "${key}" ]] || continue
    v="${line#*=}"
    if [[ "${v}" == \"*\" && "${v}" == *\" ]]; then
      v="${v:1:${#v}-2}"
    fi
    printf '%s' "${v}"
    return 0
  done < "${path}"
  return 1
}

hm_site_env_upsert() {
  local domain="$1" key="$2" value="$3" path tmp line k wrote=0
  hm_site_env_key_ok "${key}" || { hm_err "Nieprawidłowy klucz: ${key}"; return 1; }
  path="$(hm_site_env_ensure "${domain}")" || return 1
  tmp="$(mktemp "${path}.XXXXXX")"
  chmod 0600 "${tmp}"
  if [[ -f "${path}" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      if [[ "${line}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
        k="${line%%=*}"
        if [[ "${k}" == "${key}" ]]; then
          printf '%s=%s\n' "${key}" "$(hm_site_env_quote "${value}")" >> "${tmp}"
          wrote=1
          continue
        fi
      fi
      printf '%s\n' "${line}" >> "${tmp}"
    done < "${path}"
  fi
  if [[ "${wrote}" -eq 0 ]]; then
    printf '%s=%s\n' "${key}" "$(hm_site_env_quote "${value}")" >> "${tmp}"
  fi
  chmod 0600 "${tmp}"
  mv -f "${tmp}" "${path}"
  chmod 0600 "${path}"
  hm_site_env_chown "$(hm_site_unix_user "${domain}")" "${path}"
}

hm_site_env_unset_key() {
  local domain="$1" key="$2" path tmp line k
  hm_site_env_key_ok "${key}" || { hm_err "Nieprawidłowy klucz: ${key}"; return 1; }
  path="$(hm_site_env_path "${domain}")"
  [[ -f "${path}" ]] || return 0
  tmp="$(mktemp "${path}.XXXXXX")"
  chmod 0600 "${tmp}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      k="${line%%=*}"
      [[ "${k}" == "${key}" ]] && continue
    fi
    printf '%s\n' "${line}" >> "${tmp}"
  done < "${path}"
  chmod 0600 "${tmp}"
  mv -f "${tmp}" "${path}"
  chmod 0600 "${path}"
}

hm_site_url_encode() {
  local s="${1:-}" out="" i c hex
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    if [[ "${c}" =~ [A-Za-z0-9._~-] ]]; then
      out+="${c}"
    else
      printf -v hex '%%%02X' "'${c}"
      out+="${hex}"
    fi
  done
  printf '%s' "${out}"
}

hm_site_env_mask_value() {
  local key="${1:-}" val="${2:-}"
  case "${key}" in
    DATABASE_URL|REDIS_URL|*_URL)
      if [[ "${val}" =~ ^([a-zA-Z][a-zA-Z0-9+.-]*://[^:/@]*):[^@]*@(.*)$ ]]; then
        printf '%s:****@%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        return 0
      fi
      printf '****'
      ;;
    *)
      printf '****'
      ;;
  esac
}

hm_site_env_list_print() {
  local domain="$1" path line k v
  path="$(hm_site_env_path "${domain}")"
  [[ -f "${path}" ]] || { hm_info "(brak ${path})"; return 0; }
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    k="${line%%=*}"
    v="${line#*=}"
    if [[ "${v}" == \"*\" && ${#v} -ge 2 ]]; then
      v="${v:1:${#v}-2}"
    fi
    printf '%s=%s\n' "${k}" "$(hm_site_env_mask_value "${k}" "${v}")"
  done < "${path}"
}

hm_site_secret_rand() {
  local raw=""
  if hm_have_cmd openssl; then
    raw="$(openssl rand -base64 32 2>/dev/null | tr -d '\n' || true)"
  fi
  if [[ -z "${raw}" ]]; then
    raw="$(hm_gen_password 2>/dev/null || true)$(hm_gen_password 2>/dev/null || true)"
  fi
  printf '%s' "${raw}"
}

hm_site_env_ensure_secret() {
  local domain="$1" key="$2" value="$3" path cur
  path="$(hm_site_env_path "${domain}")"
  cur="$(hm_site_env_get "${path}" "${key}" 2>/dev/null || true)"
  [[ -n "${cur}" ]] && return 0
  hm_site_env_upsert "${domain}" "${key}" "${value}"
}

hm_site_env_app_secrets() {
  local domain="$1" framework="$2" rand
  rand="$(hm_site_secret_rand)"
  [[ -n "${rand}" ]] || return 0
  case "${framework}" in
    laravel|php)
      hm_site_env_ensure_secret "${domain}" APP_KEY "base64:${rand}"
      ;;
    django|python)
      hm_site_env_ensure_secret "${domain}" SECRET_KEY "${rand}"
      ;;
    node|prisma)
      hm_site_env_ensure_secret "${domain}" JWT_SECRET "${rand}"
      rand="$(hm_site_secret_rand)"
      hm_site_env_ensure_secret "${domain}" NEXTAUTH_SECRET "${rand}"
      ;;
    dotnet) ;;
  esac
}

hm_site_env_guess_framework() {
  local runtime="${1:-}" root="${2:-}" explicit="${3:-auto}"
  if [[ -n "${explicit}" && "${explicit}" != "auto" ]]; then
    printf '%s' "${explicit}"
    return 0
  fi
  if [[ -f "${root}/artisan" || -f "${root}/public_html/artisan" ]]; then
    printf 'laravel'; return 0
  fi
  if [[ -f "${root}/manage.py" || -f "${root}/public_html/manage.py" ]]; then
    printf 'django'; return 0
  fi
  if [[ -f "${root}/prisma/schema.prisma" ]]; then
    printf 'prisma'; return 0
  fi
  local cs
  for cs in "${root}"/*.csproj "${root}/public_html"/*.csproj; do
    [[ -f "${cs}" ]] || continue
    printf 'dotnet'
    return 0
  done
  case "${runtime}" in
    php) printf 'laravel' ;;
    python|django) printf 'django' ;;
    dotnet) printf 'dotnet' ;;
    *) printf 'node' ;;
  esac
}

hm_site_env_apply_database() {
  local domain="$1" framework="$2" engine="$3" name="$4" user="$5" pass="$6" host="$7" port="$8"
  local url enc
  enc="$(hm_site_url_encode "${pass}")"
  case "${engine}" in
    mysql|mariadb) url="mysql://${user}:${enc}@${host}:${port}/${name}" ;;
    postgres|postgresql) url="postgres://${user}:${enc}@${host}:${port}/${name}" ;;
    sqlite) url="sqlite:///${name}" ;;
    *) url="" ;;
  esac
  case "${framework}" in
    laravel|php)
      case "${engine}" in
        postgres|postgresql) hm_site_env_upsert "${domain}" DB_CONNECTION pgsql ;;
        sqlite) hm_site_env_upsert "${domain}" DB_CONNECTION sqlite ;;
        *) hm_site_env_upsert "${domain}" DB_CONNECTION mysql ;;
      esac
      hm_site_env_upsert "${domain}" DB_HOST "${host}"
      hm_site_env_upsert "${domain}" DB_PORT "${port}"
      hm_site_env_upsert "${domain}" DB_DATABASE "${name}"
      hm_site_env_upsert "${domain}" DB_USERNAME "${user}"
      if [[ "${engine}" != "sqlite" ]]; then
        hm_site_env_upsert "${domain}" DB_PASSWORD "${pass}"
      fi
      ;;
    dotnet)
      [[ -n "${url}" ]] && hm_site_env_upsert "${domain}" ConnectionStrings__Default "${url}"
      ;;
    *)
      [[ -n "${url}" ]] && hm_site_env_upsert "${domain}" DATABASE_URL "${url}"
      ;;
  esac
}

hm_site_env_apply_redis() {
  local domain="$1" pass="$2" dbn="$3" host="${4:-127.0.0.1}" port="${5:-6379}" role="${6:-cache}"
  local role_up enc url path cur
  role_up="$(printf '%s' "${role}" | tr '[:lower:]' '[:upper:]')"
  hm_site_env_upsert "${domain}" "REDIS_${role_up}_HOST" "${host}"
  hm_site_env_upsert "${domain}" "REDIS_${role_up}_PORT" "${port}"
  hm_site_env_upsert "${domain}" "REDIS_${role_up}_DB" "${dbn}"
  if [[ -n "${pass}" ]]; then
    hm_site_env_upsert "${domain}" "REDIS_${role_up}_PASSWORD" "${pass}"
    enc="$(hm_site_url_encode "${pass}")"
    url="redis://:${enc}@${host}:${port}/${dbn}"
    hm_site_env_upsert "${domain}" "REDIS_${role_up}_URL" "${url}"
  fi
  path="$(hm_site_env_path "${domain}")"
  cur="$(hm_site_env_get "${path}" REDIS_URL 2>/dev/null || true)"
  if [[ "${role}" == "cache" || -z "${cur}" ]]; then
    hm_site_env_upsert "${domain}" REDIS_HOST "${host}"
    hm_site_env_upsert "${domain}" REDIS_PORT "${port}"
    hm_site_env_upsert "${domain}" REDIS_DB "${dbn}"
    if [[ -n "${pass}" ]]; then
      hm_site_env_upsert "${domain}" REDIS_PASSWORD "${pass}"
      hm_site_env_upsert "${domain}" REDIS_URL "${url}"
    fi
  fi
}

# Unit systemd: tylko ścieżka EnvironmentFile. Linie z sekretami są usuwane.
hm_site_env_attach_systemd() {
  local unit="$1" envpath="$2" tmp
  [[ -f "${unit}" ]] || { hm_err "Brak unitu: ${unit}"; return 1; }
  [[ "${envpath}" == /* ]] || return 1
  tmp="$(mktemp "${TMP_DIR:-/tmp}/hmtools-unit.XXXXXX")"
  grep -Ev '^(DB_PASSWORD|DATABASE_URL|REDIS_PASSWORD|REDIS_URL|SECRET_KEY|APP_KEY|JWT_SECRET|NEXTAUTH_SECRET|ConnectionStrings__Default)=' \
    "${unit}" > "${tmp}" || true
  if ! grep -F -q "EnvironmentFile=-${envpath}" "${tmp}"; then
    if grep -q '^\[Service\]' "${tmp}"; then
      awk -v line="EnvironmentFile=-${envpath}" '
        { print }
        /^\[Service\]$/ && !seen { print line; seen=1 }
      ' "${tmp}" > "${tmp}.2"
      mv -f "${tmp}.2" "${tmp}"
    else
      printf 'EnvironmentFile=-%s\n' "${envpath}" >> "${tmp}"
    fi
  fi
  cat "${tmp}" > "${unit}"
  rm -f "${tmp}"
}

# Stub PM2 bez wartości sekretów — tylko ścieżka env_file.
hm_site_env_write_pm2_stub() {
  local dest="$1" envpath="$2" saved
  [[ -e "${dest}" ]] && return 0
  saved="$(umask)"
  umask 022
  cat > "${dest}" <<EOF
// Sekrety czytane z env_file. Nie wpisuj haseł w tym pliku.
module.exports = {
  apps: [{
    name: "app",
    env_file: "${envpath}"
  }]
}
EOF
  umask "${saved}"
  chmod 0644 "${dest}"
}
