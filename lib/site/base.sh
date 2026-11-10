#!/usr/bin/env bash
# Preflight, domena, user i układ katalogów dla site new.

if [[ -n "${HMTOOLS_SITE_BASE_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_SITE_BASE_LOADED=1

hm_site_base_os_supported() {
  local id="$1" ver="$2"
  case "${id}" in
    debian) [[ "${ver}" == "11" || "${ver}" == "12" || "${ver}" == "13" ]] ;;
    ubuntu) [[ "${ver}" == "22.04" || "${ver}" == "24.04" ]] ;;
    almalinux|rocky) [[ "${ver}" == 8* || "${ver}" == 9* ]] ;;
    *) return 1 ;;
  esac
}

hm_site_base_read_os() {
  local file="${HM_SITE_OS_FILE:-/etc/os-release}" id="" ver="" line k v
  [[ -f "${file}" ]] || { printf 'unknown\t0'; return 0; }
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" == *=* ]] || continue
    k="${line%%=*}"
    v="${line#*=}"
    v="${v%\"}"
    v="${v#\"}"
    case "${k}" in
      ID) id="${v}" ;;
      VERSION_ID) ver="${v}" ;;
    esac
  done < "${file}"
  printf '%s\t%s' "${id:-unknown}" "${ver:-0}"
}

hm_site_base_ram_mb() {
  local file="${HM_SITE_MEMINFO_FILE:-/proc/meminfo}"
  if [[ -f "${file}" ]]; then
    awk '/MemTotal/{print int($2/1024); exit}' "${file}"
    return 0
  fi
  printf '0'
}

hm_site_base_port_open() {
  local port="$1" file="${HM_SITE_SS_FILE:-}"
  if [[ -n "${file}" && -f "${file}" ]]; then
    grep -E -q ":${port}([^0-9]|$)" "${file}"
    return $?
  fi
  if hm_have_cmd ss; then
    ss -ltn 2>/dev/null | grep -E -q ":${port}([^0-9]|$)"
    return $?
  fi
  return 1
}

hm_site_base_preflight() {
  local runtime="${1:-}" id ver ram row status block=0
  IFS=$'\t' read -r id ver <<<"$(hm_site_base_read_os)"
  if hm_site_base_os_supported "${id}" "${ver}"; then
    status="OK"
  elif [[ "${ALLOW_UNSUPPORTED_OS:-}" == "1" ]]; then
    status="WARN"
  else
    status="FAIL"
    block=1
  fi
  printf '%s\t%s %s\t%s\n' "OS" "${id}" "${ver}" "${status}"
  ram="$(hm_site_base_ram_mb)"
  status="OK"
  if [[ "${ram}" =~ ^[0-9]+$ && "${ram}" -gt 0 && "${ram}" -lt 1024 ]]; then
    case "${runtime}" in
      node|dotnet) status="WARN" ;;
    esac
  fi
  printf '%s\t%s MB\t%s\n' "RAM" "${ram:-?}" "${status}"
  local disk="?"
  if [[ -n "${HM_SITE_DISK_MB:-}" ]]; then
    disk="${HM_SITE_DISK_MB}"
  fi
  status="OK"
  [[ "${disk}" != "?" && "${disk}" -lt 2048 ]] && status="WARN"
  printf '%s\t%s MB\t%s\n' "DYSK" "${disk}" "${status}"
  if hm_site_base_port_open 80 && hm_site_base_port_open 443; then
    status="OK"
  else
    status="WARN"
  fi
  printf '%s\t%s\t%s\n' "PORT-80/443" "ss" "${status}"
  if [[ "${HM_SITE_REPO_OK:-1}" == "1" ]]; then
    status="OK"
  else
    status="WARN"
  fi
  printf '%s\t%s\t%s\n' "REPO" "${PKG_MANAGER:-pakiety}" "${status}"
  if [[ "${HM_SITE_NTP:-synced}" == "synced" ]]; then
    status="OK"
  else
    status="WARN"
  fi
  printf '%s\t%s\t%s\n' "NTP" "${HM_SITE_NTP:-synced}" "${status}"
  printf '%s\t%s\t%s\n' "PANEL" "${PANEL:-brak}" "OK"
  printf '%s\t%s\t%s\n' "WWW" "${WEBSERVER:-brak}" "OK"
  [[ "${block}" -eq 0 ]]
}

