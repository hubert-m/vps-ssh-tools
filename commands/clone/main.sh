#!/usr/bin/env bash
# clone / staging / deploy — kopia strony (pliki+DB), staging WP, wypchnięcie na produkcję

_hm_cmd_help clone <<'EOF'
Użycie (globalnie):
  clone <źródło> <cel> [--db-only|--files-only] [--no-index] [--basic-auth] [--yes]
  clone help

Użycie (kontekst [domena]>):
  clone <cel> […]                 Kopia bieżącej strony → cel (np. staging.example.pl)
  staging                         Lista stagingów powiązanych z tą stroną
  deploy <produkcja> [--files] [--db] [--exclude PATH] [--yes]
  deploy rollback <stamp> [--yes]

Klon: rsync docroot + nowa baza + podmiana URL (WP: wp search-replace; inaczej .env APP_URL).
Staging: blog_public=0, X-Robots-Tag noindex, opcjonalnie HTTP basic auth (.htaccess).
Deploy: obowiązkowy lokalny snapshot produkcji przed zmianami; rollback z stamp.
EOF

_hm_cmd_help staging <<'EOF'
Użycie (kontekst [domena]>):
  staging                         Lista stagingów (.hmtools-staging)
  staging deploy <produkcja> […]  Alias: deploy <produkcja> (gdy arg = domena)

Deploy (też jako komenda „deploy” gdy pierwszym argumentem jest domena):
  deploy <produkcja> [--files] [--db] [--exclude PATH] [--yes]
  deploy rollback <stamp> [--yes]   — snapshot z /var/lib/hmtools/deploy-snaps/

Przed deploy: lokalny snapshot produkcji; confirm_critical z nazwą domeny prod.
EOF

# --- ścieżki / registry ------------------------------------------------------

hm_clone_registry_path() {
  local root="${1:-${HM_SITE_ROOT:-}}"
  [[ -n "${root}" ]] || return 1
  printf '%s/.hmtools-staging' "${root}"
}

hm_clone_marker_path() {
  local root="${1:-${HM_SITE_ROOT:-}}"
  [[ -n "${root}" ]] || return 1
  printf '%s/.hmtools-clone-of' "${root}"
}

hm_clone_snap_root() {
  local domain="${1:-}"
  printf '%s/deploy-snaps/%s' "${HMTOOLS_STATE_DIR:-/var/lib/hmtools}" "${domain}"
}

hm_clone_db_name_for_domain() {
  # staging.example.pl → staging_example_pl (max 64, tylko [A-Za-z0-9_])
  local d="${1:-}" n
  n="$(printf '%s' "${d}" | tr '.-' '__' | tr -cd 'A-Za-z0-9_')"
  [[ -n "${n}" ]] || n="site_db"
  [[ "${n}" =~ ^[0-9] ]] && n="d_${n}"
  printf '%s' "${n:0:64}"
}

hm_clone_is_staging_name() {
  local src="$1" dst="$2"
  [[ "${dst}" == "staging.${src}" || "${dst}" == "stage.${src}" || "${dst}" == "dev.${src}" ]]
}

hm_clone_registry_add() {
  local prod_root="$1" staging_domain="$2" flags="${3:-}"
  local reg
  reg="$(hm_clone_registry_path "${prod_root}")" || return 1
  mkdir -p "$(dirname "${reg}")" 2>/dev/null || true
  touch "${reg}"
  # usuń duplikat
  if [[ -f "${reg}" ]]; then
    local tmp
    tmp="$(hm_mktemp .stg)"
    grep -vE "^${staging_domain}\\|" "${reg}" > "${tmp}" 2>/dev/null || true
    cat "${tmp}" > "${reg}"
    rm -f "${tmp}"
  fi
  printf '%s|%s|%s\n' "${staging_domain}" "$(date -Is 2>/dev/null || date)" "${flags}" >> "${reg}"
}

hm_clone_registry_list() {
  local reg
  reg="$(hm_clone_registry_path "${HM_SITE_ROOT:-}")" || {
    hm_info "Brak HM_SITE_ROOT."
    return 0
  }
  echo "${C_BOLD}Staging — ${HM_SITE_DOMAIN:-?}${C_RESET}"
  if [[ ! -f "${reg}" ]] || [[ ! -s "${reg}" ]]; then
    echo "  (brak — utwórz: clone staging.${HM_SITE_DOMAIN:-domena})"
    return 0
  fi
  local line dom when flags
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" && "${line}" != \#* ]] || continue
    IFS='|' read -r dom when flags <<<"${line}"
    printf '  %-40s  %s  %s\n' "${dom}" "${when}" "${flags}"
  done < "${reg}"
}

hm_clone_write_marker() {
  local staging_root="$1" prod_domain="$2"
  local m
  m="$(hm_clone_marker_path "${staging_root}")" || return 1
  printf 'prod=%s\ncreated=%s\n' "${prod_domain}" "$(date -Is 2>/dev/null || date)" > "${m}"
  chmod 0640 "${m}" 2>/dev/null || true
}

