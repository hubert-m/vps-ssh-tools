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
      if ! rclone cat "${remote_base}/files.tar.gz" | tar -xzf - -C "${target_dir}"; then
        hm_err "Rozpakowanie files.tar.gz nieudane."
        return 1
      fi
      ;;
    chunks)
      hm_info "Odtwarzanie plików (chunks → stream) → ${target_dir}"
      local part
      local -a chunk_parts=()
      while IFS= read -r part; do
        [[ -n "${part}" ]] && chunk_parts+=("${part}")
      done < <(rclone lsf "${remote_base}/files.chunks/" 2>/dev/null | grep 'files\.tar\.gz\.part_' | sort)
      local ctotal="${#chunk_parts[@]}"
      [[ "${ctotal}" -gt 0 ]] || { hm_err "Brak plików part_* w files.chunks."; return 1; }
      hm_status_line "Stream ${ctotal} chunków → tar (może potrwać)..."
      # łączenie part_* w kolejności bez lokalnego pełnego archiwum
      if ! (
        for part in "${chunk_parts[@]}"; do
          rclone cat "${remote_base}/files.chunks/${part}" || exit 1
        done
      ) | tar -xzf - -C "${target_dir}"; then
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
  local db di=0 dtotal=0
  for db in "${_dbs[@]}"; do
    [[ -n "${db}" ]] && dtotal=$((dtotal + 1))
  done
  for db in "${_dbs[@]}"; do
    [[ -n "${db}" ]] || continue
    hm_is_valid_db_name "${db}" || { hm_warn "Pominięto nieprawidłową nazwę bazy: ${db}"; continue; }
    di=$((di + 1))
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

