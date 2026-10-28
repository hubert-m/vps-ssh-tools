#!/usr/bin/env bash
# Streamingowe / chunkowane backupy → rclone

if [[ -n "${HMTOOLS_BACKUP_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_BACKUP_LOADED=1

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_LIB_DIR}/common.sh"
# shellcheck source=detect.sh
source "${_LIB_DIR}/detect.sh"
# shellcheck source=sites.sh
source "${_LIB_DIR}/sites.sh"
# shellcheck source=rclone_drive.sh
source "${_LIB_DIR}/rclone_drive.sh"
# shellcheck source=db.sh
source "${_LIB_DIR}/db.sh"
# shellcheck source=size.sh
source "${_LIB_DIR}/size.sh"

hm_backup_check_space() {
  local free
  free="$(hm_disk_free_percent /)"
  if [[ -z "${free}" ]]; then
    hm_warn "Nie udało się odczytać wolnego miejsca na dysku."
    return 0
  fi
  if [[ "${free}" -lt "${MIN_FREE_PERCENT}" ]]; then
    hm_err "Za mało wolnego miejsca: ${free}% (wymagane >= ${MIN_FREE_PERCENT}%)."
    hm_err "Backup przerwany, aby nie zapełnić dysku. Zwolnij miejsce lub obniż MIN_FREE_PERCENT w hmtools.conf."
    return 1
  fi
  hm_info "Wolne miejsce: ${free}% (próg ${MIN_FREE_PERCENT}%)."
  return 0
}

hm_backup_tar_excludes() {
  local e
  for e in ${BACKUP_EXCLUDES}; do
    printf -- '--exclude=%s ' "${e}"
  done
}

hm_backup_stamp() {
  date +%Y%m%d-%H%M%S
}

hm_stream_mysqldump() {
  local dbname="$1"
  local dest="$2"
  local dumpcli
  dumpcli="$(hm_mysqldump_cli)" || { hm_err "Brak mysqldump/mariadb-dump."; return 1; }

  hm_info "Dump DB ${dbname} → ${dest}"
  local sock_args=()
  [[ -n "${MYSQL_SOCKET}" ]] && sock_args=(--socket="${MYSQL_SOCKET}")

  if ! "${dumpcli}" "${sock_args[@]}" --single-transaction --quick --routines --triggers \
      "${dbname}" 2>/dev/null | gzip -c | hm_rclone_rcat "${dest}"; then
    hm_err "Nie udało się zrzucić/wgrać DB ${dbname}."
    return 1
  fi
  hm_ok "DB ${dbname} OK."
}

hm_stream_tar_rcat() {
  local src_dir="$1"
  local dest="$2"
  local excludes
  excludes="$(hm_backup_tar_excludes)"

  hm_info "Archiwum (stream) ${src_dir} → ${dest}"
  # shellcheck disable=SC2086
  if ! tar -C "${src_dir}" ${excludes} -cf - . 2>/dev/null | gzip -c | hm_rclone_rcat "${dest}"; then
    hm_err "Stream tar nieudany dla ${src_dir}."
    return 1
  fi
  hm_ok "Pliki ${src_dir} OK (stream)."
}

hm_chunked_tar_upload() {
  # tar|gzip → split na chunki → rclone copy każdego → usuń lokalnie
  local src_dir="$1"
  local remote_dir="$2"   # pełny remote:path/dir
  local chunk_bytes=$((CHUNK_SIZE_MB * 1024 * 1024))
  local work="${TMP_DIR}/$$"
  local excludes
  excludes="$(hm_backup_tar_excludes)"

  mkdir -p "${work}"

  hm_info "Tryb chunk (${CHUNK_SIZE_MB} MB): ${src_dir} → ${remote_dir}"
  hm_rclone_mkdir "${remote_dir}"

  # shellcheck disable=SC2086
  if ! tar -C "${src_dir}" ${excludes} -cf - . 2>/dev/null | gzip -c \
      | split -b "${chunk_bytes}" -d -a 4 - "${work}/part_"; then
    hm_err "Błąd tworzenia chunków."
    rm -rf "${work}"
    return 1
  fi

  local part dest_file n=0
  for part in "${work}"/part_*; do
    [[ -f "${part}" ]] || continue
    n=$((n + 1))
    dest_file="${remote_dir}/files.tar.gz.$(basename "${part}")"
    hm_info "Upload chunk ${n}: $(basename "${part}") ($(hm_human_size "$(stat -c%s "${part}" 2>/dev/null || echo 0)"))"
    if ! hm_rclone_copyto "${part}" "${dest_file}"; then
      hm_err "Upload chunka nieudany: ${part}"
      rm -rf "${work}"
      return 1
    fi
    rm -f "${part}"
  done

  # marker
  echo "chunks=${n}" | hm_rclone_rcat "${remote_dir}/files.tar.gz.chunks.txt" || true
  rm -rf "${work}"
  hm_ok "Chunki wysłane (${n})."
}

hm_upload_files_smart() {
  local src_dir="$1"
  local remote_base="$2"  # remote:path/stamp
  local size_b threshold_b
  size_b="$(hm_dir_size_bytes "${src_dir}")"
  threshold_b=$((CHUNK_THRESHOLD_MB * 1024 * 1024))

  if [[ "${size_b}" -ge "${threshold_b}" ]]; then
    hm_warn "Duże drzewo ($(hm_human_size "${size_b}")) — używam chunków."
    hm_chunked_tar_upload "${src_dir}" "${remote_base}/files.chunks"
  else
    hm_stream_tar_rcat "${src_dir}" "${remote_base}/files.tar.gz"
  fi
}

hm_write_manifest_and_upload() {
  local remote_base="$1"
  local manifest_local="$2"
  hm_rclone_copyto "${manifest_local}" "${remote_base}/manifest.json" \
    || echo "$(cat "${manifest_local}")" | hm_rclone_rcat "${remote_base}/manifest.json"
}

hm_backup_site() {
  local domain="${1:-${HM_SITE_DOMAIN}}"
  [[ -n "${domain}" ]] || { hm_err "Podaj domenę lub wejdź w kontekst (use)."; return 1; }

  hm_load_config
  hm_detect_all
  hm_rclone_check || return 1
  hm_backup_check_space || return 1

  hm_set_site_context "${domain}"
  local stamp remote_base
  stamp="$(hm_backup_stamp)"
  # Drive: <root>/<domena>/<stamp>/
  remote_base="$(hm_backup_dest_site "${domain}" "${stamp}")"

  hm_info "Backup strony ${domain}"
  hm_info "Root Drive: ${RCLONE_REMOTE}"
  hm_info "Cel: ${remote_base}"
  hm_rclone_ensure_backup_layout
  hm_rclone_mkdir "$(hm_rclone_dest "${domain}")"
  hm_rclone_mkdir "${remote_base}"

  mkdir -p "${TMP_DIR}"
  local manifest="${TMP_DIR}/manifest-${domain}-${stamp}.json"
  local db_list="" db_names=()

  # Bazy
  local name user size origin
  while IFS=$'\t' read -r name user size origin; do
    [[ -n "${name}" ]] || continue
    db_names+=("${name}")
    if ! hm_stream_mysqldump "${name}" "${remote_base}/db/${name}.sql.gz"; then
      hm_warn "Pominięto DB ${name}."
    else
      db_list="${db_list}\"${name}\","
    fi
  done < <(hm_dbs_for_site "${domain}" "${HM_SITE_DOCROOT}" "${HM_SITE_ROOT}" "${HM_SITE_USER}")
  db_list="${db_list%,}"

  # Pliki
  local backup_root="${HM_SITE_ROOT}"
  if [[ -z "${backup_root}" || ! -d "${backup_root}" ]]; then
    backup_root="${HM_SITE_DOCROOT}"
  fi
  if [[ -z "${backup_root}" || ! -d "${backup_root}" ]]; then
    hm_err "Brak katalogu strony do backupu."
    return 1
  fi
  hm_upload_files_smart "${backup_root}" "${remote_base}"

  # Vhost conf (jeśli jest)
  if [[ -n "${HM_SITE_VHOST}" && -f "${HM_SITE_VHOST}" ]]; then
    hm_rclone_copyto "${HM_SITE_VHOST}" "${remote_base}/vhost.conf" 2>/dev/null \
      || cat "${HM_SITE_VHOST}" | hm_rclone_rcat "${remote_base}/vhost.conf" || true
  fi

  cat > "${manifest}" <<EOF
{
  "type": "site",
  "domain": "${domain}",
  "host": "${BACKUP_HOST_LABEL}",
  "stamp": "${stamp}",
  "site_root": "${HM_SITE_ROOT}",
  "docroot": "${HM_SITE_DOCROOT}",
  "php": "${HM_SITE_PHP}",
  "databases": [${db_list}],
  "remote": "${remote_base}",
  "created_at": "$(date -Iseconds)"
}
EOF
  hm_write_manifest_and_upload "${remote_base}" "${manifest}"
  rm -f "${manifest}"

  hm_ok "Backup strony ${domain} zakończony → ${remote_base}"
}

hm_backup_system_configs() {
  local remote_base="$1"

  hm_info "Backup konfiguracji systemowych..."
  local paths=()
  [[ -d /etc ]] && paths+=(/etc)
  [[ -n "${OLS_ROOT}" && -d "${OLS_ROOT}/conf" ]] && paths+=("${OLS_ROOT}/conf")
  [[ -n "${CYBERPANEL_ROOT}" && -d "${CYBERPANEL_ROOT}" ]] && paths+=("${CYBERPANEL_ROOT}")
  [[ -f /etc/crontab ]] && paths+=(/etc/crontab)
  [[ -d /var/spool/cron ]] && paths+=(/var/spool/cron)

  if [[ "${#paths[@]}" -eq 0 ]]; then
    hm_warn "Brak ścieżek konfiguracji do zarchiwizowania."
    return 0
  fi

  # Lekki tar wybranych ścieżek (bez ogromnych logów) — stream, bez lokalnego archiwum
  # shellcheck disable=SC2086
  if tar --ignore-failed-read -cf - \
      --exclude='*.log' --exclude='cache' --exclude='tmp' \
      "${paths[@]}" 2>/dev/null | gzip -c | hm_rclone_rcat "${remote_base}/system-configs.tar.gz"; then
    hm_ok "Konfiguracje systemowe OK."
  else
    hm_warn "Częściowy błąd przy archiwum konfiguracji."
  fi
}

hm_backup_all_databases() {
  local remote_base="$1"
  local db
  while IFS= read -r db; do
    [[ -n "${db}" ]] || continue
    hm_stream_mysqldump "${db}" "${remote_base}/databases/${db}.sql.gz" || hm_warn "DB ${db} pominięta."
  done < <(hm_list_all_databases)
}

hm_backup_full() {
  hm_load_config
  hm_detect_all
  hm_rclone_check || return 1
  hm_backup_check_space || return 1

  local stamp remote_base
  stamp="$(hm_backup_stamp)"
  # Drive: <root>/full/<stamp>/
  remote_base="$(hm_backup_dest_full "${stamp}")"

  hm_info "Pełny backup serwera"
  hm_info "Root Drive: ${RCLONE_REMOTE}"
  hm_info "Cel: ${remote_base}"
  hm_rclone_ensure_backup_layout
  hm_rclone_mkdir "${remote_base}"

  hm_backup_system_configs "${remote_base}"
  hm_backup_all_databases "${remote_base}"

  hm_discover_sites
  local domain
  for domain in "${HM_SITES_LIST[@]}"; do
    hm_info "--- Strona: ${domain} ---"
    hm_set_site_context "${domain}"
    local site_remote="${remote_base}/sites/${domain}"
    hm_rclone_mkdir "${site_remote}"
    local backup_root="${HM_SITE_ROOT}"
    [[ -z "${backup_root}" || ! -d "${backup_root}" ]] && backup_root="${HM_SITE_DOCROOT}"
    if [[ -n "${backup_root}" && -d "${backup_root}" ]]; then
      hm_upload_files_smart "${backup_root}" "${site_remote}"
    else
      hm_warn "Brak plików dla ${domain}."
    fi
  done

  local manifest="${TMP_DIR}/manifest-full-${stamp}.json"
  mkdir -p "${TMP_DIR}"
  cat > "${manifest}" <<EOF
{
  "type": "full",
  "host": "${BACKUP_HOST_LABEL}",
  "stamp": "${stamp}",
  "panel": "${PANEL}",
  "webserver": "${WEBSERVER}",
  "sites": $(printf '%s\n' "${HM_SITES_LIST[@]}" | awk 'BEGIN{printf "["} {printf sep "\"" $0 "\""; sep=","} END{printf "]"}'),
  "remote": "${remote_base}",
  "created_at": "$(date -Iseconds)"
}
EOF
  hm_write_manifest_and_upload "${remote_base}" "${manifest}"
  rm -f "${manifest}"

  hm_ok "Pełny backup zakończony → ${remote_base}"
}

# --- list / restore / prune / schedule --------------------------------------

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

hm_backup_restore_files() {
  local remote_base="$1" target_dir="$2"
  local mode
  mode="$(hm_backup_detect_files_mode "${remote_base}")"
  mkdir -p "${target_dir}"

  case "${mode}" in
    tar)
      hm_info "Odtwarzanie plików (stream files.tar.gz) → ${target_dir}"
      if ! rclone cat "${remote_base}/files.tar.gz" | gunzip -c | tar -xzf - -C "${target_dir}"; then
        hm_err "Rozpakowanie files.tar.gz nieudane."
        return 1
      fi
      ;;
    chunks)
      hm_info "Odtwarzanie plików (chunks → stream) → ${target_dir}"
      local part
      # łączenie part_* w kolejności bez lokalnego pełnego archiwum
      if ! (
        while IFS= read -r part; do
          [[ -n "${part}" ]] || continue
          hm_info "  chunk: ${part}"
          rclone cat "${remote_base}/files.chunks/${part}" || exit 1
        done < <(rclone lsf "${remote_base}/files.chunks/" 2>/dev/null | grep 'files\.tar\.gz\.part_' | sort)
      ) | gunzip -c | tar -xzf - -C "${target_dir}"; then
        hm_err "Rozpakowanie files.chunks nieudane."
        return 1
      fi
      ;;
    *)
      hm_warn "Brak archiwum plików w snapshocie (ani files.tar.gz, ani files.chunks/)."
      return 1
      ;;
  esac
  hm_ok "Pliki odtworzone."
}

