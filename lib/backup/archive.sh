#!/usr/bin/env bash
# Backup: archiwizacja serwisu (Drive → weryfikacja → usunięcie z VPS)

hm_rclone_file_nonempty() {
  local remote_file="$1"
  local sz
  sz="$(rclone size "${remote_file}" --json 2>/dev/null | sed -n 's/.*"bytes"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)"
  [[ -n "${sz}" && "${sz}" =~ ^[0-9]+$ && "${sz}" -gt 0 ]]
}

hm_backup_verify_remote_archive() {
  local remote_base="$1"
  local files_mode="$2"
  local expected_chunks="${3:-0}"
  shift 3 || true
  local -a dbs=("$@")

  hm_info "Weryfikacja integralności kopii archiwalnej na Drive: ${remote_base}"

  if ! hm_rclone_file_nonempty "${remote_base}/manifest.json"; then
    hm_err "WERYFIKACJA NIEUDANA: brak lub pusty plik manifest.json na Drive!"
    return 1
  fi

  if [[ "${files_mode}" == "tar" ]]; then
    if ! hm_rclone_file_nonempty "${remote_base}/files.tar.gz"; then
      hm_err "WERYFIKACJA NIEUDANA: brak lub pusty plik files.tar.gz na Drive!"
      return 1
    fi
  elif [[ "${files_mode}" == "chunks" ]]; then
    local remote_parts
    remote_parts="$(rclone lsf "${remote_base}/files.chunks/" 2>/dev/null | grep -c '^files\.tar\.gz\.part_' || echo 0)"
    remote_parts="$(echo "${remote_parts}" | tr -d '[:space:]')"
    [[ "${remote_parts}" =~ ^[0-9]+$ ]] || remote_parts=0
    if [[ "${remote_parts}" -ne "${expected_chunks}" || "${expected_chunks}" -le 0 ]]; then
      hm_err "WERYFIKACJA NIEUDANA: liczba chunków na Drive (${remote_parts}) != oczekiwanej (${expected_chunks})!"
      return 1
    fi
    if ! hm_rclone_file_nonempty "${remote_base}/files.chunks/files.tar.gz.part_0000"; then
      hm_err "WERYFIKACJA NIEUDANA: chunk part_0000 jest pusty lub niedostępny!"
      return 1
    fi
  else
    hm_err "WERYFIKACJA NIEUDANA: nieznany tryb archiwum plików (${files_mode})!"
    return 1
  fi

  local db sz
  for db in "${dbs[@]}"; do
    [[ -n "${db}" ]] || continue
    sz="$(rclone size "${remote_base}/db/${db}.sql.gz" --json 2>/dev/null | sed -n 's/.*"bytes"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)"
    if [[ -z "${sz}" || ! "${sz}" =~ ^[0-9]+$ || "${sz}" -le 20 ]]; then
      hm_err "WERYFIKACJA NIEUDANA: zrzut bazy db/${db}.sql.gz nie istnieje lub jest pusty (${sz:-0} B)!"
      return 1
    fi
  done

  hm_ok "Weryfikacja kopii w chmurze zakończona sukcesem (wszystkie pliki i bazy potwierdzone)."
  return 0
}

hm_archive_upload_site_files() {
  # stdout: files_mode<TAB>chunks_count
  local src_dir="$1"
  local remote_base="$2"
  local size_b threshold_b
  size_b="$(hm_dir_size_bytes "${src_dir}")"
  threshold_b=$((CHUNK_THRESHOLD_MB * 1024 * 1024))

  if [[ "${size_b}" -ge "${threshold_b}" ]]; then
    # hm_info/hm_ok idą na stdout — przekieruj, żeby report=$((...)) dostał tylko printf
    hm_chunked_tar_upload "${src_dir}" "${remote_base}/files.chunks" >&2 || return 1
    local marker n
    marker="$(rclone cat "${remote_base}/files.chunks/files.tar.gz.chunks.txt" 2>/dev/null || true)"
    n="$(printf '%s' "${marker}" | sed -n 's/^chunks=//p' | tr -d '[:space:]')"
    if [[ -z "${n}" || ! "${n}" =~ ^[0-9]+$ ]]; then
      n="$(rclone lsf "${remote_base}/files.chunks/" 2>/dev/null | grep -c '^files\.tar\.gz\.part_' || echo 0)"
      n="$(echo "${n}" | tr -d '[:space:]')"
    fi
    printf 'chunks\t%s\n' "${n:-0}"
  else
    hm_stream_tar_rcat "${src_dir}" "${remote_base}/files.tar.gz" >&2 || return 1
    printf 'tar\t0\n'
  fi
}

