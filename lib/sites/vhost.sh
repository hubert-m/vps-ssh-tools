#!/usr/bin/env bash
# Sites: vhost / OLS paths

hm_vhost_conf_path() {
  local domain="$1"
  local d
  for d in \
    "${OLS_VHOSTS}/${domain}/vhconf.conf" \
    "${OLS_VHOSTS}/${domain}/vhost.conf" \
    "${OLS_VHOSTS}/${domain}/httpd.conf"
  do
    if [[ -f "${d}" ]]; then
      echo "${d}"
      return 0
    fi
  done
  return 1
}

hm_parse_vhost_docroot() {
  local conf="$1"
  [[ -f "${conf}" ]] || return 1
  # OLS: docRoot                   /home/example.com/public_html
  #      docRoot                   $VH_ROOT/public_html
  awk '
    tolower($1)=="docroot" {
      gsub(/\r/,"",$2);
      print $2;
      exit
    }
  ' "${conf}" 2>/dev/null
}

hm_ols_vhroot_for_domain() {
  # CyberPanel/OLS: vhRoot w vhconf lub w virtualHost { } w httpd_config
  local domain="$1"
  local conf vhroot=""
  conf="$(hm_vhost_conf_path "${domain}" 2>/dev/null || true)"
  if [[ -n "${conf}" && -f "${conf}" ]]; then
    vhroot="$(awk 'tolower($1)=="vhroot" { gsub(/\r/,"",$2); print $2; exit }' "${conf}" 2>/dev/null || true)"
  fi
  if [[ -z "${vhroot}" && -n "${OLS_CONF:-}" && -f "${OLS_CONF}" ]]; then
    vhroot="$(awk -v d="${domain}" '
      BEGIN { inv=0 }
      tolower($1)=="virtualhost" && $2==d { inv=1; next }
      inv && tolower($1)=="vhroot" { gsub(/\r/,"",$2); print $2; exit }
      inv && $0 ~ /^[ \t]*\}/ { inv=0 }
    ' "${OLS_CONF}" 2>/dev/null || true)"
  fi
  vhroot="${vhroot%/}"
  # nie zostawiaj nierozwiniętych zmiennych OLS
  if [[ -z "${vhroot}" || "${vhroot}" == *'$'* ]]; then
    # /home/<domena>/public_html ⇒ katalog nadrzędny też istnieje
    if [[ -d "/home/${domain}" ]]; then
      vhroot="/home/${domain}"
    else
      vhroot=""
    fi
  fi
  printf '%s' "${vhroot}"
}

hm_expand_ols_vars() {
  # $VH_ROOT / $VH_NAME / $DOC_ROOT → realne ścieżki
  local path="$1"
  local domain="$2"
  local vhroot="${3:-}"
  [[ -n "${path}" ]] || { printf '%s' ""; return 0; }
  [[ -n "${vhroot}" ]] || vhroot="$(hm_ols_vhroot_for_domain "${domain}")"
  path="${path//\$VH_NAME/${domain}}"
  if [[ -n "${vhroot}" ]]; then
    path="${path//\$VH_ROOT/${vhroot}}"
    path="${path//\$DOC_ROOT/${vhroot}/public_html}"
  fi
  printf '%s' "${path}"
}

hm_parse_vhost_php() {
  local conf="$1"
  [[ -f "${conf}" ]] || return 0
  # szukaj lsphpXX w path / extProcessor
  local php
  php="$(grep -Eo 'lsphp[0-9]+' "${conf}" 2>/dev/null | head -1 || true)"
  if [[ -n "${php}" ]]; then
    # lsphp82 -> 8.2
    local ver="${php#lsphp}"
    if [[ "${#ver}" -eq 2 ]]; then
      echo "${ver:0:1}.${ver:1:1}"
      return
    fi
    echo "${php}"
    return
  fi
  php="$(grep -Ei 'php[ _]version|phpPath' "${conf}" 2>/dev/null | head -1 || true)"
  echo "${php:-?}"
}
