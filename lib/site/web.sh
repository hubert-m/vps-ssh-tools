#!/usr/bin/env bash
# Vhosty OLS/nginx/apache, rejestr portów i reload z cofnięciem.

if [[ -n "${HMTOOLS_SITE_WEB_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_SITE_WEB_LOADED=1

hm_site_web_templates() {
  printf '%s/share/vhost-templates' "${HMTOOLS_ROOT:-.}"
}

hm_site_web_port_file() {
  if [[ -n "${HM_SITE_PORT_FILE:-}" ]]; then
    printf '%s' "${HM_SITE_PORT_FILE}"
    return 0
  fi
  printf '%s/ports.json' "${HM_PKG_ROOT:-/var/lib/hmtools}"
}

hm_site_web_port_range() {
  local spec="${HM_APP_PORT_RANGE:-3001-3999}" lo hi
  lo="${spec%%-*}"
  hi="${spec##*-}"
  [[ "${lo}" =~ ^[0-9]+$ && "${hi}" =~ ^[0-9]+$ ]] || { lo=3001; hi=3999; }
  printf '%s %s' "${lo}" "${hi}"
}

hm_site_web_port_get() {
  local domain="$1" file esc
  file="$(hm_site_web_port_file)"
  [[ -f "${file}" ]] || return 1
  esc="${domain//./\\.}"
  sed -n "s/.*\"${esc}\":\([0-9][0-9]*\).*/\1/p" "${file}" | head -1
}

hm_site_web_port_busy() {
  local port="$1" file line
  file="$(hm_site_web_port_file)"
  if [[ -f "${file}" ]] && grep -q ":${port}[,}]" "${file}"; then
    return 0
  fi
  if [[ -n "${HM_SITE_SS_FILE:-}" && -f "${HM_SITE_SS_FILE}" ]]; then
    grep -E -q "[:.]${port}([^0-9]|$)" "${HM_SITE_SS_FILE}"
    return $?
  fi
  if hm_have_cmd ss; then
    ss -ltn 2>/dev/null | grep -E -q ":${port}([^0-9]|$)"
    return $?
  fi
  return 1
}

hm_site_web_port_write() {
  local domain="$1" port="$2" file tmp esc line d p
  file="$(hm_site_web_port_file)"
  mkdir -p "$(dirname "${file}")"
  tmp="$(mktemp "${file}.XXXXXX")"
  printf '{' > "${tmp}"
  local first=1
  if [[ -f "${file}" ]]; then
    while IFS= read -r line; do
      [[ "${line}" =~ \"([^\"]+)\":([0-9]+) ]] || continue
      d="${BASH_REMATCH[1]}"
      p="${BASH_REMATCH[2]}"
      [[ "${d}" == "${domain}" ]] && continue
      if [[ "${first}" -eq 0 ]]; then
        printf ',' >> "${tmp}"
      fi
      first=0
      printf '"%s":%s' "${d}" "${p}" >> "${tmp}"
    done < <(grep -o '"[^"]*":[0-9][0-9]*' "${file}" || true)
  fi
  if [[ "${first}" -eq 0 ]]; then
    printf ',' >> "${tmp}"
  fi
  printf '"%s":%s}\n' "${domain}" "${port}" >> "${tmp}"
  mv -f "${tmp}" "${file}"
}

hm_site_web_port_read_again() {
  local want="$1" ans=""
  if [[ -n "${HM_SITE_PORT_ANSWER:-}" ]]; then
    ans="${HM_SITE_PORT_ANSWER}"
    HM_SITE_PORT_ANSWER=""
    printf '%s' "${ans}"
    return 0
  fi
  [[ "${HMTOOLS_TEST_NO_TTY:-}" == "1" ]] && return 1
  [[ -t 0 ]] || return 1
  printf 'Port %s jest zajęty. Podaj inny: ' "${want}" >&2
  IFS= read -r ans || return 1
  printf '%s' "${ans}"
}

hm_site_web_ask_port() {
  local ans=""
  if [[ -n "${HM_SITE_PORT_ANSWER:-}" ]]; then
    ans="${HM_SITE_PORT_ANSWER}"
    HM_SITE_PORT_ANSWER=""
    printf '%s' "${ans}"
    return 0
  fi
  [[ "${HMTOOLS_TEST_NO_TTY:-}" == "1" ]] && return 1
  [[ -t 0 ]] || return 1
  printf '%s' "Port aplikacji (127.0.0.1, Enter = auto): " >&2
  IFS= read -r ans || return 1
  printf '%s' "${ans}"
}

hm_site_web_reserve_port() {
  local domain="$1" want="${2:-auto}" lo hi cur p
  read -r lo hi <<<"$(hm_site_web_port_range)"
  if [[ "${want}" != "auto" && -n "${want}" ]]; then
    [[ "${want}" =~ ^[0-9]+$ ]] || { hm_err "Zły port: ${want}"; return 1; }
    cur="$(hm_site_web_port_get "${domain}" || true)"
    if [[ -n "${cur}" && "${cur}" == "${want}" ]]; then
      printf '%s' "${want}"
      return 0
    fi
    if hm_site_web_port_busy "${want}"; then
      local again=""
      if again="$(hm_site_web_port_read_again "${want}")"; then
        [[ -n "${again}" && "${again}" != "${want}" ]] || { hm_err "Port ${want} jest zajęty."; return 1; }
        hm_site_web_reserve_port "${domain}" "${again}"
        return $?
      fi
      hm_err "Port ${want} jest zajęty."
      return 1
    fi
    hm_site_web_port_write "${domain}" "${want}"
    printf '%s' "${want}"
    return 0
  fi
  cur="$(hm_site_web_port_get "${domain}" || true)"
  if [[ -n "${cur}" ]]; then
    printf '%s' "${cur}"
    return 0
  fi
  p="${lo}"
  while [[ "${p}" -le "${hi}" ]]; do
    if ! hm_site_web_port_busy "${p}"; then
      hm_site_web_port_write "${domain}" "${p}"
      printf '%s' "${p}"
      return 0
    fi
    p=$((p + 1))
  done
  hm_err "Brak wolnego portu w ${lo}-${hi}."
  return 1
}

hm_site_web_render() {
  local server="$1" kind="$2" tpl text
  tpl="$(hm_site_web_templates)/${server}/${kind}.tpl"
  [[ -f "${tpl}" ]] || { hm_err "Brak szablonu ${server}/${kind}."; return 1; }
  text="$(cat "${tpl}")"
  text="${text//\{\{DOMAIN\}\}/${HM_SITE_WEB_DOMAIN}}"
  text="${text//\{\{ROOT\}\}/${HM_SITE_WEB_ROOT}}"
  text="${text//\{\{UPSTREAM\}\}/${HM_SITE_WEB_UPSTREAM}}"
  text="${text//\{\{SOCK\}\}/${HM_SITE_WEB_SOCK}}"
  text="${text//\{\{LOGDIR\}\}/${HM_SITE_WEB_LOGDIR}}"
  text="${text//\{\{USER\}\}/${HM_SITE_WEB_USER}}"
  printf '%s\n' "${text}"
}

hm_site_web_upstream_ok() {
  local up="${1:-}"
  [[ -n "${up}" ]] || return 1
  case "${up}" in
    0.0.0.0:*|*:0.0.0.0*|\[::\]:*) return 1 ;;
    127.0.0.1:*|unix:*) return 0 ;;
  esac
  return 1
}

hm_site_web_validate() {
  local server="$1"
  if [[ "${HM_SITE_WEB_VALIDATE:-}" == "fail" ]]; then
    return 1
  fi
  if [[ "${HM_SITE_WEB_VALIDATE:-}" == "ok" ]]; then
    return 0
  fi
  case "${server}" in
    nginx)
      hm_have_cmd nginx || return 0
      nginx -t
      ;;
    apache)
      hm_have_cmd apachectl || return 0
      apachectl configtest
      ;;
    ols)
      if declare -F hm_ols_reload_soft >/dev/null 2>&1; then
        return 0
      fi
      return 0
      ;;
    *) return 1 ;;
  esac
}

