#!/usr/bin/env bash
# Moduł: supervisor — status / sterowanie / logi programów Supervisord

_hm_cmd_help supervisor <<'EOF'
Użycie:
  supervisor | status          Lista programów (w kontekście: filtr pod stronę)
  supervisor all               Wszystkie programy (bez filtra kontekstu)
  supervisor info              Wykrycie: ctl, conf, systemd
  supervisor start|stop|restart <name|all> [--yes]
  supervisor reread | update   Przeładowanie konfiguracji
  supervisor logs <name> [N]   Ostatnie N linii (domyślnie 50)
  supervisor ctl …             Passthrough do supervisorctl

W kontekście use: „all” = tylko programy strony (nie cały serwer).
Wymaga supervisorctl. Szczegóły: detect
EOF

hm_supervisor_require() {
  hm_detect_supervisor 2>/dev/null || true
  # FORCE zawsze wygrywa — nie „odkrywaj” ctl gdy wymuszono no
  if [[ -n "${FORCE_SUPERVISOR:-}" ]]; then
    case "${FORCE_SUPERVISOR}" in
      yes)
        SUPERVISOR="yes"
        SUPERVISOR_SOURCE="override:FORCE_SUPERVISOR"
        if [[ -z "${SUPERVISOR_CTL:-}" ]]; then
          if hm_have_cmd supervisorctl; then
            SUPERVISOR_CTL="$(command -v supervisorctl)"
          elif [[ -x /usr/bin/supervisorctl ]]; then
            SUPERVISOR_CTL="/usr/bin/supervisorctl"
          fi
        fi
        ;;
      no)
        SUPERVISOR="no"
        SUPERVISOR_SOURCE="override:FORCE_SUPERVISOR"
        SUPERVISOR_CTL=""
        hm_err "Supervisor wyłączony (FORCE_SUPERVISOR=no)."
        return 1
        ;;
    esac
  fi
  if [[ "${SUPERVISOR:-no}" != "yes" ]]; then
    if [[ -n "${SUPERVISOR_CONF:-}" ]]; then
      hm_err "Wykryto konfigurację Supervisor (${SUPERVISOR_CONF}), ale brak supervisorctl."
    else
      hm_err "Brak supervisorctl — Supervisor nie jest zainstalowany / nie wykryty."
    fi
    hm_info "Sprawdź: detect   | nadpisanie: FORCE_SUPERVISOR=yes|no w hmtools.conf"
    return 1
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

hm_supervisor_conf_blob() {
  local conf_blob="" f inc_dir
  if [[ -n "${SUPERVISOR_CONF:-}" && -f "${SUPERVISOR_CONF}" ]]; then
    conf_blob="$(cat "${SUPERVISOR_CONF}" 2>/dev/null || true)"
  fi
  for inc_dir in /etc/supervisor/conf.d /etc/supervisord.d; do
    [[ -d "${inc_dir}" ]] || continue
    for f in "${inc_dir}"/*.conf "${inc_dir}"/*.ini; do
      [[ -f "${f}" ]] || continue
      conf_blob+=$'\n'"$(cat "${f}" 2>/dev/null || true)"
    done
  done
  printf '%s' "${conf_blob}"
}

hm_supervisor_program_section() {
  local name="$1"
  local conf_blob
  conf_blob="$(hm_supervisor_conf_blob)"
  printf '%s\n' "${conf_blob}" | awk -v n="${name}" '
    BEGIN { show=0 }
    /^\[program:/ {
      show=0
      line=$0
      sub(/^\[program:/, "", line)
      sub(/\].*/, "", line)
      base=line
      sub(/:.*/, "", base)
      if (line == n || base == n || index(n, line ":") == 1) show=1
      next
    }
    /^\[/ { show=0 }
    show { print }
  '
}

hm_supervisor_program_matches_site() {
  local name="$1"
  [[ -n "${HM_SITE_DOMAIN:-}" ]] || return 1

  # 1) pełna domena w nazwie programu
  [[ "${name}" == *"${HM_SITE_DOMAIN}"* ]] && return 0

  # 2) ścieżki strony (długie — bezpieczne substringi)
  local path
  for path in "${HM_SITE_ROOT:-}" "${HM_SITE_DOCROOT:-}" "/home/${HM_SITE_DOMAIN}"; do
    [[ -n "${path}" ]] || continue
    [[ "${name}" == *"${path}"* ]] && return 0
  done

  local section
  section="$(hm_supervisor_program_section "${name}")"
  [[ -n "${section}" ]] || return 1

  for path in "${HM_SITE_ROOT:-}" "${HM_SITE_DOCROOT:-}" "/home/${HM_SITE_DOMAIN}"; do
    [[ -n "${path}" ]] || continue
    [[ "${section}" == *"${path}"* ]] && return 0
  done
  [[ "${section}" == *"${HM_SITE_DOMAIN}"* ]] && return 0

  # 3) user= — tylko dokładna wartość (nie substring nazwy programu)
  if [[ -n "${HM_SITE_USER:-}" ]]; then
    local conf_user
    conf_user="$(printf '%s\n' "${section}" | awk -F= '
      tolower($1) ~ /^[[:space:]]*user[[:space:]]*$/ {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
        print $2
        exit
      }
    ')"
    [[ -n "${conf_user}" && "${conf_user}" == "${HM_SITE_USER}" ]] && return 0
  fi
  return 1
}

hm_supervisor_filtered_names() {
  # nazwy programów pasujących do kontekstu strony (stdout)
  local line name
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    name="${line%%[[:space:]]*}"
    hm_supervisor_program_matches_site "${name}" || continue
    printf '%s\n' "${name}"
  done < <(hm_supervisor_ctl status 2>/dev/null || true)
}

