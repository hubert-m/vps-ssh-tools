#!/usr/bin/env bash
# Moduł: maintenance — okna serwisowe, harmonogram update/reboot, livepatch, post-check.

_hm_cmd_help maintenance <<'EOF'
Użycie:
  maintenance window set "Sun 03:00-04:00"
  maintenance status
  maintenance schedule update security|packages [--reboot-if-required] [--require-backup]
  maintenance reboot schedule [--at "Sun 03:30"] | cancel
  maintenance post-check [--yes]
  maintenance livepatch status|enable

Okno serwisowe ogranicza rebooty. Po reboocie oneshot weryfikuje usługi i opcjonalnie
monitor http. Tylko raport/notify — livepatch enable wymaga potwierdzenia.
EOF

hm_maint_state_dir() {
  printf '%s' "${HM_MAINT_STATE_DIR:-/var/lib/hmtools/maintenance}"
}

hm_maint_window_file() { printf '%s/window.txt' "$(hm_maint_state_dir)"; }
hm_maint_reboot_file() { printf '%s/reboot.at' "$(hm_maint_state_dir)"; }
hm_maint_sched_file() { printf '%s/schedule.env' "$(hm_maint_state_dir)"; }
hm_maint_unit_dir() { printf '%s' "${HM_MAINT_UNIT_DIR:-/etc/systemd/system}"; }

hm_maint_systemctl() {
  if [[ -n "${HM_MAINT_SYSTEMCTL_LOG:-}" ]]; then
    printf '%s\n' "$*" >> "${HM_MAINT_SYSTEMCTL_LOG}"
    return 0
  fi
  [[ "${HMTOOLS_TEST:-}" == "1" ]] && return 0
  systemctl "$@"
}

hm_maint_notify() {
  local level="$1" title="$2" body="${3:-}"
  if declare -F hm_notify >/dev/null 2>&1; then
    hm_notify "${level}" "${title}" "${body}" 2>/dev/null || true
  fi
  if [[ -n "${HM_MAINT_NOTIFY_LOG:-}" ]]; then
    printf '%s|%s|%s\n' "${level}" "${title}" "${body}" >> "${HM_MAINT_NOTIFY_LOG}"
  fi
}

hm_maint_parse_window() {
  # "Sun 03:00-04:00" → day start end (HHMM)
  local raw="$1" day start end
  [[ "${raw}" =~ ^([A-Za-z]{3})[[:space:]]+([0-9]{1,2}):([0-9]{2})-([0-9]{1,2}):([0-9]{2})$ ]] || return 1
  day="${BASH_REMATCH[1]}"
  start="$(printf '%02d%02d' "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}")"
  end="$(printf '%02d%02d' "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}")"
  printf '%s\t%s\t%s' "${day}" "${start}" "${end}"
}

hm_maint_now_parts() {
  if [[ -n "${HM_MAINT_NOW:-}" ]]; then
    # format: Day HHMM  np. Sun 0315
    printf '%s' "${HM_MAINT_NOW}"
    return 0
  fi
  date '+%a %H%M'
}

hm_maint_in_window() {
  local winfile day start end now_day now_hm
  winfile="$(hm_maint_window_file)"
  [[ -f "${winfile}" ]] || return 1
  IFS=$'\t' read -r day start end < "${winfile}"
  [[ -n "${day}" && -n "${start}" && -n "${end}" ]] || return 1
  read -r now_day now_hm <<<"$(hm_maint_now_parts)"
  [[ "${now_day,,}" == "${day,,}" ]] || return 1
  if [[ "${start}" -le "${end}" ]]; then
    [[ "${now_hm}" -ge "${start}" && "${now_hm}" -le "${end}" ]]
  else
    # przez północ
    [[ "${now_hm}" -ge "${start}" || "${now_hm}" -le "${end}" ]]
  fi
}