hm_site_web_reload() {
  local server="$1"
  if [[ -n "${HM_SITE_WEB_LOG:-}" ]]; then
    printf 'reload %s\n' "${server}" >> "${HM_SITE_WEB_LOG}"
  fi
  [[ "${HM_SITE_WEB_VALIDATE:-}" == "ok" || "${HM_SITE_WEB_VALIDATE:-}" == "fail" ]] && return 0
  case "${server}" in
    nginx) hm_have_cmd nginx && nginx -s reload || true ;;
    apache) hm_have_cmd apachectl && apachectl graceful || true ;;
    ols) declare -F hm_ols_reload_soft >/dev/null 2>&1 && hm_ols_reload_soft || true ;;
  esac
}

hm_site_web_track() {
  local domain="$1" path="$2"
  if declare -F hm_site_resource_add >/dev/null 2>&1; then
    hm_site_resource_add "${domain}" vhost "${path}" 0 || true
  fi
  if [[ -n "${HM_TX_JOURNAL:-}" && -f "${HM_TX_JOURNAL}" ]]; then
    case "${path}" in
      /etc/nginx/*|/etc/apache2/*|/etc/httpd/*|*/sites-available/*|*/sites-enabled/*|*/conf.d/*)
        printf 'undo=nginx-vhost\t%s\n' "${path}" >> "${HM_TX_JOURNAL}"
        ;;
      *)
        printf 'undo=rm -f %s\n' "${path}" >> "${HM_TX_JOURNAL}"
        ;;
    esac
  fi
}

# Debian/Ubuntu: symlink sites-enabled → sites-available. RHEL (conf.d) — nic.
hm_site_web_nginx_enable() {
  local _domain="$1" dest="$2" base en link
  [[ "${dest}" == */sites-available/* ]] || return 0
  if declare -F hm_os_nginx_sites_enabled >/dev/null 2>&1; then
    hm_os_nginx_sites_enabled || return 0
  fi
  base="$(basename "${dest}")"
  en="$(dirname "${dest}")"
  en="${en%/sites-available}/sites-enabled"
  mkdir -p "${en}"
  link="${en}/${base}"
  ln -sfn "../sites-available/${base}" "${link}" || return 1
  printf '%s\n' "${link}"
}

hm_site_web_apply_file() {
  local server="$1" kind="$2" dest="$3" body="${4:-}" bak="" journal="" link="" domain=""
  mkdir -p "$(dirname "${dest}")"
  bak="${dest}.hmbak"
  rm -f "${bak}"
  if [[ -f "${dest}" ]]; then
    cp "${dest}" "${bak}"
  fi
  printf '%s\n' "${body}" > "${dest}"
  if [[ "${kind}" == "proxy" ]] && ! hm_site_web_upstream_ok "${HM_SITE_WEB_UPSTREAM}"; then
    if [[ -f "${bak}" ]]; then mv -f "${bak}" "${dest}"; else rm -f "${dest}"; fi
    hm_err "Upstream musi nasłuchiwać na 127.0.0.1 albo unix socket."
    return 1
  fi
  if grep -q '0.0.0.0' "${dest}"; then
    if [[ -f "${bak}" ]]; then mv -f "${bak}" "${dest}"; else rm -f "${dest}"; fi
    hm_err "Vhost zawiera bind 0.0.0.0."
    return 1
  fi
  domain="${dest##*/}"
  domain="${domain%.conf}"
  if [[ "${server}" == "nginx" ]]; then
    link="$(hm_site_web_nginx_enable "${domain}" "${dest}")" || return 1
  fi
  if ! hm_site_web_validate "${server}"; then
    if [[ -f "${bak}" ]]; then
      mv -f "${bak}" "${dest}"
    else
      rm -f "${dest}"
    fi
    [[ -n "${link}" ]] && rm -f "${link}"
    journal="${HM_SITE_WEB_JOURNAL:-}"
    if [[ -n "${journal}" ]]; then
      mkdir -p "$(dirname "${journal}")"
      printf 'undo %s\n' "${dest}" >> "${journal}"
    fi
    hm_err "Walidacja ${server} nieudana — przywrócono poprzedni vhost, bez reload."
    return 1
  fi
  rm -f "${bak}"
  hm_site_web_track "${domain}" "${dest}"
  [[ -n "${link}" ]] && hm_site_web_track "${domain}" "${link}"
  hm_site_web_reload "${server}"
  printf '%s' "${dest}"
}

