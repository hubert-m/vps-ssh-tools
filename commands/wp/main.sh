#!/usr/bin/env bash
# Moduł: wp — WordPress przez WP-CLI (jako user strony, snapshot przed zmianami)

_hm_cmd_help wp <<'EOF'
Użycie (globalnie, bez kontekstu strony):
  wp sites                         Instalacje WP: wersja, aktualizacje, maintenance, PHP
  wp install <domena> --title "…" --admin-email … [--yes]
  wp cli-info                      ścieżka i `wp --info` (bundled phar lub systemowy wp)
  wp cli-update                    pobierz oficjalny wp-cli.phar → lib/wp-cli/ (SHA-512)

WP-CLI: <hmtools>/lib/wp-cli/wp-cli.phar (dociągany przez update-hmtools / wp cli-update).
Gdy brak bundled — używany jest /usr/local/bin/wp lub /usr/bin/wp.

Użycie (kontekst [domena]>):
  wp                               Status: wersja, URL, aktualizacje, debug, cron
  wp plugins [--updates]
  wp update [core|plugins|themes|all] [--exclude slug] [--no-snapshot] [--yes]
  wp plugin activate|deactivate <slug>
  wp maintenance on|off
  wp verify                        core + plugin verify-checksums
  wp search-replace <old> <new> [--dry-run|--execute] [--yes]
  wp admin-reset <login>           nowe hasło (pokazane raz) / awaryjny admin
  wp cache flush | wp cron run
  wp rollback <stamp>              przywróć snapshot sprzed update
  wp snaps                         lista lokalnych snapshotów .hmtools-snap

WP-CLI uruchamiane jako user strony (runuser) z LSPHP strony.
Przed update/search-replace (bez --dry-run): snapshot DB + plugins/themes.
EOF

_HM_WP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=snapshot.sh
source "${_HM_WP_DIR}/snapshot.sh"
# shellcheck source=update.sh
source "${_HM_WP_DIR}/update.sh"

hm_wp_bundled_phar() {
  local root="${HMTOOLS_ROOT:-/hm-tools}"
  printf '%s' "${root}/lib/wp-cli/wp-cli.phar"
}

hm_wp_find_cli() {
  local p bundled
  bundled="$(hm_wp_bundled_phar)"
  if [[ -f "${bundled}" && -s "${bundled}" ]]; then
    printf '%s' "${bundled}"
    return 0
  fi
  for p in /usr/local/bin/wp /usr/bin/wp "$(command -v wp 2>/dev/null || true)"; do
    [[ -n "${p}" && -x "${p}" ]] || continue
    # nie bierz samego hmtools, gdyby PATH wskazał wrapper o tej nazwie
    [[ "$(basename "${p}")" == "hmtools" ]] && continue
    printf '%s' "${p}"
    return 0
  done
  return 1
}

hm_wp_ensure_cli() {
  local cli
  if cli="$(hm_wp_find_cli)"; then
    printf '%s' "${cli}"
    return 0
  fi
  hm_err "Brak WP-CLI (lib/wp-cli/wp-cli.phar ani /usr/bin/wp, /usr/local/bin/wp)."
  hm_info "Pobierz oficjalny phar (SHA-512):  wp cli-update"
  hm_info "Albo zaktualizuj hmtools:          update-hmtools  (instalator dociąga phar)"
  return 1
}

# Globalnie — bez kontekstu strony. Sam phar (shebang) albo php, gdy brak +x.
hm_wp_cli_exec() {
  local cli php
  cli="$(hm_wp_ensure_cli)" || return 1
  if [[ -x "${cli}" ]]; then
    "${cli}" "$@"
    return $?
  fi
  php=""
  if command -v php >/dev/null 2>&1; then
    php="$(command -v php)"
  elif [[ -x /usr/bin/php ]]; then
    php="/usr/bin/php"
  fi
  [[ -n "${php}" && -x "${php}" ]] || {
    hm_err "WP-CLI nie jest wykonywalny i brak php w PATH."
    return 1
  }
  "${php}" "${cli}" "$@"
}

