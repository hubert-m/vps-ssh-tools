#!/usr/bin/env bash
# Moduł: supervisor — status / sterowanie / logi programów Supervisord

_hm_cmd_help supervisor <<'EOF'
Użycie:
  supervisor | status          Lista programów (w kontekście: filtr pod stronę)
  supervisor all               Wszystkie programy (bez filtra kontekstu)
  supervisor info              Wykrycie: ctl, conf, systemd
  supervisor start|stop|restart <name|all>
  supervisor reread | update   Przeładowanie konfiguracji
  supervisor logs <name> [N]   Ostatnie N linii (domyślnie 50)
  supervisor ctl …             Passthrough do supervisorctl

Wymaga zainstalowanego Supervisor (supervisorctl). Szczegóły: detect
EOF

hm_supervisor_require() {
  hm_detect_supervisor 2>/dev/null || true
  if [[ -n "${FORCE_SUPERVISOR:-}" ]]; then
    case "${FORCE_SUPERVISOR}" in
      yes|no) SUPERVISOR="${FORCE_SUPERVISOR}" ;;
    esac
  fi
  if [[ "${SUPERVISOR:-no}" != "yes" ]] || [[ -z "${SUPERVISOR_CTL:-}" ]]; then
    if hm_have_cmd supervisorctl; then
      SUPERVISOR_CTL="$(command -v supervisorctl)"
      SUPERVISOR="yes"
    elif [[ -x /usr/bin/supervisorctl ]]; then
      SUPERVISOR_CTL="/usr/bin/supervisorctl"
      SUPERVISOR="yes"
    fi
  fi
  if [[ -z "${SUPERVISOR_CTL:-}" || ! -x "${SUPERVISOR_CTL}" ]]; then
    hm_err "Brak supervisorctl — Supervisor nie jest zainstalowany / nie wykryty."
    hm_info "Sprawdź: detect   | nadpisanie: FORCE_SUPERVISOR=yes w hmtools.conf"
    return 1
  fi
  return 0
}

hm_supervisor_ctl() {
  hm_supervisor_require || return 1
  local -a args=()
  if [[ -n "${SUPERVISOR_CONF:-}" && -f "${SUPERVISOR_CONF}" ]]; then
    args+=(-c "${SUPERVISOR_CONF}")
  fi
  "${SUPERVISOR_CTL}" "${args[@]}" "$@"
}

hm_supervisor_site_needles() {
  # wzorce do filtrowania programów w kontekście strony
  [[ -n "${HM_SITE_DOMAIN:-}" ]] || return 1
  printf '%s\n' "${HM_SITE_DOMAIN}"
  [[ -n "${HM_SITE_ROOT:-}" ]] && printf '%s\n' "${HM_SITE_ROOT}"
  [[ -n "${HM_SITE_DOCROOT:-}" ]] && printf '%s\n' "${HM_SITE_DOCROOT}"
  [[ -n "${HM_SITE_USER:-}" ]] && printf '%s\n' "${HM_SITE_USER}"
  if [[ -n "${HM_SITE_DOMAIN:-}" ]]; then
    printf '%s\n' "/home/${HM_SITE_DOMAIN}"
  fi
}

hm_supervisor_program_matches_site() {
  local name="$1"
  local needle conf_blob=""
  local -a needles=()
  mapfile -t needles < <(hm_supervisor_site_needles 2>/dev/null || true)
  [[ "${#needles[@]}" -gt 0 ]] || return 1

  # nazwa programu
  for needle in "${needles[@]}"; do
    [[ -n "${needle}" ]] || continue
    [[ "${name}" == *"${needle}"* ]] && return 0
  done

  # fragmenty conf (include + główny)
  if [[ -n "${SUPERVISOR_CONF:-}" && -f "${SUPERVISOR_CONF}" ]]; then
    conf_blob="$(cat "${SUPERVISOR_CONF}" 2>/dev/null || true)"
    local inc_dir
    for inc_dir in /etc/supervisor/conf.d /etc/supervisord.d; do
      [[ -d "${inc_dir}" ]] || continue
      local f
      for f in "${inc_dir}"/*.conf "${inc_dir}"/*.ini; do
        [[ -f "${f}" ]] || continue
        conf_blob+=$'\n'"$(cat "${f}" 2>/dev/null || true)"
      done
    done
  fi

  # wyciągnij sekcję [program:name] / [program:name:*] z conf
  local section
  section="$(printf '%s\n' "${conf_blob}" | awk -v n="${name}" '
    BEGIN { show=0 }
    /^\[program:/ {
      show=0
      line=$0
      sub(/^\[program:/, "", line)
      sub(/\].*/, "", line)
      # name lub group:name
      if (line == n || index(n, line ":") == 1 || index(line, n) == 1) show=1
      next
    }
    /^\[/ { show=0 }
    show { print }
  ')"

  for needle in "${needles[@]}"; do
    [[ -n "${needle}" ]] || continue
    [[ "${section}" == *"${needle}"* ]] && return 0
  done
  return 1
}