hm_site_web_conf_path() {
  local server="$1" domain="$2" dir
  dir="${HM_SITE_WEB_CONF_DIR:-}"
  if [[ -z "${dir}" ]]; then
    case "${server}" in
      nginx)
        if declare -F hm_os_nginx_conf_dir >/dev/null 2>&1; then
          dir="$(hm_os_nginx_conf_dir)"
        else
          dir="/etc/nginx/sites-available"
        fi
        ;;
      apache) dir="/etc/apache2/sites-available" ;;
      ols) dir="${OLS_VHOSTS:-/usr/local/lsws/conf/vhosts}/${domain}" ;;
    esac
  fi
  if [[ "${server}" == "ols" ]]; then
    printf '%s/vhconf.conf' "${dir}"
  else
    printf '%s/%s.conf' "${dir}" "${domain}"
  fi
}

hm_site_web_apply_proxy() {
  local domain="$1" port="$2" mode="${3:-proxy}"
  local kind="proxy"
  [[ "${mode}" == "static" ]] && kind="static"
  [[ "${mode}" == "spa" ]] && kind="spa"
  HM_SITE_WEB_DOMAIN="${domain}"
  HM_SITE_WEB_UPSTREAM="127.0.0.1:${port}"
  HM_SITE_WEB_ROOT="$(hm_site_home "${domain}")/public_html"
  HM_SITE_WEB_LOGDIR="$(hm_site_home "${domain}")/logs"
  HM_SITE_WEB_USER="$(hm_site_unix_user "${domain}")"
  HM_SITE_WEB_SOCK="/run/php/${domain}.sock"
  local server="${HM_SITE_WEBSERVER:-nginx}"
  local body dest
  body="$(hm_site_web_render "${server}" "${kind}")" || return 1
  dest="$(hm_site_web_conf_path "${server}" "${domain}")"
  hm_site_web_apply_file "${server}" "${kind}" "${dest}" "${body}" >/dev/null
}

