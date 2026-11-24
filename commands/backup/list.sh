#!/usr/bin/env bash
# Backup: listowanie snapshotów i manifestów

hm_backup_json_str() {
  # wyciąga wartość string z prostego JSON (pierwsze dopasowanie klucza)
  local json="$1" key="$2"
  printf '%s' "${json}" | tr '\n' ' ' | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -1
}

hm_backup_json_arr() {
  # wyciąga zawartość tablicy JSON (bez nawiasów), np. "a","b"
  local json="$1" key="$2"
  printf '%s' "${json}" | tr '\n' ' ' | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\\[\\([^]]*\\)\\].*/\\1/p" | head -1
}

hm_rclone_lsd_names() {
  local path="$1"
  if [[ "${path}" == /* ]]; then
    [[ -d "${path}" ]] || return 0
    local d
    for d in "${path}"/*; do
      [[ -d "${d}" ]] || continue
      basename "${d}"
    done
    return 0
  fi
  rclone lsd "${path}" 2>/dev/null | awk '{print $NF}' || true
}

hm_rclone_remote_size_bytes() {
  local path="$1"
  local out
  out="$(rclone size "${path}" --json 2>/dev/null || true)"
  if [[ -n "${out}" ]]; then
    printf '%s' "${out}" | sed -n 's/.*"bytes"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1
    return 0
  fi
  out="$(rclone size "${path}" 2>/dev/null || true)"
  printf '%s' "${out}" | sed -n 's/.*(\([0-9][0-9]*\) Byte).*/\1/p' | head -1
}

# stdout = treść JSON; rc: 0=ok, 1=błąd odczytu, 2=brak pliku
hm_backup_cat_manifest() {
  local remote_base="$1" out errf rc=0
  if [[ "${remote_base}" == /* ]]; then
    if [[ ! -f "${remote_base}/manifest.json" ]]; then
      return 2
    fi
    out="$(cat "${remote_base}/manifest.json" 2>/dev/null)" || return 1
    printf '%s' "${out}"
    return 0
  fi
  errf="$(mktemp "${TMPDIR:-/tmp}/hm-man.XXXXXX")"
  out="$(rclone cat "${remote_base}/manifest.json" 2>"${errf}")" || rc=$?
  if [[ "${rc}" -eq 0 ]]; then
    rm -f "${errf}"
    printf '%s' "${out}"
    return 0
  fi
  # Plik istnieje, ale cat się wyłożył (403, timeout, …) ≠ „nie ma snapshotu”.
  if rclone lsf "${remote_base}/" 2>/dev/null | grep -qxF 'manifest.json' \
    || rclone lsf "${remote_base}/manifest.json" >/dev/null 2>&1; then
    hm_err "Błąd odczytu manifestu: ${remote_base}/manifest.json ($(tr '\n' ' ' < "${errf}"))"
    rm -f "${errf}"
    return 1
  fi
  rm -f "${errf}"
  return 2
}

# Czy snapshot ma pliki/dumpy (nawet przy status=partial).
hm_backup_snapshot_has_payload() {
  local remote_base="$1" mode
  mode="$(hm_backup_detect_files_mode "${remote_base}")"
  [[ "${mode}" != "none" ]] && return 0
  if [[ "${remote_base}" == /* ]]; then
    if find "${remote_base}/db" "${remote_base}/databases" -type f \( -name '*.sql.gz' -o -name '*.sql.gz.enc' \) 2>/dev/null | grep -q .; then
      return 0
    fi
    [[ -f "${remote_base}/db-accounts.sql" || -f "${remote_base}/db-accounts.sql.enc" ]] && return 0
    return 1
  fi
  if rclone lsf "${remote_base}/db/" 2>/dev/null | grep -qE '\.sql'; then
    return 0
  fi
  if rclone lsf "${remote_base}/databases/" 2>/dev/null | grep -qE '\.sql'; then
    return 0
  fi
  rclone ls "${remote_base}/db-accounts.sql" >/dev/null 2>&1 && return 0
  rclone ls "${remote_base}/db-accounts.sql.enc" >/dev/null 2>&1 && return 0
  return 1
}

hm_backup_detect_files_mode() {
  # echo: tar | chunks | none
  local remote_base="$1"
  if [[ "${remote_base}" == /* ]]; then
    { [[ -f "${remote_base}/files.tar.gz" ]] || [[ -f "${remote_base}/files.tar.gz.enc" ]]; } \
      && { echo "tar"; return 0; }
    if [[ -d "${remote_base}/files.chunks" ]] \
      && find "${remote_base}/files.chunks" -name 'files.tar.gz.part_*' 2>/dev/null | grep -q .; then
      echo "chunks"
      return 0
    fi
    echo "none"
    return 0
  fi
  if rclone ls "${remote_base}/files.tar.gz" >/dev/null 2>&1 \
      || rclone ls "${remote_base}/files.tar.gz.enc" >/dev/null 2>&1; then
    echo "tar"
    return 0
  fi
  if rclone lsf "${remote_base}/files.chunks/" 2>/dev/null | grep -q 'files\.tar\.gz\.part_'; then
    echo "chunks"
    return 0
  fi
  # fallback: marker z uploadu
  if rclone cat "${remote_base}/files.chunks/files.tar.gz.chunks.txt" >/dev/null 2>&1; then
    echo "chunks"
    return 0
  fi
  echo "none"
}

hm_backup_list_stamps() {
  # wypisuje stampy (nazwy katalogów) dla relative path (domena lub full)
  local rel="$1"
  local base
  base="$(hm_rclone_dest "${rel}")"
  hm_rclone_lsd_names "${base}" | grep -E '^[0-9]{8}-[0-9]{6}(-[0-9]+)?$' | sort -r
}

# 0 = osierocony/pusty (do BAD / orphan-purge); 1 = użyteczny (także partial z payloadem)
# rc cat=1 (błąd API) → traktuj jako incomplete (ostrożnie: nie restore bez sprawdzenia)
hm_backup_snapshot_is_incomplete() {
  local remote_base="$1"
  local json status type mode rc=0
  json="$(hm_backup_cat_manifest "${remote_base}")" || rc=$?
  if [[ "${rc}" -eq 1 ]]; then
    return 0
  fi
  if [[ "${rc}" -eq 2 || -z "${json}" ]]; then
    # Brak manifestu: orphan tylko gdy brak też plików/dumpów
    hm_backup_snapshot_has_payload "${remote_base}" && return 1
    return 0
  fi
  status="$(hm_backup_json_str "${json}" "status")"
  case "${status}" in
    failed)
      hm_backup_snapshot_has_payload "${remote_base}" && return 1
      return 0
      ;;
    partial)
      # partial z danymi to nadal użyteczna kopia (keep_min / restore)
      hm_backup_snapshot_has_payload "${remote_base}" && return 1
      return 0
      ;;
  esac
  type="$(hm_backup_json_str "${json}" "type")"
  [[ -z "${type}" ]] && return 0
  # site/archive bez files.tar.gz / files.chunks i bez dumpów → BAD
  case "${type}" in
    site|archive)
      if hm_backup_snapshot_has_payload "${remote_base}"; then
        return 1
      fi
      return 0
      ;;
  esac
  return 1
}

hm_backup_print_snapshot_row() {
  local stamp="$1" remote_base="$2"
  local json type php dbs mode size_b size_h created status
  json="$(hm_backup_cat_manifest "${remote_base}")"
  type="$(hm_backup_json_str "${json}" "type")"
  status="$(hm_backup_json_str "${json}" "status")"
  [[ -z "${type}" ]] && type="?"
  if hm_backup_snapshot_is_incomplete "${remote_base}"; then
    type="${type}/BAD"
  fi
  php="$(hm_backup_json_str "${json}" "php")"
  [[ -z "${php}" ]] && php="-"
  created="$(hm_backup_json_str "${json}" "created_at")"
  [[ -z "${created}" ]] && created="-"
  dbs="$(hm_backup_json_arr "${json}" "databases")"
  dbs="${dbs//\"/}"
  [[ -z "${dbs}" ]] && dbs="-"
  mode="$(hm_backup_detect_files_mode "${remote_base}")"
  case "${mode}" in
    tar) mode="files.tar.gz" ;;
    chunks) mode="files.chunks/" ;;
    *) mode="-" ;;
  esac
  size_b="$(hm_rclone_remote_size_bytes "${remote_base}")"
  size_h="$(hm_human_size "${size_b:-0}")"
  local note="-"
  if [[ "${type}" == *"/BAD"* ]]; then
    note="${C_YELLOW}niepełny/osierocony — prune usunie; nie używaj w restore${C_RESET}"
  fi
  hm_table_row "${stamp}" "${type}" "${size_h}" "${mode}" "${created}" "php=${php}  db=[${dbs}]" "${note}"
  : "${status}"
}

hm_backup_list() {
  local target="${1:-}"
  hm_load_config
  hm_rclone_check || return 1

  if [[ -z "${target}" && -n "${HM_SITE_DOMAIN:-}" ]]; then
    target="${HM_SITE_DOMAIN}"
  fi

  if [[ -z "${target}" ]]; then
    echo "${C_BOLD}Backup — przegląd root (${RCLONE_REMOTE})${C_RESET}"
    echo
    hm_table_begin LR
    hm_table_row KATALOG SNAPSHOTY
    local name n
    while IFS= read -r name; do
      [[ -n "${name}" ]] || continue
      [[ "${name}" == "db-dumps" ]] && continue
      n="$(hm_backup_list_stamps "${name}" | wc -l | tr -d ' ')"
      hm_table_row "${name}" "${n}"
    done < <(hm_rclone_lsd_names "${RCLONE_REMOTE}")
    hm_table_print
    echo
    hm_info "Szczegóły: backup list <domena|full>"
    return 0
  fi

  local remote_parent
  remote_parent="$(hm_rclone_dest "${target}")"
  echo "${C_BOLD}Backup list — ${target}${C_RESET}"
  echo "  Remote: ${remote_parent}"
  echo

  local stamp remote_base count=0
  local -a stamps=()
  while IFS= read -r stamp; do
    [[ -n "${stamp}" ]] && stamps+=("${stamp}")
  done < <(hm_backup_list_stamps "${target}")

  local total="${#stamps[@]}"
  if [[ "${total}" -eq 0 ]]; then
    hm_warn "Brak snapshotów w ${remote_parent}"
    return 0
  fi

  hm_table_begin LLRLLLL
  hm_table_row STAMP TYP ROZMIAR ARCHIWUM UTWORZONO META UWAGA

  for stamp in "${stamps[@]}"; do
    count=$((count + 1))
    hm_progress_bar "${count}" "${total}" "Pobieranie danych snapshotu ${stamp} z Drive..."
    remote_base="$(hm_rclone_dest "${target}/${stamp}")"
    hm_status_clear
    hm_backup_print_snapshot_row "${stamp}" "${remote_base}"
  done
  hm_progress_done
  hm_table_print
  echo
  hm_ok "Znaleziono ${count} snapshot(ów)."
}