hm_clone_read_prod_from_marker() {
  local root="${1:-${HM_SITE_ROOT:-}}"
  local m
  m="$(hm_clone_marker_path "${root}")" || return 1
  [[ -f "${m}" ]] || return 1
  awk -F= '/^prod=/{print substr($0,6); exit}' "${m}"
}

# --- rsync / ownership -------------------------------------------------------

hm_clone_rsync_excludes() {
  # wypisz argumenty --exclude=… (stdout, spacje OK przez printf %q nie — wołamy tablicą)
  local e
  for e in ${BACKUP_EXCLUDES:-./node_modules ./.git ./tmp ./temp ./cache *.log}; do
    [[ -n "${e}" ]] || continue
    # względne do docroot: zdejmij ./public_html/ jeśli obecne
    e="${e#./}"
    e="${e#public_html/}"
    printf '%s\n' "${e}"
  done
  printf '%s\n' '.hmtools-snap' '.hmtools-staging' '.hmtools-clone-of' '.hmtools-malware'
}

hm_clone_rsync_docroot() {
  local src="$1" dst="$2"
  shift 2 || true
  local -a extra_excl=("$@")
  local -a args=(-aHAX --delete)
  local e
  while IFS= read -r e; do
    [[ -n "${e}" ]] && args+=(--exclude="${e}")
  done < <(hm_clone_rsync_excludes)
  for e in "${extra_excl[@]}"; do
    [[ -n "${e}" ]] && args+=(--exclude="${e}")
  done
  [[ -d "${src}" ]] || { hm_err "Brak źródła: ${src}"; return 1; }
  mkdir -p "${dst}" || return 1
  hm_info "rsync ${src}/ → ${dst}/"
  if ! rsync "${args[@]}" -- "${src}/" "${dst}/"; then
    hm_err "rsync nieudany."
    return 1
  fi
  return 0
}

hm_clone_rsync_dry_run() {
  local src="$1" dst="$2"
  shift 2 || true
  local -a extra_excl=("$@")
  local -a args=(-aHAX --delete --dry-run --itemize-changes)
  local e
  while IFS= read -r e; do
    [[ -n "${e}" ]] && args+=(--exclude="${e}")
  done < <(hm_clone_rsync_excludes)
  for e in "${extra_excl[@]}"; do
    [[ -n "${e}" ]] && args+=(--exclude="${e}")
  done
  rsync "${args[@]}" -- "${src}/" "${dst}/" 2>/dev/null | head -80
}

hm_clone_fix_ownership() {
  local root="$1" user="$2" docroot="${3:-}"
  if declare -F hm_backup_restore_fix_ownership >/dev/null 2>&1; then
    hm_backup_restore_fix_ownership "${root}" "${user}" "${docroot}"
    return $?
  fi
  local webgrp
  webgrp="$(hm_os_web_group 2>/dev/null || echo nogroup)"
  chown -R "${user}:${user}" -- "${root}" 2>/dev/null || true
  [[ -n "${docroot}" && -d "${docroot}" ]] && chown "${user}:${webgrp}" -- "${docroot}" 2>/dev/null || true
}

# --- DB ----------------------------------------------------------------------

hm_clone_detect_src_db() {
  local docroot="${1:-${HM_SITE_DOCROOT:-}}"
  local path line
  if declare -F hm_wp_find_path >/dev/null 2>&1; then
    path="$(hm_wp_find_path "${docroot}" 2>/dev/null || true)"
    if [[ -n "${path}" ]]; then
      line="$(hm_wp_db_name "${path}" 2>/dev/null || true)"
      [[ -n "${line}" ]] && { printf '%s' "${line}"; return 0; }
    fi
  fi
  if [[ -f "${docroot}/.env" ]]; then
    line="$(hm_extract_db_from_file "${docroot}/.env" env 2>/dev/null | head -1 || true)"
    [[ -n "${line}" ]] && { printf '%s' "${line%%$'\t'*}"; return 0; }
  fi
  hm_mysql_default_db_for_site 2>/dev/null || return 1
}

