#!/usr/bin/env bash
# Backup: restore plików i baz

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