hm_maint_window_set() {
  local raw="${1:-}" parsed day start end dir
  [[ -n "${raw}" ]] || {
    hm_err "Użycie: maintenance window set \"Sun 03:00-04:00\""
    return 1
  }
  parsed="$(hm_maint_parse_window "${raw}")" || {
    hm_err "Nieprawidłowe okno: ${raw} (oczekiwane: Day HH:MM-HH:MM)"
    return 1
  }
  IFS=$'\t' read -r day start end <<<"${parsed}"
  dir="$(hm_maint_state_dir)"
  mkdir -p "${dir}"
  printf '%s\t%s\t%s\n' "${day}" "${start}" "${end}" > "$(hm_maint_window_file)"
  chmod 0640 "$(hm_maint_window_file)" 2>/dev/null || true
  hm_ok "Okno serwisowe: ${day} ${start:0:2}:${start:2:2}-${end:0:2}:${end:2:2}"
}

hm_maint_status() {
  local win rb sched live
  echo "${C_BOLD}maintenance${C_RESET}"
  if [[ -f "$(hm_maint_window_file)" ]]; then
    IFS=$'\t' read -r d s e < "$(hm_maint_window_file)"
    printf '  okno       : %s %s:%s-%s:%s\n' "${d}" "${s:0:2}" "${s:2:2}" "${e:0:2}" "${e:2:2}"
    if hm_maint_in_window; then
      printf '  w oknie    : tak\n'
    else
      printf '  w oknie    : nie\n'
    fi
  else
    printf '  okno       : (brak)\n'
  fi
  if [[ -f "$(hm_maint_reboot_file)" ]]; then
    printf '  reboot at  : %s\n' "$(cat "$(hm_maint_reboot_file)")"
  else
    printf '  reboot at  : (brak)\n'
  fi
  if [[ -f "$(hm_maint_sched_file)" ]]; then
    printf '  schedule   :\n'
    sed 's/^/    /' "$(hm_maint_sched_file)"
  else
    printf '  schedule   : (brak)\n'
  fi
  live="$(hm_maint_livepatch_detect)"
  printf '  livepatch  : %s\n' "${live}"
}

hm_maint_require_window_or_fail() {
  if hm_maint_in_window; then
    return 0
  fi
  hm_err "Poza oknem serwisowym — ustaw window albo poczekaj na okno."
  return 1
}

hm_maint_schedule_update() {
  local kind="${1:-security}" reboot_if=0 require_backup=0 a
  shift || true
  for a in "$@"; do
    case "${a}" in
      --reboot-if-required) reboot_if=1 ;;
      --require-backup) require_backup=1 ;;
      *)
        hm_err "Nieznana flaga: ${a}"
        return 1
        ;;
    esac
  done
  case "${kind}" in
    security|packages) ;;
    *)
      hm_err "Użycie: maintenance schedule update security|packages [--reboot-if-required]"
      return 1
      ;;
  esac
  if [[ "${require_backup}" -eq 1 ]]; then
    if ! hm_maint_backup_fresh; then
      hm_err "Wymagana świeża kopia przed aktualizacją (--require-backup; <24h)."
      return 1
    fi
  fi
  mkdir -p "$(hm_maint_state_dir)"
  {
    printf 'KIND=%s\n' "${kind}"
    printf 'REBOOT_IF_REQUIRED=%s\n' "${reboot_if}"
    printf 'REQUIRE_BACKUP=%s\n' "${require_backup}"
    printf 'CREATED=%s\n' "$(date -Iseconds 2>/dev/null || date)"
  } > "$(hm_maint_sched_file)"
  # systemd timer (mockowalny) — co 5 min, żeby okna nie na pełnej godzinie też trafiały
  local unit_dir timer service
  unit_dir="$(hm_maint_unit_dir)"
  mkdir -p "${unit_dir}"
  timer="${unit_dir}/hmtools-maint-update.timer"
  service="${unit_dir}/hmtools-maint-update.service"
  printf '%s\n' '[Unit]' 'Description=hmtools maintenance update' '' '[Service]' 'Type=oneshot' \
    'ExecStart=/usr/bin/hmtools -c "maintenance run-scheduled"' > "${service}"
  printf '%s\n' '[Unit]' 'Description=hmtools maintenance update timer' '' '[Timer]' \
    'OnCalendar=*-*-* *:0/5:00' 'Persistent=true' '' '[Install]' 'WantedBy=timers.target' > "${timer}"
  hm_maint_systemctl daemon-reload
  hm_maint_systemctl enable --now hmtools-maint-update.timer
  hm_maint_notify "info" "maintenance schedule" "Zaplanowano update ${kind}"
  hm_ok "Zaplanowano update ${kind} (timer hmtools-maint-update)."
}

