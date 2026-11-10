#!/usr/bin/env bash
# site new (krok baz i sekretów) oraz site env.

cmd_site_env_domain() {
  local arg="${1:-}"
  if [[ -n "${arg}" && "${arg}" != -* ]]; then
    printf '%s' "${arg}"
    return 0
  fi
  if [[ -n "${HM_SITE_DOMAIN:-}" ]]; then
    printf '%s' "${HM_SITE_DOMAIN}"
    return 0
  fi
  if [[ -n "${HM_SITE_LAST_NEW:-}" ]]; then
    printf '%s' "${HM_SITE_LAST_NEW}"
    return 0
  fi
  return 1
}

cmd_site_env() {
  local sub="${1:-list}"
  shift || true
  local domain key
  case "${sub}" in
    help|-h|--help)
      hm_help_topic env 2>/dev/null || true
      echo "Użycie: site env list [domena] | set KEY | unset KEY | show KEY"
      return 0
      ;;
    list|ls)
      domain="$(cmd_site_env_domain "${1:-}")" || {
        hm_err "Użycie: site env list [domena]  (albo use <domena>)"
        return 1
      }
      hm_site_env_list_print "${domain}"
      ;;
    set)
      key="${1:-}"
      [[ -n "${key}" ]] || { hm_err "Użycie: site env set KEY  (wartość ze stdin albo promptu, nie z argv)"; return 1; }
      if [[ -n "${2:-}" ]]; then
        hm_err "Wartość nie może być argumentem (widać ją w ps). Użyj: site env set ${key}"
        return 1
      fi
      domain="$(cmd_site_env_domain)" || { hm_err "Brak domeny (use albo wcześniejsze site new)."; return 1; }
      local val=""
      if [[ -t 0 ]]; then
        IFS= read -r -s -p "Wartość ${key}: " val
        printf '\n'
      else
        IFS= read -r val || true
      fi
      [[ -n "${val}" ]] || { hm_err "Pusta wartość."; return 1; }
      hm_site_env_upsert "${domain}" "${key}" "${val}" || return 1
      hm_ok "Zapisano ${key}."
      ;;
    unset|rm|delete)
      key="${1:-}"
      [[ -n "${key}" ]] || { hm_err "Użycie: site env unset KEY"; return 1; }
      domain="$(cmd_site_env_domain "${2:-}")" || { hm_err "Brak domeny."; return 1; }
      hm_site_env_unset_key "${domain}" "${key}" || return 1
      hm_ok "Usunięto ${key}."
      ;;
    show)
      key="${1:-}"
      [[ -n "${key}" ]] || { hm_err "Użycie: site env show KEY"; return 1; }
      domain="$(cmd_site_env_domain "${2:-}")" || { hm_err "Brak domeny."; return 1; }
      local path val
      path="$(hm_site_env_path "${domain}")"
      val="$(hm_site_env_get "${path}" "${key}" 2>/dev/null || true)"
      [[ -n "${val}" ]] || { hm_err "Brak klucza ${key}."; return 1; }
      hm_print_secret "${val}"
      ;;
    *)
      hm_err "Użycie: site env list|set|unset|show"
      return 1
      ;;
  esac
}

