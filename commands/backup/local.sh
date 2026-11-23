#!/usr/bin/env bash
# backup local — szybkie kopie lokalne (ten sam format co Drive → restore bez zmian)


hm_backup_local_root() {
  printf '%s' "${BACKUP_LOCAL_ROOT:-/backup/hmtools}"
}

# Ostrzeżenie gdy lokalny root pokrywa się ze ścieżką rclone (ta sama przestrzeń).
hm_backup_local_warn_remote_overlap() {
  local root remote
  root="$(hm_backup_local_root)"
  remote="${RCLONE_REMOTE:-}"
  [[ -n "${remote}" ]] || return 0
  # lokalny rclone: ścieżka absolutna
  if [[ "${remote}" == /* ]]; then
    if [[ "${root}" == "${remote}" || "${root}" == "${remote}/"* || "${remote}" == "${root}/"* ]]; then
      hm_warn "BACKUP_LOCAL_ROOT (${root}) pokrywa się z RCLONE_REMOTE (${remote}) — rotacja local może dotyczyć tych samych snapshotów co Drive."
    fi
  fi
}

# Rotacja lokalna: nigdy type=archive; uszkodzone nie liczą się do N i są kasowane;
# wśród kompletnych site/ok zostaw N najnowszych.
hm_backup_local_prune_domain() {
  local domain="$1" keep="${2:-3}"
  local root base s stamp_dir json rc status type
  local -a stamps=() archives=() complete=() damaged=()
  root="$(hm_backup_local_root)"
  base="${root}/${domain}"
  [[ -d "${base}" ]] || return 0

  local d bn
  for d in "${base}"/*; do
    [[ -d "${d}" ]] || continue
    bn="$(basename "${d}")"
    [[ "${bn}" =~ ^[0-9]{8}-[0-9]{6}$ ]] || continue
    stamps+=("${bn}")
  done
  [[ "${#stamps[@]}" -gt 0 ]] || return 0

  local sorted
  sorted="$(printf '%s\n' "${stamps[@]}" | sort -r)"

  while IFS= read -r s; do
    [[ -n "${s}" ]] || continue
    stamp_dir="${base}/${s}"
    rc=0
    json=""
    if declare -F hm_backup_cat_manifest >/dev/null 2>&1; then
      json="$(hm_backup_cat_manifest "${stamp_dir}")" || rc=$?
    elif [[ -f "${stamp_dir}/manifest.json" ]]; then
      json="$(cat "${stamp_dir}/manifest.json" 2>/dev/null || true)"
      [[ -n "${json}" ]] || rc=2
    else
      rc=2
    fi
    if [[ "${rc}" -eq 1 ]]; then
      hm_err "local prune: błąd odczytu manifestu ${domain}/${s} — przerywam rotację (nic nie kasuję)."
      return 1
    fi
    type=""
    if [[ "${rc}" -eq 0 && -n "${json}" ]]; then
      if declare -F hm_backup_prune_is_archive >/dev/null 2>&1 \
          && hm_backup_prune_is_archive "${json}"; then
        archives+=("${s}")
        continue
      fi
      type="$(hm_backup_json_str "${json}" "type" 2>/dev/null || true)"
      [[ "${type}" == "archive" ]] && { archives+=("${s}"); continue; }
    fi
    if declare -F hm_backup_snapshot_is_incomplete >/dev/null 2>&1 \
        && hm_backup_snapshot_is_incomplete "${stamp_dir}"; then
      damaged+=("${s}")
      continue
    fi
    # kompletny (ok/partial z payloadem) — w puli keep
    complete+=("${s}")
  done <<< "${sorted}"

  # 1) usuń uszkodzone (nie zajmują miejsca w N)
  for s in "${damaged[@]+"${damaged[@]}"}"; do
    [[ -n "${s}" ]] || continue
    [[ "${s}" =~ ^[0-9]{8}-[0-9]{6}$ ]] || continue
    hm_info "local prune: usuwam uszkodzony ${base}/${s}"
    rm -rf -- "${base:?}/${s:?}"
  done

  # 2) wśród complete zostaw keep najnowszych (już sort -r w kolejności dodawania)
  local i=0
  for s in "${complete[@]+"${complete[@]}"}"; do
    [[ -n "${s}" ]] || continue
    [[ "${s}" =~ ^[0-9]{8}-[0-9]{6}$ ]] || continue
    i=$((i + 1))
    if [[ "${i}" -gt "${keep}" ]]; then
      hm_info "local prune: usuwam ${base}/${s} (poza keep=${keep})"
      rm -rf -- "${base:?}/${s:?}"
    fi
  done

  # archive nigdy nie kasujemy — tylko log gdy są
  if [[ "${#archives[@]}" -gt 0 ]]; then
    hm_info "local prune: chronię ${#archives[@]} snapshot(ów) type=archive."
  fi
  return 0
}

hm_backup_local_site() {
  local domain="${1:-${HM_SITE_DOMAIN}}"
  local keep=3
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --keep) keep="${2:-3}"; shift 2 || true ;;
      --keep=*) keep="${1#*=}"; shift ;;
      --help|-h)
        echo "Użycie: backup local <domena> [--keep N]  (domyślnie keep=3)"
        return 0
        ;;
      *)
        if hm_is_valid_domain "$1" 2>/dev/null || [[ "$1" =~ ^[0-9]+$ ]]; then
          domain="$1"; shift
        else
          hm_err "Nieznany argument: $1"; return 1
        fi
        ;;
    esac
  done

  [[ -n "${domain}" ]] || { hm_err "Użycie: backup local <domena> [--keep N]"; return 1; }
  if [[ -z "${HM_SITE_DOMAIN}" || "${HM_SITE_DOMAIN}" != "${domain}" ]]; then
    domain="$(hm_find_site_by_arg "${domain}")" || return 1
  fi

  [[ "${keep}" =~ ^[0-9]+$ ]] && [[ "${keep}" -ge 1 ]] || { hm_err "--keep musi być liczbą ≥1"; return 1; }

  local root
  root="$(hm_backup_local_root)"
  hm_backup_local_warn_remote_overlap
  if ! hm_confirm_plan "backup local — ${domain}" \
    "Szybka kopia lokalna (format jak Drive → backup restore)." \
    "Root: ${root}/${domain}/<stamp>/" \
    "Kontrola wolnego miejsca (MIN_FREE_PERCENT)" \
    "Retencja: ${keep} najnowszych kompletnych (type=archive chronione; uszkodzone poza limitem)"; then
    return 0
  fi

  hm_load_config
  local saved="${RCLONE_REMOTE}"
  RCLONE_REMOTE="${root}"
  export RCLONE_REMOTE
  HM_BACKUP_TARGET_NAME="local"
  export HM_BACKUP_TARGET_NAME

  local rc=0
  hm_backup_site "${domain}" || rc=$?

  RCLONE_REMOTE="${saved}"
  export RCLONE_REMOTE
  unset HM_BACKUP_TARGET_NAME

  if [[ "${rc}" -eq 0 ]]; then
    hm_backup_local_prune_domain "${domain}" "${keep}"
  fi
  return "${rc}"
}