# Wszystkie nazwy programów (group:process) — cicho, do Tab / skryptów.
hm_supervisor_list_names() {
  hm_detect_supervisor >/dev/null 2>&1 || true
  [[ "${SUPERVISOR:-no}" == "yes" ]] || return 0
  local ctl="${SUPERVISOR_CTL:-}"
  [[ -n "${ctl}" && -x "${ctl}" ]] || return 0
  local -a args=()
  if [[ -n "${SUPERVISOR_CONF:-}" && -f "${SUPERVISOR_CONF}" ]]; then
    args+=(-c "${SUPERVISOR_CONF}")
  fi
  local line name
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    name="${line%%[[:space:]]*}"
    [[ -n "${name}" ]] || continue
    printf '%s\n' "${name}"
  done < <("${ctl}" "${args[@]}" status 2>/dev/null || true)
}

hm_supervisor_status_lines() {
  hm_supervisor_ctl status 2>/dev/null
}

hm_supervisor_logfile() {
  local name="$1"
  local section key val
  section="$(hm_supervisor_program_section "${name}")"
  for key in stdout_logfile stderr_logfile; do
    val="$(printf '%s\n' "${section}" | awk -F= -v k="${key}" '
      BEGIN { lk=tolower(k) }
      {
        f=$1
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", f)
        if (tolower(f) == lk) {
          v=$0
          sub(/^[^=]*=/, "", v)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
          print v
          exit
        }
      }
    ')"
    if [[ -n "${val}" && "${val}" != "AUTO" && "${val}" != "NONE" && -f "${val}" ]]; then
      printf '%s' "${val}"
      return 0
    fi
  done
  return 1
}

cmd_supervisor_info() {
  hm_detect_all
  echo "${C_BOLD}Supervisor${C_RESET}"
  echo "  Detected : ${SUPERVISOR:-no}${SUPERVISOR_SOURCE:+  [${SUPERVISOR_SOURCE}]}"
  if [[ "${SUPERVISOR:-no}" == "yes" ]]; then
    echo "  ctl      : ${SUPERVISOR_CTL:--}"
  else
    echo "  ctl      : —"
  fi
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
  elif [[ -n "${SUPERVISOR_CONF:-}" ]]; then
    hm_warn "Jest conf, ale brak supervisorctl — komendy sterujące niedostępne."
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
    echo "${C_DIM}  (pełna lista serwera: supervisor all)${C_RESET}"
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

  local logf
  if logf="$(hm_supervisor_logfile "${name}")"; then
    echo "${C_DIM}# ${logf} (ostatnie ${n} linii)${C_RESET}"
    tail -n "${n}" "${logf}"
    return 0
  fi

  # supervisorctl tail -N = bajty — bierzemy duży bufor i tnemy do N linii
  local raw
  raw="$(hm_supervisor_ctl tail -1048576 "${name}" 2>/dev/null || true)"
  if [[ -n "${raw}" ]]; then
    printf '%s\n' "${raw}" | tail -n "${n}"
    return 0
  fi
  raw="$(hm_supervisor_ctl tail "${name}" 2>/dev/null || true)"
  if [[ -n "${raw}" ]]; then
    printf '%s\n' "${raw}" | tail -n "${n}"
    return 0
  fi
  hm_err "Nie udało się odczytać logów dla: ${name}"
  return 1
}

cmd_supervisor_action() {
  local action="$1"
  local target="$2"
  local yes="${3:-0}"
  hm_supervisor_require || return 1

  if [[ "${target}" != "all" ]]; then
    hm_supervisor_ctl "${action}" "${target}"
    return $?
  fi

  # „all” w kontekście strony = tylko programy strony
  if [[ -n "${HM_SITE_DOMAIN:-}" ]]; then
    local -a names=()
    mapfile -t names < <(hm_supervisor_filtered_names)
    if [[ "${#names[@]}" -eq 0 ]]; then
      hm_warn "Brak programów strony ${HM_SITE_DOMAIN} do: ${action}"
      return 0
    fi
    local -a plan=()
    local p
    for p in "${names[@]}"; do
      plan+=("${action} ${p}")
    done
    local yes_flag=()
    [[ "${yes}" -eq 1 ]] && yes_flag=(--yes)
    if ! hm_confirm_plan "supervisor ${action} (kontekst ${HM_SITE_DOMAIN})" \
      "Tylko programy tej strony (${#names[@]})." \
      "${yes_flag[@]}" \
      "${plan[@]}"; then
      return 1
    fi
    local rc=0
    for p in "${names[@]}"; do
      hm_supervisor_ctl "${action}" "${p}" || rc=$?
    done
    return "${rc}"
  fi

  # globalne all — potwierdzenie
  local yes_flag=()
  [[ "${yes}" -eq 1 ]] && yes_flag=(--yes)
  if ! hm_confirm_plan "supervisor ${action} all" \
    "Dotknie WSZYSTKICH programów Supervisora na serwerze." \
    "${yes_flag[@]}" \
    "${action} all (supervisorctl)"; then
    return 1
  fi
  hm_supervisor_ctl "${action}" all
}

cmd_supervisor() {
  local sub="${1:-}"
  local yes=0
  local -a raw=("$@")
  local a
  for a in "${raw[@]}"; do
    case "${a}" in
      --yes|-y) yes=1 ;;
    esac
  done
  # usuń flagi z listy argumentów roboczych
  set --
  for a in "${raw[@]}"; do
    case "${a}" in
      --yes|-y) ;;
      *) set -- "$@" "${a}" ;;
    esac
  done
  sub="${1:-}"

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
      [[ -n "${target}" ]] || { hm_err "Użycie: supervisor ${sub} <name|all> [--yes]"; return 1; }
      cmd_supervisor_action "${sub}" "${target}" "${yes}"
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
