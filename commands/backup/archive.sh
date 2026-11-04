#!/usr/bin/env bash
# Backup: archiwizacja serwisu (Drive → weryfikacja → usunięcie z VPS)

hm_rclone_file_nonempty() {
  local remote_file="$1"
  local sz
  sz="$(rclone size "${remote_file}" --json 2>/dev/null | sed -n 's/.*"bytes"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)"
  [[ -n "${sz}" && "${sz}" =~ ^[0-9]+$ && "${sz}" -gt 0 ]]
}

# Usuń niepełny/osierocony katalog snapshotu z Drive (po przerwanej archiwizacji).
hm_archive_purge_remote() {
  local remote_base="${1:-}"
  [[ -n "${remote_base}" ]] || return 0
  hm_warn "Sprzątam niepełny snapshot na Drive: ${remote_base}"
  if rclone purge "${remote_base}" 2>/dev/null; then
    hm_ok "Usunięto niepełny snapshot ${remote_base}"
  else
    rclone delete "${remote_base}" --rmdirs 2>/dev/null || true
    hm_warn "Nie udało się w pełni usunąć ${remote_base} — sprawdź ręcznie na Drive."
  fi
}

hm_archive_abort() {
  local msg="$1"
  local remote_base="${2:-}"
  hm_err "${msg}"
  hm_archive_purge_remote "${remote_base}"
  return 1
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
    # archive = pełny dump (ARCHIVE_EXCLUDES, domyślnie puste) — potem kasujemy VPS
    hm_chunked_tar_upload "${src_dir}" "${remote_base}/files.chunks" "archive" >&2 || return 1
    local marker n
    marker="$(rclone cat "${remote_base}/files.chunks/files.tar.gz.chunks.txt" 2>/dev/null || true)"
    n="$(printf '%s' "${marker}" | sed -n 's/^chunks=//p' | tr -d '[:space:]')"
    if [[ -z "${n}" || ! "${n}" =~ ^[0-9]+$ ]]; then
      n="$(rclone lsf "${remote_base}/files.chunks/" 2>/dev/null | grep -c '^files\.tar\.gz\.part_' || echo 0)"
      n="$(echo "${n}" | tr -d '[:space:]')"
    fi
    printf 'chunks\t%s\n' "${n:-0}"
  else
    hm_stream_tar_rcat "${src_dir}" "${remote_base}/files.tar.gz" "archive" >&2 || return 1
    printf 'tar\t0\n'
  fi
}