hm_wp_cli_info() {
  local cli
  cli="$(hm_wp_ensure_cli)" || return 1
  echo "${C_BOLD}WP-CLI${C_RESET}"
  echo "  Path : ${cli}"
  if [[ "${cli}" == "$(hm_wp_bundled_phar)" ]]; then
    echo "  Źródło: hmtools (lib/wp-cli/wp-cli.phar)"
  else
    echo "  Źródło: system"
  fi
  hm_wp_cli_exec --info
}

hm_wp_cli_update() {
  local script="${HMTOOLS_ROOT:-/hm-tools}/scripts/install-wp-cli.sh"
  local dest="${HMTOOLS_ROOT:-/hm-tools}"
  [[ -f "${script}" ]] || {
    hm_err "Brak skryptu ${script}"
    return 1
  }
  if [[ ! -w "${dest}" && "$(id -u)" -ne 0 ]]; then
    hm_err "wp cli-update wymaga zapisu do ${dest}/lib/wp-cli (uruchom jako root)."
    return 1
  fi
  hm_info "Aktualizacja WP-CLI → ${dest}/lib/wp-cli/wp-cli.phar"
  if ! bash "${script}" "${dest}"; then
    hm_err "wp cli-update nieudany (phar bez zmian, jeśli podmiana nie doszła do mv)."
    return 1
  fi
  hm_ok "WP-CLI zaktualizowany."
  hm_wp_cli_info
}

# Znajdź katalog z wp-config.php (docroot + głębokość ≤2)
hm_wp_find_path() {
  local root="${1:-${HM_SITE_DOCROOT:-}}"
  local f d sub
  [[ -n "${root}" && -d "${root}" ]] || return 1
  if [[ -f "${root}/wp-config.php" ]]; then
    printf '%s' "${root}"
    return 0
  fi
  # głębokość 1
  for d in "${root}"/*/; do
    [[ -d "${d}" ]] || continue
    [[ -f "${d}/wp-config.php" ]] && { printf '%s' "${d%/}"; return 0; }
  done
  # głębokość 2
  for d in "${root}"/*/*/; do
    [[ -d "${d}" ]] || continue
    [[ -f "${d}/wp-config.php" ]] && { printf '%s' "${d%/}"; return 0; }
  done
  # czasem wp-config w parent docroot (public_html)
  if [[ -f "$(dirname "${root}")/wp-config.php" ]]; then
    printf '%s' "$(dirname "${root}")"
    return 0
  fi
  return 1
}

hm_wp_resolve_path() {
  local p
  p="$(hm_wp_find_path "${HM_SITE_DOCROOT:-}")" || {
    hm_err "Brak instalacji WordPress (wp-config.php) w ${HM_SITE_DOCROOT:-?}."
    return 1
  }
  printf '%s' "${p}"
}

hm_wp_db_name() {
  local path="${1:-}" line
  [[ -n "${path}" && -f "${path}/wp-config.php" ]] || return 1
  line="$(hm_extract_db_from_file "${path}/wp-config.php" wp | head -1 || true)"
  [[ -n "${line}" ]] || return 1
  printf '%s' "${line%%$'\t'*}"
}

hm_wp_require_site() {
  [[ -n "${HM_SITE_DOMAIN:-}" ]] || {
    hm_err "Wejdź w kontekst: use <domena>  (lub: wp sites)"
    return 1
  }
  hm_wp_ensure_cli >/dev/null || return 1
  return 0
}

