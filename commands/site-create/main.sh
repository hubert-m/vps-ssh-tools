#!/usr/bin/env bash
# site create / child / alias — tworzenie stron przez CyberPanel CLI (+ fallback OLS)

_hm_cmd_help site <<'EOF'
Użycie:
  site create <domena> --php <ver> [--owner admin] [--package Default]
               [--email a@b.c] [--ssl] [--dkim] [--no-open-basedir] [--yes]
  site create <child> --child-of <master> [--path PATH] --php <ver> [--ssl] [--yes]
  site-create … / create-site …   (aliasy tej samej komendy)

Tworzy stronę (HTTP placeholder), child domain albo (w kontekście) alias.
Kolizja domeny/katalogu/usera → odmowa. Nieudany krok → rollback.
CyberPanel: cyberpanel createWebsite|createChild; alias przez virtualHostUtilities.py.
Bez panelu: vhost OLS + map w httpd_config (jak restore).
EOF

_hm_cmd_help site-create <<'EOF'
Alias: site create … — zobacz: help site
EOF

_hm_cmd_help create-site <<'EOF'
Alias: site create … — zobacz: help site
EOF

_hm_cmd_help alias <<'EOF'
Użycie (kontekst strony):
  alias list
  alias add <domena> [--ssl] [--yes]
  alias remove <domena> [--yes]

Parked/alias domeny w mapie listenera OLS (+ CyberPanel createAlias/deleteAlias).
Usunięcie aliasu nie rusza innych wpisów mapy.
EOF

_hm_cmd_help child <<'EOF'
Użycie (kontekst strony):
  child list

Lista domen podrzędnych (CyberPanel childdomains / vhosty z docroot pod masterem).
Tworzenie: site create <child> --child-of <master> …
EOF

# --- stan rollbacku (LIFO: typy done|cp-website|cp-child|ols-vhost|ols-map|home|user|alias-map) ---
declare -a HM_SC_ROLLBACK=()

hm_sc_rb_reset() { HM_SC_ROLLBACK=(); }

hm_sc_rb_push() {
  HM_SC_ROLLBACK+=("$1|$2")
}

hm_sc_rb_run() {
  local i entry kind payload
  for ((i = ${#HM_SC_ROLLBACK[@]} - 1; i >= 0; i--)); do
    entry="${HM_SC_ROLLBACK[$i]}"
    kind="${entry%%|*}"
    payload="${entry#*|}"
    case "${kind}" in
      cp-website)
        hm_warn "Rollback: cyberpanel deleteWebsite --domainName ${payload}"
        hm_run cyberpanel deleteWebsite --domainName "${payload}" 2>/dev/null || true
        ;;
      cp-child)
        hm_warn "Rollback: cyberpanel deleteChild --childDomain ${payload}"
        hm_run cyberpanel deleteChild --childDomain "${payload}" 2>/dev/null || true
        ;;
      ols-vhost)
        hm_warn "Rollback: vhost dir ${payload}"
        [[ -n "${payload}" && -d "${payload}" ]] && rm -rf -- "${payload}"
        ;;
      ols-map)
        hm_warn "Rollback: map/virtualhost ${payload} z OLS_CONF"
        if declare -F hm_ols_remove_domain_from_conf >/dev/null 2>&1; then
          hm_ols_remove_domain_from_conf "${payload}" || true
        fi
        ;;
      home)
        hm_warn "Rollback: katalog ${payload}"
        if [[ -n "${payload}" && -d "${payload}" ]] \
          && [[ "${payload}" =~ ^/home/[^/]+$ || "${payload}" =~ ^/var/www/[^/]+$ ]]; then
          rm -rf -- "${payload}"
        fi
        ;;
      user)
        hm_warn "Rollback: userdel ${payload}"
        if [[ -n "${payload}" ]] && id "${payload}" >/dev/null 2>&1; then
          userdel -r "${payload}" 2>/dev/null || userdel "${payload}" 2>/dev/null || true
        fi
        ;;
      alias-map)
        # payload = master|alias
        hm_warn "Rollback: alias ${payload#*|} z mapy ${payload%%|*}"
        hm_sc_ols_map_remove_alias "${payload%%|*}" "${payload#*|}" || true
        ;;
      cp-alias)
        hm_warn "Rollback: deleteAlias ${payload}"
        hm_sc_cp_python_alias deleteAlias "${payload%%|*}" "${payload#*|}" 0 || true
        ;;
    esac
  done
  hm_sc_rb_reset
  hm_ols_reload_soft 2>/dev/null || true
}

hm_sc_cyberpanel_python() {
  local p
  for p in \
    /usr/local/CyberCP/bin/python \
    /usr/local/CyberCP/bin/python3 \
    /usr/local/CyberCP/bin/python2
  do
    [[ -x "${p}" ]] && { printf '%s' "${p}"; return 0; }
  done
  return 1
}

hm_sc_cp_vhutil() {
  local f="/usr/local/CyberCP/plogical/virtualHostUtilities.py"
  [[ -f "${f}" ]] || return 1
  printf '%s' "${f}"
}

# createAlias|deleteAlias|issueAliasSSL
hm_sc_cp_python_alias() {
  local fn="$1" master="$2" alias="$3" ssl="${4:-0}"
  local py util email owner sslpath
  py="$(hm_sc_cyberpanel_python)" || return 1
  util="$(hm_sc_cp_vhutil)" || return 1
  email="admin@${master}"
  owner="admin"
  sslpath="/home/${master}/public_html"
  case "${fn}" in
    createAlias)
      hm_run "${py}" "${util}" createAlias \
        --masterDomain "${master}" \
        --aliasDomain "${alias}" \
        --ssl "${ssl}" \
        --sslPath "${sslpath}" \
        --administratorEmail "${email}" \
        --websiteOwner "${owner}"
      ;;
    deleteAlias)
      hm_run "${py}" "${util}" deleteAlias \
        --masterDomain "${master}" \
        --aliasDomain "${alias}"
      ;;
    issueAliasSSL)
      hm_run "${py}" "${util}" issueAliasSSL \
        --masterDomain "${master}" \
        --aliasDomain "${alias}" \
        --sslPath "${sslpath}" \
        --administratorEmail "${email}"
      ;;
    *)
      return 1
      ;;
  esac
}