hm_clone_mysql_create_quiet() {
  # bez confirm — caller już potwierdził. Hasło → plik 0600 ($3), nigdy stdout/applog.
  local dbname="$1" dbuser="${2:-$1}" passfile="$3"
  local pass uq pq sqlf
  [[ -n "${passfile}" ]] || return 1
  hm_is_valid_db_name "${dbname}" || return 1
  hm_is_valid_db_name "${dbuser}" || return 1
  if hm_mysql_db_exists "${dbname}"; then
    hm_err "Baza już istnieje: ${dbname}"
    return 1
  fi
  pass="$(hm_gen_password)"
  [[ ${#pass} -ge 12 ]] || return 1
  uq="$(hm_sql_quote "${dbuser}")"
  pq="$(hm_sql_quote "${pass}")"
  hm_mysql_exec -e "CREATE DATABASE \`${dbname}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || return 1
  sqlf="$(hm_mktemp .sql)"
  chmod 600 "${sqlf}"
  printf 'CREATE USER %s@'\''localhost'\'' IDENTIFIED BY %s;\n' "${uq}" "${pq}" > "${sqlf}"
  if ! hm_mysql_exec < "${sqlf}"; then
    rm -f "${sqlf}"
    return 1
  fi
  rm -f "${sqlf}"
  hm_mysql_exec -e "GRANT ALL PRIVILEGES ON \`${dbname}\`.* TO ${uq}@'localhost'; FLUSH PRIVILEGES;" || return 1
  umask 077
  printf '%s' "${pass}" > "${passfile}"
  chmod 600 "${passfile}"
  pass=""
}

hm_clone_mysql_import_quiet() {
  local dbname="$1" file="$2"
  local cli sock_args=()
  hm_is_valid_db_name "${dbname}" || return 1
  hm_mysql_db_exists "${dbname}" || return 1
  [[ -f "${file}" ]] || return 1
  cli="$(hm_mysql_cli)" || return 1
  [[ -n "${MYSQL_SOCKET:-}" ]] && sock_args=(--socket="${MYSQL_SOCKET}")
  if [[ "${file}" == *.gz ]]; then
    gunzip -c -- "${file}" | "${cli}" "${sock_args[@]}" -- "${dbname}"
  else
    "${cli}" "${sock_args[@]}" -- "${dbname}" < "${file}"
  fi
}

hm_clone_update_wp_config() {
  local path="$1" dbname="$2" dbuser="$3" passfile="$4"
  local pass
  [[ -f "${path}/wp-config.php" ]] || return 1
  pass="$(cat "${passfile}")"
  # WP-CLI jeśli dostępne w kontekście
  if declare -F hm_wp_run >/dev/null 2>&1 && hm_wp_ensure_cli >/dev/null 2>&1; then
    hm_wp_run 1 config set DB_NAME "${dbname}" --type=constant >/dev/null 2>&1 || true
    hm_wp_run 1 config set DB_USER "${dbuser}" --type=constant >/dev/null 2>&1 || true
    # hasło przez plik — uniknij argv
    local tmpphp
    tmpphp="$(hm_mktemp .php)"
    chmod 600 "${tmpphp}"
    cat > "${tmpphp}" <<'PHPEOF'
<?php
$path = $argv[1]; $pass = file_get_contents($argv[2]);
$c = file_get_contents($path);
$c = preg_replace("/define\(\s*'DB_PASSWORD'\s*,\s*'[^']*'\s*\)/", "define('DB_PASSWORD', '" . addslashes(trim($pass)) . "')", $c, 1);
file_put_contents($path, $c);
PHPEOF
    php -f "${tmpphp}" -- "${path}/wp-config.php" "${passfile}" 2>/dev/null \
      || hm_wp_run 1 config set DB_PASSWORD "${pass}" --type=constant >/dev/null 2>&1 || true
    rm -f "${tmpphp}"
    return 0
  fi
  return 1
}

hm_clone_update_env_db() {
  local envf="$1" dbname="$2" dbuser="$3" passfile="$4" new_url="${5:-}"
  [[ -f "${envf}" ]] || return 1
  local tmp pass
  pass="$(cat "${passfile}")"
  tmp="$(hm_mktemp .env)"
  chmod 600 "${tmp}"
  awk -v db="${dbname}" -v user="${dbuser}" -v pass="${pass}" -v url="${new_url}" '
    BEGIN { FS=OFS="=" }
    /^DB_DATABASE=/ { print "DB_DATABASE=" db; next }
    /^DB_USERNAME=/ { print "DB_USERNAME=" user; next }
    /^DB_PASSWORD=/ { print "DB_PASSWORD=\"" pass "\""; next }
    /^APP_URL=/ && url != "" { print "APP_URL=" url; next }
    { print }
  ' "${envf}" > "${tmp}"
  cat "${tmp}" > "${envf}"
  rm -f "${tmp}"
}

# --- staging hardening -------------------------------------------------------

hm_clone_apply_basic_auth() {
  local domain="$1" docroot="$2" user_site="${3:-}"
  local passfile htuser htpass
  htuser="staging"
  htpass="$(hm_gen_password | head -c 16)"
  passfile="${docroot}/.htpasswd.hmtools"
  if hm_have_cmd htpasswd; then
    htpasswd -nbB "${htuser}" "${htpass}" > "${passfile}" 2>/dev/null \
      || htpasswd -nb "${htuser}" "${htpass}" > "${passfile}"
  else
    # openssl apr1 fallback
    local hash
    hash="$(openssl passwd -apr1 "${htpass}" 2>/dev/null || openssl passwd -1 "${htpass}" 2>/dev/null || true)"
    if [[ -n "${hash}" ]]; then
      printf '%s:%s\n' "${htuser}" "${hash}" > "${passfile}"
    else
      hm_warn "Brak htpasswd/openssl — pomijam basic-auth."
      return 0
    fi
  fi
  chmod 640 "${passfile}" 2>/dev/null || true
  [[ -n "${user_site}" ]] && chown "${user_site}:${user_site}" "${passfile}" 2>/dev/null || true

  cat > "${docroot}/.htaccess.hmtools-staging" <<EOF
# hmtools staging basic-auth — dołączane przez .htaccess lub OLS autoLoadHtaccess
AuthType Basic
AuthName "Staging ${domain}"
AuthUserFile ${passfile}
Require valid-user
EOF
  if [[ -f "${docroot}/.htaccess" ]]; then
    if ! grep -qF 'hmtools-staging' "${docroot}/.htaccess" 2>/dev/null; then
      {
        echo "# BEGIN hmtools-staging"
        echo "AuthType Basic"
        echo "AuthName \"Staging ${domain}\""
        echo "AuthUserFile ${passfile}"
        echo "Require valid-user"
        echo "# END hmtools-staging"
        cat "${docroot}/.htaccess"
      } > "${docroot}/.htaccess.new"
      mv "${docroot}/.htaccess.new" "${docroot}/.htaccess"
    fi
  else
    cp -a "${docroot}/.htaccess.hmtools-staging" "${docroot}/.htaccess"
  fi
  hm_ok "Basic auth: user=${htuser}  hasło (raz): ${htpass}"
  hm_info "Upewnij się, że vhost ma autoLoadHtaccess 1 (OLS)."
}

hm_clone_wp_staging_options() {
  local domain="$1"
  declare -F hm_wp_run >/dev/null 2>&1 || return 0
  hm_site_context_push "${domain}" || return 0
  if hm_wp_find_path "${HM_SITE_DOCROOT}" >/dev/null 2>&1; then
    hm_wp_run 1 option update blog_public 0 >/dev/null 2>&1 || true
  fi
  hm_site_context_pop
}

hm_clone_wp_search_replace() {
  local domain="$1" old="$2" new="$3"
  hm_site_context_push "${domain}" || return 1
  if ! declare -F hm_wp_run >/dev/null 2>&1 || ! hm_wp_find_path "${HM_SITE_DOCROOT}" >/dev/null 2>&1; then
    hm_site_context_pop
    return 0
  fi
  hm_info "WP search-replace ${old} → ${new}"
  hm_wp_run 0 search-replace "https://${old}" "https://${new}" --all-tables --report-changed-only 2>/dev/null || true
  hm_wp_run 0 search-replace "http://${old}" "http://${new}" --all-tables --report-changed-only 2>/dev/null || true
  hm_wp_run 0 search-replace "https://www.${old}" "https://${new}" --all-tables --report-changed-only 2>/dev/null || true
  hm_wp_run 0 search-replace "${old}" "${new}" --all-tables --report-changed-only 2>/dev/null || true
  hm_site_context_pop
}

# --- ensure target site ------------------------------------------------------

hm_clone_ensure_target_site() {
  local src="$1" dst="$2" php_ver="${3:-}"
  if hm_find_site_by_arg_exact "${dst}" >/dev/null 2>&1; then
    hm_info "Cel ${dst} już istnieje — używam."
    return 0
  fi
  [[ -n "${php_ver}" && "${php_ver}" != "?" ]] || php_ver="8.2"
  if ! declare -F cmd_site_create >/dev/null 2>&1; then
    hm_err "Brak site create — utwórz najpierw domenę ${dst}."
    return 1
  fi
  hm_info "Tworzę stronę docelową ${dst} (php ${php_ver})…"
  if hm_clone_is_staging_name "${src}" "${dst}"; then
    cmd_site_create "${dst}" --child-of "${src}" --php "${php_ver}" --yes || return 1
  else
    cmd_site_create "${dst}" --php "${php_ver}" --yes || return 1
  fi
}

# --- clone core --------------------------------------------------------------

hm_clone_run() {
  local src="$1" dst="$2"
  shift 2 || true
  local files=1 db=1 noindex=0 basic=0 yes=0 a
  # staging.* domyślnie noindex
  hm_clone_is_staging_name "${src}" "${dst}" && noindex=1

  while [[ $# -gt 0 ]]; do
    a="$1"; shift || true
    case "${a}" in
      --db-only) files=0; db=1 ;;
      --files-only) files=1; db=0 ;;
      --no-index) noindex=1 ;;
      --basic-auth) basic=1 ;;
      --yes|-y) yes=1 ;;
      help|-h|--help) hm_help_topic clone; return 0 ;;
      -*) hm_err "Nieznana flaga: ${a}"; return 1 ;;
      *) hm_err "Za dużo argumentów: ${a}"; return 1 ;;
    esac
  done

  hm_is_valid_domain "${src}" || { hm_err "Nieprawidłowe źródło: ${src}"; return 1; }
  hm_is_valid_domain "${dst}" || { hm_err "Nieprawidłowy cel: ${dst}"; return 1; }
  [[ "${src}" != "${dst}" ]] || { hm_err "Źródło i cel muszą być różne."; return 1; }

  local src_exact
  src_exact="$(hm_find_site_by_arg_exact "${src}" 2>/dev/null || true)"
  [[ -n "${src_exact}" ]] || { hm_err "Źródło ${src} nie istnieje (webs)."; return 1; }
  src="${src_exact}"

  # kontekst źródła
  hm_site_context_push "${src}" || return 1
  local src_root="${HM_SITE_ROOT}" src_doc="${HM_SITE_DOCROOT}" src_user="${HM_SITE_USER}" src_php="${HM_SITE_PHP}"
  local src_db=""
  if [[ "${db}" -eq 1 ]]; then
    src_db="$(hm_clone_detect_src_db "${src_doc}" 2>/dev/null || true)"
    [[ -n "${src_db}" ]] || {
      hm_warn "Brak wykrytej bazy — kontynuuję tylko pliki (jak --files-only)."
      db=0
    }
  fi
  hm_site_context_pop

  local -a plan=(
    "Cel: ${dst} (utworzenie jeśli brak — child gdy staging.*)"
  )
  [[ "${files}" -eq 1 ]] && plan+=("rsync docroot ${src} → ${dst} (excludes BACKUP_EXCLUDES)")
  if [[ "${db}" -eq 1 ]]; then
    plan+=("Dump ${src_db} → nowa baza + user dla ${dst}")
    plan+=("Aktualizacja wp-config / .env + search-replace URL")
  fi
  [[ "${noindex}" -eq 1 ]] && plan+=("noindex: blog_public=0 + X-Robots-Tag vhconf")
  [[ "${basic}" -eq 1 ]] && plan+=("HTTP basic auth (.htaccess + htpasswd)")
  plan+=("chown właściciela docelowego (grupa WWW na public_html)")

  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "clone ${src} → ${dst}" "Produkcja ${src} nie jest nadpisywana." --yes "${plan[@]}" || return 1
  else
    hm_confirm_plan "clone ${src} → ${dst}" "Produkcja ${src} nie jest nadpisywana." "${plan[@]}" || return 1
  fi

  hm_clone_ensure_target_site "${src}" "${dst}" "${src_php}" || return 1

  hm_site_context_push "${dst}" || return 1
  local dst_root="${HM_SITE_ROOT}" dst_doc="${HM_SITE_DOCROOT}" dst_user="${HM_SITE_USER}"
  hm_site_context_pop

  [[ -n "${dst_doc}" && -d "${dst_doc}" ]] || {
    hm_err "Brak docroot celu ${dst}."
    return 1
  }
  [[ -n "${dst_user}" ]] || {
    hm_err "Brak użytkownika Unix dla ${dst}."
    return 1
  }

  if [[ "${files}" -eq 1 ]]; then
    hm_clone_rsync_docroot "${src_doc}" "${dst_doc}" || return 1
  fi

  local new_db="" new_user="" passfile=""
  if [[ "${db}" -eq 1 ]]; then
    new_db="$(hm_clone_db_name_for_domain "${dst}")"
    # kolizja nazwy → sufiks
    local try="${new_db}" i=0
    while hm_mysql_db_exists "${try}" 2>/dev/null; do
      i=$((i + 1))
      try="${new_db:0:60}_${i}"
      [[ "${i}" -lt 20 ]] || { hm_err "Nie dobiorę wolnej nazwy DB."; return 1; }
    done
    new_db="${try}"
    new_user="${new_db}"
    passfile="$(hm_mktemp .dbpass)"
    chmod 600 "${passfile}"
    local dumpf
    dumpf="$(hm_mktemp .sql.gz)"
    chmod 600 "${dumpf}"
    hm_info "Dump źródłowej bazy ${src_db}…"
    if ! hm_mysql_dump_local "${src_db}" "${dumpf}"; then
      rm -f "${passfile}" "${dumpf}"
      return 1
    fi
    if ! hm_clone_mysql_create_quiet "${new_db}" "${new_user}" "${passfile}"; then
      rm -f "${passfile}" "${dumpf}"
      return 1
    fi
    hm_info "Import → ${new_db}…"
    if ! hm_clone_mysql_import_quiet "${new_db}" "${dumpf}"; then
      rm -f "${passfile}" "${dumpf}"
      hm_err "Import DB nieudany."
      return 1
    fi
    rm -f "${dumpf}"

    hm_site_context_push "${dst}" || return 1
    local wpp
    wpp="$(hm_wp_find_path "${HM_SITE_DOCROOT}" 2>/dev/null || true)"
    if [[ -n "${wpp}" ]]; then
      hm_clone_update_wp_config "${wpp}" "${new_db}" "${new_user}" "${passfile}" || true
    fi
    if [[ -f "${HM_SITE_DOCROOT}/.env" ]]; then
      hm_clone_update_env_db "${HM_SITE_DOCROOT}/.env" "${new_db}" "${new_user}" "${passfile}" "https://${dst}"
    fi
    hm_site_context_pop
    rm -f "${passfile}"

    hm_clone_wp_search_replace "${dst}" "${src}" "${dst}"
  fi

  if [[ "${noindex}" -eq 1 ]]; then
    hm_clone_wp_staging_options "${dst}"
    # vhconf bez ponownego confirm (plan już zaakceptowany)
    local conf
    conf="$(hm_vhost_conf_path "${dst}" 2>/dev/null || true)"
    if [[ -n "${conf}" && -f "${conf}" ]] && declare -F hm_ols_vhost_strip_block >/dev/null 2>&1; then
      local tmp bak
      tmp="$(hm_mktemp .vhconf)"
      bak="${conf}.hmtools.$(date +%Y%m%d%H%M%S)"
      cp -a "${conf}" "${bak}" 2>/dev/null || true
      hm_ols_vhost_strip_block "${conf}" "staging" "${tmp}"
      {
        cat "${tmp}"
        echo "# hmtools:staging BEGIN"
        echo "extraHeaders              <<<END_hmtools_staging"
        echo "X-Robots-Tag noindex, nofollow"
        echo "  END_hmtools_staging"
        echo "# hmtools:staging END"
      } > "${tmp}.new"
      if declare -F hm_ols_vhost_write >/dev/null 2>&1; then
        hm_ols_vhost_write "${conf}" "${tmp}.new" || cat "${tmp}.new" > "${conf}"
      else
        cat "${tmp}.new" > "${conf}"
      fi
      rm -f "${tmp}" "${tmp}.new"
      hm_ols_reload_soft 2>/dev/null || true
      hm_ok "X-Robots-Tag noindex w vhconf ${dst}"
    fi
  fi

  if [[ "${basic}" -eq 1 ]]; then
    hm_clone_apply_basic_auth "${dst}" "${dst_doc}" "${dst_user}"
  fi

  hm_clone_fix_ownership "${dst_root}" "${dst_user}" "${dst_doc}"

  # registry na produkcji
  hm_site_context_push "${src}" || true
  hm_clone_registry_add "${HM_SITE_ROOT}" "${dst}" "noindex=${noindex};basic=${basic}"
  hm_site_context_pop
  hm_clone_write_marker "${dst_root}" "${src}"

  hm_ok "Klon ${src} → ${dst} gotowy."
  if [[ "${db}" -eq 1 ]]; then
    hm_info "Nowa baza: ${new_db} (hasło w wp-config/.env — nie logowane)."
  fi
  return 0
}