# Wstaw linie map <domain> do każdego bloku listener { } (case-insensitive).
hm_ols_insert_maps_into_listeners() {
  local conf="$1"
  shift
  local -a maps=("$@")
  [[ "${#maps[@]}" -gt 0 && -f "${conf}" ]] || return 0
  local tmp maps_file
  tmp="$(mktemp)"
  maps_file="$(mktemp)"
  printf '%s\n' "${maps[@]}" > "${maps_file}"
  awk -v mf="${maps_file}" '
    BEGIN {
      while ((getline m < mf) > 0) {
        if (m != "") maps[++nmap] = m
      }
      close(mf)
      in_listener=0; depth=0
    }
    {
      first=tolower($1)
      if (!in_listener && first=="listener") {
        in_listener=1; depth=0
        if ($0 ~ /\{/) depth=1
        print
        next
      }
      if (in_listener) {
        if ($0 ~ /\{/) depth++
        if ($0 ~ /\}/) {
          depth--
          if (depth <= 0) {
            for (i=1; i<=nmap; i++) print "  " maps[i]
            in_listener=0; depth=0
          }
        }
        print
        next
      }
      print
    }
  ' "${conf}" > "${tmp}" && mv "${tmp}" "${conf}" || rm -f "${tmp}"
  rm -f "${maps_file}"
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

  local vh_tmp maps_tmp line in_vh=0 depth=0
  vh_tmp="$(mktemp)"
  maps_tmp="$(mktemp)"
  : > "${vh_tmp}"
  : > "${maps_tmp}"

  while IFS= read -r line || [[ -n "${line}" ]]; do
    local first second
    first="$(printf '%s' "${line}" | awk '{print tolower($1)}')"
    second="$(printf '%s' "${line}" | awk '{print $2}' | tr -d '{')"
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
      printf '%s\n' "${line}" >> "${maps_tmp}"
    fi
  done < "${snip}"

  if [[ -s "${vh_tmp}" ]]; then
    {
      echo
      echo "# hmtools restore — ${domain}"
      cat "${vh_tmp}"
    } >> "${conf}"
  fi

  local -a map_lines=()
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] && map_lines+=("${line}")
  done < "${maps_tmp}"
  rm -f "${vh_tmp}" "${maps_tmp}"

  if [[ "${#map_lines[@]}" -gt 0 ]]; then
    hm_ols_insert_maps_into_listeners "${conf}" "${map_lines[@]}"
  fi
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
        if [[ -z "${HM_SITE_VHOST:-}" && -f "${vhosts}/${domain}/vhconf.conf" ]]; then
          HM_SITE_VHOST="${vhosts}/${domain}/vhconf.conf"
        fi
      else
        hm_err "Rozpakowanie ols-vhost-dir.tar.gz nieudane."
        return 1
      fi
    fi
  fi

  # 2) pojedynczy vhost.conf → vhconf / HM_SITE_VHOST
  if rclone cat "${remote_base}/vhost.conf" >/dev/null 2>&1; then
    local dest_vh="${HM_SITE_VHOST:-}"
    if [[ -z "${dest_vh}" && -n "${vhosts}" ]]; then
      mkdir -p "${vhosts}/${domain}"
      dest_vh="${vhosts}/${domain}/vhconf.conf"
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

  local domain_arg="${domain}"
  local resolved=""
  if [[ -n "${HM_SITE_DOMAIN}" && "${HM_SITE_DOMAIN}" == "${domain_arg}" ]]; then
    resolved="${domain_arg}"
  else
    resolved="$(hm_find_site_by_arg "${domain_arg}" 2>/dev/null || true)"
  fi

  if [[ -n "${resolved}" ]]; then
    domain="${resolved}"
    hm_set_site_context "${domain}"
  else
    # zarchiwizowana / usunięta z VPS — przywróć z Drive po nazwie domeny
    domain="${domain_arg}"
    hm_info "Domena ${domain} nie jest na lokalnej liście VPS — szukam snapshotów na Drive…"
    if [[ -z "$(hm_backup_list_stamps "${domain}" | head -1)" ]]; then
      hm_err "Brak snapshotów na Drive dla ${domain} i brak lokalnej strony."
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

  target_dir="${HM_SITE_ROOT:-}"
  if [[ -z "${target_dir}" || ! -d "${target_dir}" ]]; then
    target_dir="${HM_SITE_DOCROOT:-}"
  fi
  if [[ -z "${target_dir}" || ! -d "${target_dir}" ]]; then
    local json
    json="$(hm_backup_cat_manifest "${remote_base}")"
    target_dir="$(hm_backup_json_str "${json}" "site_root")"
    [[ -z "${target_dir}" ]] && target_dir="$(hm_backup_json_str "${json}" "docroot")"
    [[ -z "${HM_SITE_USER:-}" ]] && HM_SITE_USER="$(hm_backup_json_str "${json}" "site_user")"
    [[ -z "${HM_SITE_PHP:-}" ]] && HM_SITE_PHP="$(hm_backup_json_str "${json}" "php")"
    [[ -z "${HM_SITE_DOCROOT:-}" ]] && HM_SITE_DOCROOT="$(hm_backup_json_str "${json}" "docroot")"
    [[ -z "${HM_SITE_ROOT:-}" ]] && HM_SITE_ROOT="$(hm_backup_json_str "${json}" "site_root")"
    HM_SITE_DOMAIN="${domain}"
  fi
  [[ -n "${target_dir}" ]] || { hm_err "Brak katalogu docelowego strony (manifest bez site_root/docroot)."; return 1; }
  if [[ ! -d "${target_dir}" ]]; then
    mkdir -p "${target_dir}" || { hm_err "Nie można utworzyć ${target_dir}"; return 1; }
  fi

  hm_backup_check_space || return 1

  local -a plan_steps=()
  local restore_ols=0
  local db_list=""
  local snap_type=""
  snap_type="$(hm_backup_json_str "$(hm_backup_cat_manifest "${remote_base}")" "type")"

  if [[ "${db_only}" -eq 0 ]]; then
    plan_steps+=("Pobranie i rozpakowanie archiwum plików z ${remote_base} do ${target_dir} (nadpisanie plików strony)")
    if rclone cat "${remote_base}/ols-vhost-dir.tar.gz" >/dev/null 2>&1 \
      || rclone cat "${remote_base}/ols-httpd-snippet.conf" >/dev/null 2>&1 \
      || rclone cat "${remote_base}/vhost.conf" >/dev/null 2>&1; then
      restore_ols=1
      plan_steps+=("Odtworzenie vhosta OLS (katalog ${OLS_VHOSTS:-vhosts}/${domain}, blok virtualhost + map w ${OLS_CONF:-httpd_config.conf})")
    fi
    if [[ -n "${HM_SITE_USER:-}" ]] && id "${HM_SITE_USER}" >/dev/null 2>&1; then
      plan_steps+=("Ustawienie właściciela plików chown -R ${HM_SITE_USER}:${HM_SITE_USER} na ${target_dir}")
    fi
  fi
  if [[ "${files_only}" -eq 0 ]]; then
    db_list="$(rclone lsf "${remote_base}/db/" 2>/dev/null | grep '\.sql\.gz$' | sed 's|.*/||;s|\.sql\.gz$||' | paste -sd',' - || true)"
    [[ -z "${db_list}" ]] && db_list="$(rclone cat "${remote_base}/manifest.json" 2>/dev/null | grep -oE '"databases?"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 || true)"
    plan_steps+=("Pobranie i import zrzutów baz danych (${db_list:-z snapshota}) z nadpisaniem tabel")
  fi
  plan_steps+=("Przeładowanie OpenLiteSpeed (ols reload)")

  local warn_extra=""
  [[ "${snap_type}" == "archive" ]] && warn_extra=" Snapshot typu archive — odtwarzanie po usunięciu strony z VPS (vhost OLS + pliki + DB)."

  if ! hm_confirm_plan_critical "${domain}" \
    "backup restore — ${domain} (${stamp})" \
    "Nadpisanie danych strony i/lub baz — operacja trudna do cofnięcia.${warn_extra}" \
    "${plan_steps[@]}"; then
    return 0
  fi

  if [[ "${db_only}" -eq 0 ]]; then
    hm_backup_restore_files "${remote_base}" "${target_dir}" || return 1
    if [[ "${restore_ols}" -eq 1 ]]; then
      hm_backup_restore_ols_from_archive "${domain}" "${remote_base}" || {
        hm_err "Restore OLS nieudany — pliki/DB mogą być już odtworzone; dokończ vhost ręcznie."
        return 1
      }
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