hm_backup_restore_dbs() {
  local remote_base="$1"
  local json db_raw name cli sock_args=()
  json="$(hm_backup_cat_manifest "${remote_base}")"
  db_raw="$(hm_backup_json_arr "${json}" "databases")"
  db_raw="${db_raw//\"/}"
  db_raw="${db_raw// /}"

  cli="$(hm_mysql_cli)" || { hm_err "Brak klienta mysql/mariadb."; return 1; }
  [[ -n "${MYSQL_SOCKET:-}" ]] && sock_args=(--socket="${MYSQL_SOCKET}")

  if [[ -z "${db_raw}" ]]; then
    # spróbuj wylistować pliki db/*.sql.gz
    local f
    while IFS= read -r f; do
      [[ -n "${f}" ]] || continue
      name="${f%.sql.gz}"
      name="${name##*/}"
      [[ -n "${name}" ]] || continue
      if [[ -z "${db_raw}" ]]; then
        db_raw="${name}"
      else
        db_raw="${db_raw},${name}"
      fi
    done < <(rclone lsf "${remote_base}/db/" 2>/dev/null | grep '\.sql\.gz$' || true)
  fi

  if [[ -z "${db_raw}" ]]; then
    hm_warn "Brak baz do odtworzenia w snapshocie."
    return 0
  fi

  IFS=',' read -r -a _dbs <<< "${db_raw}"
  local db
  for db in "${_dbs[@]}"; do
    [[ -n "${db}" ]] || continue
    hm_info "Import DB ${db} ← ${remote_base}/db/${db}.sql.gz"
    "${cli}" "${sock_args[@]}" -e "CREATE DATABASE IF NOT EXISTS \`${db}\`;" 2>/dev/null || true
    if ! rclone cat "${remote_base}/db/${db}.sql.gz" | gunzip -c | "${cli}" "${sock_args[@]}" "${db}"; then
      hm_err "Import DB ${db} nieudany."
      return 1
    fi
    hm_ok "DB ${db} OK."
  done
}

