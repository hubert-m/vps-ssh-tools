#!/usr/bin/env bash
# Backup: rotacja starych snapshotów

hm_backup_stamp_epoch() {
  local stamp="$1"
  # YYYYMMDD-HHMMSS → epoch
  if [[ ! "${stamp}" =~ ^[0-9]{8}-[0-9]{6}(-[0-9]+)?$ ]]; then
    echo 0
    return
  fi
  local y="${stamp:0:4}" m="${stamp:4:2}" d="${stamp:6:2}"
  local H="${stamp:9:2}" M="${stamp:11:2}" S="${stamp:13:2}"
  date -d "${y}-${m}-${d} ${H}:${M}:${S}" +%s 2>/dev/null \
    || date -j -f "%Y%m%d-%H%M%S" "${stamp}" +%s 2>/dev/null \
    || echo 0
}

hm_backup_prune_is_archive() {
  local json="$1" type archived
  type="$(hm_backup_json_str "${json}" "type")"
  archived="$(hm_backup_json_str "${json}" "archived")"
  [[ "${type}" == "archive" || "${archived}" == "true" ]]
}

hm_backup_prune_scope() {
  # prune jednej ścieżki względnej (domena|full): wypisuje remote_base do usunięcia.
  # rc≠0 gdy błąd odczytu manifestu — caller pomija całą domenę (żadnego purge).
  local rel="$1" days="$2" keep_min="$3" now cutoff
  now="$(date +%s)"
  cutoff=$((now - days * 86400))

  local -a stamps=()
  local s
  while IFS= read -r s; do
    [[ -n "${s}" ]] && stamps+=("${s}")
  done < <(hm_backup_list_stamps "${rel}")

  local total="${#stamps[@]}"
  local i=0 epoch remote_base grace_h grace_cut json rc type
  local -a keepable=()
  local -a keepable_json=()
  grace_h="${BACKUP_ORPHAN_GRACE_HOURS:-24}"
  [[ "${grace_h}" =~ ^[0-9]+$ ]] || grace_h=24
  grace_cut=$((now - grace_h * 3600))

  for s in "${stamps[@]}"; do
    remote_base="$(hm_rclone_dest "${rel}/${s}")"
    rc=0
    json="$(hm_backup_cat_manifest "${remote_base}")" || rc=$?
    if [[ "${rc}" -eq 1 ]]; then
      hm_err "Przerywam prune dla ${rel}: błąd odczytu manifestu (${s}) — nic nie kasuję w tej domenie."
      return 1
    fi
    # type=archive: nigdy automatycznie
    if [[ "${rc}" -eq 0 && -n "${json}" ]] && hm_backup_prune_is_archive "${json}"; then
      keepable+=("${s}")
      keepable_json+=("${json}")
      continue
    fi
    # Orphan: brak manifestu i brak payloadu — purge po grace (nie dotyczy archive)
    if [[ "${rc}" -eq 2 || -z "${json}" ]]; then
      if ! hm_backup_snapshot_has_payload "${remote_base}"; then
        epoch="$(hm_backup_stamp_epoch "${s}")"
        if [[ "${epoch}" -gt 0 && "${epoch}" -ge "${grace_cut}" ]]; then
          hm_warn "Pomijam świeży orphan (<${grace_h}h, możliwy trwający backup): ${rel}/${s}"
          continue
        fi
        hm_warn "Osierocony snapshot (brak manifestu i danych) → do usunięcia: ${rel}/${s}"
        printf '%s\n' "${remote_base}"
        continue
      fi
      # brak manifestu, ale są dane — zostaw pod keep_min
      keepable+=("${s}")
      keepable_json+=("")
      continue
    fi
    # partial/ok/failed z payloadem lub samym manifestem typu full — w puli keep_min
    keepable+=("${s}")
    keepable_json+=("${json}")
  done

  # keep_min najnowszych (stamps już sort -r) + retencja dni; archive już w keepable bez purge wyżej
  i=0
  for s in "${keepable[@]}"; do
    json="${keepable_json[$i]}"
    i=$((i + 1))
    if [[ "${i}" -le "${keep_min}" ]]; then
      continue
    fi
    if [[ -n "${json}" ]] && hm_backup_prune_is_archive "${json}"; then
      hm_warn "Pomijam chroniony snapshot archive: ${rel}/${s}"
      continue
    fi
    # Ponowne sprawdzenie archive gdy json był pusty przy pierwszym przejściu
    if [[ -z "${json}" ]]; then
      remote_base="$(hm_rclone_dest "${rel}/${s}")"
      rc=0
      json="$(hm_backup_cat_manifest "${remote_base}")" || rc=$?
      if [[ "${rc}" -eq 1 ]]; then
        hm_err "Przerywam prune dla ${rel}: błąd odczytu manifestu (${s})."
        return 1
      fi
      if [[ "${rc}" -eq 0 && -n "${json}" ]] && hm_backup_prune_is_archive "${json}"; then
        hm_warn "Pomijam chroniony snapshot archive: ${rel}/${s}"
        continue
      fi
    fi
    epoch="$(hm_backup_stamp_epoch "${s}")"
    if [[ "${epoch}" -gt 0 && "${epoch}" -lt "${cutoff}" ]]; then
      remote_base="$(hm_rclone_dest "${rel}/${s}")"
      printf '%s\n' "${remote_base}"
    fi
  done
  : "${total}"
  return 0
}

