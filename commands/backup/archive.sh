#!/usr/bin/env bash
# Backup: archiwizacja serwisu (Drive → weryfikacja → usunięcie z VPS)

hm_rclone_file_nonempty() {
  local remote_file="$1"
  local sz
  if [[ "${remote_file}" == /* ]]; then
    [[ -f "${remote_file}" && -s "${remote_file}" ]]
    return $?
  fi
  sz="$(rclone size "${remote_file}" --json 2>/dev/null | sed -n 's/.*"bytes"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)"
  [[ -n "${sz}" && "${sz}" =~ ^[0-9]+$ && "${sz}" -gt 0 ]]
}

# gzip -t (+ opcjonalnie tar -tzf) na obiekcie zdalnym / lokalnym.
hm_backup_gzip_tar_ok() {
  local remote_file="$1"
  local check_tar="${2:-0}"
  local tmp rc=0
  if [[ "${remote_file}" == /* ]]; then
    gzip -t "${remote_file}" 2>/dev/null || return 1
    if [[ "${check_tar}" -eq 1 ]]; then
      tar -tzf "${remote_file}" >/dev/null 2>&1 || return 1
    fi
    return 0
  fi
  tmp="$(mktemp "${TMP_DIR:-/tmp}/hm-gzcheck.XXXXXX")"
  if ! rclone cat "${remote_file}" > "${tmp}" 2>/dev/null; then
    rm -f "${tmp}"
    return 1
  fi
  gzip -t "${tmp}" 2>/dev/null || rc=1
  if [[ "${rc}" -eq 0 && "${check_tar}" -eq 1 ]]; then
    tar -tzf "${tmp}" >/dev/null 2>&1 || rc=1
  fi
  rm -f "${tmp}"
  return "${rc}"
}

# Usuń niepełny/osierocony katalog snapshotu z Drive (po przerwanej archiwizacji).
hm_archive_purge_remote() {
  local remote_base="${1:-}"
  [[ -n "${remote_base}" ]] || return 0
  # Tylko katalog utworzony przez bieżący proces (kolizja stampu → nie kasuj cudzego).
  if [[ -n "${HM_BACKUP_OWNED_REMOTE:-}" && "${remote_base}" != "${HM_BACKUP_OWNED_REMOTE}" ]]; then
    hm_warn "Pomijam purge (to nie nasz snapshot): ${remote_base}"
    return 0
  fi
  if [[ "${remote_base}" == /* ]]; then
    if [[ -f "${remote_base}/.hmtools-owned" ]] \
        || [[ -n "${HM_BACKUP_OWNED_REMOTE:-}" && "${remote_base}" == "${HM_BACKUP_OWNED_REMOTE}" ]]; then
      hm_warn "Sprzątam niepełny snapshot lokalny: ${remote_base}"
      rm -rf -- "${remote_base}"
      hm_ok "Usunięto niepełny snapshot ${remote_base}"
    else
      hm_warn "Pomijam purge lokalnego katalogu bez markera .hmtools-owned: ${remote_base}"
    fi
    return 0
  fi
  hm_warn "Sprzątam niepełny snapshot na remote: ${remote_base}"
  if rclone purge "${remote_base}" 2>/dev/null; then
    hm_ok "Usunięto niepełny snapshot ${remote_base}"
  else
    rclone delete "${remote_base}" --rmdirs 2>/dev/null || true
    hm_warn "Nie udało się w pełni usunąć ${remote_base} — sprawdź ręcznie."
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
  local man want got sums_line sum path remote_parts i part_path

  hm_info "Weryfikacja integralności kopii archiwalnej: ${remote_base}"

  if ! hm_rclone_file_nonempty "${remote_base}/manifest.json"; then
    hm_err "WERYFIKACJA NIEUDANA: brak lub pusty plik manifest.json!"
    return 1
  fi

  man=""
  if [[ "${remote_base}" == /* ]]; then
    man="$(cat "${remote_base}/manifest.json" 2>/dev/null || true)"
  else
    man="$(rclone cat "${remote_base}/manifest.json" 2>/dev/null || true)"
  fi
  want="$(hm_backup_json_str "${man}" "sha256_files")"

  if [[ "${files_mode}" == "tar" ]]; then
    if ! hm_rclone_file_nonempty "${remote_base}/files.tar.gz"; then
      hm_err "WERYFIKACJA NIEUDANA: brak lub pusty plik files.tar.gz!"
      return 1
    fi
    if ! hm_backup_gzip_tar_ok "${remote_base}/files.tar.gz" 1; then
      hm_err "WERYFIKACJA NIEUDANA: files.tar.gz uszkodzony (gzip/tar)!"
      return 1
    fi
    if [[ -n "${want}" ]]; then
      got="$(hm_rclone_sha256_any "${remote_base}/files.tar.gz" || true)"
      if [[ -z "${got}" || "${got}" != "${want}" ]]; then
        hm_err "WERYFIKACJA NIEUDANA: SHA256 files.tar.gz lokalnie≠remote (${want:0:12}… ≠ ${got:0:12}…)."
        return 1
      fi
    else
      hm_err "WERYFIKACJA NIEUDANA: brak sha256_files w manifeście!"
      return 1
    fi
  elif [[ "${files_mode}" == "chunks" ]]; then
    if [[ "${remote_base}" == /* ]]; then
      remote_parts="$(find "${remote_base}/files.chunks" -maxdepth 1 -name 'files.tar.gz.part_*' 2>/dev/null | wc -l | tr -d ' ')"
    else
      remote_parts="$(rclone lsf "${remote_base}/files.chunks/" 2>/dev/null | grep -c '^files\.tar\.gz\.part_' || echo 0)"
      remote_parts="$(echo "${remote_parts}" | tr -d '[:space:]')"
    fi
    [[ "${remote_parts}" =~ ^[0-9]+$ ]] || remote_parts=0
    if [[ "${remote_parts}" -ne "${expected_chunks}" || "${expected_chunks}" -le 0 ]]; then
      hm_err "WERYFIKACJA NIEUDANA: liczba chunków (${remote_parts}) != oczekiwanej (${expected_chunks})!"
      return 1
    fi
    if ! hm_rclone_file_nonempty "${remote_base}/files.chunks/files.tar.gz.part_0000"; then
      hm_err "WERYFIKACJA NIEUDANA: chunk part_0000 jest pusty lub niedostępny!"
      return 1
    fi
    # SHA256SUMS (jeśli jest) — każdy chunk
    local sums_blob=""
    if [[ "${remote_base}" == /* && -f "${remote_base}/SHA256SUMS" ]]; then
      sums_blob="$(cat "${remote_base}/SHA256SUMS")"
    elif [[ "${remote_base}" != /* ]]; then
      sums_blob="$(rclone cat "${remote_base}/SHA256SUMS" 2>/dev/null || true)"
    fi
    local joined_want=""
    if [[ -n "${sums_blob}" ]]; then
      while read -r sums_line || [[ -n "${sums_line}" ]]; do
        sum="$(printf '%s' "${sums_line}" | awk '{print $1}')"
        path="$(printf '%s' "${sums_line}" | awk '{print $2}')"
        [[ "${sum}" =~ ^[0-9a-fA-F]{64}$ && -n "${path}" ]] || continue
        # "... files.tar.gz (joined)" = suma całego archiwum po sklejeniu (nie plik na remote)
        if [[ "${sums_line}" == *" (joined)"* ]]; then
          joined_want="${sum}"
          continue
        fi
        got="$(hm_rclone_sha256_any "${remote_base}/${path}" || true)"
        if [[ -z "${got}" || "${got}" != "${sum}" ]]; then
          hm_err "WERYFIKACJA NIEUDANA: SHA256 ${path} niezgodny."
          return 1
        fi
      done <<< "${sums_blob}"
    fi
    # sklej chunki lokalnie → gzip -t / tar -tzf + SHA256 (joined / sha256_files)
    local join_tmp
    join_tmp="$(mktemp "${TMP_DIR:-/tmp}/hm-chunks.XXXXXX.tar.gz")"
    : > "${join_tmp}"
    i=0
    while [[ "${i}" -lt "${expected_chunks}" ]]; do
      part_path="$(printf '%s/files.chunks/files.tar.gz.part_%04d' "${remote_base}" "${i}")"
      if [[ "${remote_base}" == /* ]]; then
        cat "${part_path}" >> "${join_tmp}" || {
          rm -f "${join_tmp}"
          hm_err "WERYFIKACJA NIEUDANA: brak chunka part_$(printf '%04d' "${i}")"
          return 1
        }
      else
        rclone cat "${part_path}" >> "${join_tmp}" 2>/dev/null || {
          rm -f "${join_tmp}"
          hm_err "WERYFIKACJA NIEUDANA: brak chunka part_$(printf '%04d' "${i}")"
          return 1
        }
      fi
      i=$((i + 1))
    done
    if ! gzip -t "${join_tmp}" 2>/dev/null || ! tar -tzf "${join_tmp}" >/dev/null 2>&1; then
      rm -f "${join_tmp}"
      hm_err "WERYFIKACJA NIEUDANA: sklejone chunki uszkodzone (gzip/tar)!"
      return 1
    fi
    got="$(hm_backup_sha256_file "${join_tmp}" || true)"
    if [[ -z "${got}" ]]; then
      rm -f "${join_tmp}"
      hm_err "WERYFIKACJA NIEUDANA: nie udało się policzyć SHA256 sklejonych chunków."
      return 1
    fi
    # Preferuj sha256_files z manifestu; fallback: linia (joined) w SHA256SUMS
    if [[ -n "${want}" ]]; then
      if [[ "${got}" != "${want}" ]]; then
        rm -f "${join_tmp}"
        hm_err "WERYFIKACJA NIEUDANA: SHA256 sklejonych chunków ≠ sha256_files."
        return 1
      fi
    elif [[ -n "${joined_want}" ]]; then
      if [[ "${got}" != "${joined_want}" ]]; then
        rm -f "${join_tmp}"
        hm_err "WERYFIKACJA NIEUDANA: SHA256 sklejonych chunków ≠ (joined) w SHA256SUMS."
        return 1
      fi
    else
      rm -f "${join_tmp}"
      hm_err "WERYFIKACJA NIEUDANA: brak sha256_files / (joined) dla trybu chunków!"
      return 1
    fi
    rm -f "${join_tmp}"
  else
    hm_err "WERYFIKACJA NIEUDANA: nieznany tryb archiwum plików (${files_mode})!"
    return 1
  fi

  local db sz dump_path dump_want
  for db in "${dbs[@]}"; do
    [[ -n "${db}" ]] || continue
    dump_path="${remote_base}/db/${db}.sql.gz"
    if [[ "${remote_base}" == /* ]]; then
      sz="$(stat -c%s "${dump_path}" 2>/dev/null || echo 0)"
    else
      sz="$(rclone size "${dump_path}" --json 2>/dev/null | sed -n 's/.*"bytes"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)"
    fi
    if [[ -z "${sz}" || ! "${sz}" =~ ^[0-9]+$ || "${sz}" -le 20 ]]; then
      hm_err "WERYFIKACJA NIEUDANA: zrzut bazy db/${db}.sql.gz nie istnieje lub jest pusty (${sz:-0} B)!"
      return 1
    fi
    if ! hm_backup_gzip_tar_ok "${dump_path}" 0; then
      hm_err "WERYFIKACJA NIEUDANA: db/${db}.sql.gz uszkodzony (gzip -t)!"
      return 1
    fi
    dump_want="$(printf '%s' "${man}" | sed -n "s/.*\"sha256_db_${db}\"[[:space:]]*:[[:space:]]*\"\\([0-9a-fA-F]\\{64\\}\\)\".*/\\1/p" | head -1)"
    if [[ -n "${dump_want}" ]]; then
      got="$(hm_rclone_sha256_any "${dump_path}" || true)"
      if [[ -z "${got}" || "${got}" != "${dump_want}" ]]; then
        hm_err "WERYFIKACJA NIEUDANA: SHA256 db/${db}.sql.gz niezgodny."
        return 1
      fi
    fi
  done

  # Artefakty poboczne (vhost/pula/meta/konta) — bez tego restore kończy się 404/502
  if ! hm_backup_verify_side_artifacts "${remote_base}"; then
    return 1
  fi

  hm_ok "Weryfikacja kopii zakończona sukcesem (rozmiar + SHA256 + gzip/tar)."
  return 0
}

# SHA256SUMS: dopisz/aktualizuj linię dla pliku na remote (po uploadzie).
# $1=remote_base $2=relative_name $3=sha256hex
hm_archive_sha256sums_put() {
  local remote_base="$1" name="$2" sum="$3"
  local sums_tmp blob line
  [[ -n "${name}" && "${sum}" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
  sums_tmp="$(hm_mktemp .sums)"
  blob=""
  if [[ "${remote_base}" == /* && -f "${remote_base}/SHA256SUMS" ]]; then
    blob="$(cat "${remote_base}/SHA256SUMS" 2>/dev/null || true)"
  elif [[ "${remote_base}" != /* ]]; then
    blob="$(rclone cat "${remote_base}/SHA256SUMS" 2>/dev/null || true)"
  fi
  {
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ -n "${line}" ]] || continue
      # pomiń starą linię dla tej samej nazwy ($2); zachowaj "(joined)"
      [[ "${line}" == *" (joined)"* ]] && { printf '%s\n' "${line}"; continue; }
      if [[ "$(printf '%s' "${line}" | awk '{print $2}')" == "${name}" ]]; then
        continue
      fi
      printf '%s\n' "${line}"
    done <<< "${blob}"
    printf '%s  %s\n' "${sum}" "${name}"
  } > "${sums_tmp}"
  if [[ "${remote_base}" == /* ]]; then
    mkdir -p "${remote_base}"
    cp -f "${sums_tmp}" "${remote_base}/SHA256SUMS" || { rm -f "${sums_tmp}"; return 1; }
  else
    hm_rclone_copyto "${sums_tmp}" "${remote_base}/SHA256SUMS" \
      || cat "${sums_tmp}" | hm_rclone_rcat "${remote_base}/SHA256SUMS" \
      || { rm -f "${sums_tmp}"; return 1; }
  fi
  rm -f "${sums_tmp}"
  return 0
}

# Po uploadzie lokalnego pliku: SHA256 + wpis w SHA256SUMS.
hm_archive_register_uploaded_file() {
  local local_file="$1" remote_base="$2" remote_name="$3"
  local sum
  [[ -f "${local_file}" && -n "${remote_name}" ]] || return 1
  sum="$(hm_backup_sha256_file "${local_file}" || true)"
  [[ -n "${sum}" ]] || return 1
  hm_archive_sha256sums_put "${remote_base}" "${remote_name}" "${sum}" || return 1
  printf '%s' "${sum}"
}

# Szukaj SHA w blobie SHA256SUMS (stdout=hex; rc=1 gdy brak).
# $1=blob $2=nazwa pliku
hm_backup_sums_lookup_in_blob() {
  local blob="$1" needle="$2" line s p
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    [[ "${line}" == *" (joined)"* ]] && continue
    s="$(printf '%s' "${line}" | awk '{print $1}')"
    p="$(printf '%s' "${line}" | awk '{print $2}')"
    [[ "${p}" == "${needle}" && "${s}" =~ ^[0-9a-fA-F]{64}$ ]] || continue
    printf '%s' "${s}"
    return 0
  done <<< "${blob}"
  return 1
}

# Weryfikuj webserver/php-fpm/meta/*.sql/meta kont — gzip+SHA gdy istnieją na remote.
hm_backup_verify_side_artifacts() {
  local remote_base="$1"
  local sums_blob="" want got f
  local -a side_tars=(webserver.tar.gz php-fpm.tar.gz meta.tar.gz ssl.tar.gz ols-vhost-dir.tar.gz)
  local -a side_plain=(
    db-accounts.sql db-accounts.sql.enc
    unix-account.meta unix-account.meta.enc
    crontab.txt unix-authorized_keys
  )

  if [[ "${remote_base}" == /* && -f "${remote_base}/SHA256SUMS" ]]; then
    sums_blob="$(cat "${remote_base}/SHA256SUMS" 2>/dev/null || true)"
  elif [[ "${remote_base}" != /* ]]; then
    sums_blob="$(rclone cat "${remote_base}/SHA256SUMS" 2>/dev/null || true)"
  fi

  for f in "${side_tars[@]}"; do
    hm_rclone_file_nonempty "${remote_base}/${f}" 2>/dev/null || continue
    if ! hm_backup_gzip_tar_ok "${remote_base}/${f}" 1; then
      hm_err "WERYFIKACJA NIEUDANA: ${f} uszkodzony (gzip/tar)!"
      return 1
    fi
    want="$(hm_backup_sums_lookup_in_blob "${sums_blob}" "${f}" || true)"
    if [[ -z "${want}" ]]; then
      hm_err "WERYFIKACJA NIEUDANA: brak SHA256 dla ${f} w SHA256SUMS!"
      return 1
    fi
    got="$(hm_rclone_sha256_any "${remote_base}/${f}" || true)"
    if [[ -z "${got}" || "${got}" != "${want}" ]]; then
      hm_err "WERYFIKACJA NIEUDANA: SHA256 ${f} niezgodny."
      return 1
    fi
  done

  for f in "${side_plain[@]}"; do
    hm_rclone_file_nonempty "${remote_base}/${f}" 2>/dev/null || continue
    want="$(hm_backup_sums_lookup_in_blob "${sums_blob}" "${f}" || true)"
    if [[ -z "${want}" ]]; then
      hm_err "WERYFIKACJA NIEUDANA: brak SHA256 dla ${f} w SHA256SUMS!"
      return 1
    fi
    got="$(hm_rclone_sha256_any "${remote_base}/${f}" || true)"
    if [[ -z "${got}" || "${got}" != "${want}" ]]; then
      hm_err "WERYFIKACJA NIEUDANA: SHA256 ${f} niezgodny."
      return 1
    fi
  done
  return 0
}

hm_archive_upload_site_files() {
  # stdout: files_mode<TAB>chunks_count; ustawia HM_BACKUP_LAST_SHA256 (+ SUMS)
  local src_dir="$1"
  local remote_base="$2"
  local size_b threshold_b sums_tmp
  size_b="$(hm_dir_size_bytes "${src_dir}")"
  threshold_b=$((CHUNK_THRESHOLD_MB * 1024 * 1024))
  HM_BACKUP_LAST_SHA256=""
  HM_BACKUP_LAST_SHA256SUMS=""

  if [[ "${size_b}" -ge "${threshold_b}" ]]; then
    # hm_info/hm_ok idą na stdout — przekieruj, żeby report=$((...)) dostał tylko printf
    # archive = pełny dump (ARCHIVE_EXCLUDES, domyślnie puste) — potem kasujemy VPS
    hm_chunked_tar_upload "${src_dir}" "${remote_base}/files.chunks" "archive" >&2 || return 1
    local marker n
    if [[ "${remote_base}" == /* ]]; then
      marker="$(cat "${remote_base}/files.chunks/files.tar.gz.chunks.txt" 2>/dev/null || true)"
    else
      marker="$(rclone cat "${remote_base}/files.chunks/files.tar.gz.chunks.txt" 2>/dev/null || true)"
    fi
    [[ -n "${marker}" ]] || { hm_err "Brak markera chunków po uploadzie."; return 1; }
    n="$(printf '%s' "${marker}" | sed -n 's/^chunks=//p' | tr -d '[:space:]')"
    if [[ -z "${n}" || ! "${n}" =~ ^[0-9]+$ ]]; then
      hm_err "Niepoprawny marker chunków: ${marker}"
      return 1
    fi
    if [[ -n "${HM_BACKUP_LAST_SHA256SUMS:-}" ]]; then
      sums_tmp="$(hm_mktemp .sums)"
      printf '%s' "${HM_BACKUP_LAST_SHA256SUMS}" > "${sums_tmp}"
      if [[ -n "${HM_BACKUP_LAST_SHA256:-}" ]]; then
        printf '%s  files.tar.gz (joined)\n' "${HM_BACKUP_LAST_SHA256}" >> "${sums_tmp}"
      fi
      hm_rclone_copyto "${sums_tmp}" "${remote_base}/SHA256SUMS" \
        || cat "${sums_tmp}" | hm_rclone_rcat "${remote_base}/SHA256SUMS" \
        || { rm -f "${sums_tmp}"; hm_err "Upload SHA256SUMS nieudany."; return 1; }
      rm -f "${sums_tmp}"
    fi
    # 3. pole: sha256 (command substitution gubi zmienne eksportowane w funkcji)
    printf 'chunks\t%s\t%s\n' "${n}" "${HM_BACKUP_LAST_SHA256:-}"
  else
    hm_stream_tar_rcat "${src_dir}" "${remote_base}/files.tar.gz" "archive" >&2 || return 1
    [[ -n "${HM_BACKUP_LAST_SHA256:-}" ]] || {
      hm_err "Brak SHA256 po stream uploadzie files.tar.gz."
      return 1
    }
    sums_tmp="$(hm_mktemp .sums)"
    printf '%s  files.tar.gz\n' "${HM_BACKUP_LAST_SHA256}" > "${sums_tmp}"
    hm_rclone_copyto "${sums_tmp}" "${remote_base}/SHA256SUMS" \
      || cat "${sums_tmp}" | hm_rclone_rcat "${remote_base}/SHA256SUMS" \
      || { rm -f "${sums_tmp}"; hm_err "Upload SHA256SUMS nieudany."; return 1; }
    rm -f "${sums_tmp}"
    printf 'tar\t0\t%s\n' "${HM_BACKUP_LAST_SHA256}"
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

# Ścieżki vhost (nginx/apache) z resources.ndjson + fallback hm_site_web_conf_path.
hm_archive_collect_web_paths() {
  local domain="$1" web="${2:-}" res line path
  [[ -n "${domain}" ]] || return 0
  if declare -F hm_site_resources_path >/dev/null 2>&1; then
    res="$(hm_site_resources_path "${domain}" 2>/dev/null || true)"
    if [[ -n "${res}" && -f "${res}" && ! -L "${res}" ]]; then
      while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ -n "${line}" ]] || continue
        if declare -F hm_site_resource_read >/dev/null 2>&1; then
          hm_site_resource_read "${line}" || continue
          [[ "${HM_SITE_RES_KIND}" == "vhost" ]] || continue
          path="${HM_SITE_RES_PATH}"
        else
          continue
        fi
        [[ -n "${path}" && -e "${path}" ]] || continue
        printf '%s\n' "${path}"
      done < "${res}"
    fi
  fi
  [[ -n "${web}" ]] || web="${HM_DEL_WEB:-${HM_SITE_WEBSERVER:-${WEBSERVER:-}}}"
  case "${web}" in
    nginx|apache|apache2|httpd)
      [[ "${web}" == "apache2" || "${web}" == "httpd" ]] && web="apache"
      if declare -F hm_site_web_conf_path >/dev/null 2>&1; then
        path="$(hm_site_web_conf_path "${web}" "${domain}" 2>/dev/null || true)"
        if [[ -n "${path}" && -e "${path}" ]]; then
          printf '%s\n' "${path}"
        fi
      fi
      ;;
  esac
}

# Pule php-fpm z resources + pool.d/<domain>.conf.
hm_archive_collect_fpm_paths() {
  local domain="$1" ver="${2:-}" res line path dir
  [[ -n "${domain}" ]] || return 0
  if declare -F hm_site_resources_path >/dev/null 2>&1; then
    res="$(hm_site_resources_path "${domain}" 2>/dev/null || true)"
    if [[ -n "${res}" && -f "${res}" && ! -L "${res}" ]]; then
      while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ -n "${line}" ]] || continue
        if declare -F hm_site_resource_read >/dev/null 2>&1; then
          hm_site_resource_read "${line}" || continue
          [[ "${HM_SITE_RES_KIND}" == "fpm" ]] || continue
          path="${HM_SITE_RES_PATH}"
        else
          continue
        fi
        [[ -n "${path}" && -f "${path}" ]] || continue
        printf '%s\n' "${path}"
      done < "${res}"
    fi
  fi
  [[ -n "${ver}" ]] || ver="${HM_SITE_PHP:-}"
  if [[ -n "${ver}" ]] && declare -F hm_pkg_php_pool_dir >/dev/null 2>&1; then
    dir="$(hm_pkg_php_pool_dir "${ver}" 2>/dev/null || true)"
    if [[ -n "${dir}" && -f "${dir}/${domain}.conf" ]]; then
      printf '%s\n' "${dir}/${domain}.conf"
    fi
  fi
  # Heurystyka Debian bez znanej wersji
  shopt -s nullglob
  for path in /etc/php/*/fpm/pool.d/"${domain}".conf; do
    [[ -f "${path}" ]] && printf '%s\n' "${path}"
  done
  shopt -u nullglob
}

# Spakuj ścieżki absolutne do tar.gz (ścieżki względne od /).
hm_archive_tar_abs_paths() {
  local out_tar="$1"
  shift
  local -a rels=()
  local p seen="|"
  [[ "$#" -gt 0 ]] || return 1
  for p in "$@"; do
    [[ -n "${p}" && "${p}" == /* && -e "${p}" ]] || continue
    [[ "${seen}" == *"|${p}|"* ]] && continue
    seen="${seen}${p}|"
    rels+=("${p#/}")
  done
  [[ "${#rels[@]}" -gt 0 ]] || return 1
  tar -C / -czf "${out_tar}" "${rels[@]}" 2>/dev/null
}

# Meta kreatora: .json / .dbs / resources.ndjson (+ logrotate z resources).
hm_archive_pack_site_meta() {
  local domain="$1" out_tar="$2" dir man dbs res lr
  local -a files=()
  if declare -F hm_site_manifest_dir >/dev/null 2>&1; then
    dir="$(hm_site_manifest_dir)"
  else
    dir="${HM_SITE_MANIFEST_DIR:-/etc/hmtools/sites}"
  fi
  man="${dir}/${domain}.json"
  dbs="${dir}/.${domain}.dbs"
  res="${dir}/${domain}.resources.ndjson"
  [[ -f "${man}" && ! -L "${man}" ]] && files+=("${man}")
  [[ -f "${dbs}" && ! -L "${dbs}" ]] && files+=("${dbs}")
  [[ -f "${res}" && ! -L "${res}" ]] && files+=("${res}")
  if [[ -f "${res}" && ! -L "${res}" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      hm_site_resource_read "${line}" 2>/dev/null || continue
      [[ "${HM_SITE_RES_KIND}" == "logrotate" ]] || continue
      lr="${HM_SITE_RES_PATH}"
      [[ -n "${lr}" && -f "${lr}" && ! -L "${lr}" ]] && files+=("${lr}")
    done < "${res}"
  fi
  [[ "${#files[@]}" -gt 0 ]] || return 1
  hm_archive_tar_abs_paths "${out_tar}" "${files[@]}"
}

# Upload webserver.tar.gz + php-fpm.tar.gz + meta.tar.gz (nginx/apache; OLS ma osobną ścieżkę).
hm_archive_upload_webstack() {
  local domain="$1" remote_base="$2"
  local web="${HM_DEL_WEB:-${HM_SITE_WEBSERVER:-${WEBSERVER:-}}}"
  local tarf path
  local -a webs=() fpms=()
  local seen="|"

  case "${web}" in
    ols|openlitespeed|litespeed) return 0 ;;
  esac

  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    [[ "${seen}" == *"|${path}|"* ]] && continue
    seen="${seen}${path}|"
    webs+=("${path}")
  done < <(hm_archive_collect_web_paths "${domain}" "${web}" | sort -u)

  seen="|"
  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    [[ "${seen}" == *"|${path}|"* ]] && continue
    seen="${seen}${path}|"
    fpms+=("${path}")
  done < <(hm_archive_collect_fpm_paths "${domain}" "${HM_SITE_PHP:-}" | sort -u)

  if [[ "${#webs[@]}" -gt 0 ]]; then
    tarf="$(hm_mktemp .tar.gz)"
    if hm_archive_tar_abs_paths "${tarf}" "${webs[@]}"; then
      hm_rclone_copyto "${tarf}" "${remote_base}/webserver.tar.gz" || {
        rm -f "${tarf}"
        hm_archive_abort "Upload webserver.tar.gz nieudany. Nic nie usunięto z VPS." "${remote_base}"
        return 1
      }
      hm_archive_register_uploaded_file "${tarf}" "${remote_base}" "webserver.tar.gz" >/dev/null \
        || hm_warn "Nie zapisano SHA256 webserver.tar.gz w SHA256SUMS."
      hm_ok "Zarchiwizowano vhost (${#webs[@]} plik(ów))."
    else
      hm_warn "Nie spakowano vhostów nginx/apache."
    fi
    rm -f "${tarf}"
  else
    case "${web}" in
      nginx|apache|apache2|httpd)
        hm_warn "Brak plików vhost ${web} dla ${domain} — archive bez webserver.tar.gz."
        ;;
    esac
  fi

  if [[ "${#fpms[@]}" -gt 0 ]]; then
    tarf="$(hm_mktemp .tar.gz)"
    if hm_archive_tar_abs_paths "${tarf}" "${fpms[@]}"; then
      hm_rclone_copyto "${tarf}" "${remote_base}/php-fpm.tar.gz" || {
        rm -f "${tarf}"
        hm_archive_abort "Upload php-fpm.tar.gz nieudany. Nic nie usunięto z VPS." "${remote_base}"
        return 1
      }
      hm_archive_register_uploaded_file "${tarf}" "${remote_base}" "php-fpm.tar.gz" >/dev/null \
        || hm_warn "Nie zapisano SHA256 php-fpm.tar.gz w SHA256SUMS."
      hm_ok "Zarchiwizowano php-fpm (${#fpms[@]} plik(ów))."
    fi
    rm -f "${tarf}"
  fi

  tarf="$(hm_mktemp .tar.gz)"
  if hm_archive_pack_site_meta "${domain}" "${tarf}"; then
    hm_rclone_copyto "${tarf}" "${remote_base}/meta.tar.gz" || {
      rm -f "${tarf}"
      hm_archive_abort "Upload meta.tar.gz nieudany. Nic nie usunięto z VPS." "${remote_base}"
      return 1
    }
    hm_archive_register_uploaded_file "${tarf}" "${remote_base}" "meta.tar.gz" >/dev/null \
      || hm_warn "Nie zapisano SHA256 meta.tar.gz w SHA256SUMS."
    hm_ok "Zarchiwizowano meta kreatora (manifest/.dbs/resources)."
  fi
  rm -f "${tarf}"
  return 0
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

# Usuń kolumnę `id` z INSERT … (`id`, …) VALUES (N, …)[, (M, …)] — uniknij kolizji PK.
# Obsługuje extended-insert (wiele krotek w jednym VALUES).
hm_archive_cp_sql_strip_explicit_ids() {
  local f="$1"
  local tmp
  [[ -f "${f}" ]] || return 1
  tmp="$(mktemp "${TMP_DIR:-/tmp}/hmtools-cp-noid.XXXXXX.sql")"
  awk '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    function split_csv(s, a,    n, i, q, ch, cur) {
      n = 0; cur = ""; q = 0
      for (i = 1; i <= length(s); i++) {
        ch = substr(s, i, 1)
        if (ch == "'\''") { q = 1 - q; cur = cur ch; continue }
        if (ch == "," && q == 0) { a[++n] = trim(cur); cur = ""; continue }
        cur = cur ch
      }
      a[++n] = trim(cur)
      return n
    }
    function strip_tuple(t,    n, a, i, out) {
      # t bez otaczających nawiasów
      n = split_csv(t, a)
      if (n < 1) return "(" t ")"
      out = ""
      for (i = 2; i <= n; i++) {
        if (out != "") out = out ", "
        out = out a[i]
      }
      return "(" out ")"
    }
    /^INSERT INTO/ {
      line = $0
      vi = index(line, ") VALUES (")
      vlen = 10
      if (vi == 0) { vi = index(line, ") VALUES("); vlen = 9 }
      if (vi == 0) { print; next }
      head = substr(line, 1, vi - 1)
      oi = 0
      for (i = 1; i <= length(head); i++) if (substr(head, i, 1) == "(") oi = i
      if (oi == 0) { print; next }
      prefix = substr(head, 1, oi - 1)
      colpart = substr(head, oi + 1)
      ncol = split_csv(colpart, cols)
      c0 = cols[1]; gsub(/`/, "", c0); c0 = trim(c0)
      if (c0 != "id") { print; next }
      # nowe kolumny bez id
      ncolstr = ""
      for (i = 2; i <= ncol; i++) {
        if (ncolstr != "") ncolstr = ncolstr ", "
        ncolstr = ncolstr cols[i]
      }
      # match ") VALUES (" zjada otwarcie 1. krotki — doklej "(" z powrotem
      rest = "(" substr(line, vi + vlen)
      # rest = (tup1),(tup2);
      semi = 0
      if (substr(rest, length(rest), 1) == ";") { semi = 1; rest = substr(rest, 1, length(rest) - 1) }
      # rozbij krotki na poziomie nawiasów
      depth = 0; q = 0; cur = ""; ntu = 0
      for (i = 1; i <= length(rest); i++) {
        ch = substr(rest, i, 1)
        if (ch == "'\''") { q = 1 - q; cur = cur ch; continue }
        if (q) { cur = cur ch; continue }
        if (ch == "(") {
          if (depth == 0) { cur = ""; depth = 1; continue }
          depth++; cur = cur ch; continue
        }
        if (ch == ")") {
          depth--
          if (depth == 0) { tuples[++ntu] = cur; cur = ""; continue }
          cur = cur ch; continue
        }
        if (depth > 0) cur = cur ch
      }
      outv = ""
      for (i = 1; i <= ntu; i++) {
        if (outv != "") outv = outv ", "
        outv = outv strip_tuple(tuples[i])
      }
      printf "%s(%s) VALUES %s%s\n", prefix, ncolstr, outv, (semi ? ";" : "")
      next
    }
    { print }
  ' "${f}" > "${tmp}" || { rm -f "${tmp}"; return 1; }
  mv -f "${tmp}" "${f}"
}

# Eksport wierszy CyberPanel (website + childdomains + databases) do SQL INSERT.
# Bez jawnego id (strip po dumpie) — restore nie koliduje z istniejącymi PK.
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
    echo "-- hmtools archive: CyberPanel rows for ${domain} (source id=${id}; id stripped for restore)"
    echo "USE \`cyberpanel\`;"
    # --skip-extended-insert / --skip-add-locks: jedna krotka / INSERT; bez LOCK TABLES
    # (LOCK zatwierdzałby transakcję restore → sieroty przy błędzie importu).
    "${dumpcli}" "${sock[@]}" cyberpanel websiteFunctions_websites \
      --where="id=${id}" --no-create-info --complete-insert --skip-extended-insert \
      --skip-lock-tables --skip-add-locks --skip-comments 2>/dev/null || true
    "${dumpcli}" "${sock[@]}" cyberpanel websiteFunctions_childdomains \
      --where="master_id=${id}" --no-create-info --complete-insert --skip-extended-insert \
      --skip-lock-tables --skip-add-locks --skip-comments 2>/dev/null || true
    "${dumpcli}" "${sock[@]}" cyberpanel databases_databases \
      --where="website_id=${id}" --no-create-info --complete-insert --skip-extended-insert \
      --skip-lock-tables --skip-add-locks --skip-comments 2>/dev/null || true
  } > "${out_sql}"
  [[ -s "${out_sql}" ]] || return 1
  hm_archive_cp_sql_strip_explicit_ids "${out_sql}" || true
  # Stare snapshoty / mysqldump bez skip-add-locks
  if grep -qE '^(LOCK TABLES|UNLOCK TABLES)' "${out_sql}" 2>/dev/null; then
    grep -Ev '^(LOCK TABLES|UNLOCK TABLES)' "${out_sql}" > "${out_sql}.nolock" \
      && mv -f "${out_sql}.nolock" "${out_sql}"
  fi
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
      printf -- '-- HM_DROP_IF_MISSING %s@%s\n' "${u}" "${host}" >> "${out_sql}"
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
  shift || true
  local force_nested=0 a
  for a in "$@"; do
    case "${a}" in
      --force-nested) force_nested=1 ;;
      -*)
        hm_err "Nieznana flaga: ${a}"
        return 1
        ;;
      *)
        if [[ -z "${domain}" ]]; then
          domain="${a}"
        else
          hm_err "Za dużo argumentów: ${a}"
          return 1
        fi
        ;;
    esac
  done
  [[ -n "${domain}" ]] || {
    hm_err "Użycie: webs archive <domena> [--force-nested]  /  backup archive <domena>  /  archive (w kontekście)"
    return 1
  }

  hm_load_config
  hm_detect_all
  if ! hm_rclone_root_is_local; then
    hm_rclone_check || return 1
  fi
  hm_backup_check_space / || return 1
  hm_backup_acquire_lock || return 1
  trap 'hm_backup_release_lock' RETURN

  # zachowaj oryginalny arg — nieudane `domain="$(…exact…)"` zeruje zmienną (bash)
  local domain_arg="${domain}"
  domain="$(hm_find_site_by_arg_exact "${domain_arg}" 2>/dev/null)" || {
    # exact fail — spróbuj z potwierdzeniem partial (TTY) albo jasny błąd
    domain="$(hm_find_site_by_arg "${domain_arg}")" || return 1
  }

  hm_status_line "Inwentaryzacja ${domain}…"
  if ! hm_site_collect_delete_inventory "${domain}" 0 0 0 "${force_nested}"; then
    hm_status_clear
    return 1
  fi
  hm_status_clear
  hm_set_site_context "${domain}"

  local stamp remote_base
  hm_backup_claim_stamp archive "${domain}" || return 1
  stamp="${HM_BACKUP_STAMP}"
  remote_base="${HM_BACKUP_REMOTE_BASE}"
  hm_rclone_mkdir "$(hm_rclone_dest "${domain}")" 2>/dev/null || true
  hm_rclone_mkdir "${remote_base}" 2>/dev/null || true
  hm_backup_mark_owned_remote "${remote_base}"

  local -a archive_dbs=()
  local -a archive_db_users=()
  local -a archive_dbs_from_config=()
  local dline dname dorigin dreason seen_adb="|" seen_cfg="|" seen_adu="|"
  for dline in "${HM_DEL_DBS[@]}"; do
    [[ -n "${dline}" ]] || continue
    IFS='|' read -r dname _ <<<"${dline}"
    if [[ -n "${dname}" && "${seen_adb}" != *"|${dname}|"* ]]; then
      archive_dbs+=("${dname}")
      seen_adb="${seen_adb}${dname}|"
    fi
  done
  # Manifest kreatora (.{domena}.dbs) — zawsze dump + user; Faza II i tak robi DROP z .dbs
  local _mdb_typ _mdb_name _mdb_user _mdb_dir _mdb_file
  if declare -F hm_site_manifest_dir >/dev/null 2>&1; then
    _mdb_dir="$(hm_site_manifest_dir)"
  else
    _mdb_dir="${HM_SITE_MANIFEST_DIR:-/etc/hmtools/sites}"
  fi
  _mdb_file="${_mdb_dir}/.${domain}.dbs"
  if [[ -f "${_mdb_file}" && ! -L "${_mdb_file}" ]]; then
    while IFS=$'\t' read -r _mdb_typ _mdb_name _mdb_user _ || [[ -n "${_mdb_typ:-}" ]]; do
      [[ -n "${_mdb_name}" ]] || continue
      case "${_mdb_typ}" in
        postgres|postgresql|pg)
          hm_err "Manifest zawiera bazę PostgreSQL (${_mdb_name}) — archive nie ma jeszcze pg_dump."
          hm_err "Odmowa archiwizacji (uniknięcie DROP bez kopii). Usuń PG z .dbs albo dodaj wsparcie dump."
          return 1
          ;;
        mysql|mariadb|"")
          hm_is_valid_db_name "${_mdb_name}" || continue
          if [[ "${seen_adb}" != *"|${_mdb_name}|"* ]]; then
            archive_dbs+=("${_mdb_name}")
            seen_adb="${seen_adb}${_mdb_name}|"
            hm_info "Archive dump DB ${_mdb_name} (manifest .dbs — confirmed)."
          fi
          if [[ -n "${_mdb_user}" && "${seen_adu}" != *"|${_mdb_user}|"* ]]; then
            hm_is_valid_db_name "${_mdb_user}" || continue
            archive_db_users+=("${_mdb_user}")
            seen_adu="${seen_adu}${_mdb_user}|"
          fi
          ;;
      esac
    done < "${_mdb_file}"
  fi
  # Child: DB z wp-config childa bywa w CP pod masterem → HM_DEL_SKIP (współdzielona).
  # Dump TYLKO z configu DOCROOT childa — nie confirmed/user-match baz mastera (utrata danych przy restore --overwrite-db).
  if [[ "${HM_DEL_CHILD_OF_SHARED:-0}" -eq 1 ]]; then
    local child_doc="${HM_DEL_DOCROOT:-${HM_DEL_ROOT}}" hname horigin
    if [[ -n "${child_doc}" && -d "${child_doc}" ]]; then
      while IFS=$'\t' read -r hname horigin; do
        [[ -n "${hname}" ]] || continue
        case "${horigin}" in
          wp-config|.env|.env-url|configuration.php) ;;
          *) continue ;;
        esac
        hm_is_valid_db_name "${hname}" || continue
        if [[ "${seen_cfg}" != *"|${hname}|"* ]]; then
          archive_dbs_from_config+=("${hname}")
          seen_cfg="${seen_cfg}${hname}|"
        fi
        [[ "${seen_adb}" == *"|${hname}|"* ]] && continue
        archive_dbs+=("${hname}")
        seen_adb="${seen_adb}${hname}|"
        hm_info "Archive dump DB ${hname} (child docroot, origin=${horigin}; w CP może być pod masterem — delete nadal nie dropuje)."
      done < <(
        {
          hm_extract_db_from_file "${child_doc}/wp-config.php" wp
          hm_extract_db_from_file "${child_doc}/.env" env
          hm_extract_db_from_file "${child_doc}/configuration.php" joomla
          local _sub
          for _sub in app backend api server src public private; do
            hm_extract_db_from_file "${child_doc}/${_sub}/.env" env
            hm_extract_db_from_file "${child_doc}/${_sub}/wp-config.php" wp
          done
        } | awk -F'\t' 'NF && !seen[$1]++ { print $1 "\t" $2 }'
      )
    fi
  fi
  # TYLKO konta exclusive (HM_DEL_DB_USERS) — współdzielonych NIE eksportujemy (DROP psułby inne serwisy)
  local _du
  for _du in "${HM_DEL_DB_USERS[@]}"; do
    [[ -n "${_du}" ]] || continue
    hm_is_valid_db_name "${_du}" || continue
    [[ "${seen_adu}" == *"|${_du}|"* ]] && continue
    archive_db_users+=("${_du}")
    seen_adu="${seen_adu}${_du}|"
  done

  local db_desc="brak"
  if [[ "${#archive_dbs[@]}" -gt 0 ]]; then
    db_desc="${#archive_dbs[@]} baza/baz: $(IFS=', '; echo "${archive_dbs[*]}")"
  fi
  local dbu_desc="brak"
  if [[ "${#archive_db_users[@]}" -gt 0 ]]; then
    dbu_desc="$(IFS=', '; echo "${archive_db_users[*]}")"
  fi
  local unix_desc="brak"
  # Współdzielony/chroniony Unix — NIE eksportujemy (restore nadpisałby cudze konto)
  if [[ -n "${HM_DEL_USER}" ]] && id "${HM_DEL_USER}" >/dev/null 2>&1 \
      && [[ "${HM_DEL_USER_SHARED:-0}" -eq 0 && "${HM_DEL_USER_PROTECTED:-0}" -eq 0 ]]; then
    unix_desc="${HM_DEL_USER} (uid/gid/shadow/SSH keys)"
  elif [[ -n "${HM_DEL_USER}" && ( "${HM_DEL_USER_SHARED:-0}" -eq 1 || "${HM_DEL_USER_PROTECTED:-0}" -eq 1 ) ]]; then
    unix_desc="pominięty (${HM_DEL_USER} współdzielony/chroniony)"
  fi

  # Child/shared: TYLKO docroot (nie cały HOME mastera). Exclusive: pełny HOME gdy obejmuje site.
  local archive_files_root archive_files_size
  if [[ "${HM_DEL_CHILD_OF_SHARED:-0}" -eq 1 || "${HM_DEL_USER_SHARED:-0}" -eq 1 ]]; then
    archive_files_root="${HM_DEL_ROOT:-${HM_DEL_DOCROOT}}"
    hm_info "Archiwum child/shared — pakuję wyłącznie ${archive_files_root} (bez HOME mastera)."
  else
    archive_files_root="$(hm_backup_resolve_files_root "${HM_DEL_ROOT:-${HM_DEL_DOCROOT}}" "${HM_DEL_USER}")"
    if [[ -n "${archive_files_root}" && -n "${HM_DEL_DOCROOT}" ]]; then
      archive_files_root="$(hm_backup_prefer_docroot_if_shared_home "${domain}" "${archive_files_root}" "${HM_DEL_DOCROOT}")"
    fi
  fi
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
    "[WERYFIKACJA] Twarda kontrola integralności (SHA256 + gzip/tar; chunki po sklejeniu)"
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
    return 1
  fi

  # --- Faza I: backup ---
  hm_info "Faza I — backup archiwalny → ${remote_base}"
  hm_rclone_ensure_backup_layout
  hm_rclone_mkdir "$(hm_rclone_dest "${domain}")"
  hm_rclone_mkdir "${remote_base}"
  hm_rclone_mkdir "${remote_base}/db"

  hm_ensure_secure_tmpdir
  local name
  for name in "${archive_dbs[@]}"; do
    [[ -n "${name}" ]] || continue
    if ! hm_stream_mysqldump "${name}" "${remote_base}/db/${name}.sql.gz"; then
      hm_archive_abort "Archiwizacja przerwana — błąd zrzutu/uploadu bazy ${name}. Nic nie usunięto z VPS." "${remote_base}"
      return 1
    fi
  done

  # Konta MySQL (hasła jako hash + GRANTS) — wymagane do restore 1:1
  # SHA w SUMS dopiero po uploadzie plików (ten nadpisuje SHA256SUMS).
  local has_db_accounts=0
  local db_acc_sha="" unix_meta_sha="" unix_keys_sha=""
  local remote_db="" remote_ux=""
  local db_acc_sql
  db_acc_sql="$(hm_mktemp .sql)"
  if [[ "${#archive_db_users[@]}" -gt 0 ]]; then
    if hm_archive_export_mysql_accounts "${db_acc_sql}" --dbs "$(IFS=','; echo "${archive_dbs[*]}")" "${archive_db_users[@]}"; then
      local enc_db
      if ! enc_db="$(hm_backup_maybe_encrypt_file "${db_acc_sql}")"; then
        rm -f "${db_acc_sql}" "${db_acc_sql}.enc"
        hm_archive_abort "Szyfrowanie db-accounts nieudane — bez plaintext. Nic nie usunięto z VPS." "${remote_base}"
        return 1
      fi
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

  # Konto Unix + authorized_keys — tylko exclusive (nie shared/protected)
  local has_unix_account=0
  local unix_meta unix_keys
  unix_meta="$(hm_mktemp .meta)"
  unix_keys="$(hm_mktemp .keys)"
  if [[ -n "${HM_DEL_USER}" ]] && id "${HM_DEL_USER}" >/dev/null 2>&1 \
      && [[ "${HM_DEL_USER_SHARED:-0}" -eq 0 && "${HM_DEL_USER_PROTECTED:-0}" -eq 0 ]]; then
    if hm_archive_export_unix_account "${HM_DEL_USER}" "${unix_meta}" "${unix_keys}"; then
      local enc_ux
      if ! enc_ux="$(hm_backup_maybe_encrypt_file "${unix_meta}")"; then
        rm -f "${unix_meta}" "${unix_keys}" "${unix_meta}.enc"
        hm_archive_abort "Szyfrowanie unix-account.meta nieudane — bez plaintext. Nic nie usunięto z VPS." "${remote_base}"
        return 1
      fi
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
        unix_keys_sha="$(hm_backup_sha256_file "${unix_keys}" || true)"
        hm_rclone_copyto "${unix_keys}" "${remote_base}/unix-authorized_keys" \
          || cat "${unix_keys}" | hm_rclone_rcat "${remote_base}/unix-authorized_keys" \
          || {
            rm -f "${unix_meta}" "${unix_keys}" "${unix_meta}.enc"
            hm_archive_abort "Upload unix-authorized_keys nieudany. Nic nie usunięto z VPS." "${remote_base}"
            return 1
          }
      fi
    else
      hm_warn "Nie udało się zbudować snapshota konta Unix ${HM_DEL_USER}."
    fi
  elif [[ "${HM_DEL_USER_SHARED:-0}" -eq 1 || "${HM_DEL_USER_PROTECTED:-0}" -eq 1 ]]; then
    hm_info "Pomijam eksport konta Unix ${HM_DEL_USER:-?} (współdzielony/chroniony)."
  else
    hm_info "Brak konta Unix strony do eksportu."
  fi
  rm -f "${unix_meta}" "${unix_keys}" "${unix_meta}.enc" 2>/dev/null || true

  local backup_root="${archive_files_root}"
  if [[ -z "${backup_root}" || ! -d "${backup_root}" ]]; then
    if [[ "${HM_DEL_CHILD_OF_SHARED:-0}" -eq 1 || "${HM_DEL_USER_SHARED:-0}" -eq 1 ]]; then
      backup_root="${HM_DEL_ROOT:-${HM_DEL_DOCROOT}}"
    else
      backup_root="$(hm_backup_resolve_files_root "${HM_DEL_ROOT:-${HM_DEL_DOCROOT}}" "${HM_DEL_USER}")"
    fi
  fi
  if [[ -z "${backup_root}" || ! -d "${backup_root}" ]]; then
    backup_root="${HM_DEL_ROOT:-${HM_DEL_DOCROOT}}"
  fi
  if [[ -z "${backup_root}" || ! -d "${backup_root}" ]]; then
    hm_archive_abort "Brak katalogu strony do archiwizacji. Nic nie usunięto z VPS." "${remote_base}"
    return 1
  fi
  hm_info "Archiwizacja plików z katalogu: ${backup_root}"

  local files_mode="none" chunks_count=0 report files_sha256=""
  report="$(hm_archive_upload_site_files "${backup_root}" "${remote_base}")" || {
    hm_archive_abort "Archiwizacja przerwana — błąd wysyłki plików. Nic nie usunięto z VPS." "${remote_base}"
    return 1
  }
  # ostatnia linia = tryb (tar|chunks) + sha256; ignoruj śmieci na stdout
  IFS=$'\t' read -r files_mode chunks_count files_sha256 < <(printf '%s\n' "${report}" | tail -n 1)
  [[ -n "${chunks_count}" ]] || chunks_count=0
  [[ -n "${files_sha256}" ]] || files_sha256="${HM_BACKUP_LAST_SHA256:-}"
  case "${files_mode}" in
    tar|chunks) ;;
    *)
      hm_archive_abort "Nie udało się odczytać trybu archiwum plików (otrzymano: ${files_mode:-puste}). Nic nie usunięto z VPS." "${remote_base}"
      return 1
      ;;
  esac
  if [[ -z "${files_sha256}" ]]; then
    hm_archive_abort "Brak SHA256 plików po uploadzie — przerwano przed usunięciem z VPS." "${remote_base}"
    return 1
  fi
  HM_BACKUP_LAST_SHA256="${files_sha256}"
  export HM_BACKUP_LAST_SHA256

  # Dopisz SHA artefaktów wysłanych przed files (upload plików nadpisuje SHA256SUMS).
  if [[ "${has_db_accounts}" -eq 1 && -n "${db_acc_sha}" && -n "${remote_db}" ]]; then
    hm_archive_sha256sums_put "${remote_base}" "${remote_db}" "${db_acc_sha}" \
      || hm_warn "Nie zapisano SHA256 ${remote_db} w SHA256SUMS."
  fi
  if [[ "${has_unix_account}" -eq 1 && -n "${unix_meta_sha}" && -n "${remote_ux}" ]]; then
    hm_archive_sha256sums_put "${remote_base}" "${remote_ux}" "${unix_meta_sha}" \
      || hm_warn "Nie zapisano SHA256 ${remote_ux} w SHA256SUMS."
  fi
  if [[ -n "${unix_keys_sha}" ]]; then
    hm_archive_sha256sums_put "${remote_base}" "unix-authorized_keys" "${unix_keys_sha}" \
      || hm_warn "Nie zapisano SHA256 unix-authorized_keys w SHA256SUMS."
  fi

  # vhost + cały katalog OLS vhost
  if [[ -n "${HM_SITE_VHOST:-}" && -f "${HM_SITE_VHOST}" ]]; then
    hm_rclone_copyto "${HM_SITE_VHOST}" "${remote_base}/vhost.conf" 2>/dev/null \
      || cat "${HM_SITE_VHOST}" | hm_rclone_rcat "${remote_base}/vhost.conf" \
      || { hm_archive_abort "Nie udało się wysłać vhost.conf. Nic nie usunięto z VPS." "${remote_base}"; return 1; }
  fi
  if [[ -n "${HM_DEL_VHOST_DIR}" && -d "${HM_DEL_VHOST_DIR}" ]]; then
    local vtar
    vtar="$(hm_mktemp .tar.gz)"
    if tar -C "$(dirname "${HM_DEL_VHOST_DIR}")" -czf "${vtar}" "$(basename "${HM_DEL_VHOST_DIR}")" 2>/dev/null; then
      hm_rclone_copyto "${vtar}" "${remote_base}/ols-vhost-dir.tar.gz" || {
        rm -f "${vtar}"
        hm_archive_abort "Upload ols-vhost-dir.tar.gz nieudany. Nic nie usunięto z VPS." "${remote_base}"
        return 1
      }
      hm_archive_register_uploaded_file "${vtar}" "${remote_base}" "ols-vhost-dir.tar.gz" >/dev/null || true
      rm -f "${vtar}"
    else
      rm -f "${vtar}"
      hm_archive_abort "Nie spakowano katalogu vhost OLS. Nic nie usunięto z VPS." "${remote_base}"
      return 1
    fi
  fi
  local snip
  snip="$(hm_mktemp .conf)"
  hm_archive_write_ols_snippet "${domain}" "${snip}"
  if [[ -s "${snip}" ]]; then
    hm_rclone_copyto "${snip}" "${remote_base}/ols-httpd-snippet.conf" \
      || cat "${snip}" | hm_rclone_rcat "${remote_base}/ols-httpd-snippet.conf" \
      || {
        rm -f "${snip}"
        hm_archive_abort "Upload ols-httpd-snippet.conf nieudany. Nic nie usunięto z VPS." "${remote_base}"
        return 1
      }
    hm_archive_register_uploaded_file "${snip}" "${remote_base}" "ols-httpd-snippet.conf" >/dev/null || true
  fi
  rm -f "${snip}"

  # nginx/apache vhost + php-fpm + meta kreatora (OLS ma osobną ścieżkę powyżej)
  if ! hm_archive_upload_webstack "${domain}" "${remote_base}"; then
    return 1
  fi

  # SSL (symlinki live/ zachowane)
  local ssl_tar
  ssl_tar="$(hm_mktemp .tar.gz)"
  if hm_archive_pack_ssl "${domain}" "${ssl_tar}"; then
    hm_rclone_copyto "${ssl_tar}" "${remote_base}/ssl.tar.gz" || {
      rm -f "${ssl_tar}"
      hm_archive_abort "Upload ssl.tar.gz nieudany. Nic nie usunięto z VPS." "${remote_base}"
      return 1
    }
    hm_archive_register_uploaded_file "${ssl_tar}" "${remote_base}" "ssl.tar.gz" >/dev/null \
      || hm_warn "Nie zapisano SHA256 ssl.tar.gz w SHA256SUMS."
    rm -f "${ssl_tar}"
  else
    rm -f "${ssl_tar}"
    hm_info "Brak lokalnych certyfikatów SSL do spakowania."
  fi

  # crontab + pm2 (ścieżki wyłącznie z mktemp — bez przewidywalnych nazw)
  # shared/protected: NIE eksportuj crona mastera (restore childa nadpisywałby żywy crontab)
  if [[ -n "${HM_DEL_USER}" ]]; then
    if [[ "${HM_DEL_USER_SHARED:-0}" -eq 1 || "${HM_DEL_USER_PROTECTED:-0}" -eq 1 ]]; then
      hm_info "Pomijam eksport crontab ${HM_DEL_USER} (współdzielony/chroniony — cron należy do żywych domen)."
    else
      local cron_txt
      cron_txt="$(hm_mktemp .cron)"
      crontab -u "${HM_DEL_USER}" -l > "${cron_txt}" 2>/dev/null || true
      if [[ -s "${cron_txt}" ]]; then
        hm_rclone_copyto "${cron_txt}" "${remote_base}/crontab.txt" \
          || cat "${cron_txt}" | hm_rclone_rcat "${remote_base}/crontab.txt" \
          || {
            rm -f "${cron_txt}"
            hm_archive_abort "Upload crontab.txt nieudany. Nic nie usunięto z VPS." "${remote_base}"
            return 1
          }
        hm_archive_register_uploaded_file "${cron_txt}" "${remote_base}" "crontab.txt" >/dev/null \
          || hm_warn "Nie zapisano SHA256 crontab.txt w SHA256SUMS."
      fi
      rm -f "${cron_txt}"
    fi
  fi

  local pm2_json
  pm2_json="$(hm_mktemp .json)"
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
  if [[ -s "${pm2_json}" && "$(cat "${pm2_json}")" != "[]" ]]; then
    hm_rclone_copyto "${pm2_json}" "${remote_base}/pm2-processes.json" \
      || cat "${pm2_json}" | hm_rclone_rcat "${remote_base}/pm2-processes.json" \
      || {
        rm -f "${pm2_json}"
        hm_archive_abort "Upload pm2-processes.json nieudany. Nic nie usunięto z VPS." "${remote_base}"
        return 1
      }
  fi
  rm -f "${pm2_json}"

  # CyberPanel DB rows (website / childdomains / databases)
  local has_cp=0
  local cp_sql
  cp_sql="$(hm_mktemp .sql)"
  if hm_archive_export_cyberpanel_sql "${domain}" "${cp_sql}"; then
    if hm_rclone_copyto "${cp_sql}" "${remote_base}/cyberpanel-site.sql" \
      || cat "${cp_sql}" | hm_rclone_rcat "${remote_base}/cyberpanel-site.sql"; then
      has_cp=1
      hm_ok "Wysłano cyberpanel-site.sql"
    else
      rm -f "${cp_sql}"
      hm_archive_abort "Upload cyberpanel-site.sql nieudany. Nic nie usunięto z VPS." "${remote_base}"
      return 1
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

  local dbs_cfg_json=""
  for n in "${archive_dbs_from_config[@]}"; do
    [[ -n "${n}" ]] || continue
    dbs_cfg_json="${dbs_cfg_json}\"${n}\","
  done
  dbs_cfg_json="${dbs_cfg_json%,}"

  local manifest
  manifest="$(hm_mktemp .json)"
  local _j_domain _j_host _j_root _j_doc _j_user _j_php _j_remote _j_uhome _j_web
  local _has_web=0 _has_fpm=0 _has_meta=0
  _j_domain="$(hm_json_escape_str "${domain}")"
  _j_host="$(hm_json_escape_str "${BACKUP_HOST_LABEL:-}")"
  _j_root="$(hm_json_escape_str "${backup_root}")"
  _j_doc="$(hm_json_escape_str "${HM_DEL_DOCROOT}")"
  _j_user="$(hm_json_escape_str "${HM_DEL_USER}")"
  _j_uhome="$(hm_json_escape_str "$(getent passwd "${HM_DEL_USER}" 2>/dev/null | cut -d: -f6 || true)")"
  _j_php="$(hm_json_escape_str "${HM_SITE_PHP:-}")"
  _j_web="$(hm_json_escape_str "${HM_DEL_WEB:-${HM_SITE_WEBSERVER:-${WEBSERVER:-}}}")"
  _j_remote="$(hm_json_escape_str "${remote_base}")"
  hm_rclone_file_nonempty "${remote_base}/webserver.tar.gz" 2>/dev/null && _has_web=1
  hm_rclone_file_nonempty "${remote_base}/php-fpm.tar.gz" 2>/dev/null && _has_fpm=1
  hm_rclone_file_nonempty "${remote_base}/meta.tar.gz" 2>/dev/null && _has_meta=1
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
  "webserver": "${_j_web}",
  "has_webserver_tar": ${_has_web},
  "has_php_fpm_tar": ${_has_fpm},
  "has_meta_tar": ${_has_meta},
  "databases": [${db_json}],
  "databases_from_site_config": [${dbs_cfg_json}],
  "db_users": [${dbu_json}],
  "db_accounts": ${has_db_accounts},
  "unix_account": ${has_unix_account},
  "sha256_db_accounts": "$(hm_json_escape_str "${db_acc_sha}")",
  "sha256_unix_account": "$(hm_json_escape_str "${unix_meta_sha}")",
  "sha256_files": "$(hm_json_escape_str "${files_sha256}")",
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

  # Guard: każda baza do DROP (HM_DEL_DBS + .dbs) musi mieć zweryfikowany dump
  local _guard_name _guard_missing=0
  for dline in "${HM_DEL_DBS[@]}"; do
    [[ -n "${dline}" ]] || continue
    IFS='|' read -r _guard_name _ <<<"${dline}"
    [[ -n "${_guard_name}" ]] || continue
    if [[ "${seen_adb}" != *"|${_guard_name}|"* ]] \
      || ! hm_rclone_file_nonempty "${remote_base}/db/${_guard_name}.sql.gz"; then
      hm_err "Brak zweryfikowanego zrzutu dla DB ${_guard_name} (plan DROP bez kopii)."
      _guard_missing=1
    fi
  done
  if [[ -f "${_mdb_file:-}" && ! -L "${_mdb_file}" ]]; then
    while IFS=$'\t' read -r _mdb_typ _mdb_name _ || [[ -n "${_mdb_typ:-}" ]]; do
      [[ -n "${_mdb_name}" ]] || continue
      case "${_mdb_typ}" in
        mysql|mariadb|"")
          if ! hm_rclone_file_nonempty "${remote_base}/db/${_mdb_name}.sql.gz"; then
            hm_err "Manifest .dbs: brak zrzutu db/${_mdb_name}.sql.gz przed DROP."
            _guard_missing=1
          fi
          ;;
      esac
    done < "${_mdb_file}"
  fi
  if [[ "${_guard_missing}" -eq 1 ]]; then
    hm_archive_abort "Archiwizacja przerwana: DROP bez kompletnego dumpa. Nic nie usunięto z VPS." "${remote_base}"
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