hm_sc_domain_occupied() {
  local domain="$1" d
  hm_is_valid_domain "${domain}" || return 0
  hm_discover_sites
  for d in "${HM_SITES_LIST[@]:-}"; do
    [[ "${d}" == "${domain}" ]] && return 0
  done
  if [[ -n "${OLS_VHOSTS:-}" && -d "${OLS_VHOSTS}/${domain}" ]]; then
    return 0
  fi
  if [[ -d "/home/${domain}" ]]; then
    return 0
  fi
  if declare -F hm_del_cyberpanel_has_domain >/dev/null 2>&1; then
    hm_del_cyberpanel_has_domain "${domain}" && return 0
  elif [[ "${PANEL:-}" == "cyberpanel" ]]; then
    local q n
    q="$(hm_sql_quote "${domain}" 2>/dev/null || printf "'%s'" "${domain}")"
    n="$(hm_mysql_exec cyberpanel -e "
SELECT COUNT(*) FROM (
  SELECT id FROM websiteFunctions_websites WHERE domain = ${q}
  UNION ALL
  SELECT id FROM websiteFunctions_childdomains WHERE domain = ${q}
) t;
" 2>/dev/null || echo 0)"
    [[ "${n}" =~ ^[0-9]+$ && "${n}" -gt 0 ]] && return 0
  fi
  # alias w mapie OLS (drugi token / lista po przecinku)
  if hm_sc_ols_map_has_name "${domain}"; then
    return 0
  fi
  return 1
}

hm_sc_ols_map_has_name() {
  local name="$1" conf="${OLS_CONF:-}"
  [[ -n "${conf}" && -f "${conf}" && -n "${name}" ]] || return 1
  awk -v n="${name}" '
    BEGIN { found = 0 }
    tolower($1)=="map" {
      for (i = 2; i <= NF; i++) {
        cn = split($i, a, /,/)
        for (j = 1; j <= cn; j++) {
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", a[j])
          if (a[j] == n) { found = 1; exit }
        }
      }
    }
    END { exit found ? 0 : 1 }
  ' "${conf}"
}

# Nazwy z map mastera (bez samego mastera): aliasy / www
hm_sc_ols_list_aliases() {
  local master="$1" conf="${OLS_CONF:-}"
  [[ -n "${conf}" && -f "${conf}" && -n "${master}" ]] || return 0
  awk -v m="${master}" '
    tolower($1)=="map" && $2==m {
      rest = $0
      sub(/^[[:space:]]*[Mm][Aa][Pp][[:space:]]+[^[:space:]]+[[:space:]]+/, "", rest)
      n = split(rest, parts, /,/)
      for (i = 1; i <= n; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", parts[i])
        if (parts[i] != "" && parts[i] != m && parts[i] != "*") print parts[i]
      }
    }
  ' "${conf}" | sort -u
}

hm_sc_ols_map_add_alias() {
  local master="$1" alias="$2"
  local conf="${OLS_CONF:-}"
  [[ -n "${conf}" && -f "${conf}" ]] || return 1
  [[ -n "${master}" && -n "${alias}" ]] || return 1
  cp -a "${conf}" "${conf}.hmtools.bak" 2>/dev/null || true
  local tmp
  tmp="$(hm_mktemp .olsmap)"
  awk -v m="${master}" -v a="${alias}" '
    function has_alias(line,   rest, n, parts, i) {
      rest = line
      sub(/^[[:space:]]*[Mm][Aa][Pp][[:space:]]+[^[:space:]]+[[:space:]]+/, "", rest)
      n = split(rest, parts, /,/)
      for (i = 1; i <= n; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", parts[i])
        if (parts[i] == a) return 1
      }
      return 0
    }
    {
      if (tolower($1)=="map" && $2==m) {
        if (!has_alias($0)) {
          # zachowaj wcięcie; doklej , alias przed końcem linii
          sub(/[[:space:]]*$/, "", $0)
          print $0 ", " a
          next
        }
      }
      print
    }
  ' "${conf}" > "${tmp}" || { rm -f "${tmp}"; return 1; }
  if ! cat "${tmp}" > "${conf}"; then
    rm -f "${tmp}"
    return 1
  fi
  rm -f "${tmp}"
  return 0
}

hm_sc_ols_map_remove_alias() {
  local master="$1" alias="$2"
  local conf="${OLS_CONF:-}"
  [[ -n "${conf}" && -f "${conf}" ]] || return 1
  [[ -n "${master}" && -n "${alias}" ]] || return 1
  cp -a "${conf}" "${conf}.hmtools.bak" 2>/dev/null || true
  local tmp
  tmp="$(hm_mktemp .olsmap)"
  awk -v m="${master}" -v a="${alias}" '
    tolower($1)=="map" && $2==m {
      indent = $0
      sub(/[^[:space:]].*/, "", indent)
      rest = $0
      sub(/^[[:space:]]*[Mm][Aa][Pp][[:space:]]+[^[:space:]]+[[:space:]]+/, "", rest)
      n = split(rest, parts, /,/)
      out = ""
      for (i = 1; i <= n; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", parts[i])
        if (parts[i] == "" || parts[i] == a) continue
        if (out == "") out = parts[i]
        else out = out ", " parts[i]
      }
      if (out == "") out = m
      print indent "map                     " m " " out
      next
    }
    { print }
  ' "${conf}" > "${tmp}" || { rm -f "${tmp}"; return 1; }
  if ! cat "${tmp}" > "${conf}"; then
    rm -f "${tmp}"
    return 1
  fi
  rm -f "${tmp}"
  return 0
}