hm_archive_write_ols_snippet() {
  local domain="$1"
  local out_file="$2"
  local conf="${OLS_CONF:-}"
  : > "${out_file}"
  [[ -n "${conf}" && -f "${conf}" ]] || return 0
  # virtualHost / virtualhost — case-insensitive; map z tagiem listenera (restore 1:1)
  awk -v dom="${domain}" '
    BEGIN { skip=0; depth=0; in_lis=0; ldepth=0; cur_listener="" }
    {
      line=$0
      first=$1
      second=$2
      gsub(/\{/,"",second)
    }
    tolower(first)=="virtualhost" {
      if (second == dom) {
        print; skip=1; depth=0
        if (line ~ /\{/) depth=1
        next
      }
    }
    skip {
      print
      if (line ~ /\{/) depth++
      if (line ~ /\}/) {
        depth--
        if (depth <= 0) { skip=0; depth=0 }
      }
      next
    }
    tolower(first)=="listener" {
      cur_listener=second
      in_lis=1; ldepth=0
      if (line ~ /\{/) ldepth=1
      next
    }
    in_lis {
      if (tolower(first)=="map" && second == dom) {
        print "# listener:" cur_listener
        print
      }
      if (line ~ /\{/) ldepth++
      if (line ~ /\}/) {
        ldepth--
        if (ldepth <= 0) { in_lis=0; ldepth=0; cur_listener="" }
      }
      next
    }
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
  # BEZ -h: zachowaj symlinki certbota (live/*.pem → archive/) — renew działa po restore
  tar -czf "${out_tar}" "${paths[@]}" 2>/dev/null
}

# Eksport wierszy CyberPanel (website + childdomains + databases) do SQL INSERT.
hm_archive_export_cyberpanel_sql() {
  local domain="$1"
  local out_sql="$2"
  local id dumpcli q
  hm_is_valid_domain "${domain}" || return 1
  [[ "${PANEL:-}" == "cyberpanel" ]] || return 1
  q="$(hm_sql_quote "${domain}")"
  id="$(hm_mysql_exec cyberpanel -e "SELECT id FROM websiteFunctions_websites WHERE domain=${q} LIMIT 1;" 2>/dev/null | tr -d '[:space:]')"
  [[ -n "${id}" && "${id}" =~ ^[0-9]+$ ]] || return 1
  dumpcli="$(hm_mysqldump_cli)" || return 1
  local sock=()
  [[ -n "${MYSQL_SOCKET:-}" ]] && sock=(--socket="${MYSQL_SOCKET}")
  {
    echo "-- hmtools archive: CyberPanel rows for ${domain} (id=${id})"
    echo "USE \`cyberpanel\`;"
    "${dumpcli}" "${sock[@]}" cyberpanel websiteFunctions_websites \
      --where="id=${id}" --no-create-info --complete-insert --skip-lock-tables --skip-comments 2>/dev/null || true
    "${dumpcli}" "${sock[@]}" cyberpanel websiteFunctions_childdomains \
      --where="master_id=${id}" --no-create-info --complete-insert --skip-lock-tables --skip-comments 2>/dev/null || true
    "${dumpcli}" "${sock[@]}" cyberpanel databases_databases \
      --where="website_id=${id}" --no-create-info --complete-insert --skip-lock-tables --skip-comments 2>/dev/null || true
  } > "${out_sql}"
  [[ -s "${out_sql}" ]]
}

# Czy linia GRANT dotyczy baz ze snapshotu (lub USAGE ON *.*).
# $1=linia; dalsze args = dozwolone nazwy baz.
hm_archive_grant_for_snapshot_dbs() {
  local line="$1"
  shift || true
  local -a dbs=("$@")
  local db esc
  # USAGE / minimalne na *.* — zostaw (konto musi istnieć)
  if [[ "${line}" =~ ON[[:space:]]+\*\.\* ]]; then
    return 0
  fi
  [[ "${#dbs[@]}" -eq 0 ]] && return 0
  for db in "${dbs[@]}"; do
    [[ -n "${db}" ]] || continue
    # dopasuj `dbname` oraz wariant z escapowanym \_
    esc="${db//_/\\_}"
    if [[ "${line}" == *'`'"${db}"'`'* ]] || [[ "${line}" == *'`'"${esc}"'`'* ]]; then
      return 0
    fi
  done
  return 1
}

# Zrzut kont MySQL (CREATE USER + GRANTS) — tylko konta exclusive / podane.
# Użycie: hm_archive_export_mysql_accounts out.sql [--dbs db1,db2] user1 user2…
# GRANT-y na bazy spoza --dbs są pomijane (nie psują cudzych serwisów przy restore).
hm_archive_export_mysql_accounts() {
  local out_sql="$1"
  shift || true
  local -a allow_dbs=()
  local -a users=()
  if [[ "${1:-}" == "--dbs" ]]; then
    shift
    local dbs_csv="${1:-}"
    shift || true
    IFS=',' read -r -a allow_dbs <<< "${dbs_csv}"
  fi
  users=("$@")
  : > "${out_sql}"
  chmod 600 "${out_sql}" 2>/dev/null || true

  local u host create grants line exported=0
  local -a hosts=()
  {
    echo "-- hmtools archive: MySQL/MariaDB accounts (exclusive; GRANT filtered to snapshot DBs)"
    echo "-- generated: $(date -Iseconds)"
    echo "-- allow_dbs: ${allow_dbs[*]:-*} "
    echo "FLUSH PRIVILEGES;"
  } >> "${out_sql}"

  for u in "${users[@]}"; do
    [[ -n "${u}" ]] || continue
    hm_is_valid_db_name "${u}" || continue
    case "${u}" in
      root|mysql|mariadb.sys|debian-sys-maint|phpmyadmin|cyberpanel) continue ;;
    esac
    hosts=()
    while IFS= read -r host; do
      [[ -n "${host}" ]] && hosts+=("${host}")
    done < <(hm_mysql_exec -e "SELECT Host FROM mysql.user WHERE User=$(hm_sql_quote "${u}");" 2>/dev/null || true)
    [[ "${#hosts[@]}" -gt 0 ]] || continue

    for host in "${hosts[@]}"; do
      echo >> "${out_sql}"
      echo "-- account ${u}@${host}" >> "${out_sql}"
      # DROP tylko gdy konto nie istnieje przy restore — tag dla restore parsera
      printf '-- HM_DROP_IF_MISSING %s@%s\n' "${u}" "${host}" >> "${out_sql}"
      printf 'DROP USER IF EXISTS %s@%s;\n' "$(hm_sql_quote "${u}")" "$(hm_sql_quote "${host}")" >> "${out_sql}"

      create=""
      # -r (raw): batch bez -r podwaja backslashe w SHOW GRANTS (`alpha\_x` → `alpha\\_x`)
      create="$(hm_mysql_exec_raw -e "SHOW CREATE USER $(hm_sql_quote "${u}")@$(hm_sql_quote "${host}");" 2>/dev/null | head -1 || true)"
      if [[ -z "${create}" ]]; then
        create="$(hm_mysql_exec_raw -e "
SELECT CONCAT(
  'CREATE USER ', QUOTE(User), '@', QUOTE(Host),
  ' IDENTIFIED WITH ''', IFNULL(NULLIF(plugin,''), 'mysql_native_password'), ''' AS ',
  QUOTE(IFNULL(authentication_string, '')),
  ';'
)
FROM mysql.user
WHERE User=$(hm_sql_quote "${u}") AND Host=$(hm_sql_quote "${host}")
LIMIT 1;" 2>/dev/null | head -1 || true)"
      fi
      if [[ -z "${create}" ]]; then
        hm_warn "Brak CREATE USER dla ${u}@${host} — pomijam konto."
        continue
      fi
      [[ "${create}" == *';' ]] || create="${create};"
      printf '%s\n' "${create}" >> "${out_sql}"

      grants="$(hm_mysql_exec_raw -e "SHOW GRANTS FOR $(hm_sql_quote "${u}")@$(hm_sql_quote "${host}");" 2>/dev/null || true)"
      while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ -n "${line}" ]] || continue
        if [[ "${#allow_dbs[@]}" -gt 0 ]] && ! hm_archive_grant_for_snapshot_dbs "${line}" "${allow_dbs[@]}"; then
          echo "-- skipped foreign grant: ${line}" >> "${out_sql}"
          continue
        fi
        [[ "${line}" == *';' ]] || line="${line};"
        printf '%s\n' "${line}" >> "${out_sql}"
      done <<< "${grants}"
      exported=$((exported + 1))
    done
  done

  echo >> "${out_sql}"
  echo "FLUSH PRIVILEGES;" >> "${out_sql}"
  [[ "${exported}" -gt 0 ]]
}

# Snapshot konta Unix (passwd/shadow/group) + kopia authorized_keys.
# Zwraca 0 gdy zapisano meta, 1 gdy brak użytkownika.
hm_archive_export_unix_account() {
  local user="$1"
  local out_meta="$2"
  local out_keys="$3"
  local pw sh grp home uid gid shell gecos gname keysf

  hm_is_valid_unix_user "${user}" || return 1
  pw="$(getent passwd "${user}" 2>/dev/null || true)"
  [[ -n "${pw}" ]] || return 1

  IFS=':' read -r _ _ uid gid gecos home shell _ <<< "${pw}"
  sh="$(getent shadow "${user}" 2>/dev/null || true)"
  local shadow_hash=""
  if [[ -n "${sh}" ]]; then
    IFS=':' read -r _ shadow_hash _ <<< "${sh}"
  fi
  gname="$(getent group "${gid}" 2>/dev/null | cut -d: -f1 || true)"
  [[ -n "${gname}" ]] || gname="${user}"

  # umask tylko w subshellu — nie wycieka na resztę procesu archive
  (
    umask 077
    {
      printf 'name=%s\n' "${user}"
      printf 'uid=%s\n' "${uid}"
      printf 'gid=%s\n' "${gid}"
      printf 'group=%s\n' "${gname}"
      printf 'home=%s\n' "${home}"
      printf 'shell=%s\n' "${shell}"
      printf 'gecos=%s\n' "${gecos}"
      printf 'shadow=%s\n' "${shadow_hash}"
      printf 'shared=%s\n' "${HM_DEL_USER_SHARED:-0}"
      printf 'protected=%s\n' "${HM_DEL_USER_PROTECTED:-0}"
      printf 'exported_at=%s\n' "$(date -Iseconds)"
    } > "${out_meta}"
    chmod 600 "${out_meta}"

    : > "${out_keys}"
    chmod 600 "${out_keys}"
    if [[ -n "${home}" && -f "${home}/.ssh/authorized_keys" && ! -L "${home}/.ssh" && ! -L "${home}/.ssh/authorized_keys" ]]; then
      keysf="${home}/.ssh/authorized_keys"
      while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ -n "${line}" ]] || continue
        [[ "${line}" =~ ^[[:space:]]*# ]] && { printf '%s\n' "${line}" >> "${out_keys}"; continue; }
        if declare -F hm_access_is_valid_ssh_key_line >/dev/null 2>&1; then
          hm_access_is_valid_ssh_key_line "${line}" || continue
        fi
        printf '%s\n' "${line}" >> "${out_keys}"
      done < "${keysf}"
    fi
  )
  return 0
}

# Właściwa logika archiwum — wywoływana z hm_backup_archive_site (push/pop kontekstu REPL).
_hm_backup_archive_site_body() {
  local domain="${1:-}"
  [[ -n "${domain}" ]] || {
    hm_err "Użycie: webs archive <domena>  /  backup archive <domena>  /  archive (w kontekście)"
    return 1
  }

  hm_load_config
  hm_detect_all
  hm_rclone_check || return 1
  hm_backup_check_space || return 1
  hm_backup_acquire_lock || return 1
  trap 'hm_backup_release_lock' RETURN

  domain="$(hm_find_site_by_arg_exact "${domain}" 2>/dev/null)" || {
    # exact fail — spróbuj z potwierdzeniem partial (TTY) albo jasny błąd
    domain="$(hm_find_site_by_arg "${domain}")" || return 1
  }

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
  local -a archive_db_users=()
  local dline dname
  for dline in "${HM_DEL_DBS[@]}"; do
    [[ -n "${dline}" ]] || continue
    IFS='|' read -r dname _ <<<"${dline}"
    [[ -n "${dname}" ]] && archive_dbs+=("${dname}")
  done
  # TYLKO konta exclusive (HM_DEL_DB_USERS) — współdzielonych NIE eksportujemy (DROP psułby inne serwisy)
  local _du
  for _du in "${HM_DEL_DB_USERS[@]}"; do
    [[ -n "${_du}" ]] || continue
    hm_is_valid_db_name "${_du}" || continue
    archive_db_users+=("${_du}")
  done
  # dołącz też nie-shared prefix-match z skip? — tylko pewne z HM_DEL_DBS

  local db_desc="brak"
  if [[ "${#archive_dbs[@]}" -gt 0 ]]; then
    db_desc="${#archive_dbs[@]} baza/baz: $(IFS=', '; echo "${archive_dbs[*]}")"
  fi
  local dbu_desc="brak"
  if [[ "${#archive_db_users[@]}" -gt 0 ]]; then
    dbu_desc="$(IFS=', '; echo "${archive_db_users[*]}")"
  fi
  local unix_desc="brak"
  if [[ -n "${HM_DEL_USER}" ]] && id "${HM_DEL_USER}" >/dev/null 2>&1; then
    unix_desc="${HM_DEL_USER} (uid/gid/shadow/SSH keys)"
  fi

  # Pełny katalog domowy (.ssh, .pm2, .config, historia…), gdy HOME obejmuje site root
  local archive_files_root archive_files_size
  archive_files_root="$(hm_backup_resolve_files_root "${HM_DEL_ROOT:-${HM_DEL_DOCROOT}}" "${HM_DEL_USER}")"
  if [[ -z "${archive_files_root}" || ! -d "${archive_files_root}" ]]; then
    archive_files_root="${HM_DEL_ROOT}"
  fi
  archive_files_size="$(hm_dir_size_bytes "${archive_files_root}" 2>/dev/null || echo "${HM_DEL_SIZE:-0}")"

  local -a plan_steps=(
    "[BACKUP] Utworzenie katalogu archiwum na Google Drive: ${remote_base}"
    "[BACKUP] Zrzut i wysyłka baz danych MySQL (${db_desc}) → db/*.sql.gz"
    "[BACKUP] Eksport kont MySQL (CREATE USER + GRANTS / hash): ${dbu_desc} → db-accounts.sql"
    "[BACKUP] Snapshot konta Unix SSH: ${unix_desc} → unix-account.meta + unix-authorized_keys"
    "[BACKUP] Spakowanie PEŁNEGO katalogu ${archive_files_root} ($(hm_human_size "${archive_files_size}")) bez BACKUP_EXCLUDES (ARCHIVE_EXCLUDES=$(hm_backup_excludes_list archive); ukryte .ssh/.pm2/.git/tmp/… włącznie) → files.tar.gz / files.chunks/"
    "[BACKUP] OLS vhost + SSL (symlinki live/ zachowane) + crontab + PM2 + cyberpanel-site.sql + manifest.json"
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
      hm_archive_abort "Archiwizacja przerwana — błąd zrzutu/uploadu bazy ${name}. Nic nie usunięto z VPS." "${remote_base}"
      return 1
    fi
  done

  # Konta MySQL (hasła jako hash + GRANTS) — wymagane do restore 1:1
  local has_db_accounts=0
  local db_acc_sha="" unix_meta_sha=""
  local db_acc_sql="${TMP_DIR}/db-accounts-${domain}-${stamp}.sql"
  if [[ "${#archive_db_users[@]}" -gt 0 ]]; then
    if hm_archive_export_mysql_accounts "${db_acc_sql}" --dbs "$(IFS=','; echo "${archive_dbs[*]}")" "${archive_db_users[@]}"; then
      local enc_db remote_db
      enc_db="$(hm_backup_maybe_encrypt_file "${db_acc_sql}")"
      remote_db="db-accounts.sql"
      [[ "${enc_db}" == *.enc ]] && remote_db="db-accounts.sql.enc"
      db_acc_sha="$(hm_backup_sha256_file "${enc_db}" || true)"
      if hm_rclone_copyto "${enc_db}" "${remote_base}/${remote_db}" \
        || cat "${enc_db}" | hm_rclone_rcat "${remote_base}/${remote_db}"; then
        has_db_accounts=1
        hm_ok "Wysłano ${remote_db} (${#archive_db_users[@]} userów: ${dbu_desc})"
      else
        rm -f "${db_acc_sql}" "${db_acc_sql}.enc"
        hm_archive_abort "Upload ${remote_db} nieudany. Nic nie usunięto z VPS." "${remote_base}"
        return 1
      fi
    else
      hm_warn "Nie wyeksportowano kont MySQL (brak CREATE USER / konta nieistniejące) — kontynuuję."
    fi
  else
    hm_info "Brak dedykowanych kont MySQL do eksportu."
  fi
  rm -f "${db_acc_sql}" "${db_acc_sql}.enc" 2>/dev/null || true

  # Konto Unix + authorized_keys (hash z shadow)
  local has_unix_account=0
  local unix_meta="${TMP_DIR}/unix-account-${domain}-${stamp}.meta"
  local unix_keys="${TMP_DIR}/unix-keys-${domain}-${stamp}.txt"
  if [[ -n "${HM_DEL_USER}" ]] && id "${HM_DEL_USER}" >/dev/null 2>&1; then
    if hm_archive_export_unix_account "${HM_DEL_USER}" "${unix_meta}" "${unix_keys}"; then
      local enc_ux remote_ux
      enc_ux="$(hm_backup_maybe_encrypt_file "${unix_meta}")"
      remote_ux="unix-account.meta"
      [[ "${enc_ux}" == *.enc ]] && remote_ux="unix-account.meta.enc"
      unix_meta_sha="$(hm_backup_sha256_file "${enc_ux}" || true)"
      if hm_rclone_copyto "${enc_ux}" "${remote_base}/${remote_ux}" \
        || cat "${enc_ux}" | hm_rclone_rcat "${remote_base}/${remote_ux}"; then
        has_unix_account=1
        hm_ok "Wysłano ${remote_ux} (${HM_DEL_USER})"
      else
        rm -f "${unix_meta}" "${unix_keys}" "${unix_meta}.enc"
        hm_archive_abort "Upload ${remote_ux} nieudany. Nic nie usunięto z VPS." "${remote_base}"
        return 1
      fi
      if [[ -s "${unix_keys}" ]]; then
        hm_rclone_copyto "${unix_keys}" "${remote_base}/unix-authorized_keys" \
          || cat "${unix_keys}" | hm_rclone_rcat "${remote_base}/unix-authorized_keys" \
          || hm_warn "Nie wysłano unix-authorized_keys (kontynuuję)."
      fi
    else
      hm_warn "Nie udało się zbudować snapshota konta Unix ${HM_DEL_USER}."
    fi
  else
    hm_info "Brak konta Unix strony do eksportu."
  fi
  rm -f "${unix_meta}" "${unix_keys}" "${unix_meta}.enc" 2>/dev/null || true

  local backup_root="${archive_files_root}"
  if [[ -z "${backup_root}" || ! -d "${backup_root}" ]]; then
    backup_root="$(hm_backup_resolve_files_root "${HM_DEL_ROOT:-${HM_DEL_DOCROOT}}" "${HM_DEL_USER}")"
  fi
  if [[ -z "${backup_root}" || ! -d "${backup_root}" ]]; then
    backup_root="${HM_DEL_ROOT:-${HM_DEL_DOCROOT}}"
  fi
  if [[ -z "${backup_root}" || ! -d "${backup_root}" ]]; then
    hm_archive_abort "Brak katalogu strony do archiwizacji. Nic nie usunięto z VPS." "${remote_base}"
    return 1
  fi
  hm_info "Archiwizacja plików z pełnego katalogu: ${backup_root} (ukryte .ssh/.pm2/.config/… włącznie)"

  local files_mode="none" chunks_count=0 report
  report="$(hm_archive_upload_site_files "${backup_root}" "${remote_base}")" || {
    hm_archive_abort "Archiwizacja przerwana — błąd wysyłki plików. Nic nie usunięto z VPS." "${remote_base}"
    return 1
  }
  # ostatnia linia = tryb (tar|chunks); ignoruj ewentualne śmieci na stdout
  IFS=$'\t' read -r files_mode chunks_count < <(printf '%s\n' "${report}" | tail -n 1)
  [[ -n "${chunks_count}" ]] || chunks_count=0
  case "${files_mode}" in
    tar|chunks) ;;
    *)
      hm_archive_abort "Nie udało się odczytać trybu archiwum plików (otrzymano: ${files_mode:-puste}). Nic nie usunięto z VPS." "${remote_base}"
      return 1
      ;;
  esac

  # vhost + cały katalog OLS vhost
  if [[ -n "${HM_SITE_VHOST:-}" && -f "${HM_SITE_VHOST}" ]]; then
    hm_rclone_copyto "${HM_SITE_VHOST}" "${remote_base}/vhost.conf" 2>/dev/null \
      || cat "${HM_SITE_VHOST}" | hm_rclone_rcat "${remote_base}/vhost.conf" \
      || { hm_archive_abort "Nie udało się wysłać vhost.conf. Nic nie usunięto z VPS." "${remote_base}"; return 1; }
  fi
  if [[ -n "${HM_DEL_VHOST_DIR}" && -d "${HM_DEL_VHOST_DIR}" ]]; then
    local vtar="${TMP_DIR}/ols-vhost-${domain}-${stamp}.tar.gz"
    if tar -C "$(dirname "${HM_DEL_VHOST_DIR}")" -czf "${vtar}" "$(basename "${HM_DEL_VHOST_DIR}")" 2>/dev/null; then
      hm_rclone_copyto "${vtar}" "${remote_base}/ols-vhost-dir.tar.gz" || {
        rm -f "${vtar}"
        hm_archive_abort "Upload ols-vhost-dir.tar.gz nieudany. Nic nie usunięto z VPS." "${remote_base}"
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

  # SSL (symlinki live/ zachowane)
  local ssl_tar="${TMP_DIR}/ssl-${domain}-${stamp}.tar.gz"
  if hm_archive_pack_ssl "${domain}" "${ssl_tar}"; then
    hm_rclone_copyto "${ssl_tar}" "${remote_base}/ssl.tar.gz" || {
      rm -f "${ssl_tar}"
      hm_archive_abort "Upload ssl.tar.gz nieudany. Nic nie usunięto z VPS." "${remote_base}"
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
    hm_site_context_push
    HM_SITE_DOMAIN="${domain}"
    HM_SITE_ROOT="${HM_DEL_ROOT}"
    HM_SITE_USER="${HM_DEL_USER}"
    local jlist
    jlist="$(hm_pm2_jlist 2>/dev/null || echo '[]')"
    printf '%s\n' "${jlist}" > "${pm2_json}"
    hm_site_context_pop
  fi
  if [[ -s "${pm2_json}" ]]; then
    hm_rclone_copyto "${pm2_json}" "${remote_base}/pm2-processes.json" \
      || cat "${pm2_json}" | hm_rclone_rcat "${remote_base}/pm2-processes.json" || true
  fi
  rm -f "${pm2_json}"

  # CyberPanel DB rows (website / childdomains / databases)
  local has_cp=0
  local cp_sql="${TMP_DIR}/cyberpanel-${domain}-${stamp}.sql"
  if hm_archive_export_cyberpanel_sql "${domain}" "${cp_sql}"; then
    if hm_rclone_copyto "${cp_sql}" "${remote_base}/cyberpanel-site.sql" \
      || cat "${cp_sql}" | hm_rclone_rcat "${remote_base}/cyberpanel-site.sql"; then
      has_cp=1
      hm_ok "Wysłano cyberpanel-site.sql"
    else
      hm_warn "Upload cyberpanel-site.sql nieudany (kontynuuję)."
    fi
  else
    hm_info "Brak wierszy CyberPanel do eksportu (lub nie-CP)."
  fi
  rm -f "${cp_sql}"

  local db_json="" n
  for n in "${archive_dbs[@]}"; do
    [[ -n "${n}" ]] || continue
    db_json="${db_json}\"${n}\","
  done
  db_json="${db_json%,}"

  local dbu_json=""
  for n in "${archive_db_users[@]}"; do
    [[ -n "${n}" ]] || continue
    dbu_json="${dbu_json}\"${n}\","
  done
  dbu_json="${dbu_json%,}"

  local manifest="${TMP_DIR}/manifest-archive-${domain}-${stamp}.json"
  local _j_domain _j_host _j_root _j_doc _j_user _j_php _j_remote _j_uhome
  _j_domain="$(hm_json_escape_str "${domain}")"
  _j_host="$(hm_json_escape_str "${BACKUP_HOST_LABEL:-}")"
  _j_root="$(hm_json_escape_str "${backup_root}")"
  _j_doc="$(hm_json_escape_str "${HM_DEL_DOCROOT}")"
  _j_user="$(hm_json_escape_str "${HM_DEL_USER}")"
  _j_uhome="$(hm_json_escape_str "$(getent passwd "${HM_DEL_USER}" 2>/dev/null | cut -d: -f6 || true)")"
  _j_php="$(hm_json_escape_str "${HM_SITE_PHP:-}")"
  _j_remote="$(hm_json_escape_str "${remote_base}")"
  cat > "${manifest}" <<EOF
{
  "type": "archive",
  "archived": true,
  "domain": "${_j_domain}",
  "host": "${_j_host}",
  "stamp": "${stamp}",
  "site_root": "${_j_root}",
  "docroot": "${_j_doc}",
  "site_user": "${_j_user}",
  "unix_home": "${_j_uhome}",
  "php": "${_j_php}",
  "databases": [${db_json}],
  "db_users": [${dbu_json}],
  "db_accounts": ${has_db_accounts},
  "unix_account": ${has_unix_account},
  "sha256_db_accounts": "$(hm_json_escape_str "${db_acc_sha}")",
  "sha256_unix_account": "$(hm_json_escape_str "${unix_meta_sha}")",
  "excludes": "$(hm_json_escape_str "$(hm_backup_excludes_list archive)")",
  "cyberpanel_site": ${has_cp:-0},
  "files_mode": "${files_mode}",
  "chunks_count": ${chunks_count},
  "remote": "${_j_remote}",
  "created_at": "$(date -Iseconds)"
}
EOF
  if ! hm_write_manifest_and_upload "${remote_base}" "${manifest}"; then
    rm -f "${manifest}"
    hm_archive_abort "Upload manifest.json nieudany. Nic nie usunięto z VPS." "${remote_base}"
    return 1
  fi
  rm -f "${manifest}"

  # --- Weryfikacja ---
  if ! hm_backup_verify_remote_archive "${remote_base}" "${files_mode}" "${chunks_count}" "${archive_dbs[@]}"; then
    hm_archive_abort "Archiwizacja przerwana po nieudanej weryfikacji. Nic nie usunięto z VPS." "${remote_base}"
    return 1
  fi
  local _db_remote="db-accounts.sql"
  hm_rclone_file_nonempty "${remote_base}/db-accounts.sql.enc" 2>/dev/null && _db_remote="db-accounts.sql.enc"
  local _ux_remote="unix-account.meta"
  hm_rclone_file_nonempty "${remote_base}/unix-account.meta.enc" 2>/dev/null && _ux_remote="unix-account.meta.enc"
  if [[ "${has_db_accounts}" -eq 1 ]] && ! hm_rclone_file_nonempty "${remote_base}/${_db_remote}"; then
    hm_archive_abort "WERYFIKACJA NIEUDANA: brak/pusty ${_db_remote}. Nic nie usunięto z VPS." "${remote_base}"
    return 1
  fi
  if [[ "${has_unix_account}" -eq 1 ]] && ! hm_rclone_file_nonempty "${remote_base}/${_ux_remote}"; then
    hm_archive_abort "WERYFIKACJA NIEUDANA: brak/pusty ${_ux_remote}. Nic nie usunięto z VPS." "${remote_base}"
    return 1
  fi
  # SHA256 (gdy remote wspiera hashsum) — wykrycie uszkodzonego uploadu przed usunięciem z VPS
  if [[ -n "${db_acc_sha}" && "${has_db_accounts}" -eq 1 ]]; then
    local remote_hash
    remote_hash="$(hm_rclone_remote_sha256 "${remote_base}/${_db_remote}" || true)"
    if [[ -n "${remote_hash}" && "${remote_hash}" != "${db_acc_sha}" ]]; then
      hm_archive_abort "WERYFIKACJA NIEUDANA: SHA256 ${_db_remote} lokalnie≠Drive. Nic nie usunięto z VPS." "${remote_base}"
      return 1
    fi
  fi
  if [[ -n "${unix_meta_sha}" && "${has_unix_account}" -eq 1 ]]; then
    local remote_hash_u
    remote_hash_u="$(hm_rclone_remote_sha256 "${remote_base}/${_ux_remote}" || true)"
    if [[ -n "${remote_hash_u}" && "${remote_hash_u}" != "${unix_meta_sha}" ]]; then
      hm_archive_abort "WERYFIKACJA NIEUDANA: SHA256 ${_ux_remote} lokalnie≠Drive. Nic nie usunięto z VPS." "${remote_base}"
      return 1
    fi
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

hm_backup_archive_site() {
  local prev="${HM_SITE_DOMAIN:-}"
  local rc=0
  hm_site_context_push
  _hm_backup_archive_site_body "$@" || rc=$?
  hm_site_context_pop
  # archiwum może usunąć stronę — nie zostawiaj kontekstu usuniętej domeny
  if [[ -n "${prev}" ]] && ! hm_find_site_by_arg "${prev}" >/dev/null 2>&1; then
    hm_clear_site_context
  fi
  return "${rc}"
}
