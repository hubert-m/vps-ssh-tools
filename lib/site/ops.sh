#!/usr/bin/env bash
# Operacje serwisu: cron/timer, worker, logrotate, health, firewall.

if [[ -n "${HMTOOLS_SITE_OPS_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_SITE_OPS_LOADED=1

hm_site_ops_safe() {
  local s="${1:-}"
  s="${s//[^A-Za-z0-9._-]/_}"
  printf '%s' "${s}"
}

hm_site_ops_verify_unit() {
  local file="$1"
  if [[ -n "${HM_SYSTEMD_ANALYZE:-}" ]]; then
    bash "${HM_SYSTEMD_ANALYZE}" verify "${file}"
    return $?
  fi
  if declare -F hm_have_cmd >/dev/null 2>&1 && hm_have_cmd systemd-analyze; then
    systemd-analyze verify "${file}"
    return $?
  fi
  grep -q '^\[Unit\]' "${file}" || return 1
  grep -q '0.0.0.0' "${file}" && return 1
  if grep -q '^\[Timer\]' "${file}"; then
    return 0
  fi
  grep -q '^\[Service\]' "${file}"
}

hm_site_ops_logrotate_debug() {
  local file="$1"
  if [[ -n "${HM_LOGROTATE_BIN:-}" ]]; then
    bash "${HM_LOGROTATE_BIN}" -d "${file}"
    return $?
  fi
  if declare -F hm_have_cmd >/dev/null 2>&1 && hm_have_cmd logrotate; then
    logrotate -d "${file}"
    return $?
  fi
  grep -q 'daily' "${file}" && grep -q 'rotate 14' "${file}" && grep -q 'compress' "${file}"
}

hm_site_ops_disable() {
  local unit="$1"
  if [[ -n "${HM_SITE_OPS_LOG:-}" ]]; then
    printf 'disable %s\n' "${unit}" >> "${HM_SITE_OPS_LOG}"
  fi
  [[ "${HMTOOLS_TEST:-}" == "1" ]] && return 0
  if declare -F hm_have_cmd >/dev/null 2>&1 && hm_have_cmd systemctl; then
    systemctl disable --now "${unit}" >/dev/null 2>&1 || true
  fi
}

hm_site_ops_remove() {
  local path="$1"
  case "${path}" in
    /usr/*|/bin/*|/sbin/*|/lib/*|/lib64/*) return 1 ;;
  esac
  # nigdy nie kasuj unitu aplikacji — ops nie tworzy hm-app-*
  case "$(basename "${path}")" in
    hm-app-*) return 1 ;;
  esac
  rm -f "${path}"
}

hm_site_ops_is_app_unit() {
  local base
  base="$(basename "${1:-}")"
  [[ "${base}" == hm-app-* ]]
}

hm_site_ops_firewall_backend() {
  if declare -F hm_have_cmd >/dev/null 2>&1; then
    hm_have_cmd ufw && { printf 'ufw'; return 0; }
    hm_have_cmd firewall-cmd && { printf 'firewalld'; return 0; }
    hm_have_cmd csf && { printf 'csf'; return 0; }
  else
    command -v ufw >/dev/null 2>&1 && { printf 'ufw'; return 0; }
    command -v firewall-cmd >/dev/null 2>&1 && { printf 'firewalld'; return 0; }
    command -v csf >/dev/null 2>&1 && { printf 'csf'; return 0; }
  fi
  return 1
}

hm_site_ops_journal_rm() {
  local path="$1"
  [[ -n "${path}" ]] || return 0
  if [[ -n "${HM_TX_JOURNAL:-}" && -f "${HM_TX_JOURNAL}" ]]; then
    # jedna ścieżka — legacy undo odrzuca listy ze spacjami
    printf 'undo=rm -f %s\n' "${path}" >> "${HM_TX_JOURNAL}"
  fi
}

hm_site_ops_journal_unit() {
  local path="$1"
  [[ -n "${path}" ]] || return 0
  if [[ -n "${HM_TX_JOURNAL:-}" && -f "${HM_TX_JOURNAL}" ]]; then
    printf 'undo=systemd-unit\t%s\n' "${path}" >> "${HM_TX_JOURNAL}"
  fi
}

# Rollback wyłącznie zasobów ops (worker/timer/cron/logrotate/firewall).
# Nigdy kind=unit ani hm-app-*. Opcjonalnie: tylko podane ścieżki (ta transakcja).
hm_site_ops_rollback() {
  local domain="$1"
  shift || true
  local -a only=("$@")
  local file line path base kind
  local -A allow=()
  local p
  for p in "${only[@]+"${only[@]}"}"; do
    [[ -n "${p}" ]] && allow["${p}"]=1
  done
  file="$(hm_site_resources_path "${domain}")"
  [[ -f "${file}" ]] || {
    for p in "${only[@]+"${only[@]}"}"; do
      [[ -n "${p}" ]] || continue
      hm_site_ops_is_app_unit "${p}" && continue
      case "$(basename "${p}")" in
        hm-worker-*|hm-cron-*) hm_site_ops_disable "$(basename "${p}")" ;;
      esac
      hm_site_ops_remove "${p}" || true
    done
    return 0
  }
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    hm_site_resource_read "${line}" || continue
    kind="${HM_SITE_RES_KIND}"
    path="${HM_SITE_RES_PATH}"
    base="$(basename "${path}")"
    # nigdy aplikacja
    [[ "${kind}" == "unit" ]] && continue
    hm_site_ops_is_app_unit "${path}" && continue
    if [[ "${#allow[@]}" -gt 0 && -z "${allow[${path}]+x}" ]]; then
      continue
    fi
    case "${kind}" in
      worker|timer|cron)
        hm_site_ops_disable "${base}"
        hm_site_ops_remove "${path}" || true
        ;;
      logrotate)
        hm_site_ops_remove "${path}" || true
        ;;
      firewall)
        hm_site_ops_firewall_undo "${path}" || true
        hm_site_ops_remove "${path}" || true
        ;;
    esac
  done < "${file}"
}

# Wycofaj regułę z snippeta (port/proto # hm:domena).
hm_site_ops_firewall_undo() {
  local snip="$1" line port proto=""
  [[ -f "${snip}" && ! -L "${snip}" ]] || return 0
  line="$(head -n 1 "${snip}" 2>/dev/null || true)"
  [[ -n "${line}" ]] || return 0
  port="${line%%/*}"
  proto="${line#*/}"
  proto="${proto%% *}"
  proto="${proto%%#*}"
  proto="$(printf '%s' "${proto}" | tr -d '[:space:]')"
  [[ "${port}" =~ ^[0-9]+$ ]] || return 0
  [[ -n "${proto}" ]] || proto="tcp"
  if [[ -n "${HM_SITE_OPS_LOG:-}" ]]; then
    printf 'firewall delete %s/%s\n' "${port}" "${proto}" >> "${HM_SITE_OPS_LOG}"
  fi
  if declare -F hm_os_firewall_remove >/dev/null 2>&1; then
    hm_os_firewall_remove "${port}" "${proto}" 2>/dev/null || hm_warn "Nie usunięto reguły firewall ${port}/${proto}."
  fi
}

hm_site_ops_is_active() {
  local unit="$1" state=""
  if [[ -n "${HM_SYSTEMCTL_STATE:-}" && -f "${HM_SYSTEMCTL_STATE}" ]]; then
    state="$(awk -v u="${unit}" '$1 == u { print $2 }' "${HM_SYSTEMCTL_STATE}")"
    printf '%s' "${state:-inactive}"
    return 0
  fi
  if declare -F hm_have_cmd >/dev/null 2>&1 && hm_have_cmd systemctl; then
    systemctl is-active "${unit}" 2>/dev/null || printf 'inactive'
    return 0
  fi
  printf 'inactive'
}

hm_site_ops_health_alerts() {
  local -a regs=()
  local f reg unit state
  if [[ -n "${HM_SITE_HEALTH_REG:-}" && -f "${HM_SITE_HEALTH_REG}" ]]; then
    regs+=("${HM_SITE_HEALTH_REG}")
  elif [[ -n "${HM_SITE_HOME_BASE:-}" && -d "${HM_SITE_HOME_BASE}" ]]; then
    while IFS= read -r f; do
      [[ -n "${f}" ]] && regs+=("${f}")
    done < <(find "${HM_SITE_HOME_BASE}" -type f -name health.units 2>/dev/null)
  fi
  for reg in "${regs[@]:-}"; do
    [[ -n "${reg}" && -f "${reg}" ]] || continue
    while IFS= read -r unit || [[ -n "${unit}" ]]; do
      [[ -n "${unit}" ]] || continue
      [[ "${unit}" == url=* ]] && continue
      state="$(hm_site_ops_is_active "${unit}")"
      [[ "${state}" == "active" ]] || printf 'service:failed:%s\n' "${unit}"
    done < "${reg}"
  done
}

hm_site_ops_php_bin() {
  local domain="$1" ver="" man
  ver="${HM_SITE_RUNTIME_VERSION:-}"
  man="$(hm_site_manifest_path "${domain}" 2>/dev/null || true)"
  if [[ -z "${ver}" && -n "${man}" && -f "${man}" ]]; then
    ver="$(sed -n 's/.*"type":"php","version":"\([^"]*\)".*/\1/p' "${man}" | head -1)"
  fi
  if [[ -z "${ver}" && -n "${man}" && -f "${man}" ]]; then
    ver="$(sed -n 's/.*"version":"\([^"]*\)".*/\1/p' "${man}" | head -1)"
  fi
  if [[ -n "${ver}" ]]; then
    printf '/usr/bin/php%s' "${ver}"
    return 0
  fi
  printf '/usr/bin/php'
}

hm_site_ops_node_bin() {
  local home="$1" domain="$2" ver="" man
  man="$(hm_site_manifest_path "${domain}" 2>/dev/null || true)"
  if [[ -n "${man}" && -f "${man}" ]]; then
    ver="$(sed -n 's/.*"type":"node","version":"\([^"]*\)".*/\1/p' "${man}" | head -1)"
  fi
  if [[ -z "${ver}" && -f "${home}/.nvmrc" ]]; then
    ver="$(tr -d '[:space:]' < "${home}/.nvmrc")"
  fi
  ver="${ver#v}"
  if [[ -n "${ver}" ]]; then
    printf '%s/.nvm/versions/node/v%s/bin/node' "${home}" "${ver}"
    return 0
  fi
  printf '/usr/bin/node'
}

hm_site_ops_env_file() {
  local home="$1" domain="$2" envf line
  envf="${home}/.env"
  if [[ -f "${envf}" ]]; then
    line="$(ls -ld -- "${envf}" 2>/dev/null || true)"
    if [[ "${line}" != *"->"* ]]; then
      printf '%s' "${envf}"
      return 0
    fi
  fi
  printf '%s' "$(hm_site_state_dir "${domain}")/app.env"
}

hm_site_ops_enable_now() {
  local name
  for name in "$@"; do
    [[ -n "${name}" ]] || continue
    if [[ -n "${HM_SITE_OPS_LOG:-}" ]]; then
      printf 'enable %s\n' "${name}" >> "${HM_SITE_OPS_LOG}"
    fi
  done
  [[ "${HMTOOLS_TEST:-}" == "1" ]] && return 0
  declare -F hm_have_cmd >/dev/null 2>&1 && hm_have_cmd systemctl || return 0
  systemctl daemon-reload || return 1
  for name in "$@"; do
    [[ -n "${name}" ]] || continue
    systemctl enable --now "${name}" || return 1
  done
}

hm_site_ops_cron_exec() {
  local domain="$1" home="$2" kind="$3" cmd="$4" php
  php="$(hm_site_ops_php_bin "${domain}")"
  case "${kind}" in
    laravel)
      printf '%s %s/artisan schedule:run' "${php}" "${home}"
      ;;
    wp)
      printf 'DISABLE_WP_CRON=true\n' | hm_site_write_nofollow "$(hm_site_state_dir "${domain}")/wp-cron.env" || return 1
      printf '/usr/bin/wp cron event run --due-now --path=%s' "${home}"
      ;;
    django)
      printf '%s/venv/bin/python %s/manage.py %s' "${home}" "${home}" "${cmd:-clearsessions}"
      ;;
    *)
      printf '%s' "${cmd:-/usr/bin/true}"
      ;;
  esac
}

hm_site_ops_worker_exec() {
  local home="$1" kind="$2" domain="$3" php node
  php="$(hm_site_ops_php_bin "${domain}")"
  node="$(hm_site_ops_node_bin "${home}" "${domain}")"
  case "${kind}" in
    queue) printf '%s %s/artisan queue:work --tries=3' "${php}" "${home}" ;;
    celery) printf '%s/venv/bin/celery -A app worker' "${home}" ;;
    node) printf '%s %s/worker.js' "${node}" "${home}" ;;
    dotnet)
      printf '%s %s/current/%s' \
        "$(command -v dotnet 2>/dev/null || echo /usr/bin/dotnet)" \
        "${home}" \
        "${HM_SITE_DOTNET_DLL:-App.dll}"
      ;;

    *) return 1 ;;
  esac
}