hm_sc_list_children() {
  local master="$1" q
  [[ -n "${master}" ]] || return 0
  if [[ "${PANEL:-}" == "cyberpanel" ]]; then
    q="$(hm_sql_quote "${master}" 2>/dev/null || printf "'%s'" "${master}")"
    hm_mysql_exec cyberpanel -e "
SELECT c.domain FROM websiteFunctions_childdomains c
INNER JOIN websiteFunctions_websites w ON c.master_id = w.id
WHERE w.domain = ${q} AND (c.alais = 0 OR c.alais IS NULL OR c.alais = '')
ORDER BY c.domain;
" 2>/dev/null || true
  fi
  # fallback: vhosty z docroot pod /home/master/
  local d row root doc
  hm_discover_sites
  for d in "${HM_SITES_LIST[@]:-}"; do
    [[ "${d}" == "${master}" ]] && continue
    row="$(hm_resolve_site_paths "${d}" 2>/dev/null || true)"
    [[ -n "${row}" ]] || continue
    IFS=$'\t' read -r _ root doc _ <<<"${row}"
    root="$(hm_tsv_unfield "${root}")"
    doc="$(hm_tsv_unfield "${doc}")"
    if [[ -n "${doc}" && "${doc}" == "/home/${master}/"* && "${doc}" != "/home/${master}/public_html" ]]; then
      printf '%s\n' "${d}"
    elif [[ -n "${root}" && "${root}" == "/home/${master}" && -n "${doc}" && "${doc}" != "/home/${master}/public_html" ]]; then
      printf '%s\n' "${d}"
    fi
  done | sort -u
}

hm_sc_unix_name_for_domain() {
  # skrót jak CyberPanel (alfanum, max 8) — tylko OLS fallback
  local d="$1" u
  u="$(printf '%s' "${d}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
  u="${u:0:8}"
  [[ -n "${u}" ]] || u="siteuser"
  # nie zaczynaj od cyfry
  [[ "${u}" =~ ^[0-9] ]] && u="u${u:0:7}"
  printf '%s' "${u}"
}

hm_sc_php_lsphp_path() {
  local branch="$1" suffix root
  suffix="$(hm_php_lsphp_suffix "${branch}")"
  root="${OLS_ROOT:-/usr/local/lsws}/lsphp${suffix}"
  if [[ -x "${root}/bin/lsphp" ]]; then
    printf '%s' "${root}/bin/lsphp"
    return 0
  fi
  if [[ -x "${root}/bin/php" ]]; then
    printf '%s' "${root}/bin/php"
    return 0
  fi
  return 1
}

