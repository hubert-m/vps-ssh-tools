#!/usr/bin/env bash
# Backup: restore plików i baz

# cat z rclone LUB lokalnego FS (remote_base zaczyna się od /)
hm_backup_r_cat() {
  local path="$1"
  if [[ "${path}" == /* ]]; then
    [[ -f "${path}" ]] || return 1
    cat "${path}"
    return $?
  fi
  rclone cat "${path}"
}

hm_backup_r_exists() {
  local path="$1"
  if [[ "${path}" == /* ]]; then
    [[ -e "${path}" ]]
    return $?
  fi
  rclone cat "${path}" >/dev/null 2>&1
}

hm_backup_restore_files() {
  local remote_base="$1" target_dir="$2"
  local mode
  mode="$(hm_backup_detect_files_mode "${remote_base}")"
  mkdir -p "${target_dir}"

  # --no-same-owner: numeryczne UID z innego VPS nie „kradną” plików obcemu lokalnemu userowi;
  # właściciela ustawiamy potem przez hm_backup_restore_fix_ownership.
  case "${mode}" in
    tar)
      hm_info "Odtwarzanie plików (stream files.tar.gz) → ${target_dir}"
      if ! hm_backup_r_cat "${remote_base}/files.tar.gz" | tar --no-same-owner -xzf - -C "${target_dir}"; then
        hm_err "Rozpakowanie files.tar.gz nieudane."
        return 1
      fi
      ;;
    chunks)
      hm_info "Odtwarzanie plików (chunks → stream) → ${target_dir}"
      local part
      local -a chunk_parts=()
      if [[ "${remote_base}" == /* ]]; then
        while IFS= read -r part; do
          [[ -n "${part}" ]] && chunk_parts+=("$(basename "${part}")")
        done < <(find "${remote_base}/files.chunks" -name 'files.tar.gz.part_*' 2>/dev/null | sort)
      else
        while IFS= read -r part; do
          [[ -n "${part}" ]] && chunk_parts+=("${part}")
        done < <(rclone lsf "${remote_base}/files.chunks/" 2>/dev/null | grep 'files\.tar\.gz\.part_' | sort)
      fi
      local ctotal="${#chunk_parts[@]}"
      [[ "${ctotal}" -gt 0 ]] || { hm_err "Brak plików part_* w files.chunks."; return 1; }
      hm_status_line "Stream ${ctotal} chunków → tar (może potrwać)..."
      if ! (
        for part in "${chunk_parts[@]}"; do
          hm_backup_r_cat "${remote_base}/files.chunks/${part}" || exit 1
        done
      ) | tar --no-same-owner -xzf - -C "${target_dir}"; then
        hm_status_clear
        hm_err "Rozpakowanie files.chunks nieudane."
        return 1
      fi
      hm_status_clear
      ;;
    *)
      hm_warn "Brak archiwum plików w snapshocie (ani files.tar.gz, ani files.chunks/)."
      return 1
      ;;
  esac
  hm_ok "Pliki odtworzone."
}

# Po restore: user:user wewnątrz, ale public_html/docroot zachowuje grupę WWW (nogroup/lsadm) — jak perms fix.
hm_backup_restore_fix_ownership() {
  local target_dir="$1"
  local user="$2"
  local docroot="${3:-}"
  local webgrp=""

  [[ -n "${user}" ]] && id "${user}" >/dev/null 2>&1 || return 1
  [[ -n "${target_dir}" && -d "${target_dir}" ]] || return 1

  if declare -F hm_os_web_group >/dev/null 2>&1; then
    webgrp="$(hm_os_web_group 2>/dev/null || true)"
  fi
  [[ -n "${webgrp}" ]] || webgrp="nogroup"
  if ! getent group "${webgrp}" >/dev/null 2>&1; then
    webgrp="${user}"
  fi

  hm_info "chown plików → ${user}:${user} (docroot/public_html: ${user}:${webgrp})"
  # root katalogu strony
  chown "${user}:${user}" -- "${target_dir}" 2>/dev/null || true

  # zawartość — nie zmieniaj grupy samego public_html/docroot w tym samym przebiegu
  local ent base
  while IFS= read -r -d '' ent; do
    [[ -L "${ent}" ]] && continue
    base="$(basename "${ent}")"
    if [[ "${base}" == "public_html" ]]; then
      # wnętrze public_html → user:user; sam katalog → user:webgrp
      find -P "${ent}" -xdev -mindepth 1 -maxdepth 1 -print0 2>/dev/null \
        | while IFS= read -r -d '' inner; do
            [[ -L "${inner}" ]] && continue
            chown -R "${user}:${user}" -- "${inner}" 2>/dev/null || true
          done
      chown "${user}:${webgrp}" -- "${ent}" 2>/dev/null || chown "${user}:${user}" -- "${ent}" 2>/dev/null || true
      continue
    fi
    chown -R "${user}:${user}" -- "${ent}" 2>/dev/null || true
  done < <(find -P "${target_dir}" -xdev -mindepth 1 -maxdepth 1 -print0 2>/dev/null)

  if [[ -n "${docroot}" && -d "${docroot}" ]]; then
    local rd rt
    rd="$(realpath -m "${docroot}" 2>/dev/null || echo "${docroot}")"
    rt="$(realpath -m "${target_dir}" 2>/dev/null || echo "${target_dir}")"
    if [[ "${rd}" == "${rt}" || "${rd}" == "${rt}"/* ]]; then
      chown "${user}:${webgrp}" -- "${docroot}" 2>/dev/null || true
    fi
  fi
  return 0
}

# Baza istnieje i ma ≥1 tabelę?
hm_backup_db_is_nonempty() {
  local dbname="$1" n
  hm_is_valid_db_name "${dbname}" || return 1
  n="$(hm_mysql_exec -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=$(hm_sql_quote "${dbname}");" 2>/dev/null | tr -d '[:space:]')"
  [[ "${n}" =~ ^[0-9]+$ && "${n}" -gt 0 ]]
}

# Czy import DB zagraża żywej innej domenie (np. bazy mastera w starym snapshocie childa).
# Przy restore childa: DB z website_id=master blokuj, chyba że config DOCROOT childa ją wskazuje.
hm_backup_db_belongs_to_other_domain() {
  local dbname="$1" skip_domain="$2" other q row root doc hname horigin is_child
  [[ -n "${dbname}" && -n "${skip_domain}" ]] || return 1
  hm_is_valid_db_name "${dbname}" || return 1
  [[ "${PANEL:-}" == "cyberpanel" ]] || return 1
  q="$(hm_sql_quote "${dbname}")"
  other="$(hm_mysql_exec cyberpanel -e "
SELECT w.domain FROM databases_databases d
INNER JOIN websiteFunctions_websites w ON d.website_id = w.id
WHERE d.dbName = ${q} AND w.domain <> $(hm_sql_quote "${skip_domain}")
LIMIT 1;
" 2>/dev/null | tr -d '[:space:]' || true)"
  [[ -n "${other}" ]] || return 1
  is_child="$(hm_mysql_exec cyberpanel -e "
SELECT 1 FROM websiteFunctions_childdomains c
INNER JOIN websiteFunctions_websites w ON c.master_id = w.id
WHERE c.domain = $(hm_sql_quote "${skip_domain}") AND w.domain = $(hm_sql_quote "${other}")
LIMIT 1;
" 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ "${is_child}" == "1" ]]; then
    row="$(hm_resolve_site_paths "${skip_domain}" 2>/dev/null || true)"
    if [[ -n "${row}" ]]; then
      IFS=$'\t' read -r _ root doc _ _ _ <<<"${row}"
      root="$(hm_tsv_unfield "${root}")"
      doc="$(hm_tsv_unfield "${doc}")"
      [[ -z "${doc}" || ! -d "${doc}" ]] && doc="${root}"
      if [[ -n "${doc}" && -d "${doc}" ]]; then
        while IFS=$'\t' read -r hname horigin; do
          [[ "${hname}" == "${dbname}" ]] || continue
          case "${horigin}" in
            wp-config|.env|.env-url|configuration.php) return 1 ;; # DB childa mimo CP=master
          esac
        done < <(
          {
            hm_extract_db_from_file "${doc}/wp-config.php" wp
            hm_extract_db_from_file "${doc}/.env" env
            hm_extract_db_from_file "${doc}/configuration.php" joomla
          } | awk -F'\t' 'NF && !seen[$1]++ { print $1 "\t" $2 }'
        )
      fi
    fi
    return 0 # child restore + DB mastera
  fi
  # Dwa niezależne website — zawsze odmowa
  return 0
}

hm_backup_restore_dbs() {
  local remote_base="$1"
  local overwrite_db="${2:-0}"
  local for_domain="${3:-${HM_SITE_DOMAIN:-}}"
  local json db_raw name cli sock_args=()
  json="$(hm_backup_cat_manifest "${remote_base}")"
  db_raw="$(hm_backup_json_arr "${json}" "databases")"
  db_raw="${db_raw//\"/}"
  db_raw="${db_raw// /}"

  cli="$(hm_mysql_cli)" || { hm_err "Brak klienta mysql/mariadb."; return 1; }
  [[ -n "${MYSQL_SOCKET:-}" ]] && sock_args=(--socket="${MYSQL_SOCKET}")

  if [[ -z "${db_raw}" ]]; then
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
  local db di=0 dtotal=0
  for db in "${_dbs[@]}"; do
    [[ -n "${db}" ]] && dtotal=$((dtotal + 1))
  done
  for db in "${_dbs[@]}"; do
    [[ -n "${db}" ]] || continue
    hm_is_valid_db_name "${db}" || { hm_warn "Pominięto nieprawidłową nazwę bazy: ${db}"; continue; }
    di=$((di + 1))
    if [[ -n "${for_domain}" ]] && hm_backup_db_belongs_to_other_domain "${db}" "${for_domain}"; then
      hm_err "ODMOWA: baza \`${db}\` należy w CyberPanel do innej żywej domeny niż ${for_domain} — nie nadpisuję (nawet z --overwrite-db)."
      return 1
    fi
    if hm_backup_db_is_nonempty "${db}"; then
      if [[ "${overwrite_db}" -ne 1 ]]; then
        hm_err "KOLIZJA: baza \`${db}\` już istnieje i nie jest pusta — odmowa importu (użyj --overwrite-db)."
        return 1
      fi
      hm_warn "KOLIZJA: nadpisuję niepustą bazę \`${db}\` (--overwrite-db)."
    fi
    hm_progress_bar "${di}" "${dtotal}" "Import DB: ${db}"
    hm_status_clear
    hm_info "Import DB ${db} ← ${remote_base}/db/${db}.sql.gz"
    "${cli}" "${sock_args[@]}" -e "CREATE DATABASE IF NOT EXISTS \`${db}\`;" 2>/dev/null || true
    if ! rclone cat "${remote_base}/db/${db}.sql.gz" | gunzip -c | "${cli}" "${sock_args[@]}" "${db}"; then
      hm_err "Import DB ${db} nieudany."
      return 1
    fi
    hm_ok "DB ${db} OK."
  done
  hm_progress_done
}

hm_backup_ols_reload() {
  if hm_ols_reload_soft; then
    hm_ok "OLS reload OK."
  else
    hm_warn "Nie udało się przeładować OLS — zrób ręcznie: ols reload"
  fi
  return 0
}

# Czy snapshot ma artefakty .enc (wymaga BACKUP_ENCRYPT_PASSPHRASE przy restore).
hm_backup_snapshot_has_enc() {
  local remote_base="$1"
  local f
  for f in unix-account.meta.enc db-accounts.sql.enc system-configs.tar.gz.enc; do
    if rclone cat "${remote_base}/${f}" >/dev/null 2>&1; then
      return 0
    fi
  done
  if rclone lsf "${remote_base}" 2>/dev/null | grep -qE '\.enc$'; then
    return 0
  fi
  return 1
}

# Twardy stop PRZED jakąkolwiek zmianą — snapshot .enc bez passphrase.
hm_backup_abort_if_enc_without_passphrase() {
  local remote_base="$1"
  [[ -n "${BACKUP_ENCRYPT_PASSPHRASE:-}" ]] && return 0
  if hm_backup_snapshot_has_enc "${remote_base}"; then
    hm_err "Snapshot zaszyfrowany (.enc) — ustaw BACKUP_ENCRYPT_PASSPHRASE przed restore. Żadnych zmian nie wykonano."
    return 1
  fi
  return 0
}

# Pobierz plik z Drive; jeśli .enc — deszyfruj (BACKUP_ENCRYPT_PASSPHRASE).
hm_backup_fetch_maybe_decrypt() {
  local remote_base="$1"
  local base_name="$2"   # np. unix-account.meta / db-accounts.sql
  local out_file="$3"
  local remote_path enc_tmp

  if hm_backup_r_exists "${remote_base}/${base_name}.enc"; then
    remote_path="${remote_base}/${base_name}.enc"
    if [[ -z "${BACKUP_ENCRYPT_PASSPHRASE:-}" ]]; then
      hm_err "Snapshot ma ${base_name}.enc — ustaw BACKUP_ENCRYPT_PASSPHRASE."
      return 1
    fi
    enc_tmp="$(mktemp "${TMP_DIR:-/tmp}/hmtools-enc.XXXXXX")"
    chmod 600 "${enc_tmp}" "${out_file}" 2>/dev/null || true
    if ! hm_backup_r_cat "${remote_path}" > "${enc_tmp}" || [[ ! -s "${enc_tmp}" ]]; then
      rm -f "${enc_tmp}"
      return 1
    fi
    export BACKUP_ENCRYPT_PASSPHRASE
    if ! openssl enc -d -aes-256-cbc -pbkdf2 -pass env:BACKUP_ENCRYPT_PASSPHRASE \
      -in "${enc_tmp}" -out "${out_file}" 2>/dev/null; then
      rm -f "${enc_tmp}"
      hm_err "Deszyfracja ${base_name}.enc nieudana (sprawdź BACKUP_ENCRYPT_PASSPHRASE / openssl)."
      return 1
    fi
    rm -f "${enc_tmp}"
    return 0
  fi
  if hm_backup_r_exists "${remote_base}/${base_name}"; then
    hm_backup_r_cat "${remote_base}/${base_name}" > "${out_file}"
    [[ -s "${out_file}" ]]
    return $?
  fi
  return 1
}

# Odtwórz konto Unix z unix-account.meta (+ opcjonalnie authorized_keys).
# home_override: preferowany $HOME (site_root z restore); puste = wartość z meta.
# Katalog ma jakikolwiek wpis (niepusty)?
hm_backup_dir_nonempty() {
  local d="$1"
  [[ -d "${d}" ]] || return 1
  local e
  e="$(find "${d}" -mindepth 1 -maxdepth 1 2>/dev/null | head -1 || true)"
  [[ -n "${e}" ]]
}

# Peek unix-account.meta → name/shared/protected/uid/home (stdout: name|shared|protected|uid|home)
hm_backup_peek_unix_meta() {
  local remote_base="$1"
  local meta_tmp line key val
  local name="" uid="" home="" shared=0 protected=0
  meta_tmp="$(mktemp "${TMP_DIR:-/tmp}/hmtools-unix-peek.XXXXXX")"
  chmod 600 "${meta_tmp}"
  if ! hm_backup_fetch_maybe_decrypt "${remote_base}" "unix-account.meta" "${meta_tmp}"; then
    rm -f "${meta_tmp}"
    return 1
  fi
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" && "${line}" == *=* ]] || continue
    key="${line%%=*}"; val="${line#*=}"
    case "${key}" in
      name) name="${val}" ;;
      uid) uid="${val}" ;;
      home) home="${val}" ;;
      shared) shared="${val}" ;;
      protected) protected="${val}" ;;
    esac
  done < "${meta_tmp}"
  rm -f "${meta_tmp}"
  printf '%s|%s|%s|%s|%s\n' "${name}" "${shared:-0}" "${protected:-0}" "${uid}" "${home}"
}

# $3 = adopt (0/1) — świadome nadpisanie istniejącego konta (--adopt-existing-user)
hm_backup_restore_unix_account() {
  local remote_base="$1"
  local home_override="${2:-}"
  local adopt="${3:-0}"
  local meta_tmp keys_tmp
  local name uid gid group home shell gecos shadow shared protected
  local line key val
  local live_uid="" live_home="" live_home_n="" home_n="" collision=0

  meta_tmp="$(mktemp "${TMP_DIR:-/tmp}/hmtools-unix-meta.XXXXXX")"
  chmod 600 "${meta_tmp}"
  if ! hm_backup_fetch_maybe_decrypt "${remote_base}" "unix-account.meta" "${meta_tmp}"; then
    rm -f "${meta_tmp}"
    if rclone cat "${remote_base}/unix-account.meta.enc" >/dev/null 2>&1; then
      hm_err "unix-account.meta.enc obecny, ale deszyfracja nieudana — odmowa (nie pomijam konta Unix)."
      return 1
    fi
    hm_info "Brak unix-account.meta(.enc) w snapshocie — pomijam odtworzenie konta Unix."
    return 0
  fi
  if [[ ! -s "${meta_tmp}" ]]; then
    rm -f "${meta_tmp}"
    hm_warn "Nie udało się pobrać unix-account.meta."
    return 1
  fi

  name=""; uid=""; gid=""; group=""; home=""; shell="/bin/bash"; gecos=""; shadow=""
  shared=0; protected=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    [[ "${line}" == *=* ]] || continue
    key="${line%%=*}"
    val="${line#*=}"
    case "${key}" in
      name) name="${val}" ;;
      uid) uid="${val}" ;;
      gid) gid="${val}" ;;
      group) group="${val}" ;;
      home) home="${val}" ;;
      shell) shell="${val}" ;;
      gecos) gecos="${val}" ;;
      shadow) shadow="${val}" ;;
      shared) shared="${val}" ;;
      protected) protected="${val}" ;;
    esac
  done < "${meta_tmp}"
  rm -f "${meta_tmp}"

  hm_is_valid_unix_user "${name}" || { hm_err "Nieprawidłowa nazwa Unix w meta: ${name:-?}"; return 1; }
  [[ -n "${home_override}" ]] && home="${home_override}"
  [[ -n "${home}" ]] || { hm_err "Brak home w unix-account.meta."; return 1; }
  [[ -n "${group}" ]] || group="${name}"
  [[ -n "${shell}" ]] || shell="/bin/bash"
  home_n="$(realpath -m "${home}" 2>/dev/null || echo "${home}")"
  home_n="${home_n%/}"

  if id "${name}" >/dev/null 2>&1; then
    live_uid="$(id -u "${name}" 2>/dev/null || true)"
    live_home="$(getent passwd "${name}" 2>/dev/null | cut -d: -f6 || true)"
    live_home_n="$(realpath -m "${live_home}" 2>/dev/null || echo "${live_home}")"
    live_home_n="${live_home_n%/}"

    if [[ "${shared}" -eq 1 || "${protected}" -eq 1 ]]; then
      collision=1
    fi
    if [[ -n "${uid}" && "${uid}" =~ ^[0-9]+$ && -n "${live_uid}" && "${uid}" != "${live_uid}" ]]; then
      collision=1
    fi
    if [[ -n "${live_home_n}" && -n "${home_n}" && "${live_home_n}" != "${home_n}" ]]; then
      collision=1
    fi

    # Współdzielone/chronione: nigdy nie ruszamy hasła/kluczy/home — pomijamy Unix (pliki: docroot).
    if [[ "${shared}" -eq 1 || "${protected}" -eq 1 ]]; then
      hm_warn "KOLIZJA Unix: ${name} shared=${shared} protected=${protected} — pomijam usermod/hasło/klucze (żywy serwis)."
      HM_SITE_USER="${name}"
      return 0
    fi

    if [[ "${adopt}" -ne 1 ]]; then
      hm_err "KOLIZJA Unix: konto \`${name}\` już istnieje (uid=${live_uid} home=${live_home_n}; meta uid=${uid:-?} home=${home_n})."
      hm_info "Domyślnie NIE nadpisuję hasła, kluczy SSH ani home. Użyj --adopt-existing-user aby świadomie przejąć konto."
      return 1
    fi

    hm_warn "ADOPT (--adopt-existing-user): nadpisuję shell/home/hasło/klucze istniejącego \`${name}\` (collision=${collision})."
    usermod -s "${shell}" "${name}" 2>/dev/null || true
    if [[ -n "${home}" ]]; then
      usermod -d "${home}" "${name}" 2>/dev/null || true
    fi
  else
    hm_info "Tworzenie konta Unix ${name} (uid=${uid:-auto} gid=${gid:-auto} home=${home})"
    if [[ -n "${gid}" && "${gid}" =~ ^[0-9]+$ ]]; then
      if ! getent group "${group}" >/dev/null 2>&1; then
        groupadd -g "${gid}" "${group}" 2>/dev/null \
          || groupadd "${group}" 2>/dev/null \
          || hm_warn "groupadd ${group} nieudany — użyję istniejącej grupy."
      fi
    elif ! getent group "${group}" >/dev/null 2>&1; then
      groupadd "${group}" 2>/dev/null || true
    fi

    local -a ua=(useradd -M -d "${home}" -s "${shell}" -c "${gecos}" )
    if getent group "${group}" >/dev/null 2>&1; then
      ua+=(-g "${group}")
    fi
    if [[ -n "${uid}" && "${uid}" =~ ^[0-9]+$ ]] && ! getent passwd "${uid}" >/dev/null 2>&1; then
      ua+=(-u "${uid}")
    fi
    ua+=("${name}")
    if ! "${ua[@]}"; then
      hm_err "useradd ${name} nieudany."
      return 1
    fi
    hm_ok "Utworzono użytkownika ${name}."
  fi

  if [[ -n "${shadow}" && "${shadow}" != "*" && "${shadow}" != "!" && "${shadow}" != "!!" ]]; then
    if printf '%s:%s\n' "${name}" "${shadow}" | chpasswd -e 2>/dev/null; then
      hm_ok "Przywrócono hash hasła Unix (${name})."
    else
      hm_warn "chpasswd -e nieudany dla ${name} — hasło SSH może wymagać ręcznego ustawienia."
    fi
  else
    hm_info "Brak użytecznego hasha shadow dla ${name} (konto bez hasła / zablokowane w snapshocie)."
  fi

  keys_tmp="$(mktemp "${TMP_DIR:-/tmp}/hmtools-unix-keys.XXXXXX")"
  chmod 600 "${keys_tmp}"
  if rclone cat "${remote_base}/unix-authorized_keys" > "${keys_tmp}" 2>/dev/null && [[ -s "${keys_tmp}" ]]; then
    mkdir -p "${home}/.ssh"
    chmod 700 "${home}/.ssh"
    if [[ -f "${home}/.ssh/authorized_keys" ]]; then
      local kline
      while IFS= read -r kline || [[ -n "${kline}" ]]; do
        [[ -n "${kline}" ]] || continue
        [[ "${kline}" =~ ^[[:space:]]*# ]] && continue
        if ! grep -Fqx "${kline}" "${home}/.ssh/authorized_keys" 2>/dev/null; then
          printf '%s\n' "${kline}" >> "${home}/.ssh/authorized_keys"
        fi
      done < "${keys_tmp}"
    else
      cp -f "${keys_tmp}" "${home}/.ssh/authorized_keys"
    fi
    chmod 600 "${home}/.ssh/authorized_keys"
    chown -R "${name}:${group}" "${home}/.ssh" 2>/dev/null || chown -R "${name}:${name}" "${home}/.ssh" 2>/dev/null || true
    hm_ok "Przywrócono authorized_keys → ${home}/.ssh/authorized_keys"
  fi
  rm -f "${keys_tmp}"

  HM_SITE_USER="${name}"
  return 0
}

# Czy konto MySQL user@host (lub user@jakikolwiek host) już istnieje?
hm_backup_mysql_user_exists() {
  local user="$1" host="${2:-}"
  local n q
  hm_is_valid_db_name "${user}" || return 1
  if [[ -n "${host}" ]]; then
    q="SELECT COUNT(*) FROM mysql.user WHERE User=$(hm_sql_quote "${user}") AND Host=$(hm_sql_quote "${host}");"
  else
    q="SELECT COUNT(*) FROM mysql.user WHERE User=$(hm_sql_quote "${user}");"
  fi
  n="$(hm_mysql_exec -e "${q}" 2>/dev/null | tr -d '[:space:]')"
  [[ "${n}" =~ ^[0-9]+$ && "${n}" -gt 0 ]]
}

# Usuń klauzule IDENTIFIED … z GRANT (nie zmieniaj hasła istniejącego konta).
# stdout = oczyszczony GRANT; rc=1 gdy po stripie został sam no-op GRANT USAGE ON *.*.
hm_backup_grant_without_identified() {
  local g="${1:-}"
  # IDENTIFIED BY [PASSWORD] '…'
  g="$(sed -E "s/[[:space:]]+IDENTIFIED[[:space:]]+BY[[:space:]]+(PASSWORD[[:space:]]+)?'[^']*'//gi" <<<"${g}")"
  # IDENTIFIED WITH plugin [AS 'hash']
  g="$(sed -E "s/[[:space:]]+IDENTIFIED[[:space:]]+WITH[[:space:]]+[^[:space:];]+([[:space:]]+AS[[:space:]]+'[^']*')?//gi" <<<"${g}")"
  g="$(sed -E 's/[[:space:]]+;/;/; s/[[:space:]]+$//' <<<"${g}")"
  if [[ "${g}" =~ ^[[:space:]]*GRANT[[:space:]]+USAGE[[:space:]]+ON[[:space:]]+\*\.\*[[:space:]]+TO[[:space:]] ]]; then
    printf '%s\n' "${g}"
    return 1
  fi
  printf '%s\n' "${g}"
  return 0
}

# Odtwórz konta MySQL z db-accounts.sql.
# Istniejący user@host → pomiń DROP/CREATE (nie nadpisuj hasła ani cudzych grantów);
# GRANT-y z pliku bez IDENTIFIED BY PASSWORD (archive filtruje do baz snapshotu).
hm_backup_restore_db_accounts() {
  local remote_base="$1"
  local cli sock_args=() sqlf outf
  local line skip_ddl=0 cur_user="" cur_host=""
  local created=0 skipped_ddl=0 grants_applied=0
  local safe_grant=""

  sqlf="$(mktemp "${TMP_DIR:-/tmp}/hmtools-db-accounts.XXXXXX.sql")"
  outf="$(mktemp "${TMP_DIR:-/tmp}/hmtools-db-accounts-safe.XXXXXX.sql")"
  chmod 600 "${sqlf}" "${outf}"
  if ! hm_backup_fetch_maybe_decrypt "${remote_base}" "db-accounts.sql" "${sqlf}"; then
    rm -f "${sqlf}" "${outf}"
    if rclone cat "${remote_base}/db-accounts.sql.enc" >/dev/null 2>&1; then
      hm_err "db-accounts.sql.enc obecny, ale deszyfracja nieudana — odmowa (nie pomijam kont MySQL)."
      return 1
    fi
    hm_info "Brak db-accounts.sql(.enc) w snapshocie — pomijam odtworzenie kont MySQL."
    return 0
  fi
  if [[ ! -s "${sqlf}" ]]; then
    rm -f "${sqlf}" "${outf}"
    hm_err "Nie udało się pobrać db-accounts.sql."
    return 1
  fi

  cli="$(hm_mysql_cli)" || { rm -f "${sqlf}" "${outf}"; hm_err "Brak klienta mysql/mariadb."; return 1; }
  [[ -n "${MYSQL_SOCKET:-}" ]] && sock_args=(--socket="${MYSQL_SOCKET}")

  {
    echo "-- hmtools restore: db-accounts (safe — no DROP/CREATE for existing users; no IDENTIFIED on existing)"
    echo "-- generated: $(date -Iseconds)"
  } > "${outf}"

  while IFS= read -r line || [[ -n "${line}" ]]; do
    # Tag z nowych archive: -- HM_DROP_IF_MISSING user@host
    if [[ "${line}" =~ ^--[[:space:]]*HM_DROP_IF_MISSING[[:space:]]+([^@[:space:]]+)@([^[:space:]]+)[[:space:]]*$ ]]; then
      cur_user="${BASH_REMATCH[1]}"
      cur_host="${BASH_REMATCH[2]}"
      if hm_backup_mysql_user_exists "${cur_user}" "${cur_host}" \
        || hm_backup_mysql_user_exists "${cur_user}"; then
        skip_ddl=1
        printf -- '-- SKIP DROP/CREATE: %s@%s już istnieje (zachowuję hasło i obce GRANTy)\n' \
          "${cur_user}" "${cur_host}" >> "${outf}"
        skipped_ddl=$((skipped_ddl + 1))
      else
        skip_ddl=0
      fi
      continue
    fi

    # Stare archive bez tagu: DROP USER [IF EXISTS] 'u'@'h'
    if [[ "${line}" =~ ^DROP[[:space:]]+USER([[:space:]]+IF[[:space:]]+EXISTS)?[[:space:]]+\'([^\']+)\'@\'([^\']+)\' ]]; then
      cur_user="${BASH_REMATCH[2]}"
      cur_host="${BASH_REMATCH[3]}"
      if hm_backup_mysql_user_exists "${cur_user}" "${cur_host}" \
        || hm_backup_mysql_user_exists "${cur_user}"; then
        skip_ddl=1
        printf -- '-- skipped DROP (exists): %s\n' "${line}" >> "${outf}"
        skipped_ddl=$((skipped_ddl + 1))
        continue
      fi
      skip_ddl=0
      printf '%s\n' "${line}" >> "${outf}"
      continue
    fi

    if [[ "${line}" =~ ^CREATE[[:space:]]+USER ]]; then
      if [[ "${skip_ddl}" -eq 1 ]]; then
        printf -- '-- skipped CREATE (exists): %s\n' "${line}" >> "${outf}"
        continue
      fi
      created=$((created + 1))
      printf '%s\n' "${line}" >> "${outf}"
      continue
    fi

    if [[ "${line}" =~ ^[[:space:]]*GRANT[[:space:]] ]]; then
      if [[ "${skip_ddl}" -eq 1 ]]; then
        safe_grant="$(hm_backup_grant_without_identified "${line}")" || {
          printf -- '-- skipped GRANT USAGE (exists, bez zmiany hasła): %s\n' "${line}" >> "${outf}"
          continue
        }
        if [[ "${safe_grant}" != "${line}" ]]; then
          printf -- '-- stripped IDENTIFIED (exists): %s\n' "${line}" >> "${outf}"
          line="${safe_grant}"
        fi
      fi
      grants_applied=$((grants_applied + 1))
    fi
    printf '%s\n' "${line}" >> "${outf}"
  done < "${sqlf}"

  hm_info "Odtwarzanie kont MySQL z db-accounts.sql (safe)…"
  if ! "${cli}" "${sock_args[@]}" < "${outf}"; then
    rm -f "${sqlf}" "${outf}"
    hm_err "Import db-accounts.sql nieudany."
    return 1
  fi
  rm -f "${sqlf}" "${outf}"
  hm_ok "Konta MySQL: CREATE nowych=${created}, pominięte DROP/CREATE (istniejące)=${skipped_ddl}, GRANT-y zastosowane≈${grants_applied}."
  return 0
}

# SSL z archive — rozpakowanie z zachowaniem symlinków (tar bez -h przy pakowaniu).
hm_backup_restore_ssl() {
  local remote_base="$1"
  if ! rclone cat "${remote_base}/ssl.tar.gz" >/dev/null 2>&1; then
    hm_info "Brak ssl.tar.gz — pomijam SSL."
    return 0
  fi
  hm_info "Odtwarzanie SSL z ssl.tar.gz (ścieżki absolutne → /)…"
  if rclone cat "${remote_base}/ssl.tar.gz" | tar -xzf - -C /; then
    hm_ok "SSL rozpakowany (live/archive/renewal / acme.sh)."
    return 0
  fi
  hm_warn "Rozpakowanie ssl.tar.gz nieudane."
  return 1
}

# Crontab użytkownika strony z crontab.txt
# domain (opcjonalnie $3 / HM_SITE_DOMAIN) — przy współdzielonym userze NIE nadpisuj crona mastera.
hm_backup_restore_crontab() {
  local remote_base="$1"
  local user="${2:-${HM_SITE_USER:-}}"
  local domain="${3:-${HM_SITE_DOMAIN:-}}"
  local tmp
  [[ -n "${user}" ]] && id "${user}" >/dev/null 2>&1 || {
    hm_info "Brak usera Unix — pomijam crontab."
    return 0
  }
  if declare -F hm_backup_site_user_shared_live >/dev/null 2>&1 \
      && [[ -n "${domain}" ]] \
      && hm_backup_site_user_shared_live "${user}" "${domain}"; then
    hm_warn "crontab: pomijam — ${user} współdzielony z innymi domenami (nie nadpisuję crona żywego konta)."
    return 0
  fi
  if ! rclone cat "${remote_base}/crontab.txt" >/dev/null 2>&1; then
    hm_info "Brak crontab.txt — pomijam."
    return 0
  fi
  tmp="$(mktemp "${TMP_DIR:-/tmp}/hmtools-cron.XXXXXX")"
  if ! rclone cat "${remote_base}/crontab.txt" > "${tmp}" || [[ ! -s "${tmp}" ]]; then
    rm -f "${tmp}"
    return 0
  fi
  hm_info "Przywracam crontab użytkownika ${user} ($(wc -l < "${tmp}" | tr -d ' ') linii)…"
  if crontab -u "${user}" "${tmp}" 2>/dev/null; then
    hm_ok "crontab -u ${user} odtworzony."
  else
    hm_warn "crontab -u ${user} nieudany."
  fi
  rm -f "${tmp}"
  return 0
}

# PM2 — tylko instrukcja + zapis dump (automatyczny start bywa niebezpieczny bez cwd/env).
hm_backup_restore_pm2_hint() {
  local remote_base="$1"
  local user="${2:-${HM_SITE_USER:-}}"
  if ! rclone cat "${remote_base}/pm2-processes.json" >/dev/null 2>&1; then
    return 0
  fi
  local n
  n="$(rclone cat "${remote_base}/pm2-processes.json" 2>/dev/null | head -c 200 || true)"
  if [[ -z "${n}" || "${n}" == "[]" ]]; then
    return 0
  fi
  hm_warn "Snapshot zawiera pm2-processes.json — automatyczny start PM2 pominięty (bezpieczeństwo)."
  hm_info "Ręcznie: jako ${user:-\$SITE_USER} → pm2 resurrect / pm2 start …; dump: ${remote_base}/pm2-processes.json"
  return 0
}

# CyberPanel website/childdomains/databases INSERT z cyberpanel-site.sql
# Bez jawnego PK: strip `id`, mapowanie master_id/website_id → nowy id website.
hm_backup_restore_cyberpanel_site() {
  local remote_base="$1"
  local domain="${2:-}"
  local cli sock_args=() sqlf src_id new_id dq web_sql rest_sql
  if ! rclone cat "${remote_base}/cyberpanel-site.sql" >/dev/null 2>&1; then
    hm_info "Brak cyberpanel-site.sql — panel CP może nie widzieć domeny (dodaj ręcznie lub pomiń)."
    return 0
  fi
  if [[ "${PANEL:-}" != "cyberpanel" ]]; then
    hm_warn "PANEL≠cyberpanel — zapisuję cyberpanel-site.sql lokalnie nieaplikowany; dodaj domenę w panelu ręcznie."
    return 0
  fi
  cli="$(hm_mysql_cli)" || { hm_warn "Brak mysql — pomijam cyberpanel-site.sql."; return 0; }
  [[ -n "${MYSQL_SOCKET:-}" ]] && sock_args=(--socket="${MYSQL_SOCKET}")
  sqlf="$(mktemp "${TMP_DIR:-/tmp}/hmtools-cp.XXXXXX.sql")"
  web_sql="$(mktemp "${TMP_DIR:-/tmp}/hmtools-cp-web.XXXXXX.sql")"
  rest_sql="$(mktemp "${TMP_DIR:-/tmp}/hmtools-cp-rest.XXXXXX.sql")"
  chmod 600 "${sqlf}" "${web_sql}" "${rest_sql}"
  if ! rclone cat "${remote_base}/cyberpanel-site.sql" > "${sqlf}" || [[ ! -s "${sqlf}" ]]; then
    rm -f "${sqlf}" "${web_sql}" "${rest_sql}"
    return 0
  fi
  src_id="$(grep -oE 'source id=[0-9]+' "${sqlf}" 2>/dev/null | head -1 | grep -oE '[0-9]+' || true)"
  [[ -z "${src_id}" ]] && src_id="$(grep -oE 'id=[0-9]+' "${sqlf}" 2>/dev/null | head -1 | grep -oE '[0-9]+' || true)"

  if declare -F hm_archive_cp_sql_strip_explicit_ids >/dev/null 2>&1; then
    hm_archive_cp_sql_strip_explicit_ids "${sqlf}" || true
  fi

  if [[ -n "${domain}" ]] && hm_is_valid_domain "${domain}"; then
    dq="$(hm_sql_quote "${domain}")"
    "${cli}" "${sock_args[@]}" cyberpanel -e "
DELETE d FROM databases_databases d
  INNER JOIN websiteFunctions_websites w ON d.website_id = w.id WHERE w.domain = ${dq};
DELETE c FROM websiteFunctions_childdomains c
  INNER JOIN websiteFunctions_websites w ON c.master_id = w.id WHERE w.domain = ${dq};
DELETE FROM websiteFunctions_websites WHERE domain = ${dq};
" 2>/dev/null || true
  fi

  # 1) website INSERT (bez id) → nowy autoincrement
  grep -E '^INSERT INTO `websiteFunctions_websites`' "${sqlf}" > "${web_sql}" || true
  grep -Ev '^INSERT INTO `websiteFunctions_websites`' "${sqlf}" > "${rest_sql}" || true
  hm_info "Import cyberpanel-site.sql (website → mapowanie FK)…"
  if [[ -s "${web_sql}" ]]; then
    if ! "${cli}" "${sock_args[@]}" cyberpanel < "${web_sql}"; then
      rm -f "${sqlf}" "${web_sql}" "${rest_sql}"
      hm_err "Import CyberPanel website nieudany."
      return 1
    fi
  fi
  if [[ -n "${domain}" ]] && hm_is_valid_domain "${domain}"; then
    dq="$(hm_sql_quote "${domain}")"
    new_id="$("${cli}" "${sock_args[@]}" cyberpanel -N -B -e "SELECT id FROM websiteFunctions_websites WHERE domain=${dq} LIMIT 1;" 2>/dev/null | tr -d '[:space:]')"
  fi
  if [[ -n "${src_id}" && -n "${new_id}" && "${src_id}" != "${new_id}" && -s "${rest_sql}" ]]; then
    local mapped
    mapped="$(mktemp "${TMP_DIR:-/tmp}/hmtools-cp-map.XXXXXX.sql")"
    # complete-insert: (col…, website_id, …) VALUES (…, OLD, …) — nie „website_id=OLD”
    if hm_backup_cp_sql_remap_fk_ids "${rest_sql}" "${mapped}" "${src_id}" "${new_id}"; then
      mv -f "${mapped}" "${rest_sql}"
    else
      sed -E \
        -e "s/(master_id=)${src_id}/\1${new_id}/g" \
        -e "s/(website_id=)${src_id}/\1${new_id}/g" \
        -e "s/\(${src_id},/(${new_id},/g" \
        "${rest_sql}" > "${mapped}" && mv -f "${mapped}" "${rest_sql}" || true
      rm -f "${mapped}" 2>/dev/null || true
    fi
  fi
  if [[ -s "${rest_sql}" ]]; then
    if ! "${cli}" "${sock_args[@]}" cyberpanel < "${rest_sql}"; then
      rm -f "${sqlf}" "${web_sql}" "${rest_sql}"
      hm_err "Import CyberPanel childdomains/databases nieudany (FK?)."
      return 1
    fi
  fi
  rm -f "${sqlf}" "${web_sql}" "${rest_sql}"
  hm_ok "Wpis CyberPanel odtworzony${new_id:+ (id=${new_id})}."
  return 0
}

# Przepisz website_id / master_id w INSERT complete-insert (pozycja w VALUES = pozycja kolumny).
# Portable awk (bez gawk match(..., arr)). $1=in $2=out $3=old_id $4=new_id
hm_backup_cp_sql_remap_fk_ids() {
  local inf="$1" outf="$2" old="$3" new="$4"
  [[ -f "${inf}" && -n "${old}" && -n "${new}" && "${old}" =~ ^[0-9]+$ && "${new}" =~ ^[0-9]+$ ]] || return 1
  awk -v old="${old}" -v newid="${new}" '
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
    /^INSERT INTO/ {
      line = $0
      # INSERT INTO [`]tbl[`] (cols) VALUES (vals);
      # ") VALUES (" = 10 znaków; ") VALUES(" = 9
      vi = index(line, ") VALUES (")
      vlen = 10
      if (vi == 0) { vi = index(line, ") VALUES("); vlen = 9 }
      if (vi > 0) {
        # znajdź "(" listy kolumn: ostatni "(" przed ") VALUES"
        head = substr(line, 1, vi - 1)
        oi = 0
        for (i = 1; i <= length(head); i++) if (substr(head, i, 1) == "(") oi = i
        if (oi > 0) {
          colpart = substr(head, oi + 1)
          rest = substr(line, vi + vlen)
          # rest = vals);
          if (substr(rest, length(rest), 1) == ";") rest = substr(rest, 1, length(rest) - 1)
          if (substr(rest, length(rest), 1) == ")") rest = substr(rest, 1, length(rest) - 1)
          ncol = split_csv(colpart, cols)
          nval = split_csv(rest, vals)
          if (ncol == nval && ncol > 0) {
            changed = 0
            for (i = 1; i <= ncol; i++) {
              c = cols[i]
              gsub(/`/, "", c)
              c = trim(c)
              if (c == "website_id" || c == "master_id") {
                v = trim(vals[i])
                if (v == old) { vals[i] = newid; changed = 1 }
              }
            }
            if (changed) {
              valstr = vals[1]
              for (i = 2; i <= nval; i++) valstr = valstr ", " vals[i]
              print substr(line, 1, oi - 1) "(" colpart ") VALUES (" valstr ");"
              next
            }
          }
        }
      }
      gsub("website_id=" old, "website_id=" newid)
      gsub("master_id=" old, "master_id=" newid)
      print
      next
    }
    { print }
  ' "${inf}" > "${outf}"
  [[ -s "${outf}" ]]
}

# Wstaw mapy do listenerów. Plik maps: linie „listener<TAB>mapline”
# (listener=* → wszystkie listenery; deduplikacja per listener).
hm_ols_insert_maps_into_listeners() {
  local conf="$1"
  local maps_file="${2:-}"
  [[ -n "${maps_file}" && -f "${maps_file}" && -s "${maps_file}" && -f "${conf}" ]] || return 0
  local tmp
  tmp="$(mktemp)"
  awk -v mf="${maps_file}" '
    BEGIN {
      while ((getline line < mf) > 0) {
        if (line == "") continue
        tab = index(line, "\t")
        if (tab > 0) {
          lis = substr(line, 1, tab - 1)
          map = substr(line, tab + 1)
        } else {
          lis = "*"
          map = line
        }
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", map)
        if (map == "") continue
        if (lis == "" || lis == "-") lis = "*"
        n = ++nmap[lis]
        maps[lis, n] = map
      }
      close(mf)
      in_listener=0; depth=0; cur=""
    }
    {
      first=tolower($1)
      if (!in_listener && first=="listener") {
        in_listener=1; depth=0
        cur=$2; gsub(/\{/,"",cur)
        if ($0 ~ /\{/) depth=1
        print
        next
      }
      if (in_listener) {
        if ($0 ~ /\{/) depth++
        if ($0 ~ /\}/) {
          depth--
          if (depth <= 0) {
            # mapy dla tego listenera + legacy "*"
            for (pass = 1; pass <= 2; pass++) {
              key = (pass == 1) ? cur : "*"
              for (i = 1; i <= nmap[key]; i++) {
                m = maps[key, i]
                if (seen[cur, m]++) continue
                print "  " m
              }
            }
            in_listener=0; depth=0; cur=""
          }
        }
        print
        next
      }
      print
    }
  ' "${conf}" > "${tmp}" || { rm -f "${tmp}"; return 1; }
  # cat > conf — zachowaj mode/owner (mv z mktemp = 0600)
  if ! cat "${tmp}" > "${conf}"; then
    rm -f "${tmp}"
    return 1
  fi
  rm -f "${tmp}"
}

# Scal ols-httpd-snippet (virtualhost + map) do OLS_CONF — z kopią .hmtools.bak.
hm_ols_apply_httpd_snippet() {
  local domain="$1"
  local snip="$2"
  local conf="${OLS_CONF:-}"
  [[ -n "${conf}" && -f "${conf}" && -s "${snip}" ]] || return 1

  cp -a "${conf}" "${conf}.hmtools.bak" 2>/dev/null || true

  # usuń stary blok/mapy domeny (case-insensitive), potem wstaw snippet
  if declare -F hm_ols_remove_domain_from_conf >/dev/null 2>&1; then
    hm_ols_remove_domain_from_conf "${domain}"
  fi

  local vh_tmp maps_tmp line in_vh=0 depth=0 cur_listener="*"
  vh_tmp="$(mktemp)"
  maps_tmp="$(mktemp)"
  : > "${vh_tmp}"
  : > "${maps_tmp}"

  while IFS= read -r line || [[ -n "${line}" ]]; do
    local first second
    first="$(printf '%s' "${line}" | awk '{print tolower($1)}')"
    second="$(printf '%s' "${line}" | awk '{print $2}' | tr -d '{')"
    # tag z archive: "# listener:Default"
    if [[ "${line}" =~ ^[[:space:]]*#[[:space:]]*listener:([[:alnum:]_.-]+) ]]; then
      cur_listener="${BASH_REMATCH[1]}"
      continue
    fi
    if [[ "${in_vh}" -eq 0 && "${first}" == "virtualhost" ]]; then
      in_vh=1
      depth=0
      [[ "${line}" == *"{"* ]] && depth=1
      printf '%s\n' "${line}" >> "${vh_tmp}"
      continue
    fi
    if [[ "${in_vh}" -eq 1 ]]; then
      printf '%s\n' "${line}" >> "${vh_tmp}"
      [[ "${line}" == *"{"* ]] && depth=$((depth + 1))
      if [[ "${line}" == *"}"* ]]; then
        depth=$((depth - 1))
        if [[ "${depth}" -le 0 ]]; then
          in_vh=0
          depth=0
        fi
      fi
      continue
    fi
    if [[ "${first}" == "map" && "${second}" == "${domain}" ]]; then
      # znormalizuj wcięcie — insert doda własne
      local map_line
      map_line="$(printf '%s' "${line}" | sed -E 's/^[[:space:]]+//')"
      printf '%s\t%s\n' "${cur_listener}" "${map_line}" >> "${maps_tmp}"
    fi
  done < "${snip}"

  if [[ -s "${vh_tmp}" ]]; then
    {
      # jedna pusta linia-separator tylko gdy plik nie kończy się już pustą
      if [[ -s "${conf}" ]]; then
        local last
        last="$(tail -n 1 "${conf}" 2>/dev/null || true)"
        if [[ -n "${last}" ]]; then
          echo
        fi
      fi
      echo "# hmtools restore — ${domain}"
      cat "${vh_tmp}"
    } >> "${conf}"
  fi

  if [[ -s "${maps_tmp}" ]]; then
    hm_ols_insert_maps_into_listeners "${conf}" "${maps_tmp}"
  fi
  rm -f "${vh_tmp}" "${maps_tmp}"
  return 0
}

# Odtwórz vhost OLS + snippet httpd_config z snapshota archive (także gdy strona już nie istnieje lokalnie).
hm_backup_restore_ols_from_archive() {
  local domain="$1"
  local remote_base="$2"
  local did=0
  local conf="${OLS_CONF:-}"
  local vhosts="${OLS_VHOSTS:-}"

  # 1) katalog vhosta (ols-vhost-dir.tar.gz)
  if rclone cat "${remote_base}/ols-vhost-dir.tar.gz" >/dev/null 2>&1; then
    if [[ -z "${vhosts}" ]]; then
      hm_warn "OLS_VHOSTS nieustawione — nie mogę rozpakować ols-vhost-dir.tar.gz. Ręcznie: rclone cat ${remote_base}/ols-vhost-dir.tar.gz | tar -tzf -"
    else
      mkdir -p "${vhosts}"
      hm_info "Odtwarzanie katalogu vhost OLS → ${vhosts}/${domain}"
      if rclone cat "${remote_base}/ols-vhost-dir.tar.gz" | tar -xzf - -C "${vhosts}"; then
        hm_ok "Katalog vhost ${vhosts}/${domain} odtworzony."
        did=1
        if [[ -z "${HM_SITE_VHOST:-}" ]] && declare -F hm_vhost_conf_path >/dev/null 2>&1; then
          HM_SITE_VHOST="$(hm_vhost_conf_path "${domain}" 2>/dev/null || true)"
        fi
        if [[ -z "${HM_SITE_VHOST:-}" ]]; then
          local _cand
          for _cand in \
            "${vhosts}/${domain}/vhost.conf" \
            "${vhosts}/${domain}/vhconf.conf" \
            "${vhosts}/${domain}/httpd.conf"
          do
            if [[ -f "${_cand}" ]]; then
              HM_SITE_VHOST="${_cand}"
              break
            fi
          done
        fi
      else
        hm_err "Rozpakowanie ols-vhost-dir.tar.gz nieudane."
        return 1
      fi
    fi
  fi

  # 2) osobny vhost.conf z Drive — tylko gdy ols-vhost-dir nie dał już żadnego conf
  #    (nie twórz zbędnego vhconf.conf, gdy configFile wskazuje vhost.conf)
  if rclone cat "${remote_base}/vhost.conf" >/dev/null 2>&1; then
    local dest_vh="${HM_SITE_VHOST:-}"
    if [[ "${did}" -eq 1 && -n "${dest_vh}" && -f "${dest_vh}" ]]; then
      hm_info "vhost już z ols-vhost-dir (${dest_vh}) — pomijam osobny vhost.conf"
    else
      if [[ -z "${dest_vh}" && -n "${vhosts}" ]]; then
        mkdir -p "${vhosts}/${domain}"
        # OLS/CyberPanel: zwykle configFile → vhost.conf (nie inventuj vhconf.conf)
        dest_vh="${vhosts}/${domain}/vhost.conf"
        HM_SITE_VHOST="${dest_vh}"
      fi
      if [[ -n "${dest_vh}" ]]; then
        mkdir -p "$(dirname "${dest_vh}")"
        if rclone cat "${remote_base}/vhost.conf" > "${dest_vh}"; then
          hm_ok "Przywrócono vhost.conf → ${dest_vh}"
          did=1
        else
          hm_warn "Nie udało się zapisać vhost.conf → ${dest_vh}"
        fi
      fi
    fi
  fi

  # 3) snippet httpd_config (virtualhost + map)
  if rclone cat "${remote_base}/ols-httpd-snippet.conf" >/dev/null 2>&1; then
    if [[ -z "${conf}" || ! -f "${conf}" ]]; then
      hm_warn "OLS_CONF niedostępny — zapisz ręcznie ols-httpd-snippet.conf z Drive do httpd_config.conf."
    else
      local snip
      snip="$(mktemp)"
      if rclone cat "${remote_base}/ols-httpd-snippet.conf" > "${snip}" && [[ -s "${snip}" ]]; then
        hm_info "Scalanie ols-httpd-snippet → ${conf} (kopia .hmtools.bak)"
        if hm_ols_apply_httpd_snippet "${domain}" "${snip}"; then
          hm_ok "Blok virtualhost / map dla ${domain} wstawiony do httpd_config."
          did=1
        else
          hm_warn "Nie udało się scalić ols-httpd-snippet.conf"
        fi
      fi
      rm -f "${snip}"
    fi
  fi

  if [[ "${did}" -eq 0 ]]; then
    hm_warn "Snapshot bez artefaktów OLS (ols-vhost-dir / vhost.conf / ols-httpd-snippet) — pomijam restore vhosta."
  fi
  return 0
}

_hm_backup_restore_body() {
  local domain="${1:-}"
  shift || true
  local stamp="" files_only=0 db_only=0 overwrite_db=0 adopt_user=0 overwrite_files=0
  local a
  for a in "$@"; do
    case "${a}" in
      --files-only) files_only=1 ;;
      --db-only) db_only=1 ;;
      --overwrite-db) overwrite_db=1 ;;
      --adopt-existing-user) adopt_user=1 ;;
      --overwrite-files) overwrite_files=1 ;;
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

  if [[ "${files_only}" -eq 1 && "${db_only}" -eq 1 ]]; then
    hm_err "Flagi --files-only i --db-only wykluczają się — podaj co najwyżej jedną."
    return 1
  fi

  if [[ -z "${domain}" ]]; then
    domain="${HM_SITE_DOMAIN:-}"
  fi
  [[ -n "${domain}" ]] || {
    hm_err "Użycie: backup restore <domena> [stamp] [--files-only|--db-only] [--overwrite-db] [--overwrite-files] [--adopt-existing-user]"
    return 1
  }

  hm_load_config
  hm_detect_all
  hm_rclone_check || return 1

  local domain_arg="${domain}"
  local resolved=""
  # TYLKO dokładna nazwa / numer — partial match po cichu brałby np. child.alpha.test zamiast alpha.test
  if [[ -n "${HM_SITE_DOMAIN}" && "${HM_SITE_DOMAIN}" == "${domain_arg}" ]]; then
    resolved="${domain_arg}"
  else
    resolved="$(hm_find_site_by_arg_exact "${domain_arg}" 2>/dev/null || true)"
  fi

  if [[ -n "${resolved}" ]]; then
    domain="${resolved}"
    hm_set_site_context "${domain}"
  else
    # zarchiwizowana / usunięta z VPS — Drive po DOKŁADNEJ nazwie z argumentu
    domain="${domain_arg}"
    hm_info "Domena ${domain} nie jest lokalnie (dokładna nazwa) — szukam snapshotów na Drive…"
    if [[ -z "$(hm_backup_list_stamps "${domain}" | head -1)" ]]; then
      hm_err "Brak snapshotów na Drive dla „${domain}” i brak lokalnej strony o tej dokładnej nazwie."
      return 1
    fi
  fi

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

  if [[ ! "${stamp}" =~ ^[0-9]{8}-[0-9]{6}$ ]]; then
    hm_err "Nieprawidłowy stamp: '${stamp}' (oczekiwano YYYYMMDD-HHMMSS)."
    return 1
  fi

  local remote_base target_dir
  remote_base="$(hm_backup_dest_site "${domain}" "${stamp}")"
  if ! rclone lsd "${remote_base}" >/dev/null 2>&1 && ! rclone ls "${remote_base}" >/dev/null 2>&1; then
    if [[ -z "$(rclone lsf "${remote_base}" 2>/dev/null | head -1)" ]]; then
      hm_err "Snapshot nie istnieje: ${remote_base}"
      return 1
    fi
  fi

  if hm_backup_snapshot_is_incomplete "${remote_base}"; then
    hm_err "Snapshot ${stamp} jest niepełny/osierocony (brak poprawnego manifestu) — odmowa restore. Usuń: backup prune lub rclone purge."
    return 1
  fi

  # .enc bez passphrase → stop PRZED planem/confirm (żadnych zmian)
  hm_backup_abort_if_enc_without_passphrase "${remote_base}" || return 1

  target_dir="${HM_SITE_ROOT:-}"
  if [[ -z "${target_dir}" || ! -d "${target_dir}" ]]; then
    target_dir="${HM_SITE_DOCROOT:-}"
  fi
  if [[ -z "${target_dir}" || ! -d "${target_dir}" ]]; then
    local json
    json="$(hm_backup_cat_manifest "${remote_base}")"
    # site_root w archive = spakowany katalog (zwykle pełny HOME)
    target_dir="$(hm_backup_json_str "${json}" "site_root")"
    [[ -z "${target_dir}" ]] && target_dir="$(hm_backup_json_str "${json}" "unix_home")"
    [[ -z "${target_dir}" ]] && target_dir="$(hm_backup_json_str "${json}" "docroot")"
    [[ -z "${HM_SITE_USER:-}" ]] && HM_SITE_USER="$(hm_backup_json_str "${json}" "site_user")"
    [[ -z "${HM_SITE_PHP:-}" ]] && HM_SITE_PHP="$(hm_backup_json_str "${json}" "php")"
    [[ -z "${HM_SITE_DOCROOT:-}" ]] && HM_SITE_DOCROOT="$(hm_backup_json_str "${json}" "docroot")"
    [[ -z "${HM_SITE_ROOT:-}" ]] && HM_SITE_ROOT="$(hm_backup_json_str "${json}" "site_root")"
    [[ -z "${HM_SITE_ROOT:-}" ]] && HM_SITE_ROOT="${target_dir}"
    HM_SITE_DOMAIN="${domain}"
  fi
  [[ -n "${target_dir}" ]] || { hm_err "Brak katalogu docelowego strony (manifest bez site_root/docroot)."; return 1; }

  # sprawdź pliki PRZED confirm — snapshot tylko z manifestem już oznaczony incomplete wyżej;
  # dodatkowa jasna ścieżka gdy ktoś minie incomplete
  if [[ "${db_only}" -eq 0 ]]; then
    local _fmode
    _fmode="$(hm_backup_detect_files_mode "${remote_base}")"
    if [[ "${_fmode}" == "none" ]]; then
      hm_err "Snapshot ${stamp} bez archiwum plików (files.tar.gz / files.chunks) — odmowa restore."
      return 1
    fi
  fi

  hm_backup_check_space "${target_dir}" || return 1

  local -a plan_steps=()
  local restore_ols=0
  local restore_unix=0
  local restore_db_acc=0
  local restore_ssl=0
  local restore_cron=0
  local restore_cp=0
  local skip_unix_shared=0
  local unix_collision=0
  local files_collision=0
  local db_list=""
  local snap_type=""
  local created_target=0
  local man_json
  local unix_peek="" unix_name="" unix_shared=0 unix_prot=0 unix_uid="" unix_home=""
  local man_docroot=""
  man_json="$(hm_backup_cat_manifest "${remote_base}")"
  snap_type="$(hm_backup_json_str "${man_json}" "type")"
  man_docroot="$(hm_backup_json_str "${man_json}" "docroot")"

  if rclone cat "${remote_base}/unix-account.meta" >/dev/null 2>&1 \
    || rclone cat "${remote_base}/unix-account.meta.enc" >/dev/null 2>&1; then
    restore_unix=1
    unix_peek="$(hm_backup_peek_unix_meta "${remote_base}" 2>/dev/null || true)"
    if [[ -n "${unix_peek}" ]]; then
      IFS='|' read -r unix_name unix_shared unix_prot unix_uid unix_home <<< "${unix_peek}"
      unix_shared="${unix_shared:-0}"
      unix_prot="${unix_prot:-0}"
      if [[ -n "${unix_name}" ]] && id "${unix_name}" >/dev/null 2>&1; then
        if [[ "${unix_shared}" -eq 1 || "${unix_prot}" -eq 1 ]]; then
          skip_unix_shared=1
          # child/shared: pliki tylko do docroot (nie cały HOME mastera)
          if [[ -n "${man_docroot}" ]]; then
            target_dir="${man_docroot}"
            HM_SITE_DOCROOT="${man_docroot}"
          fi
          plan_steps+=("KOLIZJA Unix: \`${unix_name}\` shared/protected — POMIJAM usermod/hasło/klucze; pliki → ${target_dir}")
        else
          unix_collision=1
          if [[ "${adopt_user}" -eq 1 ]]; then
            plan_steps+=("KOLIZJA Unix: \`${unix_name}\` istnieje — ADOPT (--adopt-existing-user): nadpisanie hasła/kluczy/home")
          else
            plan_steps+=("KOLIZJA Unix: \`${unix_name}\` już istnieje — ODMÓW bez --adopt-existing-user")
          fi
        fi
      fi
    fi
  fi
  # Child archive często BEZ unix-account.meta — wykryj shared live (ten sam user na innej domenie)
  if [[ "${skip_unix_shared}" -eq 0 ]]; then
    local live_user="${HM_SITE_USER:-${unix_name:-}}"
    if [[ -z "${live_user}" ]]; then
      live_user="$(hm_backup_json_str "${man_json}" "site_user")"
    fi
    if [[ -n "${live_user}" ]] && hm_backup_site_user_shared_live "${live_user}" "${domain}"; then
      skip_unix_shared=1
      [[ -z "${HM_SITE_USER:-}" ]] && HM_SITE_USER="${live_user}"
      if [[ -n "${man_docroot}" ]]; then
        target_dir="${man_docroot}"
        HM_SITE_DOCROOT="${man_docroot}"
      fi
      plan_steps+=("KOLIZJA Unix: \`${live_user}\` współdzielony live z innymi domenami — POMIJAM usermod/hasło/klucze/cron; pliki → ${target_dir}")
    fi
  fi
  if rclone cat "${remote_base}/db-accounts.sql" >/dev/null 2>&1 \
    || rclone cat "${remote_base}/db-accounts.sql.enc" >/dev/null 2>&1; then
    restore_db_acc=1
  fi
  rclone cat "${remote_base}/ssl.tar.gz" >/dev/null 2>&1 && restore_ssl=1
  rclone cat "${remote_base}/crontab.txt" >/dev/null 2>&1 && restore_cron=1
  rclone cat "${remote_base}/cyberpanel-site.sql" >/dev/null 2>&1 && restore_cp=1

  if [[ "${db_only}" -eq 0 ]]; then
    if [[ "${restore_unix}" -eq 1 && "${skip_unix_shared}" -eq 0 ]]; then
      if [[ "${unix_collision}" -eq 0 ]]; then
        plan_steps+=("Odtworzenie konta Unix SSH z unix-account.meta (useradd/uid/gid/shadow + authorized_keys)")
      fi
    elif [[ "${skip_unix_shared}" -eq 1 ]]; then
      : # już dodane w KOLIZJA powyżej
    fi
    if hm_backup_dir_nonempty "${target_dir}"; then
      files_collision=1
      if [[ "${overwrite_files}" -eq 1 ]]; then
        plan_steps+=("KOLIZJA pliki: ${target_dir} niepusty — NADPISANIE (--overwrite-files)")
      else
        plan_steps+=("KOLIZJA pliki: ${target_dir} niepusty — ODMÓW bez --overwrite-files")
      fi
    fi
    plan_steps+=("Pobranie i rozpakowanie archiwum plików z ${remote_base} do ${target_dir} (tar --no-same-owner)")
    if rclone cat "${remote_base}/ols-vhost-dir.tar.gz" >/dev/null 2>&1 \
      || rclone cat "${remote_base}/ols-httpd-snippet.conf" >/dev/null 2>&1 \
      || rclone cat "${remote_base}/vhost.conf" >/dev/null 2>&1; then
      restore_ols=1
      plan_steps+=("Odtworzenie vhosta OLS (katalog ${OLS_VHOSTS:-vhosts}/${domain}, blok virtualhost + map w ${OLS_CONF:-httpd_config.conf})")
    fi
    if [[ "${restore_ssl}" -eq 1 ]]; then
      plan_steps+=("Odtworzenie SSL z ssl.tar.gz (symlinki live/ → archive/ zachowane)")
    fi
    if [[ "${restore_cron}" -eq 1 && "${skip_unix_shared}" -eq 0 ]]; then
      plan_steps+=("Odtworzenie crontab użytkownika ${HM_SITE_USER:-${unix_name:-?}} z crontab.txt")
    elif [[ "${restore_cron}" -eq 1 && "${skip_unix_shared}" -eq 1 ]]; then
      plan_steps+=("crontab: POMINIĘTY (shared/protected Unix — nie nadpisuję crona żywego konta)")
      restore_cron=0
    fi
    if [[ "${restore_cp}" -eq 1 ]]; then
      plan_steps+=("Odtworzenie wpisu CyberPanel z cyberpanel-site.sql (website/childdomains/databases)")
    fi
    if rclone cat "${remote_base}/pm2-processes.json" >/dev/null 2>&1; then
      plan_steps+=("PM2: tylko wskazówka (pm2-processes.json) — bez automatycznego startu procesów")
    fi
    if [[ -n "${HM_SITE_USER:-}" ]] || [[ "${restore_unix}" -eq 1 ]]; then
      local _own_user="${HM_SITE_USER:-${unix_name:-}}"
      if [[ -n "${_own_user}" ]] && ! id "${_own_user}" >/dev/null 2>&1 && [[ "${restore_unix}" -eq 0 ]]; then
        plan_steps+=("UWAGA Unix: user \`${_own_user}\` z manifestu NIE ISTNIEJE i brak unix-account.meta — pliki zostaną jako root (tar --no-same-owner); utwórz usera ręcznie lub użyj nowszego archive")
      else
        plan_steps+=("Właściciel plików: ${_own_user:-user}:${_own_user:-user} wewnątrz; public_html/docroot → grupa WWW (nogroup/lsadm), nie user:user")
      fi
    fi
  fi
  local db_collision=0
  if [[ "${files_only}" -eq 0 ]]; then
    db_list="$(rclone lsf "${remote_base}/db/" 2>/dev/null | grep '\.sql\.gz$' | sed 's|.*/||;s|\.sql\.gz$||' | paste -sd',' - || true)"
    [[ -z "${db_list}" ]] && db_list="$(rclone cat "${remote_base}/manifest.json" 2>/dev/null | grep -oE '"databases?"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 || true)"
    plan_steps+=("Pobranie i import zrzutów baz danych (${db_list:-z snapshota})")
    local _cdb
    IFS=',' read -r -a _cdb_arr <<< "${db_list}"
    local db_foreign=0
    for _cdb in "${_cdb_arr[@]}"; do
      _cdb="${_cdb// /}"
      [[ -n "${_cdb}" ]] || continue
      hm_is_valid_db_name "${_cdb}" || continue
      if [[ -n "${domain}" ]] && hm_backup_db_belongs_to_other_domain "${_cdb}" "${domain}"; then
        db_foreign=1
        plan_steps+=("ODMOWA: baza \`${_cdb}\` należy w CP do innej żywej domeny — bez importu (także z --overwrite-db)")
        continue
      fi
      if hm_backup_db_is_nonempty "${_cdb}"; then
        db_collision=1
        if [[ "${overwrite_db}" -eq 1 ]]; then
          plan_steps+=("KOLIZJA: baza \`${_cdb}\` niepusta — NADPISANIE (--overwrite-db)")
        else
          plan_steps+=("KOLIZJA: baza \`${_cdb}\` niepusta — ODMÓW bez --overwrite-db")
        fi
      fi
    done
    if [[ "${db_foreign}" -eq 1 ]]; then
      hm_err "ODMOWA: snapshot zawiera bazy należące w CyberPanel do innej żywej domeny — restore przerwany (ochrona danych mastera przy child)."
      for _ps in "${plan_steps[@]}"; do
        [[ "${_ps}" == ODMOWA:* ]] && printf '  %s\n' "${_ps}"
      done
      return 1
    fi
    if [[ "${restore_db_acc}" -eq 1 ]]; then
      plan_steps+=("Odtworzenie kont MySQL z db-accounts.sql (istniejące: bez DROP/CREATE; tylko GRANT-y snapshotu; nowe: CREATE + GRANTS)")
    fi
  fi
  plan_steps+=("Przeładowanie OpenLiteSpeed (ols reload)")

  local _ps
  if [[ "${unix_collision}" -eq 1 && "${adopt_user}" -ne 1 ]]; then
    hm_err "KOLIZJA Unix: konto ze snapshota już istnieje — odmowa (hasło/klucze/home żywego serwisu)."
    hm_info "Użyj --adopt-existing-user aby świadomie przejąć konto, albo przywróć na czysty serwer."
    for _ps in "${plan_steps[@]}"; do
      [[ "${_ps}" == KOLIZJA:* ]] && printf '  %s\n' "${_ps}"
    done
    return 1
  fi
  if [[ "${files_collision}" -eq 1 && "${overwrite_files}" -ne 1 ]]; then
    hm_err "KOLIZJA pliki: katalog docelowy ${target_dir} nie jest pusty — odmowa nadpisania żywego site'u."
    hm_info "Użyj --overwrite-files aby świadomie nadpisać pliki w miejscu."
    for _ps in "${plan_steps[@]}"; do
      [[ "${_ps}" == KOLIZJA:* ]] && printf '  %s\n' "${_ps}"
    done
    return 1
  fi
  if [[ "${db_collision}" -eq 1 && "${overwrite_db}" -ne 1 ]]; then
    hm_err "KOLIZJA: co najmniej jedna baza ze snapshota już istnieje i nie jest pusta."
    hm_info "Uruchom ponownie z --overwrite-db aby świadomie nadpisać (plan powyżej wymienia bazy)."
    for _ps in "${plan_steps[@]}"; do
      [[ "${_ps}" == KOLIZJA:* ]] && printf '  %s\n' "${_ps}"
    done
    return 1
  fi

  local warn_extra=""
  [[ "${snap_type}" == "archive" ]] && warn_extra=" Snapshot typu archive — Unix + OLS + pliki + SSL + cron + CP + DB + konta MySQL; PM2 ręcznie."
  [[ "${overwrite_db}" -eq 1 && "${db_collision}" -eq 1 ]] && warn_extra="${warn_extra} NADPISANIE niepustych baz (--overwrite-db)."
  [[ "${adopt_user}" -eq 1 && "${unix_collision}" -eq 1 ]] && warn_extra="${warn_extra} ADOPT istniejącego Unix (--adopt-existing-user)."
  [[ "${overwrite_files}" -eq 1 && "${files_collision}" -eq 1 ]] && warn_extra="${warn_extra} NADPISANIE niepustego katalogu (--overwrite-files)."

  if ! hm_confirm_plan_critical "${domain}" \
    "backup restore — ${domain} (${stamp})" \
    "Nadpisanie danych strony i/lub baz — operacja trudna do cofnięcia.${warn_extra}" \
    "${plan_steps[@]}"; then
    return 1
  fi

  # katalog docelowy dopiero PO potwierdzeniu — anulowanie nie zostawia pustego /home/<domena>
  if [[ ! -d "${target_dir}" ]]; then
    mkdir -p "${target_dir}" || { hm_err "Nie można utworzyć ${target_dir}"; return 1; }
    created_target=1
  fi

  # Unix PRZED plikami — chown i SSH działają od razu po rozpakowaniu
  if [[ "${db_only}" -eq 0 && "${restore_unix}" -eq 1 ]]; then
    # shared/protected: funkcja sama pominie mutacje; exclusive+collision wymaga adopt (już sprawdzone)
    local unix_home_arg="${target_dir}"
    if [[ "${skip_unix_shared}" -eq 1 ]]; then
      unix_home_arg=""
    fi
    if ! hm_backup_restore_unix_account "${remote_base}" "${unix_home_arg}" "${adopt_user}"; then
      hm_err "Odtworzenie konta Unix nieudane / kolizja — przerywam restore (pliki/DB nietknięte)."
      if [[ "${created_target}" -eq 1 ]]; then
        rmdir "${target_dir}" 2>/dev/null || true
      fi
      return 1
    fi
  fi

  if [[ "${db_only}" -eq 0 ]]; then
    if ! hm_backup_restore_files "${remote_base}" "${target_dir}"; then
      if [[ "${created_target}" -eq 1 ]]; then
        rmdir "${target_dir}" 2>/dev/null || true
      fi
      return 1
    fi
    if [[ "${restore_ols}" -eq 1 ]]; then
      hm_backup_restore_ols_from_archive "${domain}" "${remote_base}" || {
        hm_err "Restore OLS nieudany — pliki/DB mogą być już odtworzone; dokończ vhost ręcznie."
        return 1
      }
    fi
    if [[ -n "${HM_SITE_USER:-}" ]] && id "${HM_SITE_USER}" >/dev/null 2>&1; then
      hm_backup_restore_fix_ownership "${target_dir}" "${HM_SITE_USER}" "${HM_SITE_DOCROOT:-}" \
        || hm_warn "chown częściowo nieudany (kontynuuję)."
    elif [[ -n "${HM_SITE_USER:-}" ]] && ! id "${HM_SITE_USER}" >/dev/null 2>&1; then
      hm_warn "Unix user ${HM_SITE_USER} nie istnieje (brak unix-account.meta / useradd) — pliki w ${target_dir} mogą być root:root."
    fi
    if [[ "${restore_ssl}" -eq 1 ]]; then
      hm_backup_restore_ssl "${remote_base}" || hm_warn "SSL restore nieudany — sprawdź certbot/acme."
    fi
    if [[ "${restore_cron}" -eq 1 ]]; then
      hm_backup_restore_crontab "${remote_base}" "${HM_SITE_USER:-}" "${domain}" || true
    fi
    if [[ "${restore_cp}" -eq 1 ]]; then
      if ! hm_backup_restore_cyberpanel_site "${remote_base}" "${domain}"; then
        hm_err "CyberPanel SQL niezaimportowany — przerywam restore (rc≠0)."
        return 1
      fi
    fi
    hm_backup_restore_pm2_hint "${remote_base}" "${HM_SITE_USER:-}"
  fi

  if [[ "${files_only}" -eq 0 ]]; then
    hm_backup_restore_dbs "${remote_base}" "${overwrite_db}" "${domain}" || return 1
    if [[ "${restore_db_acc}" -eq 1 ]]; then
      hm_backup_restore_db_accounts "${remote_base}" || {
        hm_err "Odtworzenie kont MySQL nieudane — bazy są zaimportowane, nadaj GRANT ręcznie."
        return 1
      }
    fi
  fi

  hm_backup_ols_reload
  hm_ok "Restore ${domain} (${stamp}) zakończony."
}

hm_backup_restore() {
  local rc=0
  hm_load_config
  hm_backup_acquire_lock || return 1
  trap 'hm_backup_release_lock' RETURN
  hm_site_context_push
  _hm_backup_restore_body "$@" || rc=$?
  hm_site_context_pop
  return "${rc}"
}

# Odtwórz snapshot full/<stamp>/ — system-configs + databases + sites/* + db-accounts.
hm_backup_restore_full() {
  local stamp="" do_system=0 a
  # flagi przed stampem: restore-full --system [stamp]
  for a in "$@"; do
    case "${a}" in
      --system) do_system=1 ;;
      --help|-h)
        cat <<'EOF'
Użycie: backup restore-full [stamp] [--system]

Odtwarza snapshot full/: bazy + db-accounts.
--system — dodatkowo rozpakuj system-configs.tar.gz(.enc) do /
Bez stampu — najnowszy snapshot full/.
Pliki stron (sites/<domena>/) NIE są rozpakowywane tu — użyj backup restore <domena>.
EOF
        return 0
        ;;
      -*)
        hm_err "Nieznana flaga: ${a} (backup restore-full [stamp] [--system])"
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

  hm_load_config
  hm_detect_all
  hm_rclone_check || return 1
  hm_backup_acquire_lock || return 1
  trap 'hm_backup_release_lock' RETURN

  if [[ -z "${stamp}" ]]; then
    local list
    list="$(hm_backup_list_stamps "full")"
    if [[ -z "${list}" ]]; then
      hm_err "Brak snapshotów full/ na Drive."
      return 1
    fi
    printf '%s\n' "${list}" | head -20 | sed 's/^/  /'
    stamp="$(printf '%s\n' "${list}" | head -1)"
    hm_info "Wybrano najnowszy full: ${stamp}"
  fi
  [[ "${stamp}" =~ ^[0-9]{8}-[0-9]{6}$ ]] || { hm_err "Nieprawidłowy stamp: ${stamp}"; return 1; }

  local remote_base
  remote_base="$(hm_backup_dest_full "${stamp}")"
  if hm_backup_snapshot_is_incomplete "${remote_base}"; then
    hm_err "Snapshot full ${stamp} niepełny — odmowa restore."
    return 1
  fi

  hm_backup_abort_if_enc_without_passphrase "${remote_base}" || return 1

  local -a plan=(
    "Opcjonalnie: system-configs.tar.gz(.enc) → / (OSTROŻNIE — nadpisze /etc bez shadow; tylko z --system)"
    "Import wszystkich baz z ${remote_base}/databases/*.sql.gz"
    "Odtworzenie kont MySQL z db-accounts.sql(.enc) jeśli obecne"
    "Listing sites/<domena>/ w snapshocie — BEZ rozpakowania plików (użyj: backup restore <domena>)"
  )
  if ! hm_confirm_plan_critical "full" \
    "backup restore-full — ${stamp}" \
    "Pełny restore serwera — trudny do cofnięcia. system-configs domyślnie POMIJANE (flaga --system)." \
    "${plan[@]}"; then
    return 1
  fi

  if [[ "${do_system}" -eq 1 ]]; then
    local sys_tmp
    sys_tmp="$(mktemp "${TMP_DIR:-/tmp}/hmtools-sys.XXXXXX.tar.gz")"
    if hm_backup_fetch_maybe_decrypt "${remote_base}" "system-configs.tar.gz" "${sys_tmp}"; then
      hm_warn "Rozpakowuję system-configs do / (bez shadow w archiwum)…"
      tar -xzf "${sys_tmp}" -C / 2>/dev/null || hm_warn "Częściowy błąd tar system-configs."
      hm_ok "system-configs zastosowane."
    else
      hm_warn "Brak system-configs.tar.gz(.enc)."
    fi
    rm -f "${sys_tmp}"
  else
    hm_info "Pomijam system-configs (dodaj --system aby zastosować)."
  fi

  # Bazy
  local f name cli sock_args=()
  cli="$(hm_mysql_cli)" || { hm_err "Brak mysql."; return 1; }
  [[ -n "${MYSQL_SOCKET:-}" ]] && sock_args=(--socket="${MYSQL_SOCKET}")
  while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    name="${f%.sql.gz}"
    name="${name##*/}"
    hm_is_valid_db_name "${name}" || continue
    hm_info "Import DB ${name}…"
    "${cli}" "${sock_args[@]}" -e "CREATE DATABASE IF NOT EXISTS \`${name}\`;" 2>/dev/null || true
    rclone cat "${remote_base}/databases/${name}.sql.gz" | gunzip -c | "${cli}" "${sock_args[@]}" "${name}" \
      || hm_warn "Import ${name} nieudany."
  done < <(rclone lsf "${remote_base}/databases/" 2>/dev/null | grep '\.sql\.gz$' || true)

  hm_backup_restore_db_accounts "${remote_base}" || hm_warn "db-accounts restore nieudany."

  hm_info "Strony: użyj backup restore <domena> dla poszczególnych vhostów albo rozpakuj sites/<domena>/ ręcznie."
  local site
  while IFS= read -r site; do
    [[ -n "${site}" ]] || continue
    hm_info "  dostępne w snapshocie: sites/${site}/"
  done < <(rclone lsd "${remote_base}/sites/" 2>/dev/null | awk '{print $NF}' || true)

  hm_ok "restore-full ${stamp} — bazy/konta zakończone (pliki stron: per-domena)."
}
