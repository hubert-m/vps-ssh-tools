#!/usr/bin/env bash
# WP: lokalny snapshot DB + wp-content/plugins|themes przed update/search-replace

hm_wp_snap_root() {
  local domain="${1:-${HM_SITE_DOMAIN:-}}"
  local root="${HM_SITE_ROOT:-}"
  if [[ -z "${root}" && -n "${domain}" && -d "/home/${domain}" ]]; then
    root="/home/${domain}"
  fi
  [[ -n "${root}" ]] || return 1
  printf '%s/.hmtools-snap' "${root}"
}

hm_wp_snap_list() {
  local base stamp
  base="$(hm_wp_snap_root)" || return 1
  [[ -d "${base}" ]] || return 0
  for stamp in "${base}"/*; do
    [[ -d "${stamp}" ]] || continue
    [[ -f "${stamp}/meta.txt" ]] || continue
    printf '%s\n' "$(basename "${stamp}")"
  done | sort -r
}

hm_wp_snap_create() {
  local reason="${1:-manual}"
  local path dbname base stamp dir user
  path="$(hm_wp_resolve_path)" || return 1
  dbname="$(hm_wp_db_name "${path}")" || {
    hm_err "Nie odczytam DB_NAME z wp-config (snapshot)."
    return 1
  }
  base="$(hm_wp_snap_root)" || {
    hm_err "Brak HM_SITE_ROOT — nie utworzę snapshotu."
    return 1
  }
  user="$(hm_access_require_site_user "${HM_SITE_DOMAIN}")" || return 1
  stamp="$(date +%Y%m%d-%H%M%S)"
  dir="${base}/${stamp}"
  mkdir -p "${dir}" || return 1
  chown "${user}:${user}" "${base}" "${dir}" 2>/dev/null || true

  hm_info "Snapshot ${stamp} → ${dir}"
  if ! hm_mysql_dump_local "${dbname}" "${dir}/db.sql.gz"; then
    rm -rf -- "${dir}"
    return 1
  fi
  chown "${user}:${user}" "${dir}/db.sql.gz" 2>/dev/null || true

  if [[ -d "${path}/wp-content/plugins" ]]; then
    tar -C "${path}/wp-content" -czf "${dir}/plugins.tar.gz" plugins 2>/dev/null \
      || { hm_warn "Tar plugins nieudany."; rm -f "${dir}/plugins.tar.gz"; }
  fi
  if [[ -d "${path}/wp-content/themes" ]]; then
    tar -C "${path}/wp-content" -czf "${dir}/themes.tar.gz" themes 2>/dev/null \
      || { hm_warn "Tar themes nieudany."; rm -f "${dir}/themes.tar.gz"; }
  fi
  # core files list (opcjonalnie — mały marker wersji)
  {
    echo "domain=${HM_SITE_DOMAIN}"
    echo "path=${path}"
    echo "db=${dbname}"
    echo "reason=${reason}"
    echo "stamp=${stamp}"
    echo "created=$(date -Is)"
    echo "user=${user}"
  } > "${dir}/meta.txt"
  chown -R "${user}:${user}" "${dir}" 2>/dev/null || true
  printf '%s\n' "${stamp}"
}

hm_wp_snap_rollback() {
  local stamp="${1:-}"
  local base dir path dbname user
  [[ -n "${stamp}" ]] || {
    hm_err "Użycie: wp rollback <stamp>"
    return 1
  }
  base="$(hm_wp_snap_root)" || return 1
  dir="${base}/${stamp}"
  [[ -d "${dir}" && -f "${dir}/meta.txt" ]] || {
    hm_err "Brak snapshotu: ${stamp}"
    return 1
  }
  path="$(awk -F= '/^path=/{print substr($0,6); exit}' "${dir}/meta.txt")"
  dbname="$(awk -F= '/^db=/{print substr($0,4); exit}' "${dir}/meta.txt")"
  [[ -n "${path}" && -d "${path}" ]] || path="$(hm_wp_resolve_path)" || return 1
  [[ -n "${dbname}" ]] || dbname="$(hm_wp_db_name "${path}")" || return 1
  user="$(hm_access_require_site_user "${HM_SITE_DOMAIN}")" || return 1

  if ! hm_confirm_plan_critical "${HM_SITE_DOMAIN}" "wp rollback — ${stamp}" \
    "Przywrócenie DB + plugins/themes ze snapshotu ${stamp} (nadpisze bieżący stan)." \
    "Import ${dir}/db.sql.gz → ${dbname}" \
    "Rozpakowanie plugins.tar.gz / themes.tar.gz do ${path}/wp-content" \
    "ols cache flush"; then
    return 1
  fi

  if [[ -f "${dir}/db.sql.gz" ]]; then
    hm_info "Import DB ${dbname}…"
    local mcli sock=()
    mcli="$(hm_mysql_cli 2>/dev/null || true)"
    [[ -n "${mcli}" ]] || { hm_err "Brak mysql/mariadb do importu."; return 1; }
    [[ -n "${MYSQL_SOCKET:-}" ]] && sock=(--socket="${MYSQL_SOCKET}")
    if ! gunzip -c -- "${dir}/db.sql.gz" | "${mcli}" "${sock[@]}" -- "${dbname}"; then
      hm_err "Import DB nieudany."
      return 1
    fi
  fi

  if [[ -f "${dir}/plugins.tar.gz" ]]; then
    hm_info "Przywracam plugins…"
    tar -C "${path}/wp-content" -xzf "${dir}/plugins.tar.gz" || hm_warn "plugins tar rc≠0"
  fi
  if [[ -f "${dir}/themes.tar.gz" ]]; then
    hm_info "Przywracam themes…"
    tar -C "${path}/wp-content" -xzf "${dir}/themes.tar.gz" || hm_warn "themes tar rc≠0"
  fi
  chown -R "${user}:${user}" "${path}/wp-content/plugins" "${path}/wp-content/themes" 2>/dev/null || true

  if declare -F hm_ols_cache_flush >/dev/null 2>&1; then
    hm_ols_cache_flush "${HM_SITE_DOMAIN}" 2>/dev/null || true
  fi
  hm_ok "Rollback ${stamp} zakończony."
}
