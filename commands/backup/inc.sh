#!/usr/bin/env bash
# backup inc — kopie inkrementalne (restic + backend rclone:<remote>:<path>)


hm_restic_pass_file() {
  printf '%s' "${RESTIC_PASSWORD_FILE:-/root/.config/hmtools/restic.pass}"
}

hm_restic_check() {
  if ! hm_have_cmd restic; then
    hm_err "Brak restic. Zainstaluj: https://restic.net/ (lub pakiet distro)."
    return 1
  fi
  return 0
}

hm_restic_repo_for_target() {
  local name="${1:-}"
  local spec path rem base
  spec="$(hm_backup_target_spec "${name}")" || return 1
  spec="$(hm_backup_spec_normalize "${spec}")"
  if hm_backup_spec_is_local "${spec}" || [[ "${spec}" == /* ]]; then
    printf 'local:%s/restic' "${spec%/}"
    return 0
  fi
  # rclone:remote:bucket/path → restic rclone:remote:bucket/path/restic
  rem="${spec%%:*}"
  base="${spec#*:}"
  printf 'rclone:%s:%s/restic' "${rem}" "${base}"
}

hm_restic_ensure_pass() {
  local pf
  pf="$(hm_restic_pass_file)"
  if [[ -f "${pf}" && -s "${pf}" ]]; then
    chmod 600 "${pf}" 2>/dev/null || true
    return 0
  fi
  mkdir -p "$(dirname "${pf}")"
  chmod 700 "$(dirname "${pf}")" 2>/dev/null || true
  if [[ -t 0 ]]; then
    local p1 p2
    read -r -s -p "Hasło repozytorium restic (nie logowane): " p1
    echo
    read -r -s -p "Powtórz hasło: " p2
    echo
    [[ "${p1}" == "${p2}" && -n "${p1}" ]] || { hm_err "Hasła się nie zgadzają / puste."; return 1; }
    printf '%s' "${p1}" > "${pf}"
    unset p1 p2
  else
    hm_err "Brak ${pf} i brak TTY — utwórz plik hasła (0600)."
    return 1
  fi
  chmod 600 "${pf}"
  hm_ok "Zapisano hasło restic → ${pf} (0600; nigdy w applog)."
}

hm_restic_env() {
  export RESTIC_PASSWORD_FILE
  RESTIC_PASSWORD_FILE="$(hm_restic_pass_file)"
}

# restic bez hasła w argv / logach
hm_restic() {
  hm_restic_env
  # nie hm_run — unikamy logowania pełnej linii z repo URL (OK) ale password file path jest OK
  hm_file_log INFO "RUN: restic (password-file)"
  set +e
  restic --password-file "${RESTIC_PASSWORD_FILE}" "$@"
  local rc=$?
  set -e
  hm_file_log INFO "RUN_END: rc=${rc} cmd=restic"
  return "${rc}"
}

hm_backup_inc_init() {
  hm_load_config
  hm_restic_check || return 1
  local target=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target) target="${2:-}"; shift 2 || true ;;
      --target=*) target="${1#*=}"; shift ;;
      help|-h|--help)
        echo "Użycie: backup inc init --target <name>"
        return 0
        ;;
      *) hm_err "Nieznany: $1"; return 1 ;;
    esac
  done
  [[ -n "${target}" ]] || target="$(hm_backup_default_target_name)"
  hm_backup_target_exists "${target}" || { hm_err "Nieznany cel: ${target}"; return 1; }

  local repo
  repo="$(hm_restic_repo_for_target "${target}")" || return 1
  if ! hm_confirm_plan "backup inc init — ${target}" \
    "Hasło repo tylko w $(hm_restic_pass_file) (0600)." \
    "Repo: restic (backend bez sekretów w manifeście)" \
    "Cel hmtools: ${target}"; then
    return 0
  fi
  hm_restic_ensure_pass || return 1
  if [[ "${repo}" == rclone:* ]]; then
    hm_rclone_check || return 1
  fi
  if hm_restic -r "${repo}" snapshots >/dev/null 2>&1; then
    hm_ok "Repo restic już zainicjalizowane (${target})."
    return 0
  fi
  hm_restic -r "${repo}" init || return 1
  hm_ok "Zainicjalizowano restic na celu ${target}."
}

hm_backup_inc_site() {
  hm_load_config
  hm_restic_check || return 1
  local domain="${1:-${HM_SITE_DOMAIN}}" target=""
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target) target="${2:-}"; shift 2 || true ;;
      --target=*) target="${1#*=}"; shift ;;
      *)
        if [[ -z "${domain}" || "${domain}" == --* ]]; then
          domain="$1"; shift
        else
          hm_err "Nieznany: $1"; return 1
        fi
        ;;
    esac
  done
  [[ -n "${domain}" ]] || { hm_err "Użycie: backup inc site <domena> [--target n]"; return 1; }
  if [[ -z "${HM_SITE_DOMAIN}" || "${HM_SITE_DOMAIN}" != "${domain}" ]]; then
    domain="$(hm_find_site_by_arg "${domain}")" || return 1
  fi
  [[ -n "${target}" ]] || target="$(hm_backup_default_target_name)"

  local repo
  repo="$(hm_restic_repo_for_target "${target}")" || return 1
  hm_restic_ensure_pass || return 1
  hm_site_context_push "${domain}" || return 1

  local backup_root
  backup_root="$(hm_backup_resolve_files_root "${HM_SITE_ROOT:-${HM_SITE_DOCROOT}}" "${HM_SITE_USER}")"
  backup_root="$(hm_backup_prefer_docroot_if_shared_home "${domain}" "${backup_root}" "${HM_SITE_DOCROOT}")"
  [[ -d "${backup_root}" ]] || { hm_err "Brak katalogu do backupu."; hm_site_context_pop; return 1; }

  if ! hm_confirm_plan "backup inc site — ${domain}" \
    "" \
    "restic backup ${backup_root} (tag domain=${domain})" \
    "Cel: ${target} (bez sekretów w applog)" \
    "Opcjonalnie: dump DB jako stdin-filename"; then
    hm_site_context_pop
    return 0
  fi

  hm_backup_acquire_lock || { hm_site_context_pop; return 1; }
  trap 'hm_backup_release_lock; hm_site_context_pop' RETURN

  # pliki
  if ! hm_restic -r "${repo}" backup "${backup_root}" \
    --tag "domain=${domain}" --tag "host=${BACKUP_HOST_LABEL:-$(hostname)}" \
    --exclude node_modules --exclude .git; then
    hm_err "restic backup plików nieudany."
    return 1
  fi

  # DB → osobne snapshoty stdin (opcjonalnie, gdy są bazy)
  local name
  while IFS=$'\t' read -r name _ _ _; do
    [[ -n "${name}" ]] || continue
    hm_info "restic: dump DB ${name} (stdin)…"
    local dumpcli
    dumpcli="$(hm_mysqldump_cli)" || continue
    # shellcheck disable=SC2086
    if ! "${dumpcli}" --single-transaction --quick --routines --triggers "${name}" 2>/dev/null \
      | hm_restic -r "${repo}" backup \
        --stdin --stdin-filename "db/${name}.sql" \
        --tag "domain=${domain}" --tag "db=${name}"; then
      hm_warn "restic dump DB ${name} nieudany (kontynuuję)."
    fi
  done < <(hm_dbs_for_site "${domain}" "${HM_SITE_DOCROOT}" "${HM_SITE_ROOT}" "${HM_SITE_USER}")

  hm_ok "Inkrementalny backup ${domain} → cel ${target}."
}

hm_backup_inc_list() {
  hm_load_config
  hm_restic_check || return 1
  local domain="${1:-${HM_SITE_DOMAIN}}" target=""
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target) target="${2:-}"; shift 2 || true ;;
      --target=*) target="${1#*=}"; shift ;;
      *) domain="${domain:-$1}"; shift ;;
    esac
  done
  [[ -n "${target}" ]] || target="$(hm_backup_default_target_name)"
  [[ -n "${domain}" ]] || { hm_err "Użycie: backup inc list <domena> [--target n]"; return 1; }
  local repo
  repo="$(hm_restic_repo_for_target "${target}")" || return 1
  hm_restic_ensure_pass || return 1
  echo "${C_BOLD}restic snapshots — ${domain} @ ${target}${C_RESET}"
  hm_restic -r "${repo}" snapshots --tag "domain=${domain}"
}

hm_backup_inc_restore() {
  hm_load_config
  hm_restic_check || return 1
  local domain="${1:-}" snap="${2:-}" target="" path=""
  shift 2 2>/dev/null || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target) target="${2:-}"; shift 2 || true ;;
      --target=*) target="${1#*=}"; shift ;;
      --path) path="${2:-}"; shift 2 || true ;;
      --path=*) path="${1#*=}"; shift ;;
      *) shift ;;
    esac
  done
  [[ -n "${domain}" && -n "${snap}" ]] || {
    hm_err "Użycie: backup inc restore <domena> <snapshot-id> [--path rel] [--target n]"
    return 1
  }
  [[ -n "${target}" ]] || target="$(hm_backup_default_target_name)"
  if [[ -z "${HM_SITE_DOMAIN}" || "${HM_SITE_DOMAIN}" != "${domain}" ]]; then
    domain="$(hm_find_site_by_arg "${domain}")" || return 1
  fi
  hm_site_context_push "${domain}" || return 1
  local dest="${HM_SITE_ROOT:-${HM_SITE_DOCROOT}}"
  local repo
  repo="$(hm_restic_repo_for_target "${target}")" || { hm_site_context_pop; return 1; }
  hm_restic_ensure_pass || { hm_site_context_pop; return 1; }

  # restic backup zapisuje ścieżki absolutne (backup_root) → restore --target /
  local backup_root include_abs=""
  backup_root="$(hm_backup_resolve_files_root "${HM_SITE_ROOT:-${HM_SITE_DOCROOT}}" "${HM_SITE_USER}")"
  backup_root="$(hm_backup_prefer_docroot_if_shared_home "${domain}" "${backup_root}" "${HM_SITE_DOCROOT}")"
  if [[ -n "${path}" ]]; then
    if [[ "${path}" == /* ]]; then
      include_abs="${path}"
    else
      include_abs="${backup_root%/}/${path#./}"
    fi
  fi

  local -a steps=(
    "restic restore ${snap} --target / (ścieżki absolutne ze snapshotu)"
    "Cel: ${target}"
  )
  [[ -n "${include_abs}" ]] && steps+=("Tylko: ${include_abs}")
  if ! hm_confirm_plan_critical "${domain}" \
    "backup inc restore — ${domain}" \
    "Nadpisanie plików w ${dest} (restic → /)." \
    "${steps[@]}"; then
    hm_site_context_pop
    return 0
  fi

  local -a args=(-r "${repo}" restore "${snap}" --target /)
  if [[ -n "${include_abs}" ]]; then
    args+=(--include "${include_abs}")
  else
    args+=(--include "${backup_root}")
  fi
  hm_restic "${args[@]}" || { hm_site_context_pop; return 1; }
  hm_ok "Przywrócono snapshot ${snap} (${domain})."
  hm_site_context_pop
}

hm_backup_inc_forget() {
  hm_load_config
  hm_restic_check || return 1
  local target="${1:-$(hm_backup_default_target_name)}"
  local repo
  repo="$(hm_restic_repo_for_target "${target}")" || return 1
  hm_restic_ensure_pass || return 1
  local days="${BACKUP_KEEP_DAYS:-14}"
  if ! hm_confirm_plan "backup inc forget — ${target}" \
    "" \
    "restic forget --keep-daily ${days} --keep-weekly 4 --prune"; then
    return 0
  fi
  hm_restic -r "${repo}" forget --keep-daily "${days}" --keep-weekly 4 --prune
}

cmd_backup_inc() {
  local sub="${1:-}"
  shift || true
  case "${sub}" in
    init) hm_backup_inc_init "$@" ;;
    site) hm_backup_inc_site "$@" ;;
    list|ls) hm_backup_inc_list "$@" ;;
    restore) hm_backup_inc_restore "$@" ;;
    forget|prune) hm_backup_inc_forget "$@" ;;
    help|-h|--help|"")
      cat <<'EOF'
Użycie:
  backup inc init --target <n>
  backup inc site <domena> [--target <n>]
  backup inc list <domena> [--target <n>]
  backup inc restore <domena> <snapshot> [--path rel] [--target <n>]
  backup inc forget [--target <n>]

Hasło repo: /root/.config/hmtools/restic.pass (0600). Backend: rclone:<remote>:<path>/restic.
EOF
      ;;
    *)
      hm_err "Nieznane: backup inc ${sub}"
      return 1
      ;;
  esac
}