# hm_wp_run [--no-skip] <wp-cli args...>
# Domyślnie --skip-themes --skip-plugins (odczyt); update/theme/plugin mutacje: skip=0
hm_wp_run() {
  local skip=1
  if [[ "${1:-}" == "0" || "${1:-}" == "--no-skip" ]]; then
    skip=0
    shift || true
  elif [[ "${1:-}" == "1" || "${1:-}" == "--skip" ]]; then
    skip=1
    shift || true
  fi
  local cli path user branch phpbin home
  cli="$(hm_wp_ensure_cli)" || return 1
  path="$(hm_wp_resolve_path)" || return 1
  user="$(hm_access_require_site_user "${HM_SITE_DOMAIN}")" || return 1
  branch="$(hm_php_branch_for_site "" 2>/dev/null || true)"
  phpbin=""
  if [[ -n "${branch}" ]]; then
    phpbin="$(hm_php_bin_for_branch "${branch}" 2>/dev/null || true)"
  fi
  home="$(getent passwd "${user}" 2>/dev/null | cut -d: -f6)"
  [[ -n "${home}" ]] || home="/home/${HM_SITE_DOMAIN}"

  local -a envp=(
    "HOME=${home}"
    "USER=${user}"
    "LOGNAME=${user}"
    "PATH=/usr/local/bin:/usr/bin:/bin"
  )
  local -a wpargs=("${cli}" --path="${path}" --allow-root)
  # --allow-root tylko gdy nie runuser; przy runuser niepotrzebne, ale nieszkodliwe bywa odrzucane
  # Lepiej bez --allow-root przy runuser:
  wpargs=("${cli}" --path="${path}")
  [[ "${skip}" -eq 1 ]] && wpargs+=(--skip-themes --skip-plugins)

  local -a cmd=()
  if [[ -n "${phpbin}" && -x "${phpbin}" ]]; then
    cmd=("${phpbin}" -d "error_reporting=0" -d "display_errors=0" "${wpargs[@]}" "$@")
  else
    cmd=("${wpargs[@]}" "$@")
  fi

  # timeout ochronny (odczyty)
  local timeout_bin=""
  if hm_have_cmd timeout; then
    timeout_bin="timeout"
  fi

  if [[ "$(id -u)" -eq 0 ]] && hm_have_cmd runuser; then
    if [[ -n "${timeout_bin}" ]]; then
      runuser -u "${user}" -- env "${envp[@]}" timeout 120 "${cmd[@]}"
    else
      runuser -u "${user}" -- env "${envp[@]}" "${cmd[@]}"
    fi
    return $?
  fi
  if [[ "$(id -u)" -eq 0 ]] && hm_have_cmd sudo; then
    sudo -u "${user}" -- env "${envp[@]}" "${cmd[@]}"
    return $?
  fi
  env "${envp[@]}" "${cmd[@]}"
}

hm_wp_site_is_wp() {
  local domain="$1" row doc
  row="$(hm_resolve_site_paths "${domain}" 2>/dev/null || true)"
  [[ -n "${row}" ]] || return 1
  IFS=$'\t' read -r _ _ doc _ <<<"${row}"
  doc="$(hm_tsv_unfield "${doc}")"
  hm_wp_find_path "${doc}" >/dev/null 2>&1
}

# --- status / sites ---
hm_wp_print_status() {
  local path ver url upd_p upd_t maint debug cronphp
  path="$(hm_wp_resolve_path)" || return 1
  echo "${C_BOLD}WordPress — ${HM_SITE_DOMAIN}${C_RESET}"
  echo "  Path     : ${path}"
  echo "  PHP      : ${HM_SITE_PHP:--}  user=${HM_SITE_USER:--}"

  ver="$(hm_wp_run 1 core version 2>/dev/null | tr -d '\r' | tail -1 || true)"
  echo "  Core     : ${ver:-?}"

  url="$(hm_wp_run 1 option get siteurl 2>/dev/null | tr -d '\r' | tail -1 || true)"
  echo "  URL      : ${url:--}"

  upd_p="$(hm_wp_run 1 plugin list --update=available --field=name 2>/dev/null | grep -c . || true)"
  upd_t="$(hm_wp_run 1 theme list --update=available --field=name 2>/dev/null | grep -c . || true)"
  [[ "${upd_p}" =~ ^[0-9]+$ ]] || upd_p=0
  [[ "${upd_t}" =~ ^[0-9]+$ ]] || upd_t=0
  echo "  Updates  : plugins=${upd_p}  themes=${upd_t}"

  if [[ -f "${path}/.maintenance" ]]; then
    maint="ON (.maintenance)"
  else
    maint="$(hm_wp_run 1 maintenance-mode status 2>/dev/null | tr -d '\r' | tail -1 || echo off)"
  fi
  echo "  Maint.   : ${maint}"

  debug="$(hm_wp_run 1 config get WP_DEBUG 2>/dev/null | tr -d '\r' | tail -1 || true)"
  echo "  WP_DEBUG : ${debug:-?}"

  cronphp="$(hm_wp_run 1 cron event list --fields=hook,next_run_relative --format=count 2>/dev/null | tr -d '\r' | tail -1 || true)"
  echo "  Cron evt : ${cronphp:-?}"
}

