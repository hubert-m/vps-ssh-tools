#!/usr/bin/env bash
# Backup: rotacja starych snapshotów

hm_backup_stamp_epoch() {
  local stamp="$1"
  # YYYYMMDD-HHMMSS → epoch
  if [[ ! "${stamp}" =~ ^[0-9]{8}-[0-9]{6}$ ]]; then
    echo 0
    return
  fi
  local y="${stamp:0:4}" m="${stamp:4:2}" d="${stamp:6:2}"
  local H="${stamp:9:2}" M="${stamp:11:2}" S="${stamp:13:2}"
  date -d "${y}-${m}-${d} ${H}:${M}:${S}" +%s 2>/dev/null \
    || date -j -f "%Y%m%d-%H%M%S" "${stamp}" +%s 2>/dev/null \
    || echo 0
}

hm_backup_prune_scope() {
  # prune jednej ścieżki względnej (domena|full): wypisuje remote_base do usunięcia
  local rel="$1" days="$2" keep_min="$3" now cutoff
  now="$(date +%s)"
  cutoff=$((now - days * 86400))

  local -a stamps=()
  local s
  while IFS= read -r s; do
    [[ -n "${s}" ]] && stamps+=("${s}")
  done < <(hm_backup_list_stamps "${rel}")

  local total="${#stamps[@]}"
  local i=0 epoch remote_base
  for s in "${stamps[@]}"; do
    i=$((i + 1))
    # najnowsze keep_min zawsze zostawiamy (lista jest sort -r)
    if [[ "${i}" -le "${keep_min}" ]]; then
      continue
    fi
    epoch="$(hm_backup_stamp_epoch "${s}")"
    if [[ "${epoch}" -gt 0 && "${epoch}" -lt "${cutoff}" ]]; then
      remote_base="$(hm_rclone_dest "${rel}/${s}")"
      printf '%s\n' "${remote_base}"
    fi
  done
  # unused total silences shellcheck in some contexts
  : "${total}"
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
  echo "  Dry-run  : $([[ "${dry_run}" -eq 1 ]] && echo tak || echo nie)"
  echo

  local -a to_purge=()
  local name path
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    [[ "${name}" == "db-dumps" ]] && continue
    while IFS= read -r path; do
      [[ -n "${path}" ]] && to_purge+=("${path}")
    done < <(hm_backup_prune_scope "${name}" "${days}" "${keep_min}")
  done < <(hm_rclone_lsd_names "${RCLONE_REMOTE}")

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

  if [[ "${yes}" -ne 1 ]]; then
    if ! hm_confirm "Usunąć ${#to_purge[@]} snapshot(ów) z Google Drive"; then
      hm_info "Anulowano."
      return 0
    fi
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