hm_site_base_punycode() {
  local domain="$1"
  if [[ "${domain}" =~ ^[a-zA-Z0-9.-]+$ ]]; then
    printf '%s' "${domain}"
    return 0
  fi
  if [[ -n "${HM_SITE_IDN_MAP:-}" && -f "${HM_SITE_IDN_MAP}" ]]; then
    local line
    while IFS=$'\t' read -r line rest; do
      [[ "${line}" == "${domain}" ]] || continue
      printf '%s' "${rest}"
      return 0
    done < "${HM_SITE_IDN_MAP}"
  fi
  if hm_have_cmd idn2; then
    idn2 "${domain}"
    return $?
  fi
  hm_err "Nie umiem zamienić IDN na punycode: ${domain}"
  return 1
}

hm_site_base_occupied() {
  local domain="$1" home
  if declare -F hm_sc_domain_occupied >/dev/null 2>&1; then
    hm_sc_domain_occupied "${domain}" && return 0
  fi
  home="$(hm_site_home "${domain}")"
  [[ -e "${home}" ]] && return 0
  return 1
}

hm_site_base_user_exists() {
  local user="$1"
  if [[ -n "${HM_SITE_PASSWD_FILE:-}" && -f "${HM_SITE_PASSWD_FILE}" ]]; then
    grep -q "^${user}:" "${HM_SITE_PASSWD_FILE}"
    return $?
  fi
  id "${user}" >/dev/null 2>&1
}

hm_site_base_user_add() {
  local user="$1" home="$2" shell="$3"
  if [[ "${HM_SITE_USERADD_MOCK:-}" == "1" ]]; then
    printf '%s:x:1000:1000::%s:%s\n' "${user}" "${home}" "${shell}" >> "${HM_SITE_PASSWD_FILE}"
    return 0
  fi
  if hm_have_cmd useradd; then
    useradd --home-dir "${home}" --shell "${shell}" --create-home "${user}"
    return $?
  fi
  hm_err "Brak useradd — nie tworzę użytkownika ${user}."
  return 1
}

hm_site_base_preset_runtime() {
  case "${1:-}" in
    ""|custom) printf '' ;;
    wordpress|laravel|symfony|php) printf 'php' ;;
    next|nuxt|node) printf 'node' ;;
    django|fastapi|python) printf 'python' ;;
    aspnet|dotnet) printf 'dotnet' ;;
    static|spa) printf 'static' ;;
    docker) printf 'docker' ;;
    *) hm_err "Nieznany preset: ${1}"; return 1 ;;
  esac
}

hm_site_base_layout() {
  local home="$1" user="$2" group="$3" releases="${4:-0}"
  local saved
  saved="$(umask)"
  (
    umask 027
    mkdir -p "${home}/releases" "${home}/shared" "${home}/logs" "${home}/tmp" "${home}/.config/hmtools"
    if [[ "${releases}" == "1" ]]; then
      local stamp
      stamp="$(date +%Y%m%d%H%M%S)"
      mkdir -p "${home}/releases/${stamp}/public_html"
      ln -sfn "releases/${stamp}" "${home}/current"
      ln -sfn "current/public_html" "${home}/public_html"
    else
      mkdir -p "${home}/public_html"
    fi
    chmod 0750 "${home}" "${home}/logs" "${home}/shared" || true
    if [[ ! -e "${home}/shared/.env" ]]; then
      ( umask 077; : > "${home}/shared/.env"; )
    fi
    chmod 0600 "${home}/shared/.env" || true
  )
  umask "${saved}"
  if hm_site_base_user_exists "${user}"; then
    chown "${user}:${group}" "${home}" "${home}/shared" "${home}/logs" "${home}/shared/.env" 2>/dev/null || true
  fi
}

hm_site_base_resolve_user() {
  local domain="$1" user="${2:-}"
  if [[ -n "${user}" ]]; then
    printf '%s' "${user}"
    return 0
  fi
  if declare -F hm_sc_unix_name_for_domain >/dev/null 2>&1; then
    hm_sc_unix_name_for_domain "${domain}"
    return 0
  fi
  user="${domain%%.*}"
  user="$(printf '%s' "${user}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
  user="${user:0:8}"
  printf '%s' "${user}"
}

