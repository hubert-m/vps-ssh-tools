#!/usr/bin/env bash
# Backup: upload / site / full

hm_backup_check_space() {
  # $1 opcjonalnie — ścieżka do sprawdzenia (domyślnie /); restore podaje target_dir
  local path="${1:-/}"
  local free
  # katalog docelowy może jeszcze nie istnieć — sprawdź parent / mount
  if [[ ! -d "${path}" ]]; then
    path="$(dirname "${path}")"
  fi
  [[ -d "${path}" ]] || path="/"
  free="$(hm_disk_free_percent "${path}")"
  if [[ -z "${free}" ]]; then
    hm_warn "Nie udało się odczytać wolnego miejsca na dysku (${path})."
    return 0
  fi
  if [[ "${free}" -lt "${MIN_FREE_PERCENT}" ]]; then
    hm_err "Za mało wolnego miejsca na ${path}: ${free}% (wymagane >= ${MIN_FREE_PERCENT}%)."
    hm_err "Backup/restore przerwany, aby nie zapełnić dysku. Zwolnij miejsce lub obniż MIN_FREE_PERCENT w hmtools.conf."
    return 1
  fi
  hm_info "Wolne miejsce (${path}): ${free}% (próg ${MIN_FREE_PERCENT}%)."
  return 0
}

# Wspólny flock: backup / archive / restore / prune nie mogą działać równolegle.
hm_backup_acquire_lock() {
  local lock_dir lock
  if [[ -d /run && -w /run ]]; then
    lock="/run/hmtools-backup.lock"
  else
    lock_dir="${TMP_DIR:-/tmp}"
    mkdir -p "${lock_dir}" 2>/dev/null || true
    lock="${lock_dir}/hmtools-backup.lock"
  fi
  HM_BACKUP_LOCK_PATH="${lock}"
  # shellcheck disable=SC2094
  exec 9>"${lock}"
  if ! flock -n 9; then
    hm_err "Inna operacja backup/archive/restore/prune w toku (flock: ${lock})."
    exec 9>&- 2>/dev/null || true
    return 1
  fi
  return 0
}

hm_backup_release_lock() {
  flock -u 9 2>/dev/null || true
  exec 9>&- 2>/dev/null || true
  unset HM_BACKUP_LOCK_PATH 2>/dev/null || true
}

# Szyfrowanie opcjonalne (BACKUP_ENCRYPT_PASSPHRASE) — AES-256-CBC + pbkdf2.
# stdout: ścieżka pliku do uploadu (src lub src.enc).
# Gdy passphrase ustawione: BEZ fallbacku do plaintext (openssl fail → rc=1).
hm_backup_maybe_encrypt_file() {
  local src="$1"
  local out="${src}.enc"
  [[ -f "${src}" ]] || { printf '%s\n' "${src}"; return 1; }
  if [[ -z "${BACKUP_ENCRYPT_PASSPHRASE:-}" ]]; then
    printf '%s\n' "${src}"
    return 0
  fi
  # -pass env: wymaga exportu (hm_load_config też eksportuje; tu na wszelki wypadek)
  export BACKUP_ENCRYPT_PASSPHRASE
  if ! hm_have_cmd openssl; then
    hm_err "BACKUP_ENCRYPT_PASSPHRASE ustawione, ale brak openssl — odmawiam plaintext."
    return 1
  fi
  if openssl enc -aes-256-cbc -pbkdf2 -salt \
    -pass env:BACKUP_ENCRYPT_PASSPHRASE \
    -in "${src}" -out "${out}" 2>/dev/null; then
    chmod 600 "${out}" 2>/dev/null || true
    printf '%s\n' "${out}"
    return 0
  fi
  rm -f "${out}" 2>/dev/null || true
  hm_err "openssl enc nieudany (BACKUP_ENCRYPT_PASSPHRASE) — odmawiam plaintext."
  return 1
}