hm_site_ops_apply() {
  local domain="$1" cron_kind="${2:-}" cron_cmd="${3:-}" worker_kind="${4:-}"
  local workers="${5:-1}" health_path="${6:-}" open_port="${7:-}"
  local home safe unitdir lrdir fwdir lr svc tmr wexec mem reg pub snip envf
  local i exec
  local -a enable_units=() created_paths=()
  if [[ -z "${cron_kind}" && -n "${cron_cmd}" ]]; then
    cron_kind="cmd"
  fi
  case "${cron_cmd}" in
    *$'\n'*|*$'\r'*) hm_err "Komenda crona zawiera niedozwolony znak."; return 1 ;;
  esac
  home="$(hm_site_home "${domain}")"
  safe="$(hm_site_ops_safe "${domain}")"
  unitdir="${HM_SITE_SYSTEMD_DIR:-/etc/systemd/system}"
  lrdir="${HM_SITE_LOGROTATE_DIR:-/etc/logrotate.d}"
  fwdir="${HM_SITE_FW_DIR:-/etc/hmtools/firewall}"
  [[ "${workers}" =~ ^[0-9]+$ ]] || workers=1
  [[ "${workers}" -ge 1 ]] || workers=1
  if [[ -n "${open_port}" ]]; then
    if [[ ! "${open_port}" =~ ^[0-9]+$ ]] || [[ "${open_port}" -lt 1 || "${open_port}" -gt 65535 ]]; then
      hm_err "Port firewalla musi być w zakresie 1–65535."
      return 1
    fi
  fi
  mkdir -p "${home}/logs" "$(hm_site_state_dir "${domain}")" "${unitdir}" "${lrdir}" "${fwdir}"
  chmod 0750 "${home}/logs" 2>/dev/null || true
  if [[ "$(id -u)" -eq 0 && -n "${HM_SITE_USER:-}" ]]; then
    chown "${HM_SITE_USER}:${HM_SITE_USER}" "${home}/logs" 2>/dev/null || true
  fi

  lr="${lrdir}/hm-${safe}"
  cat > "${lr}" <<EOF