# Bezpieczne KEY=VALUE (whitelist) zamiast source schedule.env.
hm_maint_load_sched() {
  HM_MAINT_KIND="security"
  HM_MAINT_REBOOT_IF=0
  HM_MAINT_REQUIRE_BACKUP=0
  local f line key val
  f="$(hm_maint_sched_file)"
  [[ -f "${f}" ]] || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" =~ ^([A-Z_]+)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    val="${BASH_REMATCH[2]}"
    case "${key}" in
      KIND) HM_MAINT_KIND="${val}" ;;
      REBOOT_IF_REQUIRED) HM_MAINT_REBOOT_IF="${val}" ;;
      REQUIRE_BACKUP) HM_MAINT_REQUIRE_BACKUP="${val}" ;;
      CREATED) ;;
      *) ;;
    esac
  done < "${f}"
  return 0
}

# Świeży backup: HM_MAINT_BACKUP_OK=1 albo znacznik <24h (epoch).
hm_maint_backup_fresh() {
  [[ "${HM_MAINT_BACKUP_OK:-}" == "1" ]] && return 0
  local stamp="${HM_MAINT_BACKUP_STAMP:-$(hm_maint_state_dir)/last-backup.epoch}"
  local now age max=86400
  [[ -f "${stamp}" ]] || return 1
  now="$(date +%s 2>/dev/null || echo 0)"
  age=$((now - $(cat "${stamp}" 2>/dev/null || echo 0)))
  [[ "${age}" -ge 0 && "${age}" -lt "${max}" ]]
}

hm_maint_reboot_due() {
  local at day hh mm now_day now_hm want
  [[ -f "$(hm_maint_reboot_file)" ]] || return 1
  at="$(tr -d '\r\n' < "$(hm_maint_reboot_file)")"
  [[ -n "${at}" ]] || return 1
  [[ "${at}" == "now-in-window" ]] && return 0
  if [[ "${at}" =~ ^([A-Za-z]{3})[[:space:]]+([0-9]{1,2}):([0-9]{2})$ ]]; then
    day="${BASH_REMATCH[1]}"
    hh="$(printf '%02d' "${BASH_REMATCH[2]}")"
    mm="$(printf '%02d' "${BASH_REMATCH[3]}")"
    want="${hh}${mm}"
    read -r now_day now_hm <<<"$(hm_maint_now_parts)"
    [[ "${now_day,,}" == "${day,,}" ]] || return 1
    [[ "${now_hm}" -ge "${want}" ]] || return 1
    return 0
  fi
  return 1
}

hm_maint_run_scheduled() {
  # Wywoływane z timera — tylko w oknie; też sprawdza zaplanowany reboot.
  local kind="security" reboot_if=0 require_backup=0
  if hm_maint_in_window && hm_maint_reboot_due; then
    hm_maint_reboot_maybe || true
  fi
  [[ -f "$(hm_maint_sched_file)" ]] || {
    hm_info "Brak harmonogramu update."
    return 0
  }
  hm_maint_load_sched || return 0
  kind="${HM_MAINT_KIND:-security}"
  reboot_if="${HM_MAINT_REBOOT_IF:-0}"
  require_backup="${HM_MAINT_REQUIRE_BACKUP:-0}"
  hm_maint_require_window_or_fail || return 1
  if [[ "${require_backup}" == "1" ]] && ! hm_maint_backup_fresh; then
    hm_err "run-scheduled: brak świeżej kopii (--require-backup)."
    hm_maint_notify "error" "maintenance update aborted" "require-backup"
    return 1
  fi
  hm_maint_notify "info" "maintenance update start" "Rodzaj: ${kind}"
  if [[ -n "${HM_MAINT_UPDATE_LOG:-}" ]]; then
    printf 'update %s\n' "${kind}" >> "${HM_MAINT_UPDATE_LOG}"
  elif declare -F cmd_update >/dev/null 2>&1; then
    cmd_update "${kind}" --yes 2>/dev/null || true
  fi
  hm_maint_notify "info" "maintenance update done" "Rodzaj: ${kind}"
  if [[ "${reboot_if}" == "1" ]]; then
    local rb="no"
    if [[ -n "${HM_MAINT_REBOOT_REQUIRED:-}" ]]; then
      rb="${HM_MAINT_REBOOT_REQUIRED}"
    elif [[ -f /var/run/reboot-required ]]; then
      rb="yes"
    fi
    if [[ "${rb}" == "yes" ]]; then
      hm_maint_reboot_schedule ""
    fi
  fi
  # Po update: jeśli reboot.at już jest i jesteśmy w oknie — wykonaj.
  if hm_maint_reboot_due; then
    hm_maint_reboot_maybe || true
  fi
  return 0
}