hm_backup_sha256_file() {
  local f="$1"
  [[ -f "${f}" ]] || return 1
  if hm_have_cmd sha256sum; then
    sha256sum "${f}" 2>/dev/null | awk '{print $1}'
  elif hm_have_cmd shasum; then
    shasum -a 256 "${f}" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

# SHA256 pliku na Drive (gdy remote wspiera hashsum); inaczej pusty string.
hm_rclone_remote_sha256() {
  local remote="$1"
  rclone hashsum SHA256 "${remote}" 2>/dev/null | awk '{print $1}' | head -1
}

# Czy Unix user jest używany przez inną domenę niż $domain (live na VPS)?
# Child archive nie ma unix-account.meta — restore i tak musi wykryć shared przed nadpisaniem crona/hasła.
# Pole user = 7. kolumna TSV z hm_resolve_site_paths (awk — bash read zwija puste \t).
hm_backup_site_user_shared_live() {
  local user="${1:-}" domain="${2:-}"
  local other row ou
  [[ -n "${user}" && -n "${domain}" ]] || return 1
  declare -F hm_discover_sites >/dev/null 2>&1 && hm_discover_sites >/dev/null 2>&1 || true
  declare -F hm_resolve_site_paths >/dev/null 2>&1 || return 1
  for other in "${HM_SITES_LIST[@]:-}"; do
    [[ -n "${other}" && "${other}" != "${domain}" ]] || continue
    row="$(hm_resolve_site_paths "${other}" 2>/dev/null || true)"
    [[ -n "${row}" ]] || continue
    ou="$(printf '%s\n' "${row}" | awk -F'\t' '{print $7}' | cut -d'|' -f1)"
    if declare -F hm_tsv_unfield >/dev/null 2>&1; then
      ou="$(hm_tsv_unfield "${ou}")"
    elif [[ "${ou}" == "-" ]]; then
      ou=""
    fi
    if [[ -n "${ou}" && "${ou}" == "${user}" ]]; then
      return 0
    fi
  done
  return 1
}

# Gdy kilka domen dzieli ten sam vhRoot/home — TYLKO child pakuje docroot.
# Master (docroot = $vhRoot/public_html|html) zawsze pełny HOME (.ssh, app/, logs/).
hm_backup_prefer_docroot_if_shared_home() {
  local domain="$1"
  local root="$2"
  local docroot="$3"
  local other o_root root_n doc_n

  [[ -n "${root}" && -d "${root}" ]] || { printf '%s\n' "${root}"; return 0; }
  root_n="$(realpath -m "${root}" 2>/dev/null || echo "${root}")"
  root_n="${root_n%/}"
  doc_n=""
  if [[ -n "${docroot}" && -d "${docroot}" ]]; then
    doc_n="$(realpath -m "${docroot}" 2>/dev/null || echo "${docroot}")"
    doc_n="${doc_n%/}"
  fi

  # Kanoniczny docroot mastera — nie zawężaj nawet przy współdzielonym vhRoot z childem
  if [[ -n "${doc_n}" && ( "${doc_n}" == "${root_n}/public_html" || "${doc_n}" == "${root_n}/html" ) ]]; then
    printf '%s\n' "${root_n}"
    return 0
  fi

  declare -F hm_discover_sites >/dev/null 2>&1 && hm_discover_sites >/dev/null 2>&1 || true
  for other in "${HM_SITES_LIST[@]:-}"; do
    [[ -n "${other}" && "${other}" != "${domain}" ]] || continue
    o_root="$(hm_ols_vhroot_for_domain "${other}" 2>/dev/null || true)"
    [[ -n "${o_root}" && -d "${o_root}" ]] || continue
    o_root="$(realpath -m "${o_root}" 2>/dev/null || echo "${o_root}")"
    o_root="${o_root%/}"
    if [[ "${o_root}" == "${root_n}" ]]; then
      # Child: docroot głębiej niż public_html (np. …/public_html/child.x)
      if [[ -n "${doc_n}" && "${doc_n}" == "${root_n}"/* && "${doc_n}" != "${root_n}" ]]; then
        hm_info "Współdzielony home z ${other} — pakuję tylko docroot child ${doc_n} (bez duplikatu całego HOME)." >&2
        printf '%s\n' "${doc_n}"
        return 0
      fi
    fi
  done
  printf '%s\n' "${root_n}"
}

# $1 = backup|archive — archive używa ARCHIVE_EXCLUDES (domyślnie puste = pełny dump przed usunięciem)
hm_backup_tar_excludes() {
  local mode="${1:-backup}"
  local list e
  case "${mode}" in
    archive) list="${ARCHIVE_EXCLUDES:-}" ;;
    *) list="${BACKUP_EXCLUDES:-}" ;;
  esac
  for e in ${list}; do
    [[ -n "${e}" ]] || continue
    printf -- '--exclude=%s ' "${e}"
  done
}

hm_backup_excludes_list() {
  local mode="${1:-backup}"
  case "${mode}" in
    archive)
      if [[ -z "${ARCHIVE_EXCLUDES:-}" ]]; then
        printf '(brak — pełny dump)'
      else
        printf '%s' "${ARCHIVE_EXCLUDES}"
      fi
      ;;
    *) printf '%s' "${BACKUP_EXCLUDES:-}" ;;
  esac
}

# Katalog plików do tar: pełny $HOME użytkownika strony, gdy jest bezpieczny
# i obejmuje (lub jest) site root — wtedy wchodzą .ssh, .pm2, .config, .bash_history itd.
# tar -C … -cf - . i tak pakuje ukryte pliki; tu upewniamy się, że root = home, nie np. sam public_html.
hm_backup_resolve_files_root() {
  local site_root="${1:-}"
  local site_user="${2:-}"
  local root="" home=""

  if [[ -n "${site_root}" && -d "${site_root}" ]]; then
    root="$(realpath -m "${site_root}" 2>/dev/null || echo "${site_root}")"
    root="${root%/}"
  fi

  if [[ -n "${site_user}" ]] && hm_is_valid_unix_user "${site_user}" && id "${site_user}" >/dev/null 2>&1; then
    home="$(getent passwd "${site_user}" 2>/dev/null | cut -d: -f6 || true)"
    if [[ -n "${home}" && -d "${home}" ]]; then
      home="$(realpath -m "${home}" 2>/dev/null || echo "${home}")"
      home="${home%/}"
      if declare -F hm_is_safe_site_root_to_delete >/dev/null 2>&1 \
        && hm_is_safe_site_root_to_delete "${home}"; then
        if [[ -z "${root}" ]]; then
          printf '%s\n' "${home}"
          return 0
        fi
        # home == root lub home jest przodkiem site root → pakuj cały home
        if [[ "${root}" == "${home}" || "${root}" == "${home}"/* ]]; then
          if [[ "${root}" != "${home}" ]]; then
            hm_info "Backup plików: rozszerzam ${root} → pełny HOME ${home} (.ssh/.pm2/.config/…)" >&2
          fi
          printf '%s\n' "${home}"
          return 0
        fi
        # site root obejmuje home → pakuj szerszy root
        if [[ "${home}" == "${root}"/* ]]; then
          printf '%s\n' "${root}"
          return 0
        fi
        # rozłączone ścieżki — trzymaj site root (treść WWW), ostrzeż o HOME
        hm_warn "Unix HOME (${home}) ≠ site root (${root}) — pakuję site root; pliki tylko w HOME mogą nie wejść do archiwum." >&2
      fi
    fi
  fi

  printf '%s\n' "${root}"
}

hm_backup_stamp() {
  if [[ -n "${HM_BACKUP_FORCE_STAMP:-}" ]]; then
    printf '%s' "${HM_BACKUP_FORCE_STAMP}"
    return 0
  fi
  date +%Y%m%d-%H%M%S
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

  hm_ensure_secure_tmpdir
  tmp="$(mktemp "${TMP_DIR}/mysqldump-XXXXXX.sql.gz")"
  errf="$(mktemp "${TMP_DIR}/mysqldump-XXXXXX.err")"

  # najpierw lokalny plik — unikamy pustego 20 B .sql.gz na Drive przy błędzie mysqldump
  hm_status_line "mysqldump ${dbname}..."
  set +e
  set +o pipefail
  "${dumpcli}" "${sock_args[@]}" --single-transaction --quick --routines --triggers \
    -- "${dbname}" 2>"${errf}" | gzip -c > "${tmp}"
  local -a _ps=( "${PIPESTATUS[@]}" )
  dump_rc=${_ps[0]:-1}
  gzip_rc=${_ps[1]:-1}
  set -o pipefail
  set -e
  hm_status_clear

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
  local exclude_mode="${3:-backup}"
  local excludes tar_err tar_rc gzip_rc rcat_rc
  excludes="$(hm_backup_tar_excludes "${exclude_mode}")"
  tar_err="$(mktemp "${TMP_DIR:-/tmp}/hmtools-tar.XXXXXX.err")"

  hm_info "Archiwum (stream) ${src_dir} → ${dest} [excludes=${exclude_mode}: $(hm_backup_excludes_list "${exclude_mode}")]"
  hm_status_line "tar|gzip|rclone ${src_dir}..."
  set +e
  set +o pipefail
  # shellcheck disable=SC2086
  tar -C "${src_dir}" --warning=no-file-changed --ignore-failed-read ${excludes} -cf - . 2>"${tar_err}" \
    | gzip -c \
    | hm_rclone_rcat "${dest}"
  local -a _ps=( "${PIPESTATUS[@]}" )
  tar_rc=${_ps[0]:-1}
  gzip_rc=${_ps[1]:-1}
  rcat_rc=${_ps[2]:-1}
  set -o pipefail
  set -e
  hm_status_clear

  if [[ -s "${tar_err}" ]]; then
    hm_warn "tar: $(head -c 300 "${tar_err}" | tr -d '\n' | tr '\r' ' ' | head -c 300)"
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
  local exclude_mode="${3:-backup}"
  local chunk_bytes=$((CHUNK_SIZE_MB * 1024 * 1024))
  local work="${TMP_DIR}/$$"
  local excludes tar_err tar_rc gzip_rc split_rc
  excludes="$(hm_backup_tar_excludes "${exclude_mode}")"

  mkdir -p "${work}"
  tar_err="$(mktemp "${work}/tar.XXXXXX.err")"

  hm_info "Tryb chunk (${CHUNK_SIZE_MB} MB): ${src_dir} → ${remote_dir} [excludes=${exclude_mode}: $(hm_backup_excludes_list "${exclude_mode}")]"
  hm_rclone_mkdir "${remote_dir}"

  set +e
  set +o pipefail
  # shellcheck disable=SC2086
  tar -C "${src_dir}" --warning=no-file-changed --ignore-failed-read ${excludes} -cf - . 2>"${tar_err}" \
    | gzip -c \
    | split -b "${chunk_bytes}" -d -a 4 - "${work}/part_"
  local -a _ps=( "${PIPESTATUS[@]}" )
  tar_rc=${_ps[0]:-1}
  gzip_rc=${_ps[1]:-1}
  split_rc=${_ps[2]:-1}
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

  local -a parts=()
  local part dest_file n=0 total_parts=0 part_sz
  for part in "${work}"/part_*; do
    [[ -f "${part}" ]] && parts+=("${part}")
  done
  total_parts="${#parts[@]}"
  if [[ "${total_parts}" -eq 0 ]]; then
    hm_err "Brak chunków do wysłania."
    rm -rf "${work}"
    return 1
  fi

  for part in "${parts[@]}"; do
    n=$((n + 1))
    part_sz="$(hm_human_size "$(stat -c%s "${part}" 2>/dev/null || echo 0)")"
    dest_file="${remote_dir}/files.tar.gz.$(basename "${part}")"
    hm_progress_bar "${n}" "${total_parts}" "Upload $(basename "${part}") (${part_sz})"
    if ! hm_rclone_copyto "${part}" "${dest_file}"; then
      hm_progress_done
      hm_err "Upload chunka nieudany: ${part}"
      rm -rf "${work}"
      return 1
    fi
    rm -f "${part}"
  done
  hm_progress_done "Chunki wysłane (${total_parts}/${total_parts})."

  # marker
  echo "chunks=${total_parts}" | hm_rclone_rcat "${remote_dir}/files.tar.gz.chunks.txt" || true
  rm -rf "${work}"
}

hm_upload_files_smart() {
  local src_dir="$1"
  local remote_base="$2"  # remote:path/stamp
  local exclude_mode="${3:-backup}"
  local size_b threshold_b
  size_b="$(hm_dir_size_bytes "${src_dir}")"
  threshold_b=$((CHUNK_THRESHOLD_MB * 1024 * 1024))

  if [[ "${size_b}" -ge "${threshold_b}" ]]; then
    hm_warn "Duże drzewo ($(hm_human_size "${size_b}")) — używam chunków."
    hm_chunked_tar_upload "${src_dir}" "${remote_base}/files.chunks" "${exclude_mode}"
  else
    hm_stream_tar_rcat "${src_dir}" "${remote_base}/files.tar.gz" "${exclude_mode}"
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
  if ! hm_rclone_root_is_local; then
    hm_rclone_check || return 1
  fi
  hm_backup_check_space || return 1
  hm_backup_acquire_lock || return 1
  trap 'hm_backup_release_lock' RETURN

  hm_site_context_push "${domain}" || return 1
  local stamp remote_base
  stamp="$(hm_backup_stamp)"
  # Root: <root>/<domena>/<stamp>/  (rclone lub lokalnie)
  remote_base="$(hm_backup_dest_site "${domain}" "${stamp}")"

  hm_info "Backup strony ${domain}"
  hm_info "Root: ${RCLONE_REMOTE}${HM_BACKUP_TARGET_NAME:+ (cel=${HM_BACKUP_TARGET_NAME})}"
  hm_info "Cel: ${remote_base}"
  hm_rclone_ensure_backup_layout
  hm_rclone_mkdir "$(hm_rclone_dest "${domain}")"
  hm_rclone_mkdir "${remote_base}"

  hm_ensure_secure_tmpdir
  local manifest
  manifest="$(hm_mktemp .json)"
  local db_list="" db_names=()
  local db_fail=0
  local -a failed_dbs=()

  # Bazy
  local name user size origin
  while IFS=$'\t' read -r name user size origin; do
    [[ -n "${name}" ]] || continue
    db_names+=("${name}")
    if ! hm_stream_mysqldump "${name}" "${remote_base}/db/${name}.sql.gz"; then
      hm_err "Błąd zrzutu/uploadu DB ${name} — backup będzie niekompletny."
      db_fail=$((db_fail + 1))
      failed_dbs+=("${name}")
    else
      db_list="${db_list}\"${name}\","
    fi
  done < <(hm_dbs_for_site "${domain}" "${HM_SITE_DOCROOT}" "${HM_SITE_ROOT}" "${HM_SITE_USER}")
  db_list="${db_list%,}"

  # Pliki — pełny HOME (gdy obejmuje site root); child ze współdzielonym home → tylko docroot
  local backup_root
  backup_root="$(hm_backup_resolve_files_root "${HM_SITE_ROOT:-${HM_SITE_DOCROOT}}" "${HM_SITE_USER}")"
  if [[ -z "${backup_root}" || ! -d "${backup_root}" ]]; then
    backup_root="${HM_SITE_ROOT:-${HM_SITE_DOCROOT}}"
  fi
  backup_root="$(hm_backup_prefer_docroot_if_shared_home "${domain}" "${backup_root}" "${HM_SITE_DOCROOT}")"
  if [[ -z "${backup_root}" || ! -d "${backup_root}" ]]; then
    hm_err "Brak katalogu strony do backupu."
    hm_site_context_pop
    return 1
  fi
  local files_ok=1
  if ! hm_upload_files_smart "${backup_root}" "${remote_base}"; then
    files_ok=0
    hm_err "Błąd podczas wysyłania plików dla ${domain}."
  fi

  if [[ "${files_ok}" -ne 1 ]]; then
    hm_err "Backup ${domain} niekompletny — usuwam niepełny snapshot (${remote_base})."
    hm_rclone_purge "${remote_base}"
    rm -f "${manifest}"
    hm_site_context_pop
    return 1
  fi

  # Vhost conf (jeśli jest)
  if [[ -n "${HM_SITE_VHOST}" && -f "${HM_SITE_VHOST}" ]]; then
    hm_rclone_copyto "${HM_SITE_VHOST}" "${remote_base}/vhost.conf" 2>/dev/null \
      || cat "${HM_SITE_VHOST}" | hm_rclone_rcat "${remote_base}/vhost.conf" || true
  fi

  local status="ok"
  [[ "${db_fail}" -eq 0 ]] || status="partial"

  local fail_db_json="[]"
  if [[ "${#failed_dbs[@]}" -gt 0 ]]; then
    fail_db_json="$(printf '%s\n' "${failed_dbs[@]}" | awk 'BEGIN{printf "["} {printf sep "\"" $0 "\""; sep=","} END{printf "]"}')"
  fi

  local _j_domain _j_host _j_root _j_doc _j_user _j_php _j_remote _j_excl
  _j_domain="$(hm_json_escape_str "${domain}")"
  _j_host="$(hm_json_escape_str "${BACKUP_HOST_LABEL}")"
  _j_root="$(hm_json_escape_str "${backup_root}")"
  _j_doc="$(hm_json_escape_str "${HM_SITE_DOCROOT}")"
  _j_user="$(hm_json_escape_str "${HM_SITE_USER:-}")"
  _j_php="$(hm_json_escape_str "${HM_SITE_PHP}")"
  _j_remote="$(hm_json_escape_str "${remote_base}")"
  _j_excl="$(hm_json_escape_str "$(hm_backup_excludes_list backup)")"
  hm_info "BACKUP_EXCLUDES: $(hm_backup_excludes_list backup)"
  cat > "${manifest}" <<EOF
{
  "type": "site",
  "status": "${status}",
  "domain": "${_j_domain}",
  "host": "${_j_host}",
  "stamp": "${stamp}",
  "site_root": "${_j_root}",
  "docroot": "${_j_doc}",
  "site_user": "${_j_user}",
  "php": "${_j_php}",
  "excludes": "${_j_excl}",
  "databases": [${db_list}],
  "failed_databases": ${fail_db_json},
  "remote": "${_j_remote}",
  "created_at": "$(date -Iseconds)"
}
EOF
  if ! hm_write_manifest_and_upload "${remote_base}" "${manifest}"; then
    rm -f "${manifest}"
    hm_err "Upload manifest.json nieudany — usuwam niepełny snapshot ${remote_base}."
    hm_rclone_purge "${remote_base}"
    hm_site_context_pop
    return 1
  fi
  rm -f "${manifest}"

  if [[ "${status}" != "ok" ]]; then
    hm_err "Backup ${domain} NIEKOMPLETNY → ${remote_base} (status=${status}; błędy DB: ${db_fail})."
    [[ "${#failed_dbs[@]}" -gt 0 ]] && hm_warn "Nieudane bazy: ${failed_dbs[*]}"
    hm_site_context_pop
    return 1
  fi
  hm_ok "Backup strony ${domain} zakończony → ${remote_base}"
  hm_site_context_pop
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

  # BEZ /etc/shadow|gshadow oraz kluczy prywatnych SSL/SSH — nie na plaintext Drive
  # privkey*.pem łapie archive/.../privkey1.pem; ssh_host_*_key — host keye bez rozszerzenia .key
  local tar_err tar_rc gzip_rc rcat_rc local_gz enc_path remote_name
  tar_err="$(mktemp "${TMP_DIR:-/tmp}/hmtools-syscfg.XXXXXX.err")"
  local_gz="$(mktemp "${TMP_DIR:-/tmp}/hmtools-syscfg.XXXXXX.tar.gz")"
  set +e
  set +o pipefail
  tar --warning=no-file-changed --ignore-failed-read -cf - \
    --exclude='*.log' --exclude='cache' --exclude='tmp' \
    --exclude='shadow' --exclude='shadow-' --exclude='gshadow' --exclude='gshadow-' \
    --exclude='privkey.pem' --exclude='privkey.*.pem' --exclude='privkey*.pem' \
    --exclude='*/privkey*.pem' --exclude='*.key' \
    --exclude='ssh_host_*_key' --exclude='*/ssh_host_*_key' \
    "${paths[@]}" 2>"${tar_err}" | gzip -c > "${local_gz}"
  # $? = ostatni w pipeline (gzip); tar = PIPESTATUS[0]
  local -a _sys_ps=( "${PIPESTATUS[@]}" )
  tar_rc=${_sys_ps[0]:-1}
  gzip_rc=${_sys_ps[1]:-1}
  set -o pipefail
  set -e
  if [[ "${gzip_rc}" -ne 0 ]]; then
    rm -f "${local_gz}"
    hm_err "gzip system-configs nieudany (rc=${gzip_rc})."
    return 1
  fi
  if [[ -s "${tar_err}" ]]; then
    hm_warn "tar (system): $(head -c 200 "${tar_err}" | tr '\n' ' ')"
  fi
  rm -f "${tar_err}"
  if ! hm_tar_pipe_ok "${tar_rc}" || [[ ! -s "${local_gz}" ]]; then
    rm -f "${local_gz}"
    hm_err "Błąd archiwum konfiguracji systemowych (tar=${tar_rc})."
    return 1
  fi

  if ! enc_path="$(hm_backup_maybe_encrypt_file "${local_gz}")"; then
    rm -f "${local_gz}" "${local_gz}.enc" 2>/dev/null || true
    return 1
  fi
  remote_name="system-configs.tar.gz"
  [[ "${enc_path}" == *.enc ]] && remote_name="system-configs.tar.gz.enc"
  if hm_rclone_copyto "${enc_path}" "${remote_base}/${remote_name}"; then
    hm_ok "Konfiguracje systemowe OK (${remote_name}; bez shadow/privkey/ssh_host_*_key)."
    rm -f "${local_gz}" "${local_gz}.enc" 2>/dev/null || true
    return 0
  fi
  rm -f "${local_gz}" "${local_gz}.enc" 2>/dev/null || true
  hm_err "Upload konfiguracji systemowych nieudany."
  return 1
}

# Ustawia HM_BACKUP_DB_FAILED=(…); return 0 gdy wszystkie dump OK, 1 przy ≥1 błędzie.
hm_backup_all_databases() {
  local remote_base="$1"
  local db
  local -a dbs=()
  HM_BACKUP_DB_FAILED=()
  while IFS= read -r db; do
    [[ -n "${db}" ]] && dbs+=("${db}")
  done < <(hm_list_all_databases)
  local i=0 total="${#dbs[@]}" fail=0
  [[ "${total}" -gt 0 ]] || return 0
  for db in "${dbs[@]}"; do
    i=$((i + 1))
    hm_progress_bar "${i}" "${total}" "Dump DB: ${db}"
    hm_status_clear
    if ! hm_stream_mysqldump "${db}" "${remote_base}/databases/${db}.sql.gz"; then
      hm_err "Błąd zrzutu/uploadu DB ${db} — full backup będzie niekompletny."
      fail=$((fail + 1))
      HM_BACKUP_DB_FAILED+=("${db}")
    fi
  done
  hm_progress_done
  [[ "${fail}" -eq 0 ]]
}

hm_backup_full() {
  hm_load_config
  hm_detect_all
  if ! hm_rclone_root_is_local; then
    hm_rclone_check || return 1
  fi
  hm_backup_check_space || return 1
  hm_backup_acquire_lock || return 1
  trap 'hm_backup_release_lock' RETURN

  local stamp remote_base
  stamp="$(hm_backup_stamp)"
  # Root: <root>/full/<stamp>/
  remote_base="$(hm_backup_dest_full "${stamp}")"

  hm_info "Pełny backup serwera"
  hm_info "Root: ${RCLONE_REMOTE}${HM_BACKUP_TARGET_NAME:+ (cel=${HM_BACKUP_TARGET_NAME})}"
  hm_info "Cel: ${remote_base}"
  if [[ -z "${BACKUP_ENCRYPT_PASSPHRASE:-}" ]]; then
    hm_warn "BACKUP_ENCRYPT_PASSPHRASE nieustawione — wrażliwe artefakty (db-accounts / opcjonalnie system-configs) idą bez szyfrowania klienta. Zalecane: passphrase lub rclone crypt remote."
  fi
  hm_rclone_ensure_backup_layout
  hm_rclone_mkdir "${remote_base}"

  local cfg_ok=1 sites_fail=0 db_ok=1 db_acc_ok=0
  local -a failed_sites=()
  HM_BACKUP_DB_FAILED=()
  if ! hm_backup_system_configs "${remote_base}"; then
    cfg_ok=0
  fi
  if ! hm_backup_all_databases "${remote_base}"; then
    db_ok=0
  fi

  # Konta MySQL wszystkich nie-systemowych użytkowników (CREATE USER + GRANTS)
  hm_ensure_secure_tmpdir
  local db_acc_sql
  db_acc_sql="$(hm_mktemp .sql)"
  local -a full_db_users=()
  local _u
  while IFS= read -r _u; do
    [[ -n "${_u}" ]] || continue
    case "${_u}" in
      root|mysql|mariadb.sys|debian-sys-maint|phpmyadmin|cyberpanel) continue ;;
    esac
    hm_is_valid_db_name "${_u}" || continue
    full_db_users+=("${_u}")
  done < <(hm_mysql_exec -e "SELECT DISTINCT User FROM mysql.user;" 2>/dev/null || true)
  if [[ "${#full_db_users[@]}" -gt 0 ]] && declare -F hm_archive_export_mysql_accounts >/dev/null 2>&1; then
    if hm_archive_export_mysql_accounts "${db_acc_sql}" "${full_db_users[@]}"; then
      local enc_acc remote_acc
      if ! enc_acc="$(hm_backup_maybe_encrypt_file "${db_acc_sql}")"; then
        rm -f "${db_acc_sql}" "${db_acc_sql}.enc" 2>/dev/null || true
        hm_err "Szyfrowanie db-accounts nieudane — przerywam full (bez plaintext)."
        return 1
      fi
      remote_acc="db-accounts.sql"
      [[ "${enc_acc}" == *.enc ]] && remote_acc="db-accounts.sql.enc"
      if hm_rclone_copyto "${enc_acc}" "${remote_base}/${remote_acc}" \
        || cat "${enc_acc}" | hm_rclone_rcat "${remote_base}/${remote_acc}"; then
        db_acc_ok=1
        hm_ok "Wysłano ${remote_acc} (${#full_db_users[@]} kont MySQL)."
      else
        hm_warn "Upload ${remote_acc} nieudany."
      fi
      rm -f "${db_acc_sql}" "${db_acc_sql}.enc" 2>/dev/null || true
    fi
  else
    hm_info "Brak kont MySQL do eksportu (lub brak hm_archive_export_mysql_accounts)."
  fi
  rm -f "${db_acc_sql}" 2>/dev/null || true

  hm_discover_sites
  local domain
  local si=0 stotal="${#HM_SITES_LIST[@]}"
  hm_site_context_push
  for domain in "${HM_SITES_LIST[@]}"; do
    si=$((si + 1))
    hm_progress_bar "${si}" "${stotal}" "Backup strony: ${domain}"
    hm_status_clear
    hm_info "--- Strona: ${domain} (${si}/${stotal}) ---"
    hm_set_site_context "${domain}"
    local site_remote="${remote_base}/sites/${domain}"
    hm_rclone_mkdir "${site_remote}"
    local backup_root
    backup_root="$(hm_backup_resolve_files_root "${HM_SITE_ROOT:-${HM_SITE_DOCROOT}}" "${HM_SITE_USER}")"
    [[ -z "${backup_root}" || ! -d "${backup_root}" ]] && backup_root="${HM_SITE_ROOT:-${HM_SITE_DOCROOT}}"
    backup_root="$(hm_backup_prefer_docroot_if_shared_home "${domain}" "${backup_root}" "${HM_SITE_DOCROOT}")"
    if [[ -n "${backup_root}" && -d "${backup_root}" ]]; then
      if ! hm_upload_files_smart "${backup_root}" "${site_remote}"; then
        hm_warn "Błąd wysyłania plików dla ${domain} — kontynuuję kolejne strony."
        sites_fail=$((sites_fail + 1))
        failed_sites+=("${domain}")
      fi
    else
      hm_warn "Brak plików dla ${domain}."
    fi
  done
  hm_site_context_pop
  hm_progress_done

  local status="ok"
  if [[ "${cfg_ok}" -ne 1 || "${sites_fail}" -gt 0 || "${db_ok}" -ne 1 ]]; then
    status="partial"
  fi

  local fail_json="[]" fail_db_json="[]"
  if [[ "${#failed_sites[@]}" -gt 0 ]]; then
    fail_json="$(printf '%s\n' "${failed_sites[@]}" | awk 'BEGIN{printf "["} {printf sep "\"" $0 "\""; sep=","} END{printf "]"}')"
  fi
  if [[ "${#HM_BACKUP_DB_FAILED[@]}" -gt 0 ]]; then
    fail_db_json="$(printf '%s\n' "${HM_BACKUP_DB_FAILED[@]}" | awk 'BEGIN{printf "["} {printf sep "\"" $0 "\""; sep=","} END{printf "]"}')"
  fi

  local manifest
  manifest="$(hm_mktemp .json)"
  local _j_host _j_panel _j_ws _j_remote
  _j_host="$(hm_json_escape_str "${BACKUP_HOST_LABEL}")"
  _j_panel="$(hm_json_escape_str "${PANEL}")"
  _j_ws="$(hm_json_escape_str "${WEBSERVER}")"
  _j_remote="$(hm_json_escape_str "${remote_base}")"
  cat > "${manifest}" <<EOF
{
  "type": "full",
  "status": "${status}",
  "host": "${_j_host}",
  "stamp": "${stamp}",
  "panel": "${_j_panel}",
  "webserver": "${_j_ws}",
  "sites": $(printf '%s\n' "${HM_SITES_LIST[@]}" | awk 'BEGIN{printf "["} {printf sep "\"" $0 "\""; sep=","} END{printf "]"}'),
  "failed_sites": ${fail_json},
  "failed_databases": ${fail_db_json},
  "db_accounts": ${db_acc_ok},
  "config_ok": ${cfg_ok},
  "databases_ok": ${db_ok},
  "remote": "${_j_remote}",
  "created_at": "$(date -Iseconds)"
}
EOF
  if ! hm_write_manifest_and_upload "${remote_base}" "${manifest}"; then
    rm -f "${manifest}"
    hm_err "Upload manifest.json nieudany — usuwam niepełny full ${remote_base}."
    hm_rclone_purge "${remote_base}"
    return 1
  fi
  rm -f "${manifest}"

  if [[ "${status}" != "ok" ]]; then
    hm_err "Pełny backup NIEKOMPLETNY → ${remote_base} (status=${status}; config_ok=${cfg_ok}; databases_ok=${db_ok}; strony z błędem plików: ${sites_fail})."
    [[ "${#failed_sites[@]}" -gt 0 ]] && hm_warn "Nieudane strony: ${failed_sites[*]}"
    [[ "${#HM_BACKUP_DB_FAILED[@]}" -gt 0 ]] && hm_warn "Nieudane bazy: ${HM_BACKUP_DB_FAILED[*]}"
    return 1
  fi
  hm_ok "Pełny backup zakończony → ${remote_base}"
  hm_info "Przywrócenie: backup restore-full ${stamp}"
}
