#!/usr/bin/env bash
# WP: update core/plugins/themes + search-replace

hm_wp_smoke_http() {
  local domain="${1:-${HM_SITE_DOMAIN}}"
  local url code body
  [[ -n "${domain}" ]] || return 1
  url="http://${domain}/"
  # Host header + resolve lokalnie gdy możliwe
  code="$(curl -sI -o /dev/null -w '%{http_code}' --max-time 15 \
    -H "Host: ${domain}" "${url}" 2>/dev/null || echo 000)"
  if [[ "${code}" == "000" ]]; then
    code="$(curl -sI -o /dev/null -w '%{http_code}' --max-time 15 "https://${domain}/" 2>/dev/null || echo 000)"
  fi
  body="$(curl -sL --max-time 20 -H "Host: ${domain}" "${url}" 2>/dev/null | head -c 8000 || true)"
  if [[ "${code}" =~ ^5 ]]; then
    hm_err "Smoke HTTP ${code} dla ${domain}."
    return 1
  fi
  if printf '%s' "${body}" | grep -qiE 'critical error|there has been a critical error'; then
    hm_err "Smoke: wykryto „critical error” w HTML."
    return 1
  fi
  if [[ "${code}" == "000" ]]; then
    hm_warn "Smoke: brak odpowiedzi HTTP (DNS/firewall?) — pomijam twardy fail."
    return 0
  fi
  hm_ok "Smoke HTTP ${code} OK."
  return 0
}

hm_wp_update_cmd() {
  local scope="${1:-all}"
  shift || true
  local no_snap=0 yes=0
  local -a exclude=()
  local a
  while [[ $# -gt 0 ]]; do
    a="$1"; shift || true
    case "${a}" in
      --no-snapshot) no_snap=1 ;;
      --yes|-y) yes=1 ;;
      --exclude)
        [[ -n "${1:-}" ]] && exclude+=("$1") && shift || true
        ;;
      --exclude=*)
        exclude+=("${a#--exclude=}")
        ;;
      help|-h|--help)
        cat <<'EOF'
Użycie: wp update [core|plugins|themes|all] [--exclude slug] [--no-snapshot] [--yes]
EOF
        return 0
        ;;
      -*)
        hm_err "Nieznana flaga: ${a}"; return 1 ;;
      *)
        scope="${a}"
        ;;
    esac
  done

  case "${scope}" in
    core|plugins|plugin|themes|theme|all) ;;
    *) hm_err "Zakres: core|plugins|themes|all"; return 1 ;;
  esac
  [[ "${scope}" == "plugin" ]] && scope="plugins"
  [[ "${scope}" == "theme" ]] && scope="themes"

  hm_wp_require_site || return 1
  local path stamp=""
  path="$(hm_wp_resolve_path)" || return 1

  local -a plan=()
  [[ "${no_snap}" -eq 0 ]] && plan+=("Snapshot DB + plugins/themes → .hmtools-snap/<stamp>")
  case "${scope}" in
    core) plan+=("wp core update (--skip-themes --skip-plugins wyłączone przy update)") ;;
    plugins) plan+=("wp plugin update --all${exclude[*]:+ (exclude: ${exclude[*]})}") ;;
    themes) plan+=("wp theme update --all") ;;
    all) plan+=("wp core update + plugin update --all + theme update --all") ;;
  esac
  plan+=("Smoke test HTTP + brak critical error")
  plan+=("ols cache flush")
  plan+=("Przy HTTP 5xx: wp rollback <stamp>")

  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "wp update ${scope} — ${HM_SITE_DOMAIN}" \
      "Aktualizacja WordPress (${scope})." --yes "${plan[@]}" || return 1
  else
    hm_confirm_plan "wp update ${scope} — ${HM_SITE_DOMAIN}" \
      "Aktualizacja WordPress (${scope})." "${plan[@]}" || return 1
  fi

  if [[ "${no_snap}" -eq 0 ]]; then
    stamp="$(hm_wp_snap_create "update-${scope}" | sed -n '$p')" || {
      hm_err "Snapshot nieudany — przerywam update."
      return 1
    }
    [[ -n "${stamp}" && "${stamp}" != INFO:* && "${stamp}" != OK:* ]] || {
      hm_err "Snapshot nieudany — przerywam update."
      return 1
    }
    hm_ok "Snapshot: ${stamp}"
  fi

  local rc=0
  case "${scope}" in
    core)
      hm_wp_run 0 core update || rc=$?
      hm_wp_run 0 core update-db 2>/dev/null || true
      ;;
    plugins)
      if [[ "${#exclude[@]}" -gt 0 ]]; then
        local ex
        ex="$(IFS=,; echo "${exclude[*]}")"
        hm_wp_run 0 plugin update --all --exclude="${ex}" || rc=$?
      else
        hm_wp_run 0 plugin update --all || rc=$?
      fi
      ;;
    themes)
      hm_wp_run 0 theme update --all || rc=$?
      ;;
    all)
      hm_wp_run 0 core update || rc=$?
      hm_wp_run 0 core update-db 2>/dev/null || true
      if [[ "${#exclude[@]}" -gt 0 ]]; then
        local ex
        ex="$(IFS=,; echo "${exclude[*]}")"
        hm_wp_run 0 plugin update --all --exclude="${ex}" || rc=$?
      else
        hm_wp_run 0 plugin update --all || rc=$?
      fi
      hm_wp_run 0 theme update --all || rc=$?
      ;;
  esac

  if declare -F hm_ols_cache_flush >/dev/null 2>&1; then
    hm_ols_cache_flush "${HM_SITE_DOMAIN}" 2>/dev/null || true
  fi

  if ! hm_wp_smoke_http "${HM_SITE_DOMAIN}"; then
    hm_err "Aktualizacja zakończona, ale smoke test nieudany."
    if [[ -n "${stamp}" ]]; then
      hm_warn "Propozycja: wp rollback ${stamp}"
    fi
    return 1
  fi

  if [[ "${rc}" -ne 0 ]]; then
    hm_warn "WP-CLI zwrócił rc=${rc} (część pakietów mogła się nie zaktualizować)."
    return "${rc}"
  fi
  hm_ok "wp update ${scope} zakończone."
  [[ -n "${stamp}" ]] && echo "  Snapshot: ${stamp}  (wp rollback ${stamp})"
  return 0
}

