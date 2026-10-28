#!/usr/bin/env bash
# Backup: upload / site / full

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

hm_mysql_db_exists() {
  local dbname="$1"
  local n
  n="$(hm_mysql_exec -e "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME=$(hm_sql_quote "${dbname}");" 2>/dev/null | tr -d '[:space:]')"
  [[ "${n}" == "1" ]]
}

hm_stream_mysqldump() {
  local dbname="$1"
  local dest="$2"
  local dumpcli tmp errf dump_rc gzip_rc
  if ! hm_is_valid_db_name "${dbname}"; then
    hm_err "Nieprawidłowa nazwa bazy (odrzucam dump): ${dbname}"
    return 1
  fi
  dumpcli="$(hm_mysqldump_cli)" || { hm_err "Brak mysqldump/mariadb-dump."; return 1; }

  if ! hm_mysql_db_exists "${dbname}"; then
    hm_err "Baza nie istnieje: ${dbname}"
    return 1
  fi

  hm_info "Dump DB ${dbname} → ${dest}"
  local sock_args=()
  [[ -n "${MYSQL_SOCKET}" ]] && sock_args=(--socket="${MYSQL_SOCKET}")

  mkdir -m 0700 -p "${TMP_DIR}" 2>/dev/null || mkdir -p "${TMP_DIR}"
  tmp="$(mktemp "${TMP_DIR}/mysqldump-XXXXXX.sql.gz")"
  errf="$(mktemp "${TMP_DIR}/mysqldump-XXXXXX.err")"

  # najpierw lokalny plik — unikamy pustego 20 B .sql.gz na Drive przy błędzie mysqldump
  set +e
  set +o pipefail
  "${dumpcli}" "${sock_args[@]}" --single-transaction --quick --routines --triggers \
    -- "${dbname}" 2>"${errf}" | gzip -c > "${tmp}"
  dump_rc=${PIPESTATUS[0]}
  gzip_rc=${PIPESTATUS[1]}
  set -o pipefail
  set -e

  if [[ "${dump_rc}" -ne 0 || "${gzip_rc}" -ne 0 || ! -s "${tmp}" ]]; then
    hm_err "Nie udało się zrzucić DB ${dbname} (mysqldump rc=${dump_rc})."
    if [[ -s "${errf}" ]]; then
      hm_warn "mysqldump: $(head -c 400 "${errf}" | tr '\n' ' ')"
    fi
    rm -f "${tmp}" "${errf}"
    return 1
  fi
  rm -f "${errf}"

  if ! hm_rclone_copyto "${tmp}" "${dest}"; then
    hm_err "Upload dumpa nieudany: ${dest}"
    # nie zostawiaj częściowego artefaktu
    rclone deletefile "${dest}" >/dev/null 2>&1 || true
    rm -f "${tmp}"
    return 1
  fi
  rm -f "${tmp}"
  hm_ok "DB ${dbname} OK."
}

# tar exit 1 = ostrzeżenie (file changed); 2 = błąd krytyczny
hm_tar_pipe_ok() {
  local tar_rc="$1"
  if [[ "${tar_rc}" -eq 0 ]]; then
    return 0
  fi
  if [[ "${tar_rc}" -eq 1 ]]; then
    hm_warn "tar: pliki zmieniły się podczas odczytu (kod 1) — traktuję jako ostrzeżenie."
    return 0
  fi
  return 1
}