# --- deploy ------------------------------------------------------------------

hm_clone_snap_prod() {
  local prod="$1"
  local stamp dir docroot root user dbname
  hm_site_context_push "${prod}" || return 1
  root="${HM_SITE_ROOT}"
  docroot="${HM_SITE_DOCROOT}"
  user="${HM_SITE_USER}"
  dbname="$(hm_clone_detect_src_db "${docroot}" 2>/dev/null || true)"
  stamp="$(date +%Y%m%d-%H%M%S)"
  dir="$(hm_clone_snap_root "${prod}")/${stamp}"
  mkdir -p "${dir}" || { hm_site_context_pop; return 1; }
  chmod 700 "$(hm_clone_snap_root "${prod}")" "${dir}" 2>/dev/null || true

  hm_info "Snapshot produkcji ${prod} → ${dir}"
  if [[ -d "${docroot}" ]]; then
    tar -C "${docroot}" -czf "${dir}/files.tar.gz" . 2>/dev/null || {
      hm_err "Tar plików produkcji nieudany."
      hm_site_context_pop
      rm -rf -- "${dir}"
      return 1
    }
  fi
  if [[ -n "${dbname}" ]]; then
    hm_mysql_dump_local "${dbname}" "${dir}/db.sql.gz" || {
      hm_site_context_pop
      rm -rf -- "${dir}"
      return 1
    }
    printf '%s\n' "${dbname}" > "${dir}/db.name"
  fi
  {
    echo "domain=${prod}"
    echo "docroot=${docroot}"
    echo "root=${root}"
    echo "user=${user}"
    echo "stamp=${stamp}"
    echo "created=$(date -Is 2>/dev/null || date)"
  } > "${dir}/meta.txt"
  hm_site_context_pop
  printf '%s\n' "${stamp}"
}