hm_supervisor_status_lines() {
  hm_supervisor_ctl status 2>/dev/null
}

cmd_supervisor_info() {
  hm_detect_all
  echo "${C_BOLD}Supervisor${C_RESET}"
  echo "  Detected : ${SUPERVISOR:-no}${SUPERVISOR_SOURCE:+  [${SUPERVISOR_SOURCE}]}"
  echo "  ctl      : ${SUPERVISOR_CTL:--}"
  echo "  conf     : ${SUPERVISOR_CONF:--}"
  if hm_have_cmd systemctl; then
    local u st="absent"
    for u in supervisord supervisor; do
      if systemctl cat "${u}" >/dev/null 2>&1; then
        if systemctl is-active --quiet "${u}" 2>/dev/null; then
          st="active (${u})"
        elif systemctl is-enabled --quiet "${u}" 2>/dev/null; then
          st="enabled (${u})"
        else
          st="unit ${u} (inactive)"
        fi
        break
      fi
    done
    echo "  systemd  : ${st}"
  fi
  if [[ "${SUPERVISOR:-no}" == "yes" && -n "${SUPERVISOR_CTL:-}" ]]; then
    echo
    hm_info "Lista: supervisor status   | sterowanie: supervisor start|stop|restart <name>"
  fi
}

cmd_supervisor_status() {
  local force_all="${1:-0}"
  hm_supervisor_require || return 1
  local line name rest
  local filtered=0
  local -a lines=()
  mapfile -t lines < <(hm_supervisor_status_lines || true)
  if [[ "${#lines[@]}" -eq 0 ]]; then
    hm_warn "Brak programów / supervisorctl status pusty."
    return 0
  fi

  if [[ "${force_all}" -eq 0 && -n "${HM_SITE_DOMAIN:-}" ]]; then
    filtered=1
    echo "${C_BOLD}Supervisor — programy (filtr: ${HM_SITE_DOMAIN})${C_RESET}"
    echo "${C_DIM}  (wszystkie: supervisor all)${C_RESET}"
  else
    echo "${C_BOLD}Supervisor — status${C_RESET}"
  fi

  local shown=0
  for line in "${lines[@]}"; do
    [[ -n "${line}" ]] || continue
    name="${line%%[[:space:]]*}"
    rest="${line#"${name}"}"
    if [[ "${filtered}" -eq 1 ]]; then
      if ! hm_supervisor_program_matches_site "${name}"; then
        continue
      fi
    fi
    printf '  %s%s\n' "${name}" "${rest}"
    shown=$((shown + 1))
  done
  if [[ "${filtered}" -eq 1 && "${shown}" -eq 0 ]]; then
    hm_warn "Brak programów pasujących do kontekstu strony. Spróbuj: supervisor all"
  fi
}

cmd_supervisor_logs() {
  local name="${1:-}"
  local n="${2:-50}"
  [[ -n "${name}" ]] || { hm_err "Użycie: supervisor logs <name> [N]"; return 1; }
  [[ "${n}" =~ ^[0-9]+$ ]] || n=50
  hm_supervisor_require || return 1
  if hm_supervisor_ctl tail -"${n}" "${name}" 2>/dev/null; then
    return 0
  fi
  if hm_supervisor_ctl tail "${name}" 2>/dev/null | tail -n "${n}"; then
    return 0
  fi
  hm_err "Nie udało się odczytać logów dla: ${name}"
  return 1
}

cmd_supervisor() {
  local sub="${1:-}"
  case "${sub}" in
    ""|status)
      cmd_supervisor_status 0
      ;;
    all|list)
      cmd_supervisor_status 1
      ;;
    info|detect|show)
      cmd_supervisor_info
      ;;
    start|stop|restart)
      shift || true
      local target="${1:-}"
      [[ -n "${target}" ]] || { hm_err "Użycie: supervisor ${sub} <name|all>"; return 1; }
      hm_supervisor_ctl "${sub}" "${target}"
      ;;
    reread|update)
      hm_supervisor_ctl "${sub}"
      ;;
    logs|log|tail)
      shift || true
      cmd_supervisor_logs "$@"
      ;;
    ctl)
      shift || true
      hm_supervisor_ctl "$@"
      ;;
    help|-h|--help)
      hm_help_topic supervisor
      ;;
    *)
      # nazwę programu traktuj jak status jednego / passthrough
      if [[ "${sub}" == -* ]]; then
        hm_supervisor_ctl "$@"
      else
        hm_err "Nieznana podkomenda: ${sub}. Zobacz: supervisor help"
        return 1
      fi
      ;;
  esac
}

_hm_cmd_register supervisor cmd_supervisor 0
