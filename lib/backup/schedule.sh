#!/usr/bin/env bash
# Backup: harmonogram cron

hm_backup_schedule_cron_path() {
  echo "/etc/cron.d/hmtools-backup"
}

hm_backup_schedule_status() {
  local f
  f="$(hm_backup_schedule_cron_path)"
  echo "${C_BOLD}Backup schedule${C_RESET}"
  if [[ -f "${f}" ]]; then
    echo "  Status : włączony (${f})"
    echo
    sed 's/^/  /' "${f}"
  else
    echo "  Status : wyłączony (brak ${f})"
  fi
  echo
  echo "  BACKUP_SCHEDULE_HOUR=${BACKUP_SCHEDULE_HOUR:-3}"
  echo "  BACKUP_SCHEDULE_PRUNE=${BACKUP_SCHEDULE_PRUNE:-1}  (1 = prune --yes po full)"
  echo "  Log: ${LOG_DIR:-/hm-tools/logs}/backup-cron.log"
}

hm_backup_schedule_enable() {
  hm_load_config
  local f hour prune_line bin logf
  f="$(hm_backup_schedule_cron_path)"
  hour="${BACKUP_SCHEDULE_HOUR:-3}"
  bin="$(command -v hmtools 2>/dev/null || echo "${HMTOOLS_ROOT}/bin/hmtools")"
  logf="${LOG_DIR:-/hm-tools/logs}/backup-cron.log"
  mkdir -p "$(dirname "${logf}")"

  if [[ ! -w "$(dirname "${f}")" ]] && [[ "$(id -u)" -ne 0 ]]; then
    hm_err "Potrzebujesz root, aby zapisać ${f}"
    return 1
  fi

  prune_line=""
  if [[ "${BACKUP_SCHEDULE_PRUNE:-1}" == "1" ]]; then
    local phour=$(( (hour + 1) % 24 ))
    prune_line="30 ${phour} * * * root ${bin} -c \"backup prune --yes\" >> ${logf} 2>&1"
  fi

  cat > "${f}" <<EOF
# hmtools — automatyczny backup (zarządzane przez: backup schedule)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""

# codzienny pełny backup
0 ${hour} * * * root ${bin} -c "backup full" >> ${logf} 2>&1
EOF
  if [[ -n "${prune_line}" ]]; then
    echo "" >> "${f}"
    echo "# rotacja starych kopii" >> "${f}"
    echo "${prune_line}" >> "${f}"
  fi
  chmod 644 "${f}"
  hm_ok "Włączono harmonogram → ${f}"
  hm_backup_schedule_status
}

hm_backup_schedule_disable() {
  local f
  f="$(hm_backup_schedule_cron_path)"
  if [[ ! -f "${f}" ]]; then
    hm_info "Harmonogram już wyłączony."
    return 0
  fi
  if [[ ! -w "$(dirname "${f}")" ]] && [[ "$(id -u)" -ne 0 ]]; then
    hm_err "Potrzebujesz root, aby usunąć ${f}"
    return 1
  fi
  rm -f "${f}"
  hm_ok "Wyłączono harmonogram (usunięto ${f})."
}

hm_backup_schedule() {
  local sub="${1:-status}"
  hm_load_config
  case "${sub}" in
    enable|on|start) hm_backup_schedule_enable ;;
    disable|off|stop) hm_backup_schedule_disable ;;
    status|show|"") hm_backup_schedule_status ;;
    *)
      hm_err "Użycie: backup schedule [enable|disable|status]"
      return 1
      ;;
  esac
}