cmd_site_new() {
  if [[ $# -eq 0 ]] && declare -F hm_wiz_site_new >/dev/null 2>&1; then
    hm_wiz_site_new
    return $?
  fi
  local domain="" runtime="node" db="none" pg_ver="" framework="auto" yes=0 db_name="" dry=0
  local node_spec="" node_default="" pkg="" process="" start="" port="" preset=""
  local instances="1" memory="300M"
  local php_ver="" php_preset="" php_ext="" php_skel="" php_sapi="fpm" php_composer="1" php_on=0 php_harden=0
  local webserver="" vhost_kind="" proxy_port="" web_ssl=0 web_on=0
  local preset_app="" site_user="" site_shell="nologin" child_of="" releases=0 no_www=0 continue_nossl=0
  local tx_resume=0 tx_rollback=0 profile_from="" save_profile=""
  local -a redis_roles=()
  local a
  while [[ $# -gt 0 ]]; do
    a="$1"
    shift || true
    case "${a}" in
      --runtime)
        runtime="${1:-}"; shift || true ;;
      --runtime=*)
        runtime="${a#*=}" ;;
      --db)
        db="${1:-}"; shift || true ;;
      --db=*)
        db="${a#*=}" ;;
      --pg-version)
        pg_ver="${1:-}"; shift || true ;;
      --pg-version=*)
        pg_ver="${a#*=}" ;;
      --framework)
        framework="${1:-}"; shift || true ;;
      --framework=*)
        framework="${a#*=}" ;;
      --db-name)
        db_name="${1:-}"; shift || true ;;
      --db-name=*)
        db_name="${a#*=}" ;;
      --redis)
        if [[ $# -gt 0 ]]; then
          case "${1:-}" in
            cache|queue|session|queues)
              redis_roles+=("$1")
              shift || true
              ;;
            *)
              redis_roles+=("cache")
              ;;
          esac
        else
          redis_roles+=("cache")
        fi
        ;;
      --node)
        node_spec="${1:-}"; shift || true ;;
      --node=*)
        node_spec="${a#*=}" ;;
      --node-default)
        node_default="${1:-}"; shift || true ;;
      --node-default=*)
        node_default="${a#*=}" ;;
      --pkg)
        pkg="${1:-}"; shift || true ;;
      --pkg=*)
        pkg="${a#*=}" ;;
      --process)
        process="${1:-}"; shift || true ;;
      --process=*)
        process="${a#*=}" ;;
      --start)
        start="${1:-}"; shift || true ;;
      --start=*)
        start="${a#*=}" ;;
      --port)
        port="${1:-}"; shift || true ;;
      --port=*)
        port="${a#*=}" ;;
      --preset)
        preset_app="${1:-}"
        case "${preset_app}" in
          next|nuxt|express|nest) preset="${preset_app}" ;;
        esac
        shift || true ;;
      --preset=*)
        preset_app="${a#*=}"
        case "${preset_app}" in
          next|nuxt|express|nest) preset="${preset_app}" ;;
        esac
        ;;
      --instances)
        instances="${1:-}"; shift || true ;;
      --instances=*)
        instances="${a#*=}" ;;
      --memory)
        memory="${1:-}"; shift || true ;;
      --memory=*)
        memory="${a#*=}" ;;
      --php)
        php_ver="${1:-}"; php_on=1; shift || true ;;
      --php=*)
        php_ver="${a#*=}"; php_on=1 ;;
      --php-preset)
        php_preset="${1:-}"; php_on=1; shift || true ;;
      --php-preset=*)
        php_preset="${a#*=}"; php_on=1 ;;
      --php-ext)
        php_ext="${1:-}"; php_on=1; shift || true ;;
      --php-ext=*)
        php_ext="${a#*=}"; php_on=1 ;;
      --php-skeleton)
        php_skel="${1:-}"; php_on=1; shift || true ;;
      --php-skeleton=*)
        php_skel="${a#*=}"; php_on=1 ;;
      --php-sapi)
        php_sapi="${1:-}"; php_on=1; shift || true ;;
      --php-sapi=*)
        php_sapi="${a#*=}"; php_on=1 ;;
      --php-harden)
        php_harden=1; php_on=1 ;;
      --no-composer)
        php_composer=0; php_on=1 ;;
      --webserver)
        webserver="${1:-}"; web_on=1; shift || true ;;
      --webserver=*)
        webserver="${a#*=}"; web_on=1 ;;
      --vhost-type)
        vhost_kind="${1:-}"; web_on=1; shift || true ;;
      --vhost-type=*)
        vhost_kind="${a#*=}"; web_on=1 ;;
      --proxy-port)
        proxy_port="${1:-}"; web_on=1; shift || true ;;
      --proxy-port=*)
        proxy_port="${a#*=}"; web_on=1 ;;
      --ssl)
        web_ssl=1; web_on=1 ;;
      --user)
        site_user="${1:-}"; shift || true ;;
      --user=*)
        site_user="${a#*=}" ;;
      --shell)
        site_shell="${1:-}"; shift || true ;;
      --shell=*)
        site_shell="${a#*=}" ;;
      --alias)
        HM_SITE_ALIASES="${1:-}"; shift || true ;;
      --alias=*)
        HM_SITE_ALIASES="${a#*=}" ;;
      --no-www)
        no_www=1 ;;
      --child-of)
        child_of="${1:-}"; shift || true ;;
      --child-of=*)
        child_of="${a#*=}" ;;
      --releases)
        releases=1 ;;
      --continue-without-ssl)
        continue_nossl=1 ;;
      --dry-run)
        dry=1 ;;
      --resume)
        tx_resume=1 ;;
      --rollback)
        tx_rollback=1 ;;
      --from)
        profile_from="${1:-}"; shift || true ;;
      --from=*)
        profile_from="${a#*=}" ;;
      --save-profile)
        save_profile="${1:-}"; shift || true ;;
      --save-profile=*)
        save_profile="${a#*=}" ;;
      --yes|-y) yes=1 ;;
      help|-h|--help)
        echo "Użycie: site new <domena> [--runtime node|php] [--db mysql|postgres|sqlite|none] [--from profil.json] [--save-profile plik] [--resume] [--rollback] [--yes]"
        return 0
        ;;
      -*)
        hm_err "Nieznana flaga: ${a}"
        return 1
        ;;
      *)
        if [[ -z "${domain}" ]]; then
          domain="${a}"
        else
          hm_err "Za dużo argumentów: ${a}"
          return 1
        fi
        ;;
    esac
  done

  if [[ -n "${profile_from}" ]]; then
    declare -F hm_site_profile_load >/dev/null 2>&1 || { hm_err "Brak lib/site/tx.sh."; return 1; }
    hm_site_profile_load "${profile_from}" || return 1
    [[ -z "${domain}" && -n "${HM_SITE_PROFILE_DOMAIN:-}" ]] && domain="${HM_SITE_PROFILE_DOMAIN}"
    [[ -z "${preset_app}" && -n "${HM_SITE_PROFILE_PRESET:-}" ]] && preset_app="${HM_SITE_PROFILE_PRESET}"
    [[ "${db}" == "none" && -n "${HM_SITE_PROFILE_DB:-}" ]] && db="${HM_SITE_PROFILE_DB}"
    [[ "${runtime}" == "node" && -n "${HM_SITE_PROFILE_RUNTIME:-}" ]] && runtime="${HM_SITE_PROFILE_RUNTIME}"
    if [[ -z "${php_ver}" && -n "${HM_SITE_PROFILE_PHP:-}" ]]; then
      php_ver="${HM_SITE_PROFILE_PHP}"
      php_on=1
    fi
    if [[ -z "${webserver}" && -n "${HM_SITE_PROFILE_WEB:-}" ]]; then
      webserver="${HM_SITE_PROFILE_WEB}"
      web_on=1
    fi
  fi

  [[ -n "${domain}" ]] || { hm_err "Użycie: site new <domena> --db …"; return 1; }
  hm_is_valid_domain "${domain}" || { hm_err "Nieprawidłowa domena: ${domain}"; return 1; }
  if [[ "${dry}" -eq 1 ]]; then
    hm_info "dry-run: brak zmian w systemie"
    printf 'plan: domena %s, runtime %s, baza %s\n' "${domain}" "${runtime}" "${db}"
    return 0
  fi
  if [[ "${tx_rollback}" -eq 1 ]]; then
    declare -F hm_tx_rollback >/dev/null 2>&1 || { hm_err "Brak lib/site/tx.sh."; return 1; }
    hm_tx_rollback "${domain}"
    return $?
  fi
  if declare -F hm_tx_begin >/dev/null 2>&1; then
    if [[ -f "$(hm_site_manifest_path "${domain}")" && "${tx_resume}" -eq 0 ]]; then
      hm_info "pomijam — już jest (manifest ${domain})"
      [[ -n "${save_profile}" ]] && hm_site_profile_save "${save_profile}" "${domain}" "${preset_app}" "${runtime}" "${db}" "${webserver}"
      return 0
    fi
    if [[ "${tx_resume}" -eq 1 ]]; then
      HM_SITE_RESUME=1
      hm_tx_resume "${domain}" || return 1
    else
      hm_tx_begin "${domain}" || return 1
    fi
  fi
  if [[ "${no_www}" -eq 1 ]]; then
    HM_SITE_ALIASES="none"
  fi
  if [[ "${continue_nossl}" -eq 1 ]]; then
    HM_SITE_CONTINUE_WITHOUT_SSL=1
  fi
  HM_SITE_SSL="${web_ssl}"
  if declare -F hm_site_base_check >/dev/null 2>&1; then
    if ! hm_site_base_check "${domain}" "${site_user}" "${site_shell}" "${preset_app}" "${child_of}"; then
      [[ -n "${HM_TX_JOURNAL:-}" ]] && hm_tx_rollback "${domain}" || true
      return 1
    fi
    [[ -n "${HM_SITE_BASE_RUNTIME:-}" && "${runtime}" == "node" ]] && runtime="${HM_SITE_BASE_RUNTIME}"
    [[ -n "${HM_SITE_BASE_DOMAIN:-}" ]] && domain="${HM_SITE_BASE_DOMAIN}"
  fi

  local -a plan=("Katalog shared/.env (0600) dla ${domain}" "Silnik bazy: ${db}")
  [[ "${#redis_roles[@]}" -gt 0 ]] && plan+=("Redis: ${redis_roles[*]}")
  if [[ -n "${node_spec}${node_default}${pkg}${process}${start}${port}${preset}" ]]; then
    plan+=("Node: ${node_spec:-Active LTS} (default ${node_default:-pierwsza}), proces ${process:-pm2}")
  fi
  if [[ "${php_on}" -eq 1 ]]; then
    plan+=("PHP: ${php_ver:-domyślna active} (${php_sapi}, preset ${php_preset:-minimal})")
  fi
  if [[ "${web_on}" -eq 1 ]]; then
    plan+=("Vhost: ${webserver:-nginx} / ${vhost_kind:-auto}")
  fi
  plan+=("Manifest bez haseł (.hmtools/service.json)")
  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "site new — ${domain}" "Sekrety tylko w shared/.env." --yes "${plan[@]}" || return 1
  else
    hm_confirm_plan "site new — ${domain}" "Sekrety tylko w shared/.env." "${plan[@]}" || return 1
  fi

  if declare -F hm_site_base_apply >/dev/null 2>&1 && [[ -n "${HM_SITE_BASE_DOMAIN:-}" ]]; then
    local txrc=0 home_undo=""
    home_undo="$(hm_site_home "${domain}")"
    if [[ -n "${HM_TX_JOURNAL:-}" ]]; then
      hm_tx_step layout "rm -rf ${home_undo}" || txrc=$?
      if [[ "${txrc}" -eq 2 ]]; then
        hm_site_base_apply "${site_shell}" "${preset_app}" "${releases}" || { hm_tx_rollback "${domain}" || true; return 1; }
        hm_tx_done layout
      elif [[ "${txrc}" -ne 0 ]]; then
        return 1
      else
        hm_info "pomijam — już jest (layout)"
      fi
    else
      hm_site_base_apply "${site_shell}" "${preset_app}" "${releases}" || return 1
    fi
  fi
  if ! hm_site_db_provision "${domain}" "${db}" "${runtime}" "${framework}" "${pg_ver}" "${yes}" "${db_name}" "${redis_roles[@]+"${redis_roles[@]}"}"; then
    if declare -F hm_site_db_rollback_session >/dev/null 2>&1; then
      hm_site_db_rollback_session "${domain}" || true
    fi
    [[ -n "${HM_TX_JOURNAL:-}" ]] && hm_tx_rollback "${domain}" || true
    hm_err "site new nieudany — cofnięto bazy utworzone w tej próbie."
    return 1
  fi
  if [[ -n "${node_spec}${node_default}${pkg}${process}${start}${port}${preset}" ]]; then
    if ! declare -F hm_site_node_provision >/dev/null 2>&1; then
      hm_err "Brak lib/site/node.sh."
      return 1
    fi
    hm_site_node_provision "${domain}" "${node_spec}" "${node_default}" "${pkg}" "${process}" "${start}" "${port}" "${preset}" "${instances}" "${memory}" || return 1
  fi
  if [[ "${php_on}" -eq 1 ]]; then
    if ! declare -F hm_site_php_provision >/dev/null 2>&1; then
      hm_err "Brak lib/site/php.sh."
      return 1
    fi
    if [[ "${php_harden}" -eq 1 ]]; then
      HM_SITE_PHP_HARDEN=1
    fi
    hm_site_php_provision "${domain}" "${php_ver}" "${php_preset:-minimal}" "${php_ext}" "${php_skel}" "${yes}" "${php_sapi}" "${php_composer}" || return 1
  fi
  if [[ "${web_on}" -eq 1 ]]; then
    if ! declare -F hm_site_web_provision >/dev/null 2>&1; then
      hm_err "Brak lib/site/web.sh."
      return 1
    fi
    if [[ -z "${vhost_kind}" ]]; then
      case "${runtime}" in
        php) vhost_kind="php-fpm" ;;
        *) vhost_kind="proxy" ;;
      esac
      [[ "${preset}" == "static" || "${preset_app}" == "static" || "${preset_app}" == "spa" ]] && vhost_kind="${preset_app:-static}"
    fi
    [[ -n "${webserver}" ]] || webserver="nginx"
    hm_site_web_provision "${domain}" "${webserver}" "${vhost_kind}" "${proxy_port:-auto}" "${web_ssl}" "${yes}" "${php_ver}" || return 1
  fi
  if declare -F hm_tx_commit >/dev/null 2>&1 && [[ -n "${HM_TX_JOURNAL:-}" ]]; then
    hm_tx_commit "${domain}" "${HM_SITE_USER:-${site_user:-${domain%%.*}}}" "${runtime}" "${webserver}" "$(hm_site_home "${domain}")/shared/.env" || return 1
  fi
  if [[ -n "${save_profile}" ]]; then
    hm_site_profile_save "${save_profile}" "${domain}" "${preset_app}" "${runtime}" "${db}" "${webserver}" || return 1
  fi
  return 0
}
