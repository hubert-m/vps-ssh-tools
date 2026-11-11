#!/usr/bin/env bash
# Wiersze TSV i obiekty --json dla list/statusów. Fixture: $HM_JSON_DIR/<nazwa>.tsv

if [[ -n "${HM_JSON_EMIT_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HM_JSON_EMIT_LOADED=1

hm_json_fixture() {
  local name="${1:-}" f
  f="${HM_JSON_DIR:-}/${name}.tsv"
  [[ -n "${HM_JSON_DIR:-}" && -f "${f}" ]] || return 1
  grep -v '^#' "${f}" 2>/dev/null | grep -v '^[[:space:]]*$' || true
  return 0
}

hm_json_row_obj() {
  local line="${1:-}"
  shift
  line="${line%$'\r'}"
  local -a fields=()
  IFS=$'\t' read -r -a fields <<<"${line}"
  local pair name typ val i=0
  local -a args=()
  for pair in "$@"; do
    name="${pair%%:*}"
    typ="${pair##*:}"
    val="${fields[$i]:-}"
    args+=("${name}" "${typ}" "${val}")
    i=$((i + 1))
  done
  hm_json_obj "${args[@]}"
}

# hm_json_table klucz specyfikacja funkcja [argumenty...]
# spec: domain:s,size_bytes:n,ok:b
hm_json_table() {
  local key="${1:-items}" spec="${2:-}" fn="${3:-}"
  shift 3 || true
  [[ -n "${fn}" ]] || return 1
  local tmp rc=0 line obj items="" sep=""
  tmp="$(mktemp "${TMP_DIR:-/tmp}/hmtools-json.XXXXXX")" || return 1
  "${fn}" "$@" >"${tmp}" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    rm -f "${tmp}"
    return "${rc}"
  fi
  local -a pairs=()
  IFS=',' read -r -a pairs <<<"${spec}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    obj="$(hm_json_row_obj "${line}" "${pairs[@]}")"
    items+="${sep}${obj}"
    sep=","
  done <"${tmp}"
  rm -f "${tmp}"
  printf '{%s:[%s]}\n' "$(hm_json_q "${key}")" "${items}"
}

hm_rows_webs() {
  local quick="${1:-0}" suspended="${2:-0}" line st
  if [[ -n "${HM_JSON_DIR:-}" && -f "${HM_JSON_DIR}/webs.tsv" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ -n "${line}" && "${line}" != \#* ]] || continue
      if [[ "${suspended}" == "1" ]]; then
        st="$(printf '%s\n' "${line}" | awk -F '\t' '{ print $5 }')"
        [[ "${st}" == "suspended" ]] || continue
      fi
      printf '%s\n' "${line%$'\r'}"
    done <"${HM_JSON_DIR}/webs.tsv"
    return 0
  fi
  declare -F hm_discover_sites >/dev/null 2>&1 || return 0
  hm_discover_sites || return 1
  local domain row site_root php rest status ssl size_bytes
  for domain in "${HM_SITES_LIST[@]:-}"; do
    [[ -n "${domain}" ]] || continue
    row="$(hm_resolve_site_paths "${domain}" 2>/dev/null || true)"
    site_root=""
    php=""
    rest=""
    if [[ -n "${row}" ]]; then
      IFS=$'\t' read -r _ site_root _ _ _ php rest <<<"${row}"
    fi
    status="${rest##*|}"
    [[ -n "${status}" ]] || status="active"
    if [[ "${suspended}" == "1" && "${status}" != "suspended" ]]; then
      continue
    fi
    ssl="no"
    if declare -F hm_ssl_has >/dev/null 2>&1; then
      ssl="$(hm_ssl_has "${domain}" 2>/dev/null || echo no)"
    fi
    size_bytes=0
    if [[ "${quick}" != "1" && -n "${site_root}" && -d "${site_root}" ]] && declare -F hm_dir_size_bytes >/dev/null 2>&1; then
      size_bytes="$(hm_dir_size_bytes "${site_root}" 2>/dev/null || echo 0)"
    fi
    [[ "${size_bytes}" =~ ^[0-9]+$ ]] || size_bytes=0
    printf '%s\t%s\t%s\t%s\t%s\n' "${domain}" "${php}" "${ssl}" "${size_bytes}" "${status}"
  done
}

hm_rows_wp() {
  if hm_json_fixture wp; then
    return 0
  fi
  declare -F hm_discover_sites >/dev/null 2>&1 || return 0
  if declare -F hm_wp_ensure_cli >/dev/null 2>&1; then
    hm_wp_ensure_cli >/dev/null || return 1
  fi
  hm_discover_sites || return 1
  local d row doc php path ver updp updt maint
  for d in "${HM_SITES_LIST[@]:-}"; do
    [[ -n "${d}" ]] || continue
    row="$(hm_resolve_site_paths "${d}" 2>/dev/null || true)"
    [[ -n "${row}" ]] || continue
    IFS=$'\t' read -r _ _ doc _ _ php _ <<<"${row}"
    path=""
    if declare -F hm_wp_find_path >/dev/null 2>&1; then
      path="$(hm_wp_find_path "${doc}" 2>/dev/null || true)"
    fi
    [[ -n "${path}" ]] || continue
    ver=""
    updp=0
    updt=0
    maint="off"
    if [[ -f "${path}/.maintenance" ]]; then
      maint="on"
    fi
    if declare -F hm_wp_run >/dev/null 2>&1 && declare -F hm_site_context_push >/dev/null 2>&1; then
      if hm_site_context_push "${d}" 2>/dev/null; then
        ver="$(hm_wp_run 1 core version 2>/dev/null | tr -d '\r' | tail -1 || true)"
        updp="$(hm_wp_run 1 plugin list --update=available --field=name 2>/dev/null | grep -c . || true)"
        updt="$(hm_wp_run 1 theme list --update=available --field=name 2>/dev/null | grep -c . || true)"
        hm_site_context_pop 2>/dev/null || true
      fi
    fi
    [[ "${updp}" =~ ^[0-9]+$ ]] || updp=0
    [[ "${updt}" =~ ^[0-9]+$ ]] || updt=0
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${d}" "${ver}" "${updp}" "${updt}" "${maint}" "${php}"
  done
}

hm_rows_ssl() {
  if hm_json_fixture ssl; then
    return 0
  fi
  declare -F hm_discover_sites >/dev/null 2>&1 || return 0
  hm_discover_sites || return 1
  local domain cert status days expiry
  for domain in "${HM_SITES_LIST[@]:-}"; do
    [[ -n "${domain}" ]] || continue
    cert=""
    if declare -F hm_ssl_paths_for_domain >/dev/null 2>&1; then
      cert="$(hm_ssl_paths_for_domain "${domain}" 2>/dev/null || true)"
    fi
    if [[ -z "${cert}" ]]; then
      printf '%s\t%s\t%s\t%s\n' "${domain}" "missing" "0" ""
      continue
    fi
    status="unknown"
    days=0
    expiry=""
    if declare -F hm_ssl_status >/dev/null 2>&1; then
      status="$(hm_ssl_status "${cert}" 2>/dev/null || echo unknown)"
    fi
    if declare -F hm_ssl_days_left >/dev/null 2>&1; then
      days="$(hm_ssl_days_left "${cert}" 2>/dev/null || echo 0)"
    fi
    if declare -F hm_ssl_expiry >/dev/null 2>&1; then
      expiry="$(hm_ssl_expiry "${cert}" 2>/dev/null || true)"
    fi
    [[ "${days}" =~ ^-?[0-9]+$ ]] || days=0
    printf '%s\t%s\t%s\t%s\n' "${domain}" "${status}" "${days}" "${expiry}"
  done
}

hm_rows_services() {
  if hm_json_fixture services; then
    return 0
  fi
  local name unit active enabled
  local names="lsws lscpd mariadb postfix dovecot pdns pure-ftpd opendkim redis fail2ban cron docker supervisor sshd openvpn"
  for name in ${names}; do
    unit=""
    if declare -F hm_services_resolve_unit >/dev/null 2>&1; then
      unit="$(hm_services_resolve_unit "${name}" 2>/dev/null || true)"
    fi
    [[ -n "${unit}" ]] || continue
    active="unknown"
    enabled="unknown"
    if command -v systemctl >/dev/null 2>&1; then
      active="$(systemctl is-active "${unit}" 2>/dev/null || echo inactive)"
      enabled="$(systemctl is-enabled "${unit}" 2>/dev/null || echo unknown)"
    fi
    printf '%s\t%s\t%s\t%s\n' "${name}" "${unit}" "${active}" "${enabled}"
  done
}

hm_metrics_stamp_age() {
  local stamp="${1:-}" now="${2:-}" ts=""
  [[ "${stamp}" =~ ^[0-9]{8}-[0-9]{6}$ ]] || return 1
  [[ "${now}" =~ ^[0-9]+$ ]] || now="$(date +%s)"
  ts="$(date -d "${stamp:0:4}-${stamp:4:2}-${stamp:6:2} ${stamp:9:2}:${stamp:11:2}:${stamp:13:2}" +%s 2>/dev/null || true)"
  [[ "${ts}" =~ ^[0-9]+$ ]] || return 1
  if [[ "${now}" -ge "${ts}" ]]; then
    printf '%s' "$((now - ts))"
  else
    printf '0'
  fi
}

hm_rows_backup_list() {
  if hm_json_fixture backup-list; then
    return 0
  fi
  local root="${HM_BACKUP_LOCAL_ROOT:-${BACKUP_LOCAL_ROOT:-}}"
  [[ -n "${root}" && -d "${root}" ]] || return 0
  local now dir stamp scope age ok
  now="${HM_METRICS_NOW:-}"
  [[ "${now}" =~ ^[0-9]+$ ]] || now="$(date +%s)"
  for dir in "${root}"/*/*; do
    [[ -d "${dir}" ]] || continue
    stamp="$(basename "${dir}")"
    [[ "${stamp}" =~ ^[0-9]{8}-[0-9]{6}$ ]] || continue
    scope="$(basename "$(dirname "${dir}")")"
    age="$(hm_metrics_stamp_age "${stamp}" "${now}" 2>/dev/null || echo 0)"
    if [[ -e "${dir}/FAILED" ]]; then
      ok="false"
    else
      ok="true"
    fi
    printf '%s\t%s\t%s\t%s\n' "${scope}" "${stamp}" "${age}" "${ok}"
  done
}

hm_rows_backup_targets() {
  if hm_json_fixture backup-targets; then
    return 0
  fi
  if ! declare -F hm_backup_target_names >/dev/null 2>&1; then
    return 0
  fi
  local name spec kind def="0"
  local default_name=""
  if declare -F hm_backup_default_target_name >/dev/null 2>&1; then
    default_name="$(hm_backup_default_target_name 2>/dev/null || true)"
  fi
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    spec=""
    if declare -F hm_backup_target_spec >/dev/null 2>&1; then
      spec="$(hm_backup_target_spec "${name}" 2>/dev/null || true)"
    fi
    kind="${spec%%:*}"
    [[ -n "${kind}" ]] || kind="rclone"
    if [[ "${name}" == "${default_name}" ]]; then
      def="true"
    else
      def="false"
    fi
    printf '%s\t%s\t%s\t%s\n' "${name}" "${kind}" "${spec}" "${def}"
  done < <(hm_backup_target_names 2>/dev/null || true)
}

hm_rows_security_status() {
  if hm_json_fixture security-status; then
    return 0
  fi
  local fw="unknown" f2b="absent" bans=0 upd="-1"
  if declare -F hm_os_firewall_backend >/dev/null 2>&1; then
    fw="$(hm_os_firewall_backend 2>/dev/null || echo unknown)"
  fi
  if [[ -n "${HM_METRICS_BANS:-}" ]]; then
    bans="${HM_METRICS_BANS}"
    f2b="present"
  elif command -v fail2ban-client >/dev/null 2>&1; then
    f2b="present"
    bans="$(fail2ban-client status 2>/dev/null | awk -F: '/Currently banned/ { gsub(/ /,"",$2); s+=$2 } END { print s+0 }' || echo 0)"
  fi
  if [[ -n "${HM_SEC_AUDIT_SEC_UPDATES:-}" ]]; then
    upd="${HM_SEC_AUDIT_SEC_UPDATES}"
  elif declare -F hm_pkg_list_security >/dev/null 2>&1; then
    upd="$(hm_pkg_list_security 2>/dev/null | grep -c . || true)"
  fi
  [[ "${bans}" =~ ^[0-9]+$ ]] || bans=0
  [[ "${upd}" =~ ^-?[0-9]+$ ]] || upd="-1"
  printf '%s\t%s\t%s\t%s\n' "${fw}" "${f2b}" "${bans}" "${upd}"
}

hm_rows_ports() {
  if hm_json_fixture ports; then
    return 0
  fi
  if ! command -v ss >/dev/null 2>&1; then
    hm_err "Brak ss (iproute2)."
    return 1
  fi
  local line proto addr port proc re
  re='users:\(\("([^"]+)"'
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    proto="${line%% *}"
    addr="$(printf '%s\n' "${line}" | awk '{ print $4 }')"
    case "${addr}" in
      0.0.0.0:*|\[::\]:*|\*:*) ;;
      *) continue ;;
    esac
    port="${addr##*:}"
    port="${port%\]}"
    [[ "${port}" =~ ^[0-9]+$ ]] || continue
    proc=""
    if [[ "${line}" =~ ${re} ]]; then
      proc="${BASH_REMATCH[1]}"
    fi
    printf '%s\t%s\t%s\t%s\n' "${port}" "${proto}" "${addr}" "${proc}"
  done < <(ss -lntup 2>/dev/null || true)
}

hm_rows_node() {
  if hm_json_fixture node; then
    return 0
  fi
  declare -F hm_discover_sites >/dev/null 2>&1 || return 0
  declare -F hm_node_probe_site >/dev/null 2>&1 || return 0
  hm_discover_sites || return 1
  local d line nvm npm
  for d in "${HM_SITES_LIST[@]:-}"; do
    [[ -n "${d}" ]] || continue
    line="$(hm_node_probe_site "${d}" 2>/dev/null || true)"
    [[ -n "${line}" ]] || continue
    IFS=$'\t' read -r _ _ _ nvm _ npm <<<"${line}"
    [[ "${nvm}" == "-" ]] && nvm=""
    [[ "${npm}" == "-" ]] && npm=""
    printf '%s\t%s\t%s\n' "${d}" "${nvm}" "${npm}"
  done
}

hm_rows_docker() {
  if hm_json_fixture docker; then
    return 0
  fi
  if ! declare -F hm_docker_require >/dev/null 2>&1; then
    hm_err "Brak modułu docker."
    return 1
  fi
  hm_docker_require || return 1
  if ! declare -F hm_docker_list_raw >/dev/null 2>&1; then
    hm_err "Brak listy kontenerów."
    return 1
  fi
  local line name image status ports
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    IFS='|' read -r name image status ports _ <<<"${line}"
    printf '%s\t%s\t%s\t%s\n' "${name}" "${image}" "${status}" "${ports}"
  done < <(hm_docker_list_raw)
}

hm_rows_limits() {
  if hm_json_fixture limits; then
    return 0
  fi
  declare -F hm_discover_sites >/dev/null 2>&1 || return 0
  hm_discover_sites 2>/dev/null || true
  local d row user site_root doc path bytes props cpu mem io drop uid
  local n=0
  for d in "${HM_SITES_LIST[@]:-}"; do
    [[ -n "${d}" ]] || continue
    n=$((n + 1))
    [[ "${n}" -le 80 ]] || break
    row="$(hm_resolve_site_paths "${d}" 2>/dev/null || true)"
    user=""
    site_root=""
    doc=""
    if [[ -n "${row}" ]]; then
      IFS=$'\t' read -r _ site_root doc _ _ _ user _ <<<"${row}"
    fi
    path="${site_root:-${doc}}"
    bytes=0
    if [[ -n "${path}" && -d "${path}" ]] && declare -F hm_dir_size_bytes >/dev/null 2>&1; then
      bytes="$(hm_dir_size_bytes "${path}" 2>/dev/null || echo 0)"
    fi
    [[ "${bytes}" =~ ^[0-9]+$ ]] || bytes=0
    cpu=""
    mem=""
    io=""
    if [[ -n "${user}" && "${user}" != "-" ]] && declare -F hm_limits_uid_for_user >/dev/null 2>&1; then
      uid="$(hm_limits_uid_for_user "${user}" 2>/dev/null || true)"
      if [[ -n "${uid}" ]] && declare -F hm_limits_slice_dropin_file >/dev/null 2>&1; then
        drop="$(hm_limits_slice_dropin_file "${uid}" 2>/dev/null || true)"
        if [[ -n "${drop}" ]] && declare -F hm_limits_read_dropin_props >/dev/null 2>&1; then
          props="$(hm_limits_read_dropin_props "${drop}" 2>/dev/null || true)"
          cpu="$(printf '%s\n' "${props}" | awk '{ for (i=1;i<=NF;i++) if ($i ~ /^cpu=/) { sub(/^cpu=/,"",$i); print $i } }')"
          mem="$(printf '%s\n' "${props}" | awk '{ for (i=1;i<=NF;i++) if ($i ~ /^mem=/) { sub(/^mem=/,"",$i); print $i } }')"
          io="$(printf '%s\n' "${props}" | awk '{ for (i=1;i<=NF;i++) if ($i ~ /^io=/) { sub(/^io=/,"",$i); print $i } }')"
        fi
      fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${d}" "${user}" "${bytes}" "${cpu}" "${mem}" "${io}"
  done
}

hm_rows_disk() {
  if hm_json_fixture disk; then
    return 0
  fi
  if ! command -v df >/dev/null 2>&1; then
    hm_err "Brak df."
    return 1
  fi
  df -P 2>/dev/null | awk 'NR>1 && NF>=6 {
    cap=$5
    gsub(/%/,"",cap)
    avail=$4
    fs=$1
    mount=$6
    for (i=7; i<=NF; i++) mount=mount " " $i
    printf "%s\t%s\t%s\t%s\n", mount, cap, avail, fs
  }' || {
    hm_err "df nie zwrócił listy systemów plików."
    return 1
  }
}

hm_rows_mysql() {
  if hm_json_fixture mysql; then
    return 0
  fi
  if ! declare -F hm_list_all_databases >/dev/null 2>&1; then
    hm_err "Brak listy baz MySQL."
    return 1
  fi
  local db size
  while IFS= read -r db; do
    [[ -n "${db}" ]] || continue
    size=0
    if declare -F hm_db_size_bytes >/dev/null 2>&1; then
      size="$(hm_db_size_bytes "${db}" 2>/dev/null || echo 0)"
    fi
    [[ "${size}" =~ ^[0-9]+$ ]] || size=0
    printf '%s\t%s\n' "${db}" "${size}"
  done < <(hm_list_all_databases)
}

hm_rows_http() {
  if hm_json_fixture http; then
    return 0
  fi
  local latest="${HM_MONITOR_LATEST:-}"
  if [[ -z "${latest}" ]] && declare -F hm_monitor_dir >/dev/null 2>&1; then
    latest="$(hm_monitor_dir)/latest.txt"
  fi
  [[ -n "${latest}" && -f "${latest}" ]] || return 0
  local line dom code _ms _tls status up
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    IFS=$'\t' read -r dom code _ms _tls status _ <<<"${line}"
    up="false"
    if [[ "${status}" == "ok" || "${code}" == "200" ]]; then
      up="true"
    fi
    printf '%s\t%s\t%s\n' "${dom}" "${up}" "${code}"
  done <"${latest}"
}

hm_json_emit() {
  local kind="${1:-}"
  shift || true
  if ! declare -F hm_json_obj >/dev/null 2>&1; then
    hm_err "Brak helpera JSON."
    return 1
  fi
  case "${kind}" in
    webs)
      hm_json_table sites "domain:s,php:s,ssl:s,size_bytes:n,status:s" hm_rows_webs "$@"
      ;;
    wp)
      hm_json_table sites "domain:s,version:s,plugins:n,themes:n,maintenance:s,php:s" hm_rows_wp "$@"
      ;;
    ssl)
      hm_json_table certs "domain:s,status:s,days:n,expiry:s" hm_rows_ssl "$@"
      ;;
    services)
      hm_json_table services "name:s,unit:s,active:s,enabled:s" hm_rows_services "$@"
      ;;
    backup_list)
      hm_json_table snapshots "scope:s,stamp:s,age_seconds:n,ok:b" hm_rows_backup_list "$@"
      ;;
    backup_targets)
      hm_json_table targets "name:s,kind:s,spec:s,default:b" hm_rows_backup_targets "$@"
      ;;
    security_status)
      local line fw f2b bans upd
      line="$(hm_rows_security_status | head -1 || true)"
      if [[ -z "${line}" ]]; then
        hm_err "Brak statusu security."
        return 1
      fi
      IFS=$'\t' read -r fw f2b bans upd <<<"${line}"
      hm_json_obj firewall s "${fw}" fail2ban s "${f2b}" bans n "${bans}" updates_pending n "${upd}"
      printf '\n'
      ;;
    ports)
      hm_json_table ports "port:n,proto:s,address:s,process:s" hm_rows_ports "$@"
      ;;
    node)
      hm_json_table sites "domain:s,nvm:s,npm:s" hm_rows_node "$@"
      ;;
    docker)
      hm_json_table containers "name:s,image:s,status:s,ports:s" hm_rows_docker "$@"
      ;;
    limits)
      hm_json_table sites "domain:s,user:s,disk_bytes:n,cpu:s,mem:s,io:s" hm_rows_limits "$@"
      ;;
    disk)
      hm_json_table filesystems "mount:s,used_percent:n,avail_kb:n,fstype:s" hm_rows_disk "$@"
      ;;
    mysql)
      hm_json_table databases "name:s,size_bytes:n" hm_rows_mysql "$@"
      ;;
    *)
      hm_err "Nieznany eksport JSON: ${kind}"
      return 1
      ;;
  esac
}