hm_backup_ols_reload() {
  hm_detect_all 2>/dev/null || true
  if [[ -n "${OLS_CTRL:-}" && -x "${OLS_CTRL}" ]]; then
    if "${OLS_CTRL}" reload 2>/dev/null; then
      hm_ok "OLS reload OK."
      return 0
    fi
  fi
  if hm_have_cmd systemctl; then
    if systemctl reload lsws 2>/dev/null || systemctl reload lshttpd 2>/dev/null; then
      hm_ok "OLS reload OK (systemctl)."
      return 0
    fi
  fi
  hm_warn "Nie udało się przeładować OLS — zrób ręcznie: ols reload"
  return 0
}

hm_backup_restore() {
  local domain="${1:-}"
  shift || true
  local stamp="" files_only=0 db_only=0
  local a
  for a in "$@"; do
    case "${a}" in
      --files-only) files_only=1 ;;
      --db-only) db_only=1 ;;
      -*)
        hm_err "Nieznana flaga: ${a}"
        return 1
        ;;
      *)
        if [[ -z "${stamp}" ]]; then
          stamp="${a}"
        else
          hm_err "Za dużo argumentów: ${a}"
          return 1
        fi
        ;;
    esac
  done

  if [[ -z "${domain}" ]]; then
    domain="${HM_SITE_DOMAIN:-}"
  fi
  [[ -n "${domain}" ]] || { hm_err "Użycie: backup restore <domena> [stamp] [--files-only|--db-only]"; return 1; }

  hm_load_config
  hm_detect_all
  hm_rclone_check || return 1

  if [[ -z "${HM_SITE_DOMAIN}" || "${HM_SITE_DOMAIN}" != "${domain}" ]]; then
    domain="$(hm_find_site_by_arg "${domain}")" || return 1
  fi
  hm_set_site_context "${domain}"

  if [[ -z "${stamp}" ]]; then
    echo "${C_BOLD}Dostępne snapshoty — ${domain}${C_RESET}"
    local list
    list="$(hm_backup_list_stamps "${domain}")"
    if [[ -z "${list}" ]]; then
      hm_err "Brak snapshotów dla ${domain} na Drive."
      return 1
    fi
    printf '%s\n' "${list}" | head -20 | sed 's/^/  /'
    stamp="$(printf '%s\n' "${list}" | head -1)"
    hm_info "Wybrano najnowszy: ${stamp}"
  fi

  local remote_base target_dir
  remote_base="$(hm_backup_dest_site "${domain}" "${stamp}")"
  if ! rclone lsd "${remote_base}" >/dev/null 2>&1 && ! rclone ls "${remote_base}" >/dev/null 2>&1; then
    # rclone ls na katalogu zwraca pliki; sprawdź istnienie przez lsf
    if [[ -z "$(rclone lsf "${remote_base}" 2>/dev/null | head -1)" ]]; then
      hm_err "Snapshot nie istnieje: ${remote_base}"
      return 1
    fi
  fi

  target_dir="${HM_SITE_ROOT}"
  if [[ -z "${target_dir}" || ! -d "${target_dir}" ]]; then
    target_dir="${HM_SITE_DOCROOT}"
  fi
  [[ -n "${target_dir}" ]] || { hm_err "Brak katalogu docelowego strony."; return 1; }

  echo
  echo "${C_BOLD}Restore — ${domain}${C_RESET}"
  echo "  Snapshot : ${stamp}"
  echo "  Remote   : ${remote_base}"
  echo "  Cel plików: ${target_dir}"
  local mode_label="pliki + DB"
  [[ "${files_only}" -eq 1 ]] && mode_label="tylko pliki"
  [[ "${db_only}" -eq 1 ]] && mode_label="tylko DB"
  echo "  Tryb     : ${mode_label}"
  echo

  hm_backup_check_space || return 1

  if ! hm_confirm "Nadpisać dane strony ${domain} z kopii ${stamp}"; then
    hm_info "Anulowano."
    return 0
  fi

  if [[ "${db_only}" -eq 0 ]]; then
    hm_backup_restore_files "${remote_base}" "${target_dir}" || return 1
    # vhost (opcjonalnie)
    if [[ -n "${HM_SITE_VHOST:-}" ]] && rclone cat "${remote_base}/vhost.conf" >/dev/null 2>&1; then
      if hm_confirm "Przywrócić też vhost.conf → ${HM_SITE_VHOST}"; then
        rclone cat "${remote_base}/vhost.conf" > "${HM_SITE_VHOST}" \
          || hm_warn "Nie udało się zapisać vhost.conf"
      fi
    fi
    if [[ -n "${HM_SITE_USER:-}" ]] && id "${HM_SITE_USER}" >/dev/null 2>&1; then
      hm_info "chown -R ${HM_SITE_USER}: → ${target_dir}"
      chown -R "${HM_SITE_USER}:${HM_SITE_USER}" "${target_dir}" 2>/dev/null \
        || hm_warn "chown częściowo nieudany (kontynuuję)."
    fi
  fi

  if [[ "${files_only}" -eq 0 ]]; then
    hm_backup_restore_dbs "${remote_base}" || return 1
  fi

  hm_backup_ols_reload
  hm_ok "Restore ${domain} (${stamp}) zakończony."
}

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

  local rc=0
  for path in "${to_purge[@]}"; do
    hm_info "rclone purge ${path}"
    if rclone purge "${path}"; then
      hm_ok "Usunięto: ${path}"
    else
      hm_err "Purge nieudany: ${path}"
      rc=1
    fi
  done
  return "${rc}"
}

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