hm_clone_deploy_rollback() {
  local stamp="${1:-}" yes=0
  shift || true
  [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && yes=1
  local prod="${HM_SITE_DOMAIN:-}"
  [[ -n "${prod}" ]] || { hm_err "Kontekst: use <produkcja> → deploy rollback <stamp>"; return 1; }
  [[ -n "${stamp}" ]] || { hm_err "Użycie: deploy rollback <stamp>"; return 1; }
  local dir docroot dbname user
  dir="$(hm_clone_snap_root "${prod}")/${stamp}"
  [[ -d "${dir}" && -f "${dir}/meta.txt" ]] || { hm_err "Brak snapshu: ${stamp}"; return 1; }
  docroot="$(awk -F= '/^docroot=/{print substr($0,9); exit}' "${dir}/meta.txt")"
  user="$(awk -F= '/^user=/{print substr($0,6); exit}' "${dir}/meta.txt")"
  [[ -n "${docroot}" ]] || docroot="${HM_SITE_DOCROOT}"
  dbname=""
  [[ -f "${dir}/db.name" ]] && dbname="$(tr -d '[:space:]' < "${dir}/db.name")"

  local -a plan=("Przywrócenie plików z ${dir}/files.tar.gz → ${docroot}")
  [[ -n "${dbname}" && -f "${dir}/db.sql.gz" ]] && plan+=("Import ${dir}/db.sql.gz → ${dbname}")

  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan_critical "${prod}" "deploy rollback — ${stamp}" \
      "Nadpisanie bieżącej produkcji stanem ze snapshotu." --yes "${plan[@]}" || return 1
  else
    hm_confirm_plan_critical "${prod}" "deploy rollback — ${stamp}" \
      "Nadpisanie bieżącej produkcji stanem ze snapshotu." "${plan[@]}" || return 1
  fi

  if [[ -f "${dir}/files.tar.gz" ]]; then
    tar -C "${docroot}" -xzf "${dir}/files.tar.gz" || return 1
  fi
  if [[ -n "${dbname}" && -f "${dir}/db.sql.gz" ]]; then
    hm_clone_mysql_import_quiet "${dbname}" "${dir}/db.sql.gz" || return 1
  fi
  [[ -n "${user}" ]] && hm_clone_fix_ownership "${HM_SITE_ROOT}" "${user}" "${docroot}"
  hm_ok "Rollback ${stamp} → ${prod}"
}

hm_clone_deploy() {
  local prod="${1:-}"
  shift || true
  local do_files=0 do_db=0 yes=0
  local -a excludes=()
  local a

  if [[ "${prod}" == "rollback" ]]; then
    hm_clone_deploy_rollback "$@"
    return $?
  fi

  # domyślnie oba
  local explicit=0
  while [[ $# -gt 0 ]]; do
    a="$1"; shift || true
    case "${a}" in
      --files) do_files=1; explicit=1 ;;
      --db) do_db=1; explicit=1 ;;
      --exclude)
        excludes+=("${1:-}"); shift || true ;;
      --exclude=*)
        excludes+=("${a#--exclude=}") ;;
      --yes|-y) yes=1 ;;
      help|-h|--help) hm_help_topic deploy; return 0 ;;
      -*) hm_err "Nieznana flaga: ${a}"; return 1 ;;
      *)
        if [[ -z "${prod}" || "${prod}" == --* ]]; then prod="${a}"
        else hm_err "Za dużo argumentów"; return 1
        fi
        ;;
    esac
  done
  [[ "${explicit}" -eq 0 ]] && { do_files=1; do_db=1; }

  local staging="${HM_SITE_DOMAIN:-}"
  [[ -n "${staging}" ]] || { hm_err "Wejdź w kontekst staging: use staging.example.pl"; return 1; }
  hm_is_valid_domain "${prod}" || { hm_err "Nieprawidłowa produkcja: ${prod}"; return 1; }

  local marked
  marked="$(hm_clone_read_prod_from_marker 2>/dev/null || true)"
  if [[ -n "${marked}" && "${marked}" != "${prod}" ]]; then
    hm_warn "Marker wskazuje prod=${marked}, a podano ${prod}."
  fi

  local prod_exact
  prod_exact="$(hm_find_site_by_arg_exact "${prod}" 2>/dev/null || true)"
  [[ -n "${prod_exact}" ]] || { hm_err "Produkcja ${prod} nie istnieje."; return 1; }
  prod="${prod_exact}"

  # obowiązkowy snapshot PRZED planem mutacji
  local stamp
  stamp="$(hm_clone_snap_prod "${prod}")" || {
    hm_err "Snapshot produkcji wymagany — deploy przerwany (brak zmian)."
    return 1
  }
  hm_ok "Snapshot produkcji: ${stamp}"

  local st_doc pr_doc
  hm_site_context_push "${staging}" || return 1
  st_doc="${HM_SITE_DOCROOT}"
  hm_site_context_pop
  hm_site_context_push "${prod}" || return 1
  pr_doc="${HM_SITE_DOCROOT}"
  local pr_root="${HM_SITE_ROOT}" pr_user="${HM_SITE_USER}"
  hm_site_context_pop

  echo "${C_BOLD}Podgląd różnic (rsync dry-run, max 80 linii):${C_RESET}"
  hm_clone_rsync_dry_run "${st_doc}" "${pr_doc}" "${excludes[@]}" || true
  echo

  local -a plan=(
    "Snapshot lokalny już zapisany: $(hm_clone_snap_root "${prod}")/${stamp}"
  )
  [[ "${do_files}" -eq 1 ]] && plan+=("rsync staging→prod docroot (--delete, excludes)")
  [[ "${do_db}" -eq 1 ]] && plan+=("Dump DB staging → import na produkcję + search-replace URL")
  plan+=("Rollback: deploy rollback ${stamp} (w kontekście produkcji)")

  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan_critical "${prod}" "deploy ${staging} → ${prod}" \
      "NADPISANIE PRODUKCJI. Snapshot: ${stamp}" --yes "${plan[@]}" || return 1
  else
    hm_confirm_plan_critical "${prod}" "deploy ${staging} → ${prod}" \
      "NADPISANIE PRODUKCJI. Snapshot: ${stamp}" "${plan[@]}" || return 1
  fi

  if [[ "${do_files}" -eq 1 ]]; then
    hm_clone_rsync_docroot "${st_doc}" "${pr_doc}" "${excludes[@]}" || return 1
  fi

  if [[ "${do_db}" -eq 1 ]]; then
    local st_db pr_db dumpf
    hm_site_context_push "${staging}" || return 1
    st_db="$(hm_clone_detect_src_db 2>/dev/null || true)"
    hm_site_context_pop
    hm_site_context_push "${prod}" || return 1
    pr_db="$(hm_clone_detect_src_db 2>/dev/null || true)"
    hm_site_context_pop
    [[ -n "${st_db}" && -n "${pr_db}" ]] || {
      hm_err "Brak DB staging/prod — pomiń --db lub sklonuj z bazą."
      return 1
    }
    dumpf="$(hm_mktemp .sql.gz)"
    chmod 600 "${dumpf}"
    hm_mysql_dump_local "${st_db}" "${dumpf}" || { rm -f "${dumpf}"; return 1; }
    hm_clone_mysql_import_quiet "${pr_db}" "${dumpf}" || { rm -f "${dumpf}"; return 1; }
    rm -f "${dumpf}"
    # URL staging → prod
    hm_clone_wp_search_replace "${prod}" "${staging}" "${prod}"
  fi

  hm_clone_fix_ownership "${pr_root}" "${pr_user}" "${pr_doc}"
  hm_ok "Deploy ${staging} → ${prod} OK. Rollback: use ${prod} → deploy rollback ${stamp}"
}