cmd_wp_sites() {
  hm_wp_ensure_cli >/dev/null || return 1
  hm_discover_sites
  echo "${C_BOLD}WordPress — instalacje${C_RESET}"
  printf '  %-28s %-10s %-8s %-8s %-12s %s\n' "DOMENA" "CORE" "PLUG↑" "THEME↑" "MAINT" "PHP"
  local d path ver updp updt maint row doc php
  local found=0
  for d in "${HM_SITES_LIST[@]:-}"; do
    [[ -n "${d}" ]] || continue
    row="$(hm_resolve_site_paths "${d}" 2>/dev/null || true)"
    [[ -n "${row}" ]] || continue
    IFS=$'\t' read -r _ _ doc _ _ php _ <<<"${row}"
    doc="$(hm_tsv_unfield "${doc}")"
    php="$(hm_tsv_unfield "${php}")"
    path="$(hm_wp_find_path "${doc}" 2>/dev/null || true)"
    [[ -n "${path}" ]] || continue
    found=1
    ver="?"
    updp=0
    updt=0
    maint="off"
    if hm_site_context_push "${d}" 2>/dev/null; then
      ver="$(hm_wp_run 1 core version 2>/dev/null | tr -d '\r' | tail -1 || echo '?')"
      updp="$(hm_wp_run 1 plugin list --update=available --field=name 2>/dev/null | grep -c . || true)"
      updt="$(hm_wp_run 1 theme list --update=available --field=name 2>/dev/null | grep -c . || true)"
      [[ "${updp}" =~ ^[0-9]+$ ]] || updp=0
      [[ "${updt}" =~ ^[0-9]+$ ]] || updt=0
      if [[ -f "${path}/.maintenance" ]]; then maint="ON"; fi
      hm_site_context_pop 2>/dev/null || true
    fi
    printf '  %-28s %-10s %-8s %-8s %-12s %s\n' "${d}" "${ver:-?}" "${updp}" "${updt}" "${maint}" "${php:--}"
  done
  [[ "${found}" -eq 1 ]] || echo "  (brak instalacji WP)"
}

hm_wp_plugins_list() {
  local only_upd=0 a
  for a in "$@"; do
    case "${a}" in
      --updates|--update) only_upd=1 ;;
      help|-h|--help) echo "Użycie: wp plugins [--updates]"; return 0 ;;
    esac
  done
  hm_wp_require_site || return 1
  if [[ "${only_upd}" -eq 1 ]]; then
    hm_wp_run 1 plugin list --update=available --fields=name,status,version,update_version --format=table
  else
    hm_wp_run 1 plugin list --fields=name,status,version,update --format=table
  fi
}