hm_sc_write_placeholder() {
  local doc="$1" domain="$2"
  mkdir -p "${doc}"
  cat > "${doc}/index.html" <<EOF
<!DOCTYPE html>
<html lang="pl"><head><meta charset="utf-8"><title>${domain}</title>
<style>body{font-family:system-ui,sans-serif;max-width:40rem;margin:4rem auto;padding:0 1rem;color:#222}
h1{font-size:1.4rem}p{color:#555}</style></head>
<body><h1>${domain}</h1>
<p>Strona utworzona przez hmtools. Zamień zawartość <code>public_html</code>.</p>
</body></html>
EOF
}

hm_sc_write_vhconf() {
  local domain="$1" branch="$2" user="$3" email="$4"
  local vdir conf suffix lsphp sock
  [[ -n "${OLS_VHOSTS:-}" ]] || return 1
  vdir="${OLS_VHOSTS}/${domain}"
  mkdir -p "${vdir}"
  conf="${vdir}/vhconf.conf"
  suffix="$(hm_php_lsphp_suffix "${branch}")"
  lsphp="$(hm_sc_php_lsphp_path "${branch}")" || {
    hm_err "Brak binarnego LSPHP dla PHP ${branch}."
    return 1
  }
  sock="uds://tmp/lshttpd/${user}.sock"
  cat > "${conf}" <<EOF
docRoot                   \$VH_ROOT/public_html
vhDomain                  ${domain}
vhAliases                 www.${domain}
adminEmails               ${email}
enableGzip                1
enableIpGeo               1

errorlog \$VH_ROOT/logs/error.log {
  useServer               0
  logLevel                ERROR
  rollingSize             10M
}

accesslog \$VH_ROOT/logs/access.log {
  useServer               0
  logFormat               "%h %l %u %t \"%r\" %>s %b \"%{Referer}i\" \"%{User-Agent}i\""
  logHeaders              5
  rollingSize             10M
  keepDays                10
  compressArchive         1
}

index  {
  useServer               0
  indexFiles              index.php, index.html
}

scripthandler  {
  add                     lsapi:${user} php
}

extprocessor ${user} {
  type                    lsapi
  address                 ${sock}
  maxConns                10
  env                     LSAPI_CHILDREN=10
  initTimeout             60
  retryTimeout            0
  persistConn             1
  pcKeepAliveTimeout      1
  respBuffer              0
  autoStart               1
  path                    ${lsphp}
  backlog                 100
  instances               1
  priority                0
  memSoftLimit            2047M
  memHardLimit            2047M
  procSoftLimit           400
  procHardLimit           500
}

phpIniOverride  {
}

rewrite  {
  enable                  1
  autoLoadHtaccess        1
}
EOF
  printf '%s' "${vdir}"
}

hm_sc_ols_append_vhost_block() {
  local domain="$1"
  local conf="${OLS_CONF:-}"
  [[ -n "${conf}" && -f "${conf}" ]] || return 1
  cp -a "${conf}" "${conf}.hmtools.bak" 2>/dev/null || true
  # usuń ewentualny stary blok
  if declare -F hm_ols_remove_domain_from_conf >/dev/null 2>&1; then
    hm_ols_remove_domain_from_conf "${domain}" || true
  fi
  {
    echo
    echo "# hmtools create — ${domain}"
    cat <<EOF
virtualhost ${domain} {
  vhRoot                  /home/${domain}
  configFile              \$SERVER_ROOT/conf/vhosts/\$VH_NAME/vhconf.conf
  allowSymbolLink         1
  enableScript            1
  restrained              1
}
EOF
  } >> "${conf}"

  local maps_tmp
  maps_tmp="$(hm_mktemp .maps)"
  printf '%s\t%s\n' "*" "map                     ${domain} ${domain}" > "${maps_tmp}"
  if declare -F hm_ols_insert_maps_into_listeners >/dev/null 2>&1; then
    hm_ols_insert_maps_into_listeners "${conf}" "${maps_tmp}" || {
      rm -f "${maps_tmp}"
      return 1
    }
  else
    # prosty append do pierwszego listenera — awaryjnie
    hm_warn "hm_ols_insert_maps_into_listeners niedostępne — map może wymagać ręcznej edycji."
  fi
  rm -f "${maps_tmp}"
  return 0
}

hm_sc_create_ols_primary() {
  local domain="$1" branch="$2" email="$3"
  local user home webgrp vdir
  user="$(hm_sc_unix_name_for_domain "${domain}")"
  if id "${user}" >/dev/null 2>&1; then
    # kolizja usera — spróbuj z sufiksem
    local base="${user}" n=1
    while id "${user}" >/dev/null 2>&1; do
      user="${base:0:6}${n}"
      n=$((n + 1))
      [[ "${n}" -gt 20 ]] && {
        hm_err "Nie udało się dobrać wolnej nazwy użytkownika Unix (bazowo ${base})."
        return 1
      }
    done
  fi
  home="/home/${domain}"
  webgrp="$(hm_os_web_group 2>/dev/null || echo nogroup)"

  useradd -r -M -d "${home}" -s /usr/sbin/nologin "${user}" 2>/dev/null \
    || useradd -M -d "${home}" -s /usr/sbin/nologin "${user}" || {
    hm_err "useradd ${user} nieudany."
    return 1
  }
  hm_sc_rb_push "user" "${user}"

  mkdir -p "${home}/public_html" "${home}/logs"
  hm_sc_rb_push "home" "${home}"
  hm_sc_write_placeholder "${home}/public_html" "${domain}"
  chown -R "${user}:${user}" "${home}"
  chown "${user}:${webgrp}" "${home}/public_html"
  chmod 750 "${home}/public_html"
  chmod 755 "${home}"

  vdir="$(hm_sc_write_vhconf "${domain}" "${branch}" "${user}" "${email}")" || return 1
  hm_sc_rb_push "ols-vhost" "${vdir}"

  hm_sc_ols_append_vhost_block "${domain}" || return 1
  hm_sc_rb_push "ols-map" "${domain}"

  hm_ols_reload_soft || hm_warn "ols reload nieudany"
  return 0
}

hm_sc_create_ols_child() {
  local child="$1" master="$2" branch="$3" path="${4:-}" email="$5"
  local home doc user webgrp vdir
  home="/home/${master}"
  [[ -d "${home}" ]] || {
    hm_err "Brak katalogu mastera: ${home}"
    return 1
  }
  if [[ -z "${path}" ]]; then
    doc="${home}/public_html/${child}"
  else
    doc="${path}"
  fi
  user="$(stat -c '%U' "${home}" 2>/dev/null || true)"
  [[ -n "${user}" && "${user}" != "root" ]] || user="$(hm_sc_unix_name_for_domain "${master}")"
  webgrp="$(hm_os_web_group 2>/dev/null || echo nogroup)"
  email="${email:-admin@${master}}"

  mkdir -p "${doc}"
  hm_sc_write_placeholder "${doc}" "${child}"
  chown -R "${user}:${user}" "${doc}"
  chown "${user}:${webgrp}" "${doc}"
  chmod 750 "${doc}"

  # vhost child: vhRoot = master home, docRoot = absolute path
  [[ -n "${OLS_VHOSTS:-}" ]] || return 1
  vdir="${OLS_VHOSTS}/${child}"
  mkdir -p "${vdir}"
  local conf suffix lsphp sock
  conf="${vdir}/vhconf.conf"
  suffix="$(hm_php_lsphp_suffix "${branch}")"
  lsphp="$(hm_sc_php_lsphp_path "${branch}")" || return 1
  sock="uds://tmp/lshttpd/${user}.sock"
  cat > "${conf}" <<EOF
docRoot                   ${doc}
vhDomain                  ${child}
adminEmails               ${email}
enableGzip                1

errorlog ${home}/logs/${child}.error.log {
  useServer               0
  logLevel                ERROR
  rollingSize             10M
}

accesslog ${home}/logs/${child}.access.log {
  useServer               0
  rollingSize             10M
}

index  {
  useServer               0
  indexFiles              index.php, index.html
}

scripthandler  {
  add                     lsapi:${user} php
}

extprocessor ${user} {
  type                    lsapi
  address                 ${sock}
  maxConns                10
  env                     LSAPI_CHILDREN=10
  initTimeout             60
  retryTimeout            0
  persistConn             1
  autoStart               1
  path                    ${lsphp}
  instances               1
}

rewrite  {
  enable                  1
  autoLoadHtaccess        1
}
EOF
  hm_sc_rb_push "ols-vhost" "${vdir}"

  # virtualhost + map (vhRoot = master)
  local oconf="${OLS_CONF:-}"
  [[ -n "${oconf}" && -f "${oconf}" ]] || return 1
  cp -a "${oconf}" "${oconf}.hmtools.bak" 2>/dev/null || true
  {
    echo
    echo "# hmtools create child — ${child}"
    cat <<EOF
virtualhost ${child} {
  vhRoot                  ${home}
  configFile              \$SERVER_ROOT/conf/vhosts/\$VH_NAME/vhconf.conf
  allowSymbolLink         1
  enableScript            1
  restrained              1
}
EOF
  } >> "${oconf}"
  local maps_tmp
  maps_tmp="$(hm_mktemp .maps)"
  printf '%s\t%s\n' "*" "map                     ${child} ${child}" > "${maps_tmp}"
  if declare -F hm_ols_insert_maps_into_listeners >/dev/null 2>&1; then
    hm_ols_insert_maps_into_listeners "${oconf}" "${maps_tmp}" || true
  fi
  rm -f "${maps_tmp}"
  hm_sc_rb_push "ols-map" "${child}"
  # child doc nie kasujemy przy rollbacku całego /home/master — tylko vhost/map
  hm_ols_reload_soft || hm_warn "ols reload nieudany"
  return 0
}

hm_sc_summary() {
  local domain="$1"
  hm_discover_sites
  if declare -F hm_print_site_info >/dev/null 2>&1; then
    hm_set_site_context "${domain}" 2>/dev/null || true
    hm_print_site_info "${domain}" 2>/dev/null || true
  else
    local row
    row="$(hm_resolve_site_paths "${domain}" 2>/dev/null || true)"
    echo "${C_BOLD}Podsumowanie — ${domain}${C_RESET}"
    echo "  ${row}"
  fi
  # DNS hint
  local ip apex
  apex="$(getent ahostsv4 "${domain}" 2>/dev/null | awk '{print $1; exit}' || true)"
  ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  if [[ -n "${apex}" && -n "${ip}" ]]; then
    if [[ "${apex}" == "${ip}" ]]; then
      hm_ok "DNS A ${domain} → ${apex} (ten VPS)."
    else
      hm_warn "DNS A ${domain} → ${apex} (VPS: ${ip}) — sprawdź rekord A przed SSL."
    fi
  fi
}

hm_sc_issue_ssl() {
  local domain="$1"
  if declare -F hm_ssl_issue_via_cyberpanel >/dev/null 2>&1; then
    if hm_ssl_issue_via_cyberpanel "${domain}" domain; then
      hm_ok "SSL (cyberpanel issueSSL) dla ${domain}."
      hm_ols_reload_soft || true
      return 0
    fi
  fi
  local doc
  doc="$(hm_resolve_site_paths "${domain}" 2>/dev/null | awk -F'\t' '{print $3}' || true)"
  doc="$(hm_tsv_unfield "${doc}")"
  if declare -F hm_ssl_issue_via_acme_webroot >/dev/null 2>&1 && [[ -n "${doc}" && -d "${doc}" ]]; then
    if hm_ssl_issue_via_acme_webroot "${domain}" "${doc}"; then
      hm_ok "SSL (acme.sh) dla ${domain}."
      hm_ols_reload_soft || true
      return 0
    fi
  fi
  hm_warn "SSL dla ${domain} nieudany — spróbuj później: ssl issue ${domain}"
  return 1
}

# --- create (primary / child) ---
cmd_site_create() {
  local domain="" child_of="" path="" php_raw="" owner="admin" package="Default"
  local email="" want_ssl=0 want_dkim=0 open_basedir=1 yes=0
  local a

  while [[ $# -gt 0 ]]; do
    a="$1"
    shift || true
    case "${a}" in
      --php)
        php_raw="${1:-}"; shift || true ;;
      --php=*)
        php_raw="${a#--php=}" ;;
      --owner)
        owner="${1:-}"; shift || true ;;
      --owner=*)
        owner="${a#--owner=}" ;;
      --package)
        package="${1:-}"; shift || true ;;
      --package=*)
        package="${a#--package=}" ;;
      --email)
        email="${1:-}"; shift || true ;;
      --email=*)
        email="${a#--email=}" ;;
      --child-of)
        child_of="${1:-}"; shift || true ;;
      --child-of=*)
        child_of="${a#--child-of=}" ;;
      --path)
        path="${1:-}"; shift || true ;;
      --path=*)
        path="${a#--path=}" ;;
      --ssl) want_ssl=1 ;;
      --dkim) want_dkim=1 ;;
      --no-open-basedir) open_basedir=0 ;;
      --yes|-y) yes=1 ;;
      help|-h|--help)
        hm_help_topic site; return 0 ;;
      -*)
        hm_err "Nieznana flaga: ${a}"; return 1 ;;
      *)
        if [[ -z "${domain}" ]]; then
          domain="${a}"
        else
          hm_err "Za dużo argumentów: ${a}"; return 1
        fi
        ;;
    esac
  done

  [[ -n "${domain}" ]] || {
    hm_err "Użycie: site create <domena> --php <ver> […]  |  site create <child> --child-of <master> --php <ver>"
    return 1
  }
  if ! hm_is_valid_domain "${domain}"; then
    hm_err "Nieprawidłowa domena: ${domain}"
    return 1
  fi
  [[ -n "${php_raw}" ]] || {
    hm_err "Wymagane --php <ver> (np. 8.3)."
    return 1
  }
  local branch
  branch="$(hm_php_normalize_branch "${php_raw}")" || {
    hm_err "Nieprawidłowa wersja PHP: ${php_raw}"
    return 1
  }
  local suffix pkgs
  suffix="$(hm_php_lsphp_suffix "${branch}")"
  pkgs="$(hm_php_installed_packages "${suffix}" 2>/dev/null | head -1 || true)"
  if [[ -z "${pkgs}" ]] && ! hm_sc_php_lsphp_path "${branch}" >/dev/null 2>&1; then
    hm_err "PHP ${branch} (lsphp${suffix}) nie jest zainstalowane. Najpierw: update-php ${branch}"
    return 1
  fi

  email="${email:-admin@${domain}}"

  hm_detect_all
  hm_sc_rb_reset

  if [[ -n "${child_of}" ]]; then
    if ! hm_is_valid_domain "${child_of}"; then
      hm_err "Nieprawidłowy master: ${child_of}"
      return 1
    fi
    local master_ok=""
    master_ok="$(hm_find_site_by_arg_exact "${child_of}" 2>/dev/null || true)"
    [[ -n "${master_ok}" ]] || {
      hm_err "Master ${child_of} nie istnieje (webs)."
      return 1
    }
    child_of="${master_ok}"
    if hm_sc_domain_occupied "${domain}"; then
      hm_err "Kolizja: ${domain} już istnieje (vhost/katalog/CP/alias) — odmowa bez zmian."
      return 1
    fi

    local -a plan=()
    if [[ "${PANEL}" == "cyberpanel" ]] && hm_have_cmd cyberpanel; then
      plan+=("cyberpanel createChild --masterDomain ${child_of} --childDomain ${domain} --owner ${owner} --php ${branch}")
    else
      plan+=("OLS fallback: vhost ${domain} + docroot ${path:-/home/${child_of}/public_html/${domain}} + map")
    fi
    [[ "${want_ssl}" -eq 1 ]] && plan+=("SSL: issueSSL / acme dla ${domain}")
    plan+=("Podsumowanie (info) + soft-reload OLS")
    plan+=("Rollback przy błędzie: deleteChild / usunięcie vhost+map")

    if [[ "${yes}" -eq 1 ]]; then
      if ! hm_confirm_plan "site create child — ${domain}" \
        "Utworzenie child domain pod ${child_of}." --yes "${plan[@]}"; then
        return 1
      fi
    else
      if ! hm_confirm_plan "site create child — ${domain}" \
        "Utworzenie child domain pod ${child_of}." "${plan[@]}"; then
        return 1
      fi
    fi

    if [[ "${PANEL}" == "cyberpanel" ]] && hm_have_cmd cyberpanel; then
      local -a cargs=(createChild --masterDomain "${child_of}" --childDomain "${domain}"
        --owner "${owner}" --php "${branch}"
        --ssl "${want_ssl}" --dkim "${want_dkim}" --openBasedir "${open_basedir}")
      [[ -n "${path}" ]] && cargs+=(--path "${path}")
      if ! hm_run cyberpanel "${cargs[@]}"; then
        hm_err "cyberpanel createChild nieudany — rollback."
        hm_sc_rb_run
        return 1
      fi
      hm_sc_rb_push "cp-child" "${domain}"
    else
      if [[ "${PANEL}" == "cyberpanel" ]] && ! hm_have_cmd cyberpanel; then
        hm_err "PANEL=cyberpanel, ale brak CLI cyberpanel."
        return 1
      fi
      [[ "${WEBSERVER:-}" == "openlitespeed" || -n "${OLS_CONF:-}" ]] || {
        hm_err "Brak CyberPanel CLI i OLS — nie utworzę child."
        return 1
      }
      if ! hm_sc_create_ols_child "${domain}" "${child_of}" "${branch}" "${path}" "${email}"; then
        hm_err "OLS child create nieudany — rollback."
        hm_sc_rb_run
        return 1
      fi
    fi

    if [[ "${want_ssl}" -eq 1 ]]; then
      hm_sc_issue_ssl "${domain}" || true
    fi
    hm_sc_rb_reset
    hm_ok "Child ${domain} utworzony pod ${child_of}."
    hm_sc_summary "${domain}"
    return 0
  fi

  # primary website
  if hm_sc_domain_occupied "${domain}"; then
    hm_err "Kolizja: ${domain} już istnieje (vhost/katalog/CP/alias) — odmowa bez zmian."
    return 1
  fi
  # unix user collision tylko dla OLS fallback (CP sam zarządza)
  if [[ "${PANEL}" != "cyberpanel" ]] || ! hm_have_cmd cyberpanel; then
    local cand
    cand="$(hm_sc_unix_name_for_domain "${domain}")"
    if id "${cand}" >/dev/null 2>&1; then
      # nie twarda odmowa — create_ols dobierze sufiks; ostrzeż
      hm_warn "User Unix ${cand} już istnieje — dobiorę wolną nazwę."
    fi
  fi

  local -a plan=()
  if [[ "${PANEL}" == "cyberpanel" ]] && hm_have_cmd cyberpanel; then
    plan+=("cyberpanel createWebsite --package ${package} --owner ${owner} --domainName ${domain} --email ${email} --php ${branch} --ssl ${want_ssl} --dkim ${want_dkim} --openBasedir ${open_basedir}")
  else
    plan+=("OLS: user + /home/${domain}/public_html + vhconf + virtualhost/map")
  fi
  [[ "${want_ssl}" -eq 1 ]] && plan+=("SSL (jeśli CP nie wydał w createWebsite)")
  plan+=("Placeholder index.html + podsumowanie info")
  plan+=("Rollback: deleteWebsite / userdel + rm home + vhost/map")

  if [[ "${yes}" -eq 1 ]]; then
    if ! hm_confirm_plan "site create — ${domain}" \
      "Utworzenie nowej strony." --yes "${plan[@]}"; then
      return 1
    fi
  else
    if ! hm_confirm_plan "site create — ${domain}" \
      "Utworzenie nowej strony." "${plan[@]}"; then
      return 1
    fi
  fi

  if [[ "${PANEL}" == "cyberpanel" ]] && hm_have_cmd cyberpanel; then
    if ! hm_run cyberpanel createWebsite \
      --package "${package}" \
      --owner "${owner}" \
      --domainName "${domain}" \
      --email "${email}" \
      --php "${branch}" \
      --ssl "${want_ssl}" \
      --dkim "${want_dkim}" \
      --openBasedir "${open_basedir}"; then
      hm_err "cyberpanel createWebsite nieudany — rollback."
      hm_sc_rb_run
      return 1
    fi
    hm_sc_rb_push "cp-website" "${domain}"
  else
    if [[ "${PANEL}" == "cyberpanel" ]] && ! hm_have_cmd cyberpanel; then
      hm_err "PANEL=cyberpanel, ale brak CLI cyberpanel."
      return 1
    fi
    [[ -n "${OLS_CONF:-}" && -n "${OLS_VHOSTS:-}" ]] || {
      hm_err "Brak CyberPanel i OLS (OLS_CONF/OLS_VHOSTS) — nie utworzę strony."
      return 1
    }
    if ! hm_sc_create_ols_primary "${domain}" "${branch}" "${email}"; then
      hm_err "OLS create nieudany — rollback."
      hm_sc_rb_run
      return 1
    fi
  fi

  # placeholder jeśli CP nie zostawił index
  if [[ -d "/home/${domain}/public_html" ]] && [[ ! -e "/home/${domain}/public_html/index.html" && ! -e "/home/${domain}/public_html/index.php" ]]; then
    hm_sc_write_placeholder "/home/${domain}/public_html" "${domain}"
    local u
    u="$(stat -c '%U' "/home/${domain}" 2>/dev/null || true)"
    [[ -n "${u}" && "${u}" != "root" ]] && chown "${u}:${u}" "/home/${domain}/public_html/index.html" 2>/dev/null || true
  fi

  if [[ "${want_ssl}" -eq 1 ]]; then
    # CP createWebsite z --ssl 1 zwykle już wystawił; awaryjnie ponów
    if [[ ! -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
      hm_sc_issue_ssl "${domain}" || true
    fi
  fi

  hm_sc_rb_reset
  hm_ok "Strona ${domain} utworzona."
  hm_sc_summary "${domain}"
  return 0
}

cmd_site() {
  local sub="${1:-}"
  shift || true
  case "${sub}" in
    create)
      cmd_site_create "$@"
      ;;
    help|-h|--help|"")
      hm_help_topic site
      ;;
    *)
      hm_err "Użycie: site create …  (help site)"
      return 1
      ;;
  esac
}