# --- entrypoints -------------------------------------------------------------

cmd_clone() {
  local a="${1:-}"
  case "${a}" in
    help|-h|--help) hm_help_topic clone; return 0 ;;
  esac

  if [[ -n "${HM_SITE_DOMAIN:-}" ]]; then
    # [src]> clone dst …
    local dst="${1:-}"
    shift || true
    [[ -n "${dst}" ]] || { hm_err "Użycie: clone <cel> [--db-only|--files-only] [--no-index] [--basic-auth]"; return 1; }
    hm_clone_run "${HM_SITE_DOMAIN}" "${dst}" "$@"
    return $?
  fi

  local src="${1:-}" dst="${2:-}"
  shift 2 2>/dev/null || true
  [[ -n "${src}" && -n "${dst}" ]] || {
    hm_err "Użycie: clone <źródło> <cel> …   lub w kontekście: clone <cel>"
    return 1
  }
  hm_clone_run "${src}" "${dst}" "$@"
}

cmd_staging() {
  local a="${1:-}"
  case "${a}" in
    help|-h|--help) hm_help_topic staging; return 0 ;;
    deploy|push)
      shift || true
      hm_clone_deploy "$@"
      return $?
      ;;
    list|ls|"")
      [[ -n "${HM_SITE_DOMAIN:-}" ]] || {
        hm_err "Wejdź w kontekst produkcji: use <domena> → staging"
        return 1
      }
      hm_clone_registry_list
      ;;
    *)
      hm_err "Użycie: staging | staging deploy <produkcja> …"
      return 1
      ;;
  esac
}

# Nie rejestruj cmd_deploy — kolizja z commands/git/deploy.sh.
# Routing: git cmd_deploy → hm_clone_deploy gdy arg to domena / clone-snap rollback.

_hm_cmd_register clone cmd_clone 0
_hm_cmd_register_site clone cmd_clone
_hm_cmd_register_site staging cmd_staging