${home}/logs/*.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
    copytruncate
}
EOF
  hm_site_resource_add "${domain}" logrotate "${lr}" 0
  created_paths+=("${lr}")
  hm_site_ops_journal_rm "${lr}"
  if ! hm_site_ops_logrotate_debug "${lr}"; then
    hm_site_ops_rollback "${domain}" "${created_paths[@]}"
    hm_err "logrotate odrzucił konfigurację ${domain}."
    return 1
  fi

  if [[ -n "${cron_kind}" ]]; then
    exec="$(hm_site_ops_cron_exec "${domain}" "${home}" "${cron_kind}" "${cron_cmd}")"
    svc="${unitdir}/hm-cron-${safe}-schedule.service"
    tmr="${unitdir}/hm-cron-${safe}-schedule.timer"
    envf="$(hm_site_ops_env_file "${home}" "${domain}")"
    cat > "${svc}" <<EOF
[Unit]
Description=hm cron ${domain}

[Service]
Type=oneshot
User=${HM_SITE_USER:-${safe}}
WorkingDirectory=${home}
EnvironmentFile=-${envf}
NoNewPrivileges=true
PrivateTmp=true
ExecStart=${exec}
EOF
    cat > "${tmr}" <<EOF
[Unit]
Description=hm cron ${domain}

[Timer]
OnCalendar=minutely
Unit=hm-cron-${safe}-schedule.service

[Install]
WantedBy=timers.target
EOF
    hm_site_resource_add "${domain}" cron "${svc}" 0
    hm_site_resource_add "${domain}" timer "${tmr}" 0
    created_paths+=("${svc}" "${tmr}")
    hm_site_ops_journal_unit "${svc}"
    hm_site_ops_journal_unit "${tmr}"
    if ! hm_site_ops_verify_unit "${svc}" || ! hm_site_ops_verify_unit "${tmr}"; then
      hm_site_ops_rollback "${domain}" "${created_paths[@]}"
      hm_err "systemd-analyze odrzucił timer ${domain}."
      return 1
    fi
    enable_units+=("hm-cron-${safe}-schedule.timer")
  fi

  if [[ -n "${worker_kind}" ]]; then
    wexec="$(hm_site_ops_worker_exec "${home}" "${worker_kind}" "${domain}")" || {
      hm_err "Nieznany worker: ${worker_kind}"
      hm_site_ops_rollback "${domain}" "${created_paths[@]}"
      return 1
    }
    mem="${HM_SITE_MEMORY_MAX:-512M}"
    envf="$(hm_site_ops_env_file "${home}" "${domain}")"
    svc="${unitdir}/hm-worker-${safe}@.service"
    cat > "${svc}" <<EOF
[Unit]
Description=hm worker ${domain}

[Service]
Type=simple
User=${HM_SITE_USER:-${safe}}
WorkingDirectory=${home}
EnvironmentFile=-${envf}
NoNewPrivileges=true
ProtectSystem=strict
PrivateTmp=true
ReadWritePaths=${home}
Restart=always
MemoryMax=${mem}
KillSignal=SIGTERM
TimeoutStopSec=30
ExecStart=${wexec}

[Install]
WantedBy=multi-user.target
EOF
    hm_site_resource_add "${domain}" worker "${svc}" 0
    created_paths+=("${svc}")
    hm_site_ops_journal_unit "${svc}"
    if ! hm_site_ops_verify_unit "${svc}"; then
      hm_site_ops_rollback "${domain}" "${created_paths[@]}"
      hm_err "systemd-analyze odrzucił worker ${domain}."
      return 1
    fi
    if [[ -n "${HM_SITE_HEALTH_REG:-}" ]]; then
      reg="${HM_SITE_HEALTH_REG}"
    else
      reg="$(hm_site_state_dir "${domain}")/health.units"
    fi
    {
      for ((i = 1; i <= workers; i++)); do
        printf 'hm-worker-%s@%s.service\n' "${safe}" "${i}"
      done
    } | hm_site_write_nofollow "${reg}" || {
      hm_site_ops_rollback "${domain}" "${created_paths[@]}"
      return 1
    }
    for ((i = 1; i <= workers; i++)); do
      enable_units+=("hm-worker-${safe}@${i}.service")
    done
  fi

  if [[ -n "${health_path}" ]]; then
    printf 'https://%s%s\n' "${domain}" "${health_path}" | hm_site_write_nofollow "$(hm_site_state_dir "${domain}")/health.url"
  fi

  pub="${fwdir}/public.rules"
  if [[ ! -f "${pub}" ]]; then
    printf '80/tcp\n443/tcp\n' > "${pub}"
  fi
  if [[ -n "${open_port}" ]]; then
    snip="${fwdir}/hm-${safe}.rules"
    printf '%s/tcp # hm:%s\n' "${open_port}" "${domain}" > "${snip}"
    hm_site_resource_add "${domain}" firewall "${snip}" 0
    created_paths+=("${snip}")
    hm_site_ops_journal_rm "${snip}"
    if [[ -n "${HM_SITE_OPS_LOG:-}" ]]; then
      printf 'firewall allow %s/tcp hm:%s\n' "${open_port}" "${domain}" >> "${HM_SITE_OPS_LOG}"
    fi
    # opcjonalne: brak backendu / błąd allow = ostrzeżenie, bez rollbacku strony/ops
    if [[ "${HMTOOLS_TEST:-}" == "1" ]]; then
      if declare -F hm_os_firewall_allow >/dev/null 2>&1; then
        hm_os_firewall_allow "${open_port}" tcp "" "hm:${domain}" || true
      fi
    elif ! hm_site_ops_firewall_backend >/dev/null 2>&1; then
      hm_warn "Brak ufw/firewalld/csf — zapisano snippet ${snip}, reguła nie zastosowana."
    elif declare -F hm_os_firewall_allow >/dev/null 2>&1; then
      if ! hm_os_firewall_allow "${open_port}" tcp "" "hm:${domain}"; then
        hm_warn "Firewall nie przyjął portu ${open_port} — snippet zapisany, reszta ops bez zmian."
      else
        # marker: reguła dodana w tym przebiegu (rollback wywoła remove)
        printf 'applied=1\n' >> "${snip}"
      fi
    else
      hm_warn "Brak hm_os_firewall_allow — snippet zapisany bez aplikacji reguły."
    fi
  fi
  if [[ "${#enable_units[@]}" -gt 0 ]]; then
    hm_site_ops_enable_now "${enable_units[@]}" || {
      hm_site_ops_rollback "${domain}" "${created_paths[@]}"
      hm_err "systemctl nie włączył jednostek ${domain}."
      return 1
    }
  fi
  if [[ "${HM_SITE_DOCKER:-}" == "1" ]]; then
    hm_warn "Docker omija UFW — porty kontenera mogą być publiczne."
  fi
  if [[ "${HM_SITE_BACKUP:-}" == "1" ]]; then
    local blist="${HM_SITE_BACKUP_LIST:-$(hm_site_state_dir "${domain}")/backup.list}"
    if [[ -L "${blist}" ]]; then
      hm_err "Odmowa zapisu listy backupu przez symlink."
      return 1
    fi
    printf '%s\n' "${domain}" >> "${blist}"
  fi
  hm_ok "Operacje ${domain}: logi, cron, workery, firewall."
}
