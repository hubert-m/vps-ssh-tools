#!/usr/bin/env bash
# suspend / unsuspend / openbasedir — zawieszenie strony (503) + open_basedir per vhost


_hm_cmd_help suspend <<'EOF'
Użycie (kontekst strony):
  suspend [--reason "…"] [--page maintenance|503] [--allow-ip A.B.C.D]
  unsuspend
  openbasedir status|on|off

Suspend: blok # hmtools:suspend w vhconf (503 + Retry-After; opcjonalnie strona
serwisowa). Dane/DB nienaruszone. Child domeny i inne vhosty — bez zmian
(jawnie w planie). Współdzielony user → bez stop cron/PM2.

Globalnie: webs --suspended
EOF

_hm_cmd_help unsuspend <<'EOF'
Użycie (kontekst strony): unsuspend

Usuwa wyłącznie blok # hmtools:suspend, przywraca crontab/PM2 zapisane przy
suspend (gdy user exclusive).
EOF

_hm_cmd_help openbasedir <<'EOF'
Użycie (kontekst strony):
  openbasedir status
  openbasedir on     php_admin_value open_basedir (root strony + /tmp + OLS)
  openbasedir off    usuwa blok # hmtools:openbasedir
EOF

# --- ścieżki stanu -----------------------------------------------------------

hm_suspend_state_root() {
  printf '%s' "${HMTOOLS_SUSPEND_DIR:-/var/lib/hmtools/suspend}"
}

hm_suspend_domain_key() {
  local d="${1:-}"
  printf '%s' "${d}" | tr './:' '___' | tr -cd 'A-Za-z0-9_-'
}

hm_suspend_state_dir() {
  local domain="${1:-${HM_SITE_DOMAIN:-}}"
  local key
  key="$(hm_suspend_domain_key "${domain}")"
  [[ -n "${key}" ]] || return 1
  printf '%s/%s' "$(hm_suspend_state_root)" "${key}"
}

hm_suspend_html_installed() {
  local dest="${OLS_ROOT:-/usr/local/lsws}/hmtools/suspended.html"
  printf '%s' "${dest}"
}

hm_suspend_ensure_html() {
  local reason="${1:-}"
  local dest src dir tmp
  dest="$(hm_suspend_html_installed)"
  dir="$(dirname "${dest}")"
  mkdir -p "${dir}" 2>/dev/null || true
  src="${HMTOOLS_ROOT}/share/suspended.html"
  if [[ ! -f "${src}" ]]; then
    src=""
  fi
  tmp="$(hm_mktemp .html)"
  if [[ -n "${src}" && -f "${src}" ]]; then
    cp -a "${src}" "${tmp}"
  else
    cat > "${tmp}" <<'EOF'
<!DOCTYPE html><html lang="pl"><head><meta charset="utf-8"><title>503</title></head>
<body><h1>Serwis niedostępny</h1><p><!--HMTOOLS_REASON-->Przerwa techniczna.<!--/HMTOOLS_REASON--></p></body></html>
EOF
  fi
  if [[ -n "${reason}" ]]; then
    # escapuj HTML-ish
    local esc
    esc="$(printf '%s' "${reason}" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g')"
    sed -i "s|<!--HMTOOLS_REASON-->.*<!--/HMTOOLS_REASON-->|<!--HMTOOLS_REASON-->${esc}<!--/HMTOOLS_REASON-->|" "${tmp}" 2>/dev/null \
      || sed -i.bak "s|<!--HMTOOLS_REASON-->.*<!--/HMTOOLS_REASON-->|<!--HMTOOLS_REASON-->${esc}<!--/HMTOOLS_REASON-->|" "${tmp}"
  fi
  cat "${tmp}" > "${dest}"
  rm -f "${tmp}" "${tmp}.bak" 2>/dev/null || true
  chmod 644 "${dest}" 2>/dev/null || true
  printf '%s' "${dest}"
}