hm_site_base_check() {
  local domain="$1" user="${2:-}" shell="${3:-nologin}" preset="${4:-}" child="${5:-}"
  local puny runtime
  puny="$(hm_site_base_punycode "${domain}")" || return 1
  domain="${puny}"
  HM_SITE_BASE_DOMAIN="${domain}"
  runtime="$(hm_site_base_preset_runtime "${preset}")" || return 1
  [[ -n "${runtime}" ]] && HM_SITE_BASE_RUNTIME="${runtime}"
  hm_site_base_preflight "${runtime}" >&2 || { hm_err "Preflight: nieobsługiwany system."; return 1; }
  if hm_site_base_occupied "${domain}" && [[ "${HM_SITE_RESUME:-}" != "1" ]]; then
    hm_err "Domena zajęta: ${domain}"
    return 1
  fi
  user="$(hm_site_base_resolve_user "${domain}" "${user}")"
  HM_SITE_BASE_USER="${user}"
  hm_is_valid_unix_user "${user}" || { hm_err "Zła nazwa użytkownika: ${user}"; return 1; }
  if [[ "${shell}" != "nologin" && "${shell}" != "bash" && "${shell}" != "/usr/sbin/nologin" && "${shell}" != "/bin/bash" ]]; then
    hm_err "Shell: nologin albo bash."
    return 1
  fi
  if [[ -z "${child}" ]] && hm_site_base_user_exists "${user}" && [[ "${HM_SITE_RESUME:-}" != "1" ]]; then
    hm_err "Użytkownik już istnieje: ${user}"
    return 1
  fi
  if [[ -n "${HM_SITE_DNS_A:-}" && -n "${HM_SITE_VPS_IP:-}" && "${HM_SITE_DNS_A}" != "${HM_SITE_VPS_IP}" ]]; then
    if [[ "${HM_SITE_SSL:-}" == "1" && "${HM_SITE_CONTINUE_WITHOUT_SSL:-}" != "1" ]]; then
      hm_err "DNS A (${HM_SITE_DNS_A}) ≠ IP VPS (${HM_SITE_VPS_IP}). Użyj --continue-without-ssl."
      return 1
    fi
    hm_warn "DNS A nie wskazuje na VPS — kontynuuję bez SSL."
  fi
  HM_SITE_BASE_CHILD="${child}"
  return 0
}

hm_site_base_apply() {
  local domain="${HM_SITE_BASE_DOMAIN:?}" user="${HM_SITE_BASE_USER:?}" shell="${1:-nologin}" preset="${2:-}" releases="${3:-0}"
  local home group runtime="${HM_SITE_BASE_RUNTIME:-}" child="${HM_SITE_BASE_CHILD:-}"
  home="$(hm_site_home "${domain}")"
  [[ "${shell}" == "nologin" ]] && shell="/usr/sbin/nologin"
  [[ "${shell}" == "bash" ]] && shell="/bin/bash"
  if [[ -z "${child}" ]]; then
    if hm_site_base_user_exists "${user}"; then
      hm_info "pomijam — już jest (user ${user})"
    else
      hm_site_base_user_add "${user}" "${home}" "${shell}" || return 1
    fi
  fi
  group="${HM_SITE_WEB_GROUP:-www-data}"
  hm_site_base_layout "${home}" "${user}" "${group}" "${releases}" || return 1
  mkdir -p "${home}/.config/hmtools"
  {
    printf 'domain=%s\n' "${domain}"
    printf 'user=%s\n' "${user}"
    printf 'preset=%s\n' "${preset}"
    printf 'runtime=%s\n' "${runtime}"
    [[ -n "${child}" ]] && printf 'child_of=%s\n' "${child}"
  } > "${home}/.config/hmtools/site.env"
  if [[ "${HM_SITE_ALIASES:-www}" != "none" ]]; then
    printf '%s\n' "${HM_SITE_ALIASES:-www}" > "${home}/.config/hmtools/aliases"
  fi
  HM_SITE_USER="${user}"
  if [[ "${PANEL:-}" == "cyberpanel" && "${WEBSERVER:-}" != "nginx" && "${WEBSERVER:-}" != "apache" ]]; then
    hm_run cyberpanel createWebsite --domainName "${domain}" --owner admin --package Default
  fi
  hm_ok "Katalog ${home} (user ${user})."
}