hm_wp_plugin_toggle() {
  local action="$1" slug="$2"
  [[ -n "${slug}" ]] || { hm_err "Użycie: wp plugin ${action} <slug>"; return 1; }
  hm_wp_require_site || return 1
  if ! hm_confirm_plan "wp plugin ${action} — ${slug}" \
    "" \
    "wp plugin ${action} ${slug} (jako ${HM_SITE_USER})" \
    "ols cache flush"; then
    return 1
  fi
  hm_wp_run 0 plugin "${action}" "${slug}" || return 1
  if declare -F hm_ols_cache_flush >/dev/null 2>&1; then
    hm_ols_cache_flush "${HM_SITE_DOMAIN}" 2>/dev/null || true
  fi
  hm_ok "Plugin ${slug}: ${action}."
}

hm_wp_maintenance() {
  local mode="${1:-}"
  hm_wp_require_site || return 1
  case "${mode}" in
    on|enable|1)
      hm_confirm_plan "wp maintenance on — ${HM_SITE_DOMAIN}" "" \
        "Włączenie maintenance-mode (WP-CLI)" || return 1
      hm_wp_run 0 maintenance-mode activate || return 1
      hm_ok "Maintenance ON."
      ;;
    off|disable|0)
      hm_confirm_plan "wp maintenance off — ${HM_SITE_DOMAIN}" "" \
        "Wyłączenie maintenance-mode" || return 1
      hm_wp_run 0 maintenance-mode deactivate || {
        # fallback: usuń .maintenance
        local path
        path="$(hm_wp_resolve_path)" || return 1
        rm -f "${path}/.maintenance"
      }
      hm_ok "Maintenance OFF."
      ;;
    status|"")
      hm_wp_run 1 maintenance-mode status 2>/dev/null || {
        local path
        path="$(hm_wp_resolve_path)"
        [[ -f "${path}/.maintenance" ]] && echo "on" || echo "off"
      }
      ;;
    *)
      hm_err "Użycie: wp maintenance on|off|status"
      return 1
      ;;
  esac
}

hm_wp_verify() {
  hm_wp_require_site || return 1
  hm_info "core verify-checksums…"
  hm_wp_run 1 core verify-checksums || hm_warn "core checksums: różnice / błąd"
  hm_info "plugin verify-checksums --all…"
  hm_wp_run 1 plugin verify-checksums --all || hm_warn "plugin checksums: różnice / błąd"
  hm_ok "verify zakończone (sprawdź ostrzeżenia powyżej)."
}