# IPv4 → wzorzec RewriteCond (kropki escapowane)
hm_suspend_ip_to_rewrite() {
  local ip="$1"
  printf '%s' "${ip}" | sed 's/\./\\./g'
}

hm_suspend_is_valid_ip() {
  local ip="$1"
  if declare -F hm_is_valid_ip >/dev/null 2>&1; then
    hm_is_valid_ip "${ip}"
    return $?
  fi
  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local o
  IFS=. read -r -a o <<<"${ip}"
  local x
  for x in "${o[@]}"; do
    [[ "${x}" -ge 0 && "${x}" -le 255 ]] 2>/dev/null || return 1
  done
  [[ "${ip}" != "0.0.0.0" ]]
}

# Domeny sibling / child — tylko do planu (nie ruszamy ich vhconf).
hm_suspend_related_domains() {
  local domain="${1:-${HM_SITE_DOMAIN}}"
  local user="${2:-${HM_SITE_USER:-}}"
  local root="${3:-${HM_SITE_ROOT:-}}"
  hm_discover_sites 2>/dev/null || true
  local other row oroot ouser orest
  local -a out=()
  for other in "${HM_SITES_LIST[@]:-}"; do
    [[ -n "${other}" && "${other}" != "${domain}" ]] || continue
    row="$(hm_resolve_site_paths "${other}" 2>/dev/null || true)"
    [[ -n "${row}" ]] || continue
    oroot="$(echo "${row}" | awk -F'\t' '{print $2}')"
    orest="$(echo "${row}" | awk -F'\t' '{print $7}')"
    oroot="$(hm_tsv_unfield "${oroot}")"
    ouser="$(hm_tsv_unfield "${orest%%|*}")"
    oroot="$(realpath -m "${oroot}" 2>/dev/null || echo "${oroot}")"
    root="$(realpath -m "${root}" 2>/dev/null || echo "${root}")"
    if [[ -n "${user}" && -n "${ouser}" && "${ouser}" == "${user}" ]]; then
      out+=("${other} (współdzielony user)")
    elif [[ -n "${root}" && -n "${oroot}" && ( "${oroot}" == "${root}" || "${oroot}" == "${root}"/* || "${root}" == "${oroot}"/* ) ]]; then
      out+=("${other} (powiązany katalog)")
    fi
  done
  printf '%s\n' "${out[@]:-}"
}

hm_suspend_user_shared() {
  local domain="${1:-${HM_SITE_DOMAIN}}"
  local user="${2:-${HM_SITE_USER:-}}"
  [[ -n "${user}" ]] || return 1
  hm_discover_sites 2>/dev/null || true
  local other row orest ouser
  for other in "${HM_SITES_LIST[@]:-}"; do
    [[ -n "${other}" && "${other}" != "${domain}" ]] || continue
    row="$(hm_resolve_site_paths "${other}" 2>/dev/null || true)"
    [[ -n "${row}" ]] || continue
    orest="$(echo "${row}" | awk -F'\t' '{print $7}')"
    ouser="$(hm_tsv_unfield "${orest%%|*}")"
    if [[ -n "${ouser}" && "${ouser}" == "${user}" ]]; then
      return 0
    fi
  done
  return 1
}

# Treść bloku vhconf suspend
hm_suspend_block_body() {
  local page="$1" allow_ip="$2" html_path="$3" reason="$4"
  local ip_re=""
  if [[ -n "${allow_ip}" ]]; then
    ip_re="$(hm_suspend_ip_to_rewrite "${allow_ip}")"
  fi
  echo "# reason: ${reason:-—}"
  echo "# page: ${page}"
  [[ -n "${allow_ip}" ]] && echo "# allow-ip: ${allow_ip}"
  if [[ "${page}" == "maintenance" ]]; then
    cat <<EOF
context /hmtools-suspended.html {
  type                    NULL
  location                ${html_path}
  allowBrowse             1
  addDefaultCharset       off
  extraHeaders            <<<END_hmtools_suspend_hdr
Retry-After: 3600
Content-Type: text/html; charset=utf-8
  END_hmtools_suspend_hdr
}
errorpage 503 {
  url                     /hmtools-suspended.html
}
rewrite  {
  enable                  1
  rules                   <<<END_hmtools_suspend
# hmtools suspend
EOF
    if [[ -n "${ip_re}" ]]; then
      echo "RewriteCond %{REMOTE_ADDR} !^${ip_re}$"
    fi
    cat <<'EOF'
RewriteCond %{REQUEST_URI} !^/hmtools-suspended\.html$
RewriteRule .* - [R=503,L]
  END_hmtools_suspend
}
EOF
  else
    # page=503 — sam kod, bez HTML
    cat <<'EOF'
rewrite  {
  enable                  1
  rules                   <<<END_hmtools_suspend
# hmtools suspend
EOF
    if [[ -n "${ip_re}" ]]; then
      echo "RewriteCond %{REMOTE_ADDR} !^${ip_re}$"
    fi
    cat <<'EOF'
RewriteRule .* - [R=503,L]
  END_hmtools_suspend
}
extraHeaders              <<<END_hmtools_suspend_ra
Retry-After: 3600
  END_hmtools_suspend_ra
EOF
  fi
}

hm_suspend_save_cron() {
  local user="$1" sdir="$2"
  [[ -n "${user}" ]] || return 0
  local out
  if out="$(crontab -u "${user}" -l 2>/dev/null)"; then
    printf '%s\n' "${out}" > "${sdir}/crontab.bak"
    printf '# hmtools suspend — crontab wstrzymany %s\n' "$(date -Is)" | crontab -u "${user}" - 2>/dev/null \
      || { printf '' | crontab -u "${user}" - 2>/dev/null || true; }
    echo "1" > "${sdir}/cron.paused"
  else
    rm -f "${sdir}/crontab.bak" "${sdir}/cron.paused" 2>/dev/null || true
  fi
}

hm_suspend_restore_cron() {
  local user="$1" sdir="$2"
  [[ -n "${user}" ]] || return 0
  [[ -f "${sdir}/cron.paused" ]] || return 0
  if [[ -f "${sdir}/crontab.bak" ]]; then
    crontab -u "${user}" "${sdir}/crontab.bak" 2>/dev/null || true
  fi
  rm -f "${sdir}/cron.paused" 2>/dev/null || true
}

hm_suspend_save_pm2() {
  local user="$1" sdir="$2"
  [[ -n "${user}" ]] || return 0
  declare -F hm_pm2_run_as_owner >/dev/null 2>&1 || return 0
  local home
  home="$(getent passwd "${user}" 2>/dev/null | cut -d: -f6 || true)"
  [[ -n "${home}" && -d "${home}/.pm2" ]] || return 0
  if hm_pm2_run_as_owner "${home}" jlist >/dev/null 2>&1; then
    hm_pm2_run_as_owner "${home}" jlist > "${sdir}/pm2.jlist" 2>/dev/null || true
    hm_pm2_run_as_owner "${home}" stop all >/dev/null 2>&1 || true
    echo "1" > "${sdir}/pm2.paused"
  fi
}

hm_suspend_restore_pm2() {
  local user="$1" sdir="$2"
  [[ -n "${user}" ]] || return 0
  [[ -f "${sdir}/pm2.paused" ]] || return 0
  declare -F hm_pm2_run_as_owner >/dev/null 2>&1 || return 0
  local home
  home="$(getent passwd "${user}" 2>/dev/null | cut -d: -f6 || true)"
  [[ -n "${home}" ]] || return 0
  hm_pm2_run_as_owner "${home}" restart all >/dev/null 2>&1 || true
  rm -f "${sdir}/pm2.paused" 2>/dev/null || true
}

cmd_suspend() {
  local domain="${HM_SITE_DOMAIN:-}"
  [[ -n "${domain}" ]] || { hm_err "Użycie w kontekście strony: use <domena> → suspend"; return 1; }
  hm_is_valid_domain "${domain}" || { hm_err "Nieprawidłowa domena: ${domain}"; return 1; }

  local reason="" page="maintenance" allow_ip=""
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --reason)
        reason="${2:-}"; shift 2 || true ;;
      --reason=*)
        reason="${1#*=}"; shift ;;
      --page)
        page="${2:-}"; shift 2 || true ;;
      --page=*)
        page="${1#*=}"; shift ;;
      --allow-ip)
        allow_ip="${2:-}"; shift 2 || true ;;
      --allow-ip=*)
        allow_ip="${1#*=}"; shift ;;
      help|-h|--help)
        hm_help_topic suspend; return 0 ;;
      *)
        hm_err "Nieznany argument: ${1}"; return 1 ;;
    esac
  done

  case "${page}" in
    maintenance|503) ;;
    *) hm_err "--page: maintenance|503"; return 1 ;;
  esac
  if [[ -n "${allow_ip}" ]] && ! hm_suspend_is_valid_ip "${allow_ip}"; then
    hm_err "Nieprawidłowe --allow-ip: ${allow_ip}"
    return 1
  fi

  local conf
  conf="$(hm_ols_vhost_conf_for "${domain}")" || return 1

  if hm_ols_vhost_has_block "${conf}" "suspend"; then
    hm_warn "Strona już zawieszona (blok hmtools:suspend). unsuspend → ponownie suspend."
  fi

  local html_path=""
  if [[ "${page}" == "maintenance" ]]; then
    html_path="$(hm_suspend_ensure_html "${reason}")"
  fi

  local -a related=()
  local line
  while IFS= read -r line; do
    [[ -n "${line}" ]] && related+=("${line}")
  done < <(hm_suspend_related_domains "${domain}" "${HM_SITE_USER:-}" "${HM_SITE_ROOT:-}")

  local shared=0
  if hm_suspend_user_shared "${domain}" "${HM_SITE_USER:-}"; then
    shared=1
  fi

  local -a steps=(
    "Tylko vhconf ${domain} (+ opcjonalnie cron/PM2 usera ${HM_SITE_USER:--})"
    "Blok # hmtools:suspend (page=${page}$([[ -n "${allow_ip}" ]] && echo ", allow-ip=${allow_ip}"))"
    "Kopia vhconf .hmtools.<stamp> + ols reload; HTTP probe oczekuje 503"
    "Dane, DB, certyfikaty — bez zmian"
  )
  if [[ "${#related[@]}" -gt 0 ]]; then
    steps+=("BEZ zmian na powiązanych domenach:")
    local r
    for r in "${related[@]}"; do
      steps+=("  · ${r}")
    done
  else
    steps+=("Brak wykrytych sibling/child do pominięcia")
  fi
  if [[ "${shared}" -eq 1 ]]; then
    steps+=("User współdzielony — POMIJAM stop cron/PM2 (zero wpływu na inne strony)")
  else
    steps+=("Zapis crontab + pm2 stop all (user exclusive) → state")
  fi
  [[ -n "${reason}" ]] && steps+=("Powód: ${reason}")

  local tmp body
  tmp="$(hm_mktemp .vhconf)"
  hm_ols_vhost_strip_block "${conf}" "suspend" "${tmp}"
  body="$(hm_suspend_block_body "${page}" "${allow_ip}" "${html_path}" "${reason}")"
  {
    cat "${tmp}"
    echo "# hmtools:suspend BEGIN"
    printf '%s\n' "${body}"
    echo "# hmtools:suspend END"
  } > "${tmp}.new"
  mv "${tmp}.new" "${tmp}"

  # oczekuj 503 przy probe
  export HM_OLS_ACCEPT_HTTP=503
  if ! hm_ols_vhost_apply_tmp "${domain}" "${conf}" "${tmp}" \
    "suspend — ${domain}" \
    "${steps[@]}"; then
    unset HM_OLS_ACCEPT_HTTP
    rm -f "${tmp}"
    return 1
  fi
  unset HM_OLS_ACCEPT_HTTP
  rm -f "${tmp}"

  # cancel confirm_plan → apply rc=0 bez zapisu
  if ! hm_ols_vhost_has_block "${conf}" "suspend"; then
    hm_info "Anulowano — brak zmian."
    return 0
  fi

  local sdir
  sdir="$(hm_suspend_state_dir "${domain}")"
  mkdir -p "${sdir}" 2>/dev/null || true
  chmod 700 "${sdir}" 2>/dev/null || true
  {
    echo "domain=${domain}"
    echo "reason=${reason}"
    echo "page=${page}"
    echo "allow_ip=${allow_ip}"
    echo "stamp=$(date -Is)"
    echo "html=${html_path}"
  } > "${sdir}/meta"
  chmod 600 "${sdir}/meta" 2>/dev/null || true

  if [[ "${shared}" -eq 0 && -n "${HM_SITE_USER:-}" ]]; then
    hm_suspend_save_cron "${HM_SITE_USER}" "${sdir}"
    hm_suspend_save_pm2 "${HM_SITE_USER}" "${sdir}"
  fi

  # odśwież STATUS w kontekście
  HM_SITE_STATUS="suspended"
  hm_ok "Zawieszono ${domain} (503)."
  [[ -n "${allow_ip}" ]] && hm_info "Wyjątek IP: ${allow_ip}"
}

cmd_unsuspend() {
  local domain="${HM_SITE_DOMAIN:-}"
  [[ -n "${domain}" ]] || { hm_err "Użycie w kontekście: unsuspend"; return 1; }
  case "${1:-}" in
    help|-h|--help) hm_help_topic unsuspend; return 0 ;;
  esac

  local conf
  conf="$(hm_ols_vhost_conf_for "${domain}")" || return 1

  if ! hm_ols_vhost_has_block "${conf}" "suspend"; then
    hm_info "Brak bloku hmtools:suspend — strona nie jest zawieszona przez hmtools."
    return 0
  fi

  local shared=0
  hm_suspend_user_shared "${domain}" "${HM_SITE_USER:-}" && shared=1

  local sdir
  sdir="$(hm_suspend_state_dir "${domain}")"

  local -a steps=(
    "Usunięcie wyłącznie bloku # hmtools:suspend z ${conf}"
    "ols reload + walidacja (HTTP ≠ 5xx)"
    "Inne domeny / DB / pliki — bez zmian"
  )
  if [[ "${shared}" -eq 0 && -d "${sdir}" ]]; then
    [[ -f "${sdir}/cron.paused" ]] && steps+=("Przywrócenie crontab usera ${HM_SITE_USER}")
    [[ -f "${sdir}/pm2.paused" ]] && steps+=("pm2 restart all (user ${HM_SITE_USER})")
  fi

  local tmp
  tmp="$(hm_mktemp .vhconf)"
  hm_ols_vhost_strip_block "${conf}" "suspend" "${tmp}"

  if ! hm_ols_vhost_apply_tmp "${domain}" "${conf}" "${tmp}" \
    "unsuspend — ${domain}" \
    "${steps[@]}"; then
    rm -f "${tmp}"
    return 1
  fi
  rm -f "${tmp}"

  if hm_ols_vhost_has_block "${conf}" "suspend"; then
    hm_info "Anulowano — blok suspend nadal obecny."
    return 0
  fi

  if [[ "${shared}" -eq 0 && -n "${HM_SITE_USER:-}" && -d "${sdir}" ]]; then
    hm_suspend_restore_cron "${HM_SITE_USER}" "${sdir}"
    hm_suspend_restore_pm2 "${HM_SITE_USER}" "${sdir}"
  fi

  HM_SITE_STATUS="active"
  hm_ok "Odwieszono ${domain}."
}

# --- open_basedir ------------------------------------------------------------

hm_openbasedir_paths_for_site() {
  local root="${HM_SITE_ROOT:-}"
  local ols="${OLS_ROOT:-/usr/local/lsws}"
  if [[ -z "${root}" || ! -d "${root}" ]]; then
    root="/home/${HM_SITE_DOMAIN}"
  fi
  root="$(realpath -m "${root}" 2>/dev/null || echo "${root}")"
  printf '%s/:/tmp/:%s/' "${root}" "${ols}"
}

hm_openbasedir_block_body() {
  local paths="$1"
  cat <<EOF
phpIniOverride  {
php_admin_value open_basedir "${paths}"
}
EOF
}

cmd_openbasedir() {
  local domain="${HM_SITE_DOMAIN:-}"
  [[ -n "${domain}" ]] || { hm_err "Użycie w kontekście: openbasedir status|on|off"; return 1; }
  local sub="${1:-status}"
  shift || true

  local conf
  conf="$(hm_ols_vhost_conf_for "${domain}")" || return 1

  case "${sub}" in
    status|show|"")
      echo "${C_BOLD}open_basedir — ${domain}${C_RESET}"
      if hm_ols_vhost_has_block "${conf}" "openbasedir"; then
        echo "  hmtools: on"
        awk '
          /# hmtools:openbasedir BEGIN/{p=1;next}
          /# hmtools:openbasedir END/{p=0;next}
          p{print "  " $0}
        ' "${conf}"
      else
        echo "  hmtools: off"
        if grep -qiE 'open_basedir' "${conf}" 2>/dev/null; then
          hm_info "W vhconf jest open_basedir poza blokiem hmtools (np. CyberPanel)."
          grep -i 'open_basedir' "${conf}" | head -5 | sed 's/^/  /'
        fi
      fi
      ;;
    on|enable)
      local paths
      paths="$(hm_openbasedir_paths_for_site)"
      local tmp
      tmp="$(hm_mktemp .vhconf)"
      hm_ols_vhost_strip_block "${conf}" "openbasedir" "${tmp}"
      {
        cat "${tmp}"
        echo "# hmtools:openbasedir BEGIN"
        hm_openbasedir_block_body "${paths}"
        echo "# hmtools:openbasedir END"
      } > "${tmp}.new"
      mv "${tmp}.new" "${tmp}"
      hm_ols_vhost_apply_tmp "${domain}" "${conf}" "${tmp}" \
        "openbasedir on — ${domain}" \
        "Blok # hmtools:openbasedir" \
        "php_admin_value open_basedir \"${paths}\"" \
        "ols reload + walidacja"
      local rc=$?
      rm -f "${tmp}"
      return "${rc}"
      ;;
    off|disable|remove)
      if ! hm_ols_vhost_has_block "${conf}" "openbasedir"; then
        hm_info "Brak bloku hmtools:openbasedir."
        return 0
      fi
      local tmp
      tmp="$(hm_mktemp .vhconf)"
      hm_ols_vhost_strip_block "${conf}" "openbasedir" "${tmp}"
      hm_ols_vhost_apply_tmp "${domain}" "${conf}" "${tmp}" \
        "openbasedir off — ${domain}" \
        "Usunięcie bloku # hmtools:openbasedir" \
        "ols reload"
      local rc=$?
      rm -f "${tmp}"
      return "${rc}"
      ;;
    help|-h|--help)
      hm_help_topic openbasedir
      ;;
    *)
      hm_err "Użycie: openbasedir status|on|off"
      return 1
      ;;
  esac
}

_hm_cmd_register_site suspend cmd_suspend
_hm_cmd_register_site unsuspend cmd_unsuspend
_hm_cmd_register_site openbasedir cmd_openbasedir
