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

hm_backup_cat_manifest() {
  local remote_base="$1"
  rclone cat "${remote_base}/manifest.json" 2>/dev/null || true
}

hm_backup_detect_files_mode() {
  # echo: tar | chunks | none
  local remote_base="$1"
  if rclone ls "${remote_base}/files.tar.gz" >/dev/null 2>&1; then
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
  hm_rclone_lsd_names "${base}" | grep -E '^[0-9]{8}-[0-9]{6}$' | sort -r
}

hm_backup_print_snapshot_row() {
  local stamp="$1" remote_base="$2"
  local json type php dbs mode size_b size_h created
  json="$(hm_backup_cat_manifest "${remote_base}")"
  type="$(hm_backup_json_str "${json}" "type")"
  [[ -z "${type}" ]] && type="?"
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
  printf '  %-18s %-6s %10s  %-14s  %s\n' "${stamp}" "${type}" "${size_h}" "${mode}" "php=${php}  db=[${dbs}]"
  if [[ "${created}" != "-" ]]; then
    printf '  %-18s %s\n' "" "${C_DIM}created: ${created}${C_RESET}"
  fi
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
    printf '  %-28s %s\n' "KATALOG" "SNAPSHOTY"
    printf '  %-28s %s\n' "-------" "---------"
    local name n
    while IFS= read -r name; do
      [[ -n "${name}" ]] || continue
      [[ "${name}" == "db-dumps" ]] && continue
      n="$(hm_backup_list_stamps "${name}" | wc -l | tr -d ' ')"
      printf '  %-28s %s\n' "${name}" "${n}"
    done < <(hm_rclone_lsd_names "${RCLONE_REMOTE}")
    echo
    hm_info "Szczegóły: backup list <domena|full>"
    return 0
  fi

  local remote_parent
  remote_parent="$(hm_rclone_dest "${target}")"
  echo "${C_BOLD}Backup list — ${target}${C_RESET}"
  echo "  Remote: ${remote_parent}"
  echo
  printf '  %-18s %-6s %10s  %-14s  %s\n' "STAMP" "TYP" "ROZMIAR" "ARCHIWUM" "META"
  printf '  %-18s %-6s %10s  %-14s  %s\n' "-----" "---" "-------" "--------" "----"

  local stamp remote_base count=0
  while IFS= read -r stamp; do
    [[ -n "${stamp}" ]] || continue
    remote_base="$(hm_rclone_dest "${target}/${stamp}")"
    hm_backup_print_snapshot_row "${stamp}" "${remote_base}"
    count=$((count + 1))
  done < <(hm_backup_list_stamps "${target}")

  if [[ "${count}" -eq 0 ]]; then
    hm_warn "Brak snapshotów w ${remote_parent}"
    return 0
  fi
  echo
  hm_ok "Znaleziono ${count} snapshot(ów)."
}