hm_maint_reboot_schedule() {
  local at="${1:-}"
  mkdir -p "$(hm_maint_state_dir)"
  if [[ -z "${at}" ]]; then
    # domyślnie: natychmiast w oknie
    hm_maint_require_window_or_fail || return 1
    at="now-in-window"
  else
    # --at Day HH:MM → zapisz; reboot dopiero gdy w oknie i czas
    if [[ "${at}" =~ ^([A-Za-z]{3})[[:space:]]+([0-9]{1,2}):([0-9]{2})$ ]]; then
      :
    else
      hm_err "Użycie: maintenance reboot schedule [--at \"Sun 03:30\"]"
      return 1
    fi
  fi
  printf '%s\n' "${at}" > "$(hm_maint_reboot_file)"
  # oneshot po reboocie
  local unit_dir service
  unit_dir="$(hm_maint_unit_dir)"
  mkdir -p "${unit_dir}"
  service="${unit_dir}/hmtools-maint-postcheck.service"
  printf '%s\n' '[Unit]' 'Description=hmtools post-reboot check' 'After=network-online.target' \
    '' '[Service]' 'Type=oneshot' 'ExecStart=/usr/bin/hmtools -c "maintenance post-check --yes"' \
    '' '[Install]' 'WantedBy=multi-user.target' > "${service}"
  hm_maint_systemctl daemon-reload
  hm_maint_systemctl enable hmtools-maint-postcheck.service
  hm_maint_notify "warn" "maintenance reboot scheduled" "${at}"
  hm_ok "Zaplanowano reboot: ${at}"
}

hm_maint_reboot_cancel() {
  rm -f "$(hm_maint_reboot_file)"
  hm_maint_systemctl disable hmtools-maint-postcheck.service 2>/dev/null || true
  hm_maint_notify "info" "maintenance reboot cancelled" ""
  hm_ok "Anulowano zaplanowany reboot."
}

hm_maint_reboot_maybe() {
  # Wykonaj reboot tylko w oknie.
  [[ -f "$(hm_maint_reboot_file)" ]] || return 0
  hm_maint_require_window_or_fail || {
    hm_warn "Reboot zaplanowany, ale poza oknem — czekam."
    return 1
  }
  hm_maint_notify "warn" "maintenance reboot now" "W oknie serwisowym"
  if [[ -n "${HM_MAINT_REBOOT_LOG:-}" ]]; then
    printf 'reboot\n' >> "${HM_MAINT_REBOOT_LOG}"
    rm -f "$(hm_maint_reboot_file)"
    return 0
  fi
  [[ "${HMTOOLS_TEST:-}" == "1" ]] && return 0
  /sbin/reboot
}

hm_maint_post_check() {
  local problems=0 line svc
  local -a services=(lsws nginx mysql mariadb redis fail2ban)
  local report=""
  report+="Post-reboot check"$'\n'
  for svc in "${services[@]}"; do
    if [[ -n "${HM_MAINT_SERVICES_FILE:-}" && -f "${HM_MAINT_SERVICES_FILE}" ]]; then
      if grep -qx "${svc}=active" "${HM_MAINT_SERVICES_FILE}"; then
        report+="  OK  ${svc}"$'\n'
      elif grep -q "^${svc}=" "${HM_MAINT_SERVICES_FILE}"; then
        report+="  FAIL ${svc}"$'\n'
        problems=1
      fi
      continue
    fi
    if [[ -n "${HM_MAINT_SYSTEMCTL_LOG:-}" ]]; then
      report+="  OK  ${svc} (mock)"$'\n'
      continue
    fi
    if systemctl is-active --quiet "${svc}" 2>/dev/null; then
      report+="  OK  ${svc}"$'\n'
    elif systemctl list-unit-files "${svc}.service" >/dev/null 2>&1; then
      report+="  FAIL ${svc}"$'\n'
      problems=1
    fi
  done
  if [[ -n "${HM_MAINT_HTTP_FILE:-}" && -f "${HM_MAINT_HTTP_FILE}" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ -n "${line}" ]] || continue
      if [[ "${line}" == *OK* ]]; then
        report+="  HTTP ${line}"$'\n'
      else
        report+="  HTTP FAIL ${line}"$'\n'
        problems=1
      fi
    done < "${HM_MAINT_HTTP_FILE}"
  fi
  printf '%s' "${report}"
  if [[ "${problems}" -eq 0 ]]; then
    hm_maint_notify "info" "maintenance post-check OK" "${report}"
    hm_ok "Post-check: wszystko OK."
    return 0
  fi
  hm_maint_notify "error" "maintenance post-check FAIL" "${report}"
  hm_warn "Post-check: wykryto problemy."
  return 1
}

