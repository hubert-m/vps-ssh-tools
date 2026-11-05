#!/usr/bin/env bash
# backup local — szybkie kopie lokalne (ten sam format co Drive → restore bez zmian)


hm_backup_local_root() {
  printf '%s' "${BACKUP_LOCAL_ROOT:-/backup/hmtools}"
}

hm_backup_local_prune_domain() {
  local domain="$1" keep="${2:-3}"
  local root base
  root="$(hm_backup_local_root)"
  base="${root}/${domain}"
  [[ -d "${base}" ]] || return 0
  local -a stamps=()
  local d
  for d in "${base}"/*; do
    [[ -d "${d}" ]] || continue
    local bn
    bn="$(basename "${d}")"
    [[ "${bn}" =~ ^[0-9]{8}-[0-9]{6}$ ]] && stamps+=("${bn}")
  done
  # sort malejąco
  local sorted
  sorted="$(printf '%s\n' "${stamps[@]}" | sort -r)"
  local i=0 s
  while IFS= read -r s; do
    [[ -n "${s}" ]] || continue
    i=$((i + 1))
    if [[ "${i}" -gt "${keep}" ]]; then
      hm_info "local prune: usuwam ${base}/${s}"
      rm -rf "${base}/${s}"
    fi
  done <<< "${sorted}"
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
  if ! hm_confirm_plan "backup local — ${domain}" \
    "Szybka kopia lokalna (format jak Drive → backup restore)." \
    "Root: ${root}/${domain}/<stamp>/" \
    "Kontrola wolnego miejsca (MIN_FREE_PERCENT)" \
    "Retencja: zostaw ${keep} najnowszych lokalnych snapshotów"; then
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