hm_archive_write_ols_snippet() {
  local domain="$1"
  local out_file="$2"
  local conf="${OLS_CONF:-}"
  : > "${out_file}"
  [[ -n "${conf}" && -f "${conf}" ]] || return 0
  awk -v dom="${domain}" '
    BEGIN { skip=0; depth=0 }
    /^[[:space:]]*virtualHost[[:space:]]+/ {
      name=$2; gsub(/\{/,"",name)
      if (name == dom) {
        print; skip=1; depth=0
        if ($0 ~ /\{/) depth=1
        next
      }
    }
    skip {
      print
      if ($0 ~ /\{/) depth++
      if ($0 ~ /\}/) {
        depth--
        if (depth <= 0) { skip=0; depth=0 }
      }
      next
    }
    /^[[:space:]]*map[[:space:]]+/ && $2 == dom { print }
  ' "${conf}" > "${out_file}" 2>/dev/null || true
}

hm_archive_pack_ssl() {
  local domain="$1"
  local out_tar="$2"
  local -a paths=()
  local p
  for p in \
    "/etc/letsencrypt/live/${domain}" \
    "/etc/letsencrypt/archive/${domain}" \
    "/etc/letsencrypt/renewal/${domain}.conf" \
    "/root/.acme.sh/${domain}" \
    "/root/.acme.sh/${domain}_ecc"
  do
    [[ -e "${p}" ]] && paths+=("${p}")
  done
  [[ "${#paths[@]}" -gt 0 ]] || return 1
  # -h: dereferencja symlinków (live/ → archive/)
  tar -chzf "${out_tar}" "${paths[@]}" 2>/dev/null
}

hm_backup_archive_site() {
  local domain="${1:-}"
  [[ -n "${domain}" ]] || {
    hm_err "Użycie: webs archive <domena>  /  backup archive <domena>  /  archive (w kontekście)"
    return 1
  }

  hm_load_config
  hm_detect_all
  hm_rclone_check || return 1
  hm_backup_check_space || return 1

  domain="$(hm_find_site_by_arg "${domain}")" || return 1

  hm_status_line "Inwentaryzacja ${domain}…"
  if ! hm_site_collect_delete_inventory "${domain}" 0 0 0; then
    hm_status_clear
    return 1
  fi
  hm_status_clear
  hm_set_site_context "${domain}"

  local stamp remote_base
  stamp="$(hm_backup_stamp)"
  remote_base="$(hm_backup_dest_site "${domain}" "${stamp}")"

  local -a archive_dbs=()
  local dline dname
  for dline in "${HM_DEL_DBS[@]}"; do
    [[ -n "${dline}" ]] || continue
    IFS='|' read -r dname _ <<<"${dline}"
    [[ -n "${dname}" ]] && archive_dbs+=("${dname}")
  done
  # dołącz też nie-shared prefix-match z skip? — tylko pewne z HM_DEL_DBS

  local db_desc="brak"
  if [[ "${#archive_dbs[@]}" -gt 0 ]]; then
    db_desc="${#archive_dbs[@]} baza/baz: $(IFS=', '; echo "${archive_dbs[*]}")"
  fi

  local -a plan_steps=(
    "[BACKUP] Utworzenie katalogu archiwum na Google Drive: ${remote_base}"
    "[BACKUP] Zrzut i wysyłka baz danych MySQL (${db_desc}) → db/*.sql.gz"
    "[BACKUP] Spakowanie i wysyłka plików środowiska ${HM_DEL_ROOT} ($(hm_human_size "${HM_DEL_SIZE}")) → files.tar.gz / files.chunks/"
    "[BACKUP] Zapis konfiguracji vhosta OLS, certyfikatów SSL, crontaba i metadanych PM2 + manifest.json"
    "[WERYFIKACJA] Twarda kontrola integralności wszystkich plików kopii na Google Drive (rozmiar > 0 B)"
  )

  hm_site_build_delete_plan
  local s
  for s in "${HM_DEL_PLAN_STEPS[@]}"; do
    [[ -n "${s}" ]] || continue
    plan_steps+=("[USUNIĘCIE] ${s}")
  done

  hm_site_print_delete_inventory

  if ! hm_confirm_plan_critical "${domain}" \
    "ARCHIWIZACJA SERWISU WEBOWEGO (BACKUP → USUNIĘCIE Z VPS): ${domain}" \
    "Jeśli którykolwiek krok backupu lub weryfikacji na Google Drive się nie powiedzie, operacja zostanie NATYCHMIAST PRZERWANA i żaden plik ani baza na VPS nie zostaną usunięte!" \
    "${plan_steps[@]}"; then
    return 0
  fi

  # --- Faza I: backup ---
  hm_info "Faza I — backup archiwalny → ${remote_base}"
  hm_rclone_ensure_backup_layout
  hm_rclone_mkdir "$(hm_rclone_dest "${domain}")"
  hm_rclone_mkdir "${remote_base}"
  hm_rclone_mkdir "${remote_base}/db"

  mkdir -p "${TMP_DIR}"
  local name
  for name in "${archive_dbs[@]}"; do
    [[ -n "${name}" ]] || continue
    if ! hm_stream_mysqldump "${name}" "${remote_base}/db/${name}.sql.gz"; then
      hm_err "Archiwizacja przerwana — błąd zrzutu/uploadu bazy ${name}. Nic nie usunięto z VPS."
      return 1
    fi
  done

  local backup_root="${HM_DEL_ROOT}"
  if [[ -z "${backup_root}" || ! -d "${backup_root}" ]]; then
    backup_root="${HM_DEL_DOCROOT}"
  fi
  if [[ -z "${backup_root}" || ! -d "${backup_root}" ]]; then
    hm_err "Brak katalogu strony do archiwizacji. Nic nie usunięto z VPS."
    return 1
  fi

  local files_mode="none" chunks_count=0 report
  report="$(hm_archive_upload_site_files "${backup_root}" "${remote_base}")" || {
    hm_err "Archiwizacja przerwana — błąd wysyłki plików. Nic nie usunięto z VPS."
    return 1
  }
  # ostatnia linia = tryb (tar|chunks); ignoruj ewentualne śmieci na stdout
  IFS=$'\t' read -r files_mode chunks_count < <(printf '%s\n' "${report}" | tail -n 1)
  [[ -n "${chunks_count}" ]] || chunks_count=0
  case "${files_mode}" in
    tar|chunks) ;;
    *)
      hm_err "Nie udało się odczytać trybu archiwum plików (otrzymano: ${files_mode:-puste}). Nic nie usunięto z VPS."
      return 1
      ;;
  esac

  # vhost + cały katalog OLS vhost
  if [[ -n "${HM_SITE_VHOST:-}" && -f "${HM_SITE_VHOST}" ]]; then
    hm_rclone_copyto "${HM_SITE_VHOST}" "${remote_base}/vhost.conf" 2>/dev/null \
      || cat "${HM_SITE_VHOST}" | hm_rclone_rcat "${remote_base}/vhost.conf" \
      || { hm_err "Nie udało się wysłać vhost.conf. Nic nie usunięto z VPS."; return 1; }
  fi
  if [[ -n "${HM_DEL_VHOST_DIR}" && -d "${HM_DEL_VHOST_DIR}" ]]; then
    local vtar="${TMP_DIR}/ols-vhost-${domain}-${stamp}.tar.gz"
    if tar -C "$(dirname "${HM_DEL_VHOST_DIR}")" -czf "${vtar}" "$(basename "${HM_DEL_VHOST_DIR}")" 2>/dev/null; then
      hm_rclone_copyto "${vtar}" "${remote_base}/ols-vhost-dir.tar.gz" || {
        hm_err "Upload ols-vhost-dir.tar.gz nieudany. Nic nie usunięto z VPS."
        rm -f "${vtar}"
        return 1
      }
      rm -f "${vtar}"
    else
      hm_warn "Nie spakowano katalogu vhost OLS (kontynuuję)."
    fi
  fi
  local snip="${TMP_DIR}/ols-httpd-snippet-${domain}.conf"
  hm_archive_write_ols_snippet "${domain}" "${snip}"
  if [[ -s "${snip}" ]]; then
    hm_rclone_copyto "${snip}" "${remote_base}/ols-httpd-snippet.conf" \
      || cat "${snip}" | hm_rclone_rcat "${remote_base}/ols-httpd-snippet.conf" \
      || hm_warn "Nie wysłano ols-httpd-snippet.conf"
  fi
  rm -f "${snip}"

  # SSL
  local ssl_tar="${TMP_DIR}/ssl-${domain}-${stamp}.tar.gz"
  if hm_archive_pack_ssl "${domain}" "${ssl_tar}"; then
    hm_rclone_copyto "${ssl_tar}" "${remote_base}/ssl.tar.gz" || {
      hm_err "Upload ssl.tar.gz nieudany. Nic nie usunięto z VPS."
      rm -f "${ssl_tar}"
      return 1
    }
    rm -f "${ssl_tar}"
  else
    rm -f "${ssl_tar}"
    hm_info "Brak lokalnych certyfikatów SSL do spakowania."
  fi

  # crontab + pm2
  if [[ -n "${HM_DEL_USER}" ]]; then
    local cron_txt="${TMP_DIR}/crontab-${domain}.txt"
    crontab -u "${HM_DEL_USER}" -l > "${cron_txt}" 2>/dev/null || true
    if [[ -s "${cron_txt}" ]]; then
      hm_rclone_copyto "${cron_txt}" "${remote_base}/crontab.txt" \
        || cat "${cron_txt}" | hm_rclone_rcat "${remote_base}/crontab.txt" || true
    fi
    rm -f "${cron_txt}"
  fi

  local pm2_json="${TMP_DIR}/pm2-${domain}.json"
  echo '[]' > "${pm2_json}"
  if [[ "${#HM_DEL_PM2[@]}" -gt 0 ]]; then
    local save_d="${HM_SITE_DOMAIN:-}" save_r="${HM_SITE_ROOT:-}" save_u="${HM_SITE_USER:-}"
    HM_SITE_DOMAIN="${domain}"
    HM_SITE_ROOT="${HM_DEL_ROOT}"
    HM_SITE_USER="${HM_DEL_USER}"
    local jlist
    jlist="$(hm_pm2_jlist 2>/dev/null || echo '[]')"
    printf '%s\n' "${jlist}" > "${pm2_json}"
    HM_SITE_DOMAIN="${save_d}"
    HM_SITE_ROOT="${save_r}"
    HM_SITE_USER="${save_u}"
  fi
  if [[ -s "${pm2_json}" ]]; then
    hm_rclone_copyto "${pm2_json}" "${remote_base}/pm2-processes.json" \
      || cat "${pm2_json}" | hm_rclone_rcat "${remote_base}/pm2-processes.json" || true
  fi
  rm -f "${pm2_json}"

  local db_json="" n
  for n in "${archive_dbs[@]}"; do
    [[ -n "${n}" ]] || continue
    db_json="${db_json}\"${n}\","
  done
  db_json="${db_json%,}"

  local manifest="${TMP_DIR}/manifest-archive-${domain}-${stamp}.json"
  cat > "${manifest}" <<EOF
{
  "type": "archive",
  "archived": true,
  "domain": "${domain}",
  "host": "${BACKUP_HOST_LABEL:-}",
  "stamp": "${stamp}",
  "site_root": "${HM_DEL_ROOT}",
  "docroot": "${HM_DEL_DOCROOT}",
  "site_user": "${HM_DEL_USER}",
  "php": "${HM_SITE_PHP:-}",
  "databases": [${db_json}],
  "files_mode": "${files_mode}",
  "chunks_count": ${chunks_count},
  "remote": "${remote_base}",
  "created_at": "$(date -Iseconds)"
}
EOF
  if ! hm_write_manifest_and_upload "${remote_base}" "${manifest}"; then
    hm_err "Upload manifest.json nieudany. Nic nie usunięto z VPS."
    rm -f "${manifest}"
    return 1
  fi
  rm -f "${manifest}"

  # --- Weryfikacja ---
  if ! hm_backup_verify_remote_archive "${remote_base}" "${files_mode}" "${chunks_count}" "${archive_dbs[@]}"; then
    hm_err "Archiwizacja przerwana po nieudanej weryfikacji. Nic nie usunięto z VPS."
    return 1
  fi

  # --- Faza II: usunięcie ---
  hm_info "Faza II — usunięcie serwisu z VPS (po potwierdzonym backupie)."
  hm_site_execute_delete || {
    hm_err "Backup na Drive jest OK (${remote_base}), ale usuwanie z VPS zakończyło się błędem — sprawdź ręcznie."
    return 1
  }

  hm_ok "Archiwizacja ${domain} zakończona. Snapshot: ${remote_base}"
  hm_info "Przywrócenie: backup restore ${domain} ${stamp}"
}