hm_site_web_offer_install() {
  local server="$1" yes="${2:-0}"
  hm_have_cmd "${server}" && return 0
  local -a steps=("Instalacja pakietu ${server}" "Bazowa konfiguracja: server_tokens off, default_server 444")
  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "Serwer www — ${server}" "" --yes "${steps[@]}" || return 1
  else
    hm_confirm_plan "Serwer www — ${server}" "" "${steps[@]}" || return 1
  fi
  hm_pkg_install "${server}" || return 1
  if [[ "${server}" == "nginx" ]]; then
    local drop="${HM_SITE_WEB_CONF_DIR:-/etc/nginx/conf.d}"
    mkdir -p "${drop}"
    cat > "${drop}/00-hmtools-base.conf" <<'EOF'
server_tokens off;
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 444;
}
EOF
  fi
}

hm_site_web_ssl() {
  local domain="$1" server="$2" root="$3"
  if [[ "${server}" == "ols" ]] && declare -F hm_sc_issue_ssl >/dev/null 2>&1; then
    hm_sc_issue_ssl "${domain}"
    return $?
  fi
  if [[ -n "${HM_SITE_WEB_LOG:-}" ]]; then
    printf 'certbot certonly --webroot -w %s -d %s\n' "${root}" "${domain}" >> "${HM_SITE_WEB_LOG}"
  fi
  return 0
}

hm_site_web_provision() {
  local domain="$1" server="$2" kind="$3" port_want="${4:-auto}" ssl="${5:-0}" yes="${6:-0}" php_ver="${7:-}"
  local home user port body dest
  case "${server}" in
    nginx|apache|ols) ;;
    *) hm_err "Nieznany serwer: ${server}"; return 1 ;;
  esac
  case "${kind}" in
    php-fpm|proxy|static|spa) ;;
    *) hm_err "Nieznany typ vhosta: ${kind}"; return 1 ;;
  esac
  hm_site_web_offer_install "${server}" "${yes}" || return 1
  home="$(hm_site_home "${domain}")"
  user="$(hm_site_unix_user "${domain}")"
  mkdir -p "${home}/public_html" "${home}/logs" "${home}/.well-known/acme-challenge"
  HM_SITE_WEBSERVER="${server}"
  if [[ "${kind}" == "proxy" ]]; then
    port="$(hm_site_web_reserve_port "${domain}" "${port_want}")" || return 1
    HM_SITE_WEB_UPSTREAM="127.0.0.1:${port}"
  else
    port=""
    HM_SITE_WEB_UPSTREAM="127.0.0.1:9"
  fi
  hm_site_web_upstream_ok "${HM_SITE_WEB_UPSTREAM}" || { hm_err "Zły upstream."; return 1; }
  HM_SITE_WEB_DOMAIN="${domain}"
  HM_SITE_WEB_ROOT="${home}/public_html"
  HM_SITE_WEB_LOGDIR="${home}/logs"
  HM_SITE_WEB_USER="${user}"
  HM_SITE_WEB_SOCK="/run/php/${domain}.sock"
  if [[ "${server}" == "ols" && "${kind}" == "php-fpm" && -n "${php_ver}" && -n "${OLS_VHOSTS:-}" ]] \
    && declare -F hm_sc_write_vhconf >/dev/null 2>&1; then
    hm_sc_write_vhconf "${domain}" "${php_ver}" "${user}" "admin@${domain}" || return 1
    if declare -F hm_sc_ols_append_vhost_block >/dev/null 2>&1; then
      hm_sc_ols_append_vhost_block "${domain}" || return 1
    fi
  else
    body="$(hm_site_web_render "${server}" "${kind}")" || return 1
    dest="$(hm_site_web_conf_path "${server}" "${domain}")"
    hm_site_web_apply_file "${server}" "${kind}" "${dest}" "${body}" >/dev/null || return 1
  fi
  if [[ "${ssl}" == "1" ]]; then
    hm_site_web_ssl "${domain}" "${server}" "${HM_SITE_WEB_ROOT}" || return 1
  fi
  if [[ -n "${port}" ]]; then
    hm_ok "Vhost ${server}/${kind} dla ${domain} (bind 127.0.0.1:${port})."
  else
    hm_ok "Vhost ${server}/${kind} dla ${domain}."
  fi
}
