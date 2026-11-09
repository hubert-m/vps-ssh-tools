#!/usr/bin/env bash
# Cele backupu (nazwane remotes / lokalne) — rejestr + multi-target.
# Wymaga: lib/rclone_drive.sh (local-aware hm_rclone_*).

if [[ -n "${HMTOOLS_RCLONE_TARGETS_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_RCLONE_TARGETS_LOADED=1

hm_backup_spec_is_local() {
  local s="${1:-}"
  [[ "${s}" == /* ]] || [[ "${s}" == local:/* ]] || [[ "${s}" == local: ]]
}

hm_backup_spec_normalize() {
  local s="${1:-}"
  if [[ "${s}" == local:/* ]]; then
    printf '%s' "${s#local:}"
  elif [[ "${s}" == local: ]]; then
    printf '/'
  else
    printf '%s' "${s}"
  fi
}

hm_backup_default_target_name() {
  local r="${RCLONE_REMOTE:-gdrive:vps-backups}"
  if hm_backup_spec_is_local "${r}"; then
    printf 'local'
  else
    printf '%s' "${r%%:*}"
  fi
}

hm_backup_target_names() {
  hm_load_config 2>/dev/null || true
  local -a names=()
  local def t
  def="$(hm_backup_default_target_name)"
  names+=("${def}")
  if [[ -n "${BACKUP_TARGETS:-}" ]]; then
    local IFS=','
    for t in ${BACKUP_TARGETS}; do
      t="$(printf '%s' "${t}" | tr -d '[:space:]')"
      [[ -n "${t}" ]] || continue
      [[ "${t}" == "${def}" ]] && continue
      names+=("${t}")
    done
  fi
  printf '%s\n' "${names[@]}"
}

hm_backup_target_spec() {
  local name="${1:-}"
  hm_load_config 2>/dev/null || true
  local def
  def="$(hm_backup_default_target_name)"

  if [[ "${name}" == "default" || "${name}" == "${def}" ]]; then
    printf '%s' "${RCLONE_REMOTE:-gdrive:vps-backups}"
    return 0
  fi
  # alias gdrive → RCLONE_REMOTE gdy remote gdrive:
  if [[ "${name}" == "gdrive" && "${RCLONE_REMOTE:-}" == gdrive:* ]]; then
    printf '%s' "${RCLONE_REMOTE}"
    return 0
  fi

  local key var
  key="$(printf '%s' "${name}" | tr '-' '_')"
  var="BACKUP_TARGET_${key}"
  if [[ -n "${!var:-}" ]]; then
    printf '%s' "${!var}"
    return 0
  fi
  if [[ "${name}" == "local" ]]; then
    printf '%s' "${BACKUP_LOCAL_ROOT:-/backup/hmtools}"
    return 0
  fi
  return 1
}

hm_backup_target_exists() {
  hm_backup_target_spec "$1" >/dev/null 2>&1
}

hm_backup_use_target() {
  local name="$1"
  local spec
  spec="$(hm_backup_target_spec "${name}")" || {
    hm_err "Nieznany cel backupu: ${name} (backup targets / backup target add)"
    return 1
  }
  spec="$(hm_backup_spec_normalize "${spec}")"
  if ! hm_backup_spec_is_local "${spec}"; then
    if ! hm_is_valid_rclone_remote "${spec}"; then
      hm_err "Nieprawidłowy spec celu ${name}: ${spec}"
      return 1
    fi
  fi
  RCLONE_REMOTE="${spec}"
  export RCLONE_REMOTE
  HM_BACKUP_TARGET_NAME="${name}"
  export HM_BACKUP_TARGET_NAME
}

hm_backup_target_save() {
  local name="$1" spec="$2"
  local conf="${HMTOOLS_CONF:-${HMTOOLS_ROOT}/config/hmtools.conf}"
  local key
  key="$(printf '%s' "${name}" | tr '-' '_')"
  if ! hm_backup_spec_is_local "${spec}" && ! hm_is_valid_rclone_remote "${spec}"; then
    hm_err "Nieprawidłowy remote: ${spec}"
    return 1
  fi
  [[ "${name}" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_-]{0,31}$ ]] || {
    hm_err "Nieprawidłowa nazwa celu: ${name}"
    return 1
  }
  mkdir -p "$(dirname "${conf}")"
  touch "${conf}"
  chmod 600 "${conf}" 2>/dev/null || true

  local tmp cur
  tmp="$(hm_mktemp .conf)"
  grep -vE "^[[:space:]]*BACKUP_TARGET_${key}=" "${conf}" 2>/dev/null > "${tmp}" || true
  printf 'BACKUP_TARGET_%s="%s"\n' "${key}" "${spec}" >> "${tmp}"

  cur=""
  if grep -qE '^[[:space:]]*BACKUP_TARGETS=' "${conf}" 2>/dev/null; then
    cur="$(grep -E '^[[:space:]]*BACKUP_TARGETS=' "${conf}" | tail -1 | sed -E 's/^[^=]+=//; s/^"//; s/"$//')"
  fi
  cur="${cur:-${BACKUP_TARGETS:-}}"
  if [[ -z "${cur}" ]]; then
    cur="${name}"
  elif [[ ",${cur}," != *",${name},"* ]]; then
    cur="${cur},${name}"
  fi
  grep -vE '^[[:space:]]*BACKUP_TARGETS=' "${tmp}" > "${tmp}.2" 2>/dev/null || cp "${tmp}" "${tmp}.2"
  printf 'BACKUP_TARGETS="%s"\n' "${cur}" >> "${tmp}.2"
  cat "${tmp}.2" > "${conf}"
  rm -f "${tmp}" "${tmp}.2"
  BACKUP_TARGETS="${cur}"
  eval "BACKUP_TARGET_${key}=\"\${spec}\""
  export BACKUP_TARGETS
}

# Złóż pełną ścieżkę snapshotu (root + rel) niezależnie od bieżącego RCLONE_REMOTE
hm_backup_join_root_rel() {
  local root="$1" rel="${2#/}"
  root="$(hm_backup_spec_normalize "${root}")"
  if [[ "${root}" == /* ]]; then
    printf '%s/%s' "${root%/}" "${rel}"
    return 0
  fi
  local base="${root#*:}" rem="${root%%:*}"
  if [[ -n "${base}" && "${base}" != "${root}" ]]; then
    printf '%s:%s/%s' "${rem}" "${base}" "${rel}"
  else
    printf '%s:%s' "${rem}" "${rel}"
  fi
}

hm_backup_copy_snapshot_between() {
  local src_root="$1" dst_root="$2" rel="$3"
  local src dst
  src="$(hm_backup_join_root_rel "${src_root}" "${rel}")"
  dst="$(hm_backup_join_root_rel "${dst_root}" "${rel}")"
  hm_info "Replikacja snapshotu → cel (rel=${rel})"
  if [[ "${src}" == /* && "${dst}" == /* ]]; then
    mkdir -p "$(dirname "${dst}")"
    rm -rf "${dst}"
    cp -a "${src}" "${dst}"
    return $?
  fi
  hm_rclone_check || return 1
  set +e
  rclone copy "${src}" "${dst}" --quiet
  local rc=$?
  set -e
  return "${rc}"
}

hm_backup_verify_snapshot() {
  local root="$1" rel="$2"
  local base
  base="$(hm_backup_join_root_rel "${root}" "${rel}")"
  if [[ "${base}" == /* ]]; then
    [[ -f "${base}/manifest.json" ]]
    return $?
  fi
  rclone ls "${base}/manifest.json" >/dev/null 2>&1
}

# Parse "--target x" / "--targets a,b" z argv → HM_BACKUP_TARGETS_SELECTED (csv)
hm_backup_parse_target_args() {
  HM_BACKUP_TARGETS_SELECTED=""
  local -a rest=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target)
        HM_BACKUP_TARGETS_SELECTED="${2:-}"; shift 2 || true ;;
      --target=*)
        HM_BACKUP_TARGETS_SELECTED="${1#*=}"; shift ;;
      --targets)
        HM_BACKUP_TARGETS_SELECTED="${2:-}"; shift 2 || true ;;
      --targets=*)
        HM_BACKUP_TARGETS_SELECTED="${1#*=}"; shift ;;
      *)
        rest+=("$1"); shift ;;
    esac
  done
  if [[ -z "${HM_BACKUP_TARGETS_SELECTED}" ]]; then
    HM_BACKUP_TARGETS_SELECTED="$(hm_backup_default_target_name)"
  fi
  export HM_BACKUP_TARGETS_SELECTED
  # zwróć resztę argv przez globalną tablicę
  HM_BACKUP_ARGS_REST=("${rest[@]}")
}

# Uruchom backup site/full na 1+ celach. $1=site|full, dalsze: domena / flagi
# Pierwszy cel: pełny backup; kolejne: rclone copy snapshotu + verify.
hm_backup_run_on_targets() {
  local mode="$1" # site|full
  shift
  local domain="" stamp=""
  local -a tnames=()
  local IFS=',' t
  for t in ${HM_BACKUP_TARGETS_SELECTED:-$(hm_backup_default_target_name)}; do
    t="$(printf '%s' "${t}" | tr -d '[:space:]')"
    [[ -n "${t}" ]] && tnames+=("${t}")
  done
  [[ "${#tnames[@]}" -gt 0 ]] || tnames=("$(hm_backup_default_target_name)")

  local primary="${tnames[0]}"
  local primary_root
  hm_backup_use_target "${primary}" || return 1
  primary_root="${RCLONE_REMOTE}"

  stamp="$(hm_backup_stamp)"
  export HM_BACKUP_FORCE_STAMP="${stamp}"

  local rc_primary=0
  case "${mode}" in
    site)
      domain="$1"
      hm_backup_site "${domain}" || rc_primary=$?
      ;;
    full)
      hm_backup_full || rc_primary=$?
      ;;
    *)
      hm_err "hm_backup_run_on_targets: mode=${mode}"
      unset HM_BACKUP_FORCE_STAMP
      return 1
      ;;
  esac

  local -a report=()
  # Pierwszy udany cel = źródło replikacji (fallback: pełny backup na kolejnych)
  local source_root=""
  if [[ "${rc_primary}" -eq 0 ]]; then
    report+=("OK  ${primary} (${primary_root})")
    source_root="${primary_root}"
  else
    report+=("FAIL ${primary} (${primary_root}) rc=${rc_primary}")
  fi

  local rel=""
  if [[ "${mode}" == "site" ]]; then
    rel="${domain}/${stamp}"
  else
    rel="full/${stamp}"
  fi

  local overall="${rc_primary}"
  local i name root rc_fb=0
  for ((i = 1; i < ${#tnames[@]}; i++)); do
    name="${tnames[$i]}"
    if ! root="$(hm_backup_target_spec "${name}")"; then
      report+=("FAIL ${name} (nieznany cel)")
      overall=1
      continue
    fi
    root="$(hm_backup_spec_normalize "${root}")"

    if [[ -n "${source_root}" ]]; then
      if hm_backup_copy_snapshot_between "${source_root}" "${root}" "${rel}" \
        && hm_backup_verify_snapshot "${root}" "${rel}"; then
        report+=("OK  ${name} (${root})")
      else
        report+=("FAIL ${name} (${root}) — replikacja/weryfikacja")
        overall=1
      fi
      continue
    fi

    # Brak kompletnego źródła — pełny snapshot bezpośrednio na ten cel (ten sam stamp)
    hm_info "Cel ${primary} nieudany — pełny backup na ${name} (fallback)…"
    if ! hm_backup_use_target "${name}"; then
      report+=("FAIL ${name} (nie można ustawić celu)")
      overall=1
      continue
    fi
    rc_fb=0
    case "${mode}" in
      site) hm_backup_site "${domain}" || rc_fb=$? ;;
      full) hm_backup_full || rc_fb=$? ;;
    esac
    if [[ "${rc_fb}" -eq 0 ]] && hm_backup_verify_snapshot "${root}" "${rel}"; then
      report+=("OK  ${name} (${root}) [fallback direct]")
      source_root="${root}"
      # Awaria któregokolwiek celu (tu: primary) → overall ≠ 0, mimo udanego fallbacku
      overall=1
    else
      report+=("FAIL ${name} (${root}) rc=${rc_fb} [fallback]")
      overall=1
    fi
  done

  unset HM_BACKUP_FORCE_STAMP
  echo
  echo "${C_BOLD}Backup — raport celów${C_RESET}"
  local line
  for line in "${report[@]}"; do
    echo "  ${line}"
  done
  return "${overall}"
}