hm_stream_tar_rcat() {
  local src_dir="$1"
  local dest="$2"
  local excludes tar_err tar_rc gzip_rc rcat_rc
  excludes="$(hm_backup_tar_excludes)"
  tar_err="$(mktemp "${TMP_DIR:-/tmp}/hmtools-tar.XXXXXX.err")"

  hm_info "Archiwum (stream) ${src_dir} → ${dest}"
  set +e
  set +o pipefail
  # shellcheck disable=SC2086
  tar -C "${src_dir}" --warning=no-file-changed --ignore-failed-read ${excludes} -cf - . 2>"${tar_err}" \
    | gzip -c \
    | hm_rclone_rcat "${dest}"
  tar_rc=${PIPESTATUS[0]}
  gzip_rc=${PIPESTATUS[1]}
  rcat_rc=${PIPESTATUS[2]}
  set -o pipefail
  set -e

  if [[ -s "${tar_err}" ]]; then
    hm_warn "tar: $(head -c 300 "${tar_err}" | tr '\n' ' ')"
  fi
  rm -f "${tar_err}"

  if [[ "${gzip_rc}" -ne 0 || "${rcat_rc}" -ne 0 ]]; then
    hm_err "Stream tar nieudany dla ${src_dir} (gzip=${gzip_rc} rcat=${rcat_rc})."
    return 1
  fi
  if ! hm_tar_pipe_ok "${tar_rc}"; then
    hm_err "tar błąd krytyczny (kod ${tar_rc}) dla ${src_dir}."
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
  local excludes tar_err tar_rc gzip_rc split_rc
  excludes="$(hm_backup_tar_excludes)"

  mkdir -p "${work}"
  tar_err="$(mktemp "${work}/tar.XXXXXX.err")"

  hm_info "Tryb chunk (${CHUNK_SIZE_MB} MB): ${src_dir} → ${remote_dir}"
  hm_rclone_mkdir "${remote_dir}"

  set +e
  set +o pipefail
  # shellcheck disable=SC2086
  tar -C "${src_dir}" --warning=no-file-changed --ignore-failed-read ${excludes} -cf - . 2>"${tar_err}" \
    | gzip -c \
    | split -b "${chunk_bytes}" -d -a 4 - "${work}/part_"
  tar_rc=${PIPESTATUS[0]}
  gzip_rc=${PIPESTATUS[1]}
  split_rc=${PIPESTATUS[2]}
  set -o pipefail
  set -e

  if [[ -s "${tar_err}" ]]; then
    hm_warn "tar: $(head -c 300 "${tar_err}" | tr '\n' ' ')"
  fi
  rm -f "${tar_err}"

  if [[ "${gzip_rc}" -ne 0 || "${split_rc}" -ne 0 ]] || ! hm_tar_pipe_ok "${tar_rc}"; then
    if [[ "${gzip_rc}" -ne 0 || "${split_rc}" -ne 0 ]] || [[ "${tar_rc}" -ge 2 ]]; then
      hm_err "Błąd tworzenia chunków (tar=${tar_rc} gzip=${gzip_rc} split=${split_rc})."
      rm -rf "${work}"
      return 1
    fi
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

  if [[ "${n}" -eq 0 ]]; then
    hm_err "Brak chunków do wysłania."
    rm -rf "${work}"
    return 1
  fi

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
  if ! hm_upload_files_smart "${backup_root}" "${remote_base}"; then
    hm_warn "Błąd podczas wysyłania plików dla ${domain} — kontynuuję (vhost/manifest)."
  fi

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
  # /etc/crontab tylko gdy nie archiwizujemy całego /etc (unikamy duplikatu w tar)
  if [[ ! -d /etc ]] && [[ -f /etc/crontab ]]; then
    paths+=(/etc/crontab)
  fi
  [[ -d /var/spool/cron ]] && paths+=(/var/spool/cron)

  if [[ "${#paths[@]}" -eq 0 ]]; then
    hm_warn "Brak ścieżek konfiguracji do zarchiwizowania."
    return 0
  fi

  # Lekki tar wybranych ścieżek (bez ogromnych logów) — stream, bez lokalnego archiwum
  local tar_err tar_rc gzip_rc rcat_rc
  tar_err="$(mktemp "${TMP_DIR:-/tmp}/hmtools-syscfg.XXXXXX.err")"
  set +e
  set +o pipefail
  # shellcheck disable=SC2086
  tar --warning=no-file-changed --ignore-failed-read -cf - \
    --exclude='*.log' --exclude='cache' --exclude='tmp' \
    "${paths[@]}" 2>"${tar_err}" | gzip -c | hm_rclone_rcat "${remote_base}/system-configs.tar.gz"
  tar_rc=${PIPESTATUS[0]}
  gzip_rc=${PIPESTATUS[1]}
  rcat_rc=${PIPESTATUS[2]}
  set -o pipefail
  set -e
  if [[ -s "${tar_err}" ]]; then
    hm_warn "tar (system): $(head -c 200 "${tar_err}" | tr '\n' ' ')"
  fi
  rm -f "${tar_err}"
  if [[ "${gzip_rc}" -eq 0 && "${rcat_rc}" -eq 0 ]] && hm_tar_pipe_ok "${tar_rc}"; then
    hm_ok "Konfiguracje systemowe OK."
  else
    hm_warn "Częściowy błąd przy archiwum konfiguracji (tar=${tar_rc} gzip=${gzip_rc} rcat=${rcat_rc})."
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
      if ! hm_upload_files_smart "${backup_root}" "${site_remote}"; then
        hm_warn "Błąd wysyłania plików dla ${domain} — kontynuuję kolejne strony."
      fi
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