hm_maint_livepatch_detect() {
  if [[ -n "${HM_MAINT_LIVEPATCH:-}" ]]; then
    printf '%s' "${HM_MAINT_LIVEPATCH}"
    return 0
  fi
  if command -v canonical-livepatch >/dev/null 2>&1; then
    printf 'canonical'
  elif command -v kpatch >/dev/null 2>&1; then
    printf 'kpatch'
  else
    printf 'none'
  fi
}

hm_maint_livepatch() {
  local sub="${1:-status}"
  local kind
  kind="$(hm_maint_livepatch_detect)"
  case "${sub}" in
    status)
      echo "livepatch: ${kind}"
      if [[ "${kind}" == "canonical" && "${HMTOOLS_TEST:-}" != "1" ]]; then
        canonical-livepatch status 2>/dev/null || true
      fi
      ;;
    enable)
      if [[ "${kind}" == "none" ]]; then
        hm_err "Brak Canonical Livepatch / kpatch."
        return 1
      fi
      if [[ "${HMTOOLS_TEST:-}" == "1" ]]; then
        printf 'enable %s\n' "${kind}" >> "${HM_MAINT_LIVEPATCH_LOG:-/dev/null}"
        hm_ok "livepatch enable (test): ${kind}"
        return 0
      fi
      hm_confirm_plan "livepatch enable" "Włączenie ${kind}" "" "livepatch enable" || return 1
      if [[ "${kind}" == "canonical" ]]; then
        canonical-livepatch enable || return 1
      fi
      hm_ok "livepatch enable: ${kind}"
      ;;
    *)
      hm_err "Użycie: maintenance livepatch status|enable"
      return 1
      ;;
  esac
}

cmd_maintenance() {
  local sub="${1:-status}"
  shift || true
  case "${sub}" in
    window)
      case "${1:-}" in
        set) shift || true; hm_maint_window_set "$*" ;;
        *)
          hm_err "Użycie: maintenance window set \"Day HH:MM-HH:MM\""
          return 1
          ;;
      esac
      ;;
    status|"") hm_maint_status ;;
    schedule)
      case "${1:-}" in
        update) shift || true; hm_maint_schedule_update "$@" ;;
        *)
          hm_err "Użycie: maintenance schedule update security|packages …"
          return 1
          ;;
      esac
      ;;
    run-scheduled) hm_maint_run_scheduled ;;
    reboot)
      case "${1:-}" in
        schedule)
          shift || true
          local at=""
          if [[ "${1:-}" == "--at" ]]; then
            shift || true
            at="${1:-}"
            shift || true
          elif [[ "${1:-}" == --at=* ]]; then
            at="${1#*=}"
            shift || true
          fi
          hm_maint_reboot_schedule "${at}"
          ;;
        cancel) hm_maint_reboot_cancel ;;
        maybe|now) hm_maint_reboot_maybe ;;
        *)
          hm_err "Użycie: maintenance reboot schedule|cancel"
          return 1
          ;;
      esac
      ;;
    post-check) hm_maint_post_check "$@" ;;
    livepatch) hm_maint_livepatch "$@" ;;
    help|-h|--help) hm_help_topic maintenance 2>/dev/null || true ;;
    *)
      hm_err "Nieznana podkomenda: ${sub}"
      return 1
      ;;
  esac
}

_hm_cmd_register maintenance cmd_maintenance 1 maint
