#!/usr/bin/env bash
# Pluginowy dispatch: katalog = komenda (aliasy / restricted z rejestru _load.sh)

hm_cmd_resolve() {
  local raw="${1:-}"
  [[ -n "${raw}" ]] || return 1
  local canon="${HM_CMD_ALIAS_MAP[${raw}]:-}"
  [[ -n "${canon}" ]] || return 1
  printf '%s' "${canon}"
}

# Nadpisanie listy z detect.sh — whitelist z HM_CMD_RESTRICTED
hm_dispatch_allowed_when_restricted() {
  local cmd="${1:-}"
  case "${cmd}" in
    ""|exit|quit|q) return 0 ;;
  esac
  local canon
  canon="$(hm_cmd_resolve "${cmd}" 2>/dev/null || true)"
  [[ -n "${canon}" ]] || return 1
  [[ "${HM_CMD_RESTRICTED[${canon}]:-0}" == "1" ]]
}

# Kontekst site — specjalne ścieżki + HM_CMD_SITE_ENTRY
# Ustawia HM_SITE_DISPATCH_HIT=1 gdy obsłużono (nawet przy rc≠0 komendy).
hm_site_try_dispatch() {
  local cmd="${1:-}"
  shift || true
  HM_SITE_DISPATCH_HIT=0
  [[ -n "${HM_SITE_DOMAIN:-}" ]] || return 1

  _hm_site_hit() {
    HM_SITE_DISPATCH_HIT=1
    "$@"
  }

  case "${cmd}" in
    exit|quit|back|\.\.)
      HM_SITE_DISPATCH_HIT=1
      hm_ok "Wyjście z kontekstu ${HM_SITE_DOMAIN}."
      hm_clear_site_context
      return 0
      ;;
    ssl)
      if [[ "${1:-}" == "renew" || "${1:-}" == "renewal" || "${1:-}" == "issue" ]]; then
        shift || true
        _hm_site_hit cmd_renew_ssl "${1:-${HM_SITE_DOMAIN}}"
        return $?
      fi
      if declare -F cmd_site_ssl >/dev/null 2>&1; then
        _hm_site_hit cmd_site_ssl
        return $?
      fi
      ;;
    renew-ssl|ssl-renew)
      _hm_site_hit cmd_renew_ssl "${1:-${HM_SITE_DOMAIN}}"
      return $?
      ;;
    backup)
      if [[ "${1:-}" == "archive" ]]; then
        _hm_site_hit hm_backup_archive_site "${HM_SITE_DOMAIN}"
        return $?
      elif [[ -z "${1:-}" ]]; then
        _hm_site_hit cmd_site_backup
        return $?
      fi
      # inne podkomendy backup → globalny cmd_backup
      return 1
      ;;
    archive|archive-site)
      _hm_site_hit hm_backup_archive_site "${HM_SITE_DOMAIN}"
      return $?
      ;;
    webs|sites)
      if [[ "${1:-}" == "delete" || "${1:-}" == "remove" || "${1:-}" == "destroy" || "${1:-}" == "rm" ]]; then
        shift || true
        _hm_site_hit cmd_delete_site "${HM_SITE_DOMAIN}" "$@"
        return $?
      fi
      if [[ "${1:-}" == "archive" ]]; then
        _hm_site_hit hm_backup_archive_site "${HM_SITE_DOMAIN}"
        return $?
      fi
      return 1
      ;;
    htaccess|hta)
      _hm_site_hit cmd_site_htaccess "$@"
      return $?
      ;;
    proxy)
      _hm_site_hit cmd_site_proxy "$@"
      return $?
      ;;
    php)
      _hm_site_hit cmd_php "$@"
      return $?
      ;;
  esac

  local site_fn="${HM_CMD_SITE_ENTRY[${cmd}]:-}"
  if [[ -n "${site_fn}" ]] && declare -F "${site_fn}" >/dev/null 2>&1; then
    _hm_site_hit "${site_fn}" "$@"
    return $?
  fi
  return 1
}

hm_cmd_invoke() {
  local cmd="${1:-}"
  shift || true
  local canon entry
  [[ -n "${cmd}" ]] || return 0

  canon="$(hm_cmd_resolve "${cmd}" 2>/dev/null || true)"
  if [[ -z "${canon}" ]]; then
    hm_err "Nieznana komenda: ${cmd}. Wpisz 'help'."
    return 1
  fi
  entry="${HM_CMD_ENTRY[${canon}]:-}"
  if [[ -z "${entry}" ]] || ! declare -F "${entry}" >/dev/null 2>&1; then
    hm_err "Komenda ${canon} bez handlera (${entry:-?})."
    return 1
  fi
  "${entry}" "$@"
}