cmd_site_create_entry() {
  # site-create / create-site [create] <domena> …
  local a="${1:-}"
  case "${a}" in
    help|-h|--help)
      hm_help_topic site; return 0 ;;
    create)
      shift || true
      cmd_site_create "$@"
      ;;
    *)
      cmd_site_create "$@"
      ;;
  esac
}

# --- kontekst: alias / child ---
cmd_site_alias() {
  local sub="${1:-list}"
  shift || true
  local domain="${HM_SITE_DOMAIN:-}"
  [[ -n "${domain}" ]] || {
    hm_err "Użycie w kontekście strony: use <domena> → alias …"
    return 1
  }
  hm_detect_all

  case "${sub}" in
    list|ls|"")
      echo "${C_BOLD}Aliasy — ${domain}${C_RESET}"
      local al any=0
      while IFS= read -r al; do
        [[ -n "${al}" ]] || continue
        echo "  ${al}"
        any=1
      done < <(hm_sc_ols_list_aliases "${domain}")
      if [[ "${PANEL:-}" == "cyberpanel" ]]; then
        local q
        q="$(hm_sql_quote "${domain}" 2>/dev/null || printf "'%s'" "${domain}")"
        while IFS= read -r al; do
          [[ -n "${al}" ]] || continue
          echo "  ${al}  ${C_DIM}(CP alias)${C_RESET}"
          any=1
        done < <(hm_mysql_exec cyberpanel -e "
SELECT c.domain FROM websiteFunctions_childdomains c
INNER JOIN websiteFunctions_websites w ON c.master_id = w.id
WHERE w.domain = ${q} AND c.alais = 1
ORDER BY c.domain;
" 2>/dev/null || true)
      fi
      [[ "${any}" -eq 1 ]] || echo "  (brak)"
      return 0
      ;;
    add)
      local alias="" want_ssl=0 yes=0 a
      while [[ $# -gt 0 ]]; do
        a="$1"; shift || true
        case "${a}" in
          --ssl) want_ssl=1 ;;
          --yes|-y) yes=1 ;;
          help|-h|--help) hm_help_topic alias; return 0 ;;
          -*) hm_err "Nieznana flaga: ${a}"; return 1 ;;
          *) [[ -z "${alias}" ]] && alias="${a}" || { hm_err "Za dużo argumentów"; return 1; } ;;
        esac
      done
      [[ -n "${alias}" ]] || { hm_err "Użycie: alias add <domena> [--ssl]"; return 1; }
      if ! hm_is_valid_domain "${alias}"; then
        hm_err "Nieprawidłowa domena: ${alias}"; return 1
      fi
      if hm_sc_domain_occupied "${alias}"; then
        hm_err "Kolizja: ${alias} już zajęta — odmowa."; return 1
      fi
      hm_sc_rb_reset
      local -a plan=("Dodanie aliasu ${alias} do mapy ${domain}")
      if [[ "${PANEL}" == "cyberpanel" ]] && hm_sc_cyberpanel_python >/dev/null && hm_sc_cp_vhutil >/dev/null; then
        plan=("CyberCP virtualHostUtilities createAlias ${domain} ← ${alias}")
      fi
      [[ "${want_ssl}" -eq 1 ]] && plan+=("SSL alias (issueAliasSSL / issue)")
      plan+=("Rollback: deleteAlias / usunięcie z mapy")
      if [[ "${yes}" -eq 1 ]]; then
        hm_confirm_plan "alias add — ${alias}" "" --yes "${plan[@]}" || return 1
      else
        hm_confirm_plan "alias add — ${alias}" "" "${plan[@]}" || return 1
      fi

      local used_cp=0
      if [[ "${PANEL}" == "cyberpanel" ]] && hm_sc_cyberpanel_python >/dev/null && hm_sc_cp_vhutil >/dev/null; then
        if hm_sc_cp_python_alias createAlias "${domain}" "${alias}" "${want_ssl}"; then
          used_cp=1
          hm_sc_rb_push "cp-alias" "${domain}|${alias}"
        else
          hm_warn "createAlias (python) nieudany — próbuję mapę OLS."
        fi
      fi
      if [[ "${used_cp}" -eq 0 ]]; then
        [[ -n "${OLS_CONF:-}" && -f "${OLS_CONF}" ]] || {
          hm_err "Brak OLS_CONF — nie dodam aliasu."
          return 1
        }
        if ! hm_sc_ols_map_add_alias "${domain}" "${alias}"; then
          hm_err "Edycja mapy OLS nieudana."
          hm_sc_rb_run
          return 1
        fi
        hm_sc_rb_push "alias-map" "${domain}|${alias}"
        hm_ols_reload_soft || hm_warn "ols reload nieudany"
      fi
      if [[ "${want_ssl}" -eq 1 ]]; then
        if [[ "${used_cp}" -eq 1 ]]; then
          hm_sc_cp_python_alias issueAliasSSL "${domain}" "${alias}" 0 || hm_sc_issue_ssl "${alias}" || true
        else
          hm_sc_issue_ssl "${alias}" || true
        fi
      fi
      hm_sc_rb_reset
      hm_ok "Alias ${alias} → ${domain}."
      return 0
      ;;
    remove|rm|del|delete)
      local alias="" yes=0 a
      while [[ $# -gt 0 ]]; do
        a="$1"; shift || true
        case "${a}" in
          --yes|-y) yes=1 ;;
          help|-h|--help) hm_help_topic alias; return 0 ;;
          -*) hm_err "Nieznana flaga: ${a}"; return 1 ;;
          *) [[ -z "${alias}" ]] && alias="${a}" || { hm_err "Za dużo argumentów"; return 1; } ;;
        esac
      done
      [[ -n "${alias}" ]] || { hm_err "Użycie: alias remove <domena>"; return 1; }
      if ! hm_is_valid_domain "${alias}"; then
        hm_err "Nieprawidłowa domena: ${alias}"; return 1
      fi
      local -a plan=("Usunięcie aliasu ${alias} z mapy ${domain} (inne wpisy bez zmian)")
      if [[ "${PANEL}" == "cyberpanel" ]] && hm_sc_cp_vhutil >/dev/null; then
        plan=("CyberCP deleteAlias + oczyszczenie mapy OLS dla ${alias}")
      fi
      if [[ "${yes}" -eq 1 ]]; then
        hm_confirm_plan "alias remove — ${alias}" \
          "Usunięcie aliasu (nie kasuje plików mastera)." --yes "${plan[@]}" || return 1
      else
        hm_confirm_plan "alias remove — ${alias}" \
          "Usunięcie aliasu (nie kasuje plików mastera)." "${plan[@]}" || return 1
      fi
      if [[ "${PANEL}" == "cyberpanel" ]] && hm_sc_cyberpanel_python >/dev/null && hm_sc_cp_vhutil >/dev/null; then
        hm_sc_cp_python_alias deleteAlias "${domain}" "${alias}" 0 || hm_warn "deleteAlias python — kontynuuję mapę OLS."
      fi
      if [[ -n "${OLS_CONF:-}" && -f "${OLS_CONF}" ]]; then
        hm_sc_ols_map_remove_alias "${domain}" "${alias}" || {
          hm_err "Nie udało się usunąć aliasu z mapy OLS."
          return 1
        }
        hm_ols_reload_soft || hm_warn "ols reload nieudany"
      fi
      hm_ok "Alias ${alias} usunięty z ${domain}."
      return 0
      ;;
    help|-h|--help)
      hm_help_topic alias
      ;;
    *)
      hm_err "Użycie: alias list|add|remove"
      return 1
      ;;
  esac
}

cmd_site_child() {
  local sub="${1:-list}"
  shift || true
  local domain="${HM_SITE_DOMAIN:-}"
  [[ -n "${domain}" ]] || {
    hm_err "Użycie w kontekście: child list"
    return 1
  }
  case "${sub}" in
    list|ls|"")
      echo "${C_BOLD}Child domains — ${domain}${C_RESET}"
      local c any=0
      while IFS= read -r c; do
        [[ -n "${c}" ]] || continue
        echo "  ${c}"
        any=1
      done < <(hm_sc_list_children "${domain}")
      [[ "${any}" -eq 1 ]] || echo "  (brak)"
      echo
      echo "${C_DIM}Utwórz: site create <child> --child-of ${domain} --php <ver>${C_RESET}"
      return 0
      ;;
    help|-h|--help)
      hm_help_topic child
      ;;
    *)
      hm_err "Użycie: child list"
      return 1
      ;;
  esac
}

_hm_cmd_register site cmd_site 0
_hm_cmd_register site-create cmd_site_create_entry 0 create-site
_hm_cmd_register_site alias cmd_site_alias
_hm_cmd_register_site child cmd_site_child