hm_backup_prune() {
  local days="" dry_run=0 yes=0
  local -a args=("$@")
  local i=0 a
  while [[ "${i}" -lt "${#args[@]}" ]]; do
    a="${args[$i]}"
    case "${a}" in
      --dry-run) dry_run=1 ;;
      --yes|-y) yes=1 ;;
      --days)
        i=$((i + 1))
        days="${args[$i]:-}"
        [[ -n "${days}" ]] || { hm_err "Użycie: backup prune [--days N] [--dry-run] [--yes]"; return 1; }
        ;;
      --days=*) days="${a#--days=}" ;;
      *)
        hm_err "Nieznany argument: ${a}. Użycie: backup prune [--days N] [--dry-run] [--yes]"
        return 1
        ;;
    esac
    i=$((i + 1))
  done

  hm_load_config
  hm_rclone_check || return 1
  hm_backup_acquire_lock || return 1
  trap 'hm_backup_release_lock' RETURN
  days="${days:-${BACKUP_KEEP_DAYS}}"
  local keep_min="${BACKUP_KEEP_MIN}"
  if ! [[ "${days}" =~ ^[0-9]+$ ]]; then
    hm_err "BACKUP_KEEP_DAYS / --days musi być liczbą (dni)."
    return 1
  fi
  if ! [[ "${keep_min}" =~ ^[0-9]+$ ]]; then
    keep_min=3
  fi

  echo "${C_BOLD}Backup prune${C_RESET}"
  echo "  Retencja : ${days} dni (zostaw min. ${keep_min} najnowszych na katalog)"
  echo "  Grace orphan: ${BACKUP_ORPHAN_GRACE_HOURS:-24}h (świeże bez manifestu nie kasowane)"
  echo "  Dry-run  : $([[ "${dry_run}" -eq 1 ]] && echo tak || echo nie)"
  echo

  local -a to_purge=()
  local name path scope_tmp scope_rc
  scope_tmp="$(mktemp "${TMPDIR:-/tmp}/hm-prune.XXXXXX")"
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    [[ "${name}" == "db-dumps" ]] && continue
    : > "${scope_tmp}"
    scope_rc=0
    hm_backup_prune_scope "${name}" "${days}" "${keep_min}" > "${scope_tmp}" || scope_rc=$?
    if [[ "${scope_rc}" -ne 0 ]]; then
      hm_warn "Pomijam katalog ${name} (błąd odczytu — bez purge)."
      continue
    fi
    while IFS= read -r path; do
      [[ -n "${path}" ]] && to_purge+=("${path}")
    done < "${scope_tmp}"
  done < <(hm_rclone_lsd_names "${RCLONE_REMOTE}")
  rm -f "${scope_tmp}"

  if [[ "${#to_purge[@]}" -eq 0 ]]; then
    hm_ok "Nic do usunięcia."
    return 0
  fi

  echo "Do usunięcia (${#to_purge[@]}):"
  for path in "${to_purge[@]}"; do
    echo "  ${path}"
  done
  echo

  if [[ "${dry_run}" -eq 1 ]]; then
    hm_info "Dry-run — nic nie usunięto."
    return 0
  fi

  local -a plan_steps=()
  for path in "${to_purge[@]}"; do
    plan_steps+=("Trwałe usunięcie (rclone purge) ${path}")
  done
  local yes_flag=()
  [[ "${yes}" -eq 1 ]] && yes_flag=(--yes)
  if ! hm_confirm_plan "backup prune — ${#to_purge[@]} snapshot(ów)" \
    "Zachowane min. ${keep_min} najnowszych na katalog; retencja ${days} dni." \
    "${yes_flag[@]}" \
    "${plan_steps[@]}"; then
    return 0
  fi

  local rc=0 i=0 total="${#to_purge[@]}"
  for path in "${to_purge[@]}"; do
    i=$((i + 1))
    hm_progress_bar "${i}" "${total}" "Usuwanie: ${path}"
    hm_status_clear
    hm_info "rclone purge ${path}"
    if rclone purge "${path}"; then
      hm_ok "Usunięto: ${path}"
    else
      hm_err "Purge nieudany: ${path}"
      rc=1
    fi
  done
  hm_progress_done
  return "${rc}"
}