hm_wp_admin_reset() {
  local login="${1:-}"
  [[ -n "${login}" ]] || { hm_err "Użycie: wp admin-reset <login>"; return 1; }
  hm_wp_require_site || return 1
  if ! hm_confirm_plan "wp admin-reset — ${login}" \
    "Nowe hasło zostanie wypisane RAZ na ekranie (nie trafia do applog)." \
    "Wygenerowanie hasła (hm_gen_password)" \
    "wp_set_password / utworzenie admina gdy brak loginu" \
    "Plik hasła 0600 + shred"; then
    return 1
  fi

  if ! [[ "${login}" =~ ^[A-Za-z0-9._@-]+$ ]]; then
    hm_err "Nieprawidłowy login (dozwolone: A-Za-z0-9._@-)."
    return 1
  fi
  local pass passf php_f user
  pass="$(hm_gen_password)"
  [[ -n "${pass}" && ${#pass} -ge 12 ]] || { hm_err "Nie wygenerowano hasła."; return 1; }
  user="$(hm_access_require_site_user "${HM_SITE_DOMAIN}")" || return 1
  passf="$(hm_mktemp .wppass)"
  php_f="$(hm_mktemp .wpreset.php)"
  umask 077
  printf '%s' "${pass}" > "${passf}"
  chmod 0600 "${passf}"
  # hasło i login tylko w plikach 0600 — nie w argv wp
  local passf_e="${passf//\\/\\\\}"
  passf_e="${passf_e//\'/\\\'}"
  cat > "${php_f}" <<EOF
<?php
\$f = '${passf_e}';
\$login = '${login}';
\$p = @file_get_contents(\$f);
@unlink(\$f);
if (\$p === false || \$p === '') { fwrite(STDERR, "pass read fail\n"); exit(1); }
\$u = get_user_by('login', \$login);
if (\$u) {
  wp_set_password(\$p, \$u->ID);
  echo "updated:" . \$u->ID;
  exit(0);
}
\$host = parse_url(home_url(), PHP_URL_HOST);
\$id = wp_create_user(\$login, \$p, \$login . '@' . \$host);
if (is_wp_error(\$id)) { fwrite(STDERR, \$id->get_error_message() . "\n"); exit(1); }
\$u = new WP_User(\$id);
\$u->set_role('administrator');
echo "created:" . \$id;
EOF
  chown "${user}:${user}" "${passf}" "${php_f}" 2>/dev/null || true
  chmod 0600 "${php_f}"
  if ! hm_wp_run 0 eval-file "${php_f}"; then
    rm -f "${passf}" "${php_f}"
    hm_err "admin-reset nieudany."
    return 1
  fi
  rm -f "${passf}" "${php_f}"
  hm_ok "Konto ${login} gotowe."
  echo
  echo "  ${C_BOLD}Login:${C_RESET} ${login}"
  echo "  ${C_BOLD}Hasło:${C_RESET} ${pass}"
  echo "  ${C_DIM}Zapisz hasło — nie będzie ponownie pokazane.${C_RESET}"
}

hm_wp_cache_flush() {
  hm_wp_require_site || return 1
  hm_wp_run 0 cache flush 2>/dev/null || true
  if declare -F hm_ols_cache_flush >/dev/null 2>&1; then
    hm_ols_cache_flush "${HM_SITE_DOMAIN}" 2>/dev/null || true
  fi
  hm_ok "Cache flushed (WP + OLS LSCache)."
}

hm_wp_cron_run() {
  hm_wp_require_site || return 1
  hm_wp_run 0 cron event run --due-now
}

hm_wp_install() {
  local domain="${1:-}"
  shift || true
  local title="" email="" yes=0 a
  while [[ $# -gt 0 ]]; do
    a="$1"; shift || true
    case "${a}" in
      --title) title="${1:-}"; shift || true ;;
      --title=*) title="${a#--title=}" ;;
      --admin-email|--email) email="${1:-}"; shift || true ;;
      --admin-email=*|--email=*) email="${a#*=}" ;;
      --yes|-y) yes=1 ;;
      help|-h|--help)
        echo "Użycie: wp install <domena> --title \"…\" --admin-email … [--yes]"
        return 0
        ;;
      -*) hm_err "Nieznana flaga: ${a}"; return 1 ;;
      *) [[ -z "${domain}" ]] && domain="${a}" ;;
    esac
  done
  [[ -n "${domain}" ]] || { hm_err "Użycie: wp install <domena> --title … --admin-email …"; return 1; }
  if ! hm_is_valid_domain "${domain}"; then
    hm_err "Nieprawidłowa domena: ${domain}"; return 1
  fi
  [[ -n "${title}" && -n "${email}" ]] || {
    hm_err "Wymagane --title i --admin-email"
    return 1
  }
  if ! hm_have_cmd cyberpanel; then
    hm_err "wp install wymaga cyberpanel installWordPress (brak CLI)."
    return 1
  fi
  local pass
  pass="$(hm_gen_password)"
  local -a plan=(
    "cyberpanel installWordPress --domainName ${domain} --siteTitle … --adminEmail ${email}"
    "Hasło admina wygenerowane i pokazane raz (nie w applog)"
  )
  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "wp install — ${domain}" "" --yes "${plan[@]}" || return 1
  else
    hm_confirm_plan "wp install — ${domain}" "" "${plan[@]}" || return 1
  fi
  # cyberpanel często: --domainName --email --userName --password --siteTitle
  if ! hm_run cyberpanel installWordPress \
    --domainName "${domain}" \
    --email "${email}" \
    --userName admin \
    --passWord "${pass}" \
    --siteTitle "${title}" 2>/dev/null; then
    # wariant z innymi flagami
    if ! hm_run cyberpanel installWordPress \
      --domainName "${domain}" \
      --adminEmail "${email}" \
      --adminUser admin \
      --adminPassword "${pass}" \
      --siteTitle "${title}"; then
      hm_err "cyberpanel installWordPress nieudany."
      return 1
    fi
  fi
  hm_ok "WordPress zainstalowany na ${domain}."
  echo "  ${C_BOLD}Admin:${C_RESET} admin"
  echo "  ${C_BOLD}Hasło:${C_RESET} ${pass}"
  echo "  ${C_DIM}Zapisz hasło — nie będzie ponownie pokazane.${C_RESET}"
}