hm_wp_search_replace() {
  local old="${1:-}" new="${2:-}"
  shift 2 2>/dev/null || true
  local dry=1 yes=0 a
  # domyślnie dry-run; --execute / --no-dry-run wyłącza
  while [[ $# -gt 0 ]]; do
    a="$1"; shift || true
    case "${a}" in
      --dry-run) dry=1 ;;
      --execute|--no-dry-run|--apply) dry=0 ;;
      --yes|-y) yes=1 ;;
      help|-h|--help)
        cat <<'EOF'
Użycie: wp search-replace <old> <new> [--dry-run|--execute] [--yes]

Domyślnie: --dry-run (tylko raport liczby zmian, bez zapisu).
EOF
        return 0
        ;;
      -*) hm_err "Nieznana flaga: ${a}"; return 1 ;;
      *)
        if [[ -z "${old}" ]]; then old="${a}"
        elif [[ -z "${new}" ]]; then new="${a}"
        else hm_err "Za dużo argumentów"; return 1
        fi
        ;;
    esac
  done
  [[ -n "${old}" && -n "${new}" ]] || {
    hm_err "Użycie: wp search-replace <old> <new> [--dry-run|--execute]"
    return 1
  }
  hm_wp_require_site || return 1

  local -a plan=("wp search-replace (serializacja zachowana przez WP-CLI)")
  if [[ "${dry}" -eq 1 ]]; then
    plan+=("TRYB DRY-RUN — bez zapisu; raport liczby zmian")
  else
    plan+=("Snapshot DB + plugins/themes")
    plan+=("Wykonanie search-replace old→new w całej bazie")
    plan+=("Smoke HTTP")
  fi

  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "wp search-replace — ${HM_SITE_DOMAIN}" \
      "Zamiana URL/tekstu w bazie WP." --yes "${plan[@]}" || return 1
  else
    hm_confirm_plan "wp search-replace — ${HM_SITE_DOMAIN}" \
      "Zamiana URL/tekstu w bazie WP." "${plan[@]}" || return 1
  fi

  local stamp=""
  if [[ "${dry}" -eq 0 ]]; then
    stamp="$(hm_wp_snap_create "search-replace" | sed -n '$p')" || {
      hm_err "Snapshot nieudany — przerywam."
      return 1
    }
    [[ -n "${stamp}" ]] || {
      hm_err "Snapshot nieudany — przerywam."
      return 1
    }
  fi

  local -a args=(search-replace "${old}" "${new}" --all-tables --report-changed-only)
  [[ "${dry}" -eq 1 ]] && args+=(--dry-run)

  hm_info "WP-CLI search-replace${dry:+ (dry-run)}…"
  if ! hm_wp_run 0 "${args[@]}"; then
    hm_err "search-replace nieudany."
    [[ -n "${stamp}" ]] && hm_warn "Rollback: wp rollback ${stamp}"
    return 1
  fi

  if [[ "${dry}" -eq 1 ]]; then
    hm_ok "Dry-run zakończony. Aby zapisać: wp search-replace … --execute"
    return 0
  fi

  if declare -F hm_ols_cache_flush >/dev/null 2>&1; then
    hm_ols_cache_flush "${HM_SITE_DOMAIN}" 2>/dev/null || true
  fi
  hm_wp_smoke_http "${HM_SITE_DOMAIN}" || {
    [[ -n "${stamp}" ]] && hm_warn "Propozycja: wp rollback ${stamp}"
    return 1
  }
  hm_ok "search-replace zapisany. Snapshot: ${stamp}"
}