cmd_wp() {
  local sub="${1:-}"
  case "${sub}" in
    cli-info|cliinfo)
      hm_wp_cli_info
      ;;
    cli-update|cliupdate)
      hm_wp_cli_update
      ;;
    sites|list-sites)
      shift || true
      cmd_wp_sites "$@"
      ;;
    install)
      shift || true
      hm_wp_install "$@"
      ;;
    plugins|plugin-list)
      shift || true
      hm_wp_plugins_list "$@"
      ;;
    plugin)
      shift || true
      local act="${1:-}"
      shift || true
      case "${act}" in
        activate|deactivate) hm_wp_plugin_toggle "${act}" "$@" ;;
        list) hm_wp_plugins_list "$@" ;;
        *) hm_err "Użycie: wp plugin activate|deactivate <slug>"; return 1 ;;
      esac
      ;;
    update)
      shift || true
      hm_wp_update_cmd "$@"
      ;;
    maintenance|maint)
      shift || true
      hm_wp_maintenance "$@"
      ;;
    verify|checksums)
      shift || true
      hm_wp_verify "$@"
      ;;
    search-replace|sr|replace)
      shift || true
      hm_wp_search_replace "$@"
      ;;
    admin-reset|reset-admin)
      shift || true
      hm_wp_admin_reset "$@"
      ;;
    cache)
      shift || true
      case "${1:-flush}" in
        flush|clear) hm_wp_cache_flush ;;
        *) hm_err "Użycie: wp cache flush"; return 1 ;;
      esac
      ;;
    cron)
      shift || true
      case "${1:-run}" in
        run) hm_wp_cron_run ;;
        *) hm_err "Użycie: wp cron run"; return 1 ;;
      esac
      ;;
    rollback)
      shift || true
      hm_wp_require_site || return 1
      hm_wp_snap_rollback "$@"
      ;;
    snaps|snapshots)
      hm_wp_require_site || return 1
      echo "${C_BOLD}Snapshoty — ${HM_SITE_DOMAIN}${C_RESET}"
      local s any=0
      while IFS= read -r s; do
        [[ -n "${s}" ]] || continue
        echo "  ${s}"
        any=1
      done < <(hm_wp_snap_list)
      [[ "${any}" -eq 1 ]] || echo "  (brak)"
      ;;
    help|-h|--help)
      hm_help_topic wp
      ;;
    "")
      if [[ -n "${HM_SITE_DOMAIN:-}" ]]; then
        hm_wp_require_site || return 1
        hm_wp_print_status
      else
        hm_help_topic wp
      fi
      ;;
    *)
      # wp <domena> → tymczasowy kontekst?
      if hm_is_valid_domain "${sub}" 2>/dev/null; then
        local resolved
        resolved="$(hm_find_site_by_arg_exact "${sub}" 2>/dev/null || true)"
        if [[ -n "${resolved}" ]]; then
          shift || true
          hm_with_site_context "${resolved}" cmd_wp "$@"
          return $?
        fi
      fi
      hm_err "Nieznana podkomenda: ${sub}. Zobacz: wp help"
      return 1
      ;;
  esac
}

_hm_cmd_register wp cmd_wp 0
_hm_cmd_register_site wp cmd_wp
