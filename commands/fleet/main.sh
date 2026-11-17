#!/usr/bin/env bash
# fleet — multi-server: inwentarz, równoległe hmtools na VPS, zbiorcze raporty.

_hm_cmd_help fleet <<'EOF'
Użycie:
  fleet add <nazwa> <user@host[:port]> [--tags tag1,tag2]
  fleet list|remove|test [<nazwa>]
  fleet run [--tags …] [--limit N] [--timeout SEK] [--yes] -- "<komenda hmtools>"
  fleet health|update check|backup status|ssl [--tags …] [--limit N] [--timeout SEK]
  fleet report [--tags …] [--limit N] [--timeout SEK]

Inwentarz: /etc/hmtools/fleet/inventory.tsv (0600), known_hosts zarządzany przy add.
SSH: tylko klucze / ssh-agent (BatchMode, bez haseł). StrictHostKeyChecking=yes.
Zmienne: HM_FLEET_DIR, HM_FLEET_SSH, HM_FLEET_KEYSCAN, HM_FLEET_PARALLEL, HM_FLEET_TIMEOUT.
Zdalnie: HM_FLEET_REMOTE_BIN (domyślnie hmtools).
EOF

hm_fleet_refresh_paths() {
  HM_FLEET_DIR="${HM_FLEET_DIR:-/etc/hmtools/fleet}"
  HM_FLEET_INVENTORY="${HM_FLEET_DIR}/inventory.tsv"
  HM_FLEET_KNOWN_HOSTS="${HM_FLEET_DIR}/known_hosts"
}
hm_fleet_refresh_paths
HM_FLEET_SSH="${HM_FLEET_SSH:-ssh}"
HM_FLEET_KEYSCAN="${HM_FLEET_KEYSCAN:-ssh-keyscan}"
HM_FLEET_PARALLEL="${HM_FLEET_PARALLEL:-8}"
HM_FLEET_TIMEOUT="${HM_FLEET_TIMEOUT:-120}"
HM_FLEET_REMOTE_BIN="${HM_FLEET_REMOTE_BIN:-hmtools}"

declare -ga HM_FLEET_RUN_PIDS=()
HM_FLEET_RUN_TMP=""

hm_fleet_inv_header() {
  printf '# name\tuser\thost\tport\ttags\tadded_at\n'
}

hm_fleet_ensure_state() {
  hm_fleet_refresh_paths
  local d="${HM_FLEET_DIR}"
  if [[ ! -d "${d}" ]]; then
    mkdir -p "${d}" 2>/dev/null || return 1
    chmod 0700 "${d}" 2>/dev/null || true
  fi
  if [[ ! -f "${HM_FLEET_INVENTORY}" ]]; then
    hm_fleet_inv_header >"${HM_FLEET_INVENTORY}"
    chmod 0600 "${HM_FLEET_INVENTORY}" 2>/dev/null || chmod 600 "${HM_FLEET_INVENTORY}"
  fi
  if [[ ! -f "${HM_FLEET_KNOWN_HOSTS}" ]]; then
    : >"${HM_FLEET_KNOWN_HOSTS}"
    chmod 0600 "${HM_FLEET_KNOWN_HOSTS}" 2>/dev/null || chmod 600 "${HM_FLEET_KNOWN_HOSTS}"
  fi
  chmod 0600 "${HM_FLEET_INVENTORY}" 2>/dev/null || true
  chmod 0600 "${HM_FLEET_KNOWN_HOSTS}" 2>/dev/null || true
  return 0
}

hm_fleet_parse_target() {
  # stdin/argv: user@host[:port] → HM_FLEET_USER HM_FLEET_HOST HM_FLEET_PORT
  local raw="${1:-}"
  HM_FLEET_USER="" HM_FLEET_HOST="" HM_FLEET_PORT="22"
  if [[ ! "${raw}" =~ ^([^@]+)@([^:]+)(:([0-9]+))?$ ]]; then
    hm_err "Oczekiwano user@host[:port], np. root@203.0.113.5:2222"
    return 1
  fi
  HM_FLEET_USER="${BASH_REMATCH[1]}"
  HM_FLEET_HOST="${BASH_REMATCH[2]}"
  if [[ -n "${BASH_REMATCH[4]:-}" ]]; then
    HM_FLEET_PORT="${BASH_REMATCH[4]}"
  fi
  return 0
}

hm_fleet_valid_name() {
  local n="${1:-}"
  [[ "${n}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}$ ]]
}

hm_fleet_read_hosts() {
  # stdout: name\tuser\thost\tport\ttags
  local line name
  [[ -f "${HM_FLEET_INVENTORY}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    name="${line%%$'\t'*}"
    hm_fleet_valid_name "${name}" || continue
    printf '%s\n' "${line}"
  done <"${HM_FLEET_INVENTORY}"
}

hm_fleet_host_line() {
  local want="$1" line name
  while IFS= read -r line; do
    name="${line%%$'\t'*}"
    [[ "${name}" == "${want}" ]] || continue
    printf '%s' "${line}"
    return 0
  done < <(hm_fleet_read_hosts)
  return 1
}

hm_fleet_tags_match() {
  local host_tags="${1:-}" want="${2:-}"
  [[ -z "${want}" ]] && return 0
  [[ -z "${host_tags}" ]] && return 1
  local w ht
  IFS=',' read -r -a want_a <<<"${want}"
  for w in "${want_a[@]}"; do
    [[ -z "${w}" ]] && continue
    IFS=',' read -r -a host_a <<<"${host_tags}"
    for ht in "${host_a[@]}"; do
      [[ "${ht}" == "${w}" ]] && return 0
    done
  done
  return 1
}

hm_fleet_select_hosts() {
  local filter_name="${1:-}" filter_tags="${2:-}"
  local line name user host port tags
  while IFS= read -r line; do
  IFS=$'\t' read -r name user host port tags _ <<<"${line}"
    [[ -n "${filter_name}" && "${name}" != "${filter_name}" ]] && continue
    hm_fleet_tags_match "${tags}" "${filter_tags}" || continue
    printf '%s\n' "${name}"
  done < <(hm_fleet_read_hosts)
}

hm_fleet_ssh_target() {
  local user="$1" host="$2" port="$3"
  HM_FLEET_SSH_CMD=(
    "${HM_FLEET_SSH}"
    -o BatchMode=yes
    -o StrictHostKeyChecking=yes
    -o "UserKnownHostsFile=${HM_FLEET_KNOWN_HOSTS}"
    -o PasswordAuthentication=no
    -o PreferredAuthentications=publickey
    -o IdentitiesOnly=yes
    -o ConnectTimeout=15
    -p "${port}"
    "${user}@${host}"
  )
}

hm_fleet_ssh_keyscan() {
  local host="$1" port="${2:-22}" tmp merged=0
  [[ -n "${host}" ]] || return 1
  if ! command -v "${HM_FLEET_KEYSCAN}" >/dev/null 2>&1; then
    hm_warn "Brak ${HM_FLEET_KEYSCAN} — known_hosts bez aktualizacji."
    return 0
  fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/fleet-kh.XXXXXX")" || return 1
  if ! "${HM_FLEET_KEYSCAN}" -T 10 -p "${port}" -H "${host}" 2>/dev/null >"${tmp}"; then
    rm -f "${tmp}"
    hm_err "ssh-keyscan nie zwrócił klucza dla ${host}:${port}"
    return 1
  fi
  if [[ ! -s "${tmp}" ]]; then
    rm -f "${tmp}"
    hm_err "Pusty wynik ssh-keyscan dla ${host}:${port}"
    return 1
  fi
  touch "${HM_FLEET_KNOWN_HOSTS}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    if ! grep -qxF "${line}" "${HM_FLEET_KNOWN_HOSTS}" 2>/dev/null; then
      printf '%s\n' "${line}" >>"${HM_FLEET_KNOWN_HOSTS}"
      merged=1
    fi
  done <"${tmp}"
  rm -f "${tmp}"
  chmod 0600 "${HM_FLEET_KNOWN_HOSTS}" 2>/dev/null || true
  [[ "${merged}" -eq 1 ]] && hm_ok "Dodano klucz hosta do known_hosts."
  return 0
}

# Komenda hmtools bez metaznaków powłoki (zdalny ssh skleja argv w shell).
hm_fleet_validate_cmd() {
  local cmd="${1:-}"
  [[ -n "${cmd}" ]] || { hm_err "Pusta komenda fleet."; return 1; }
  if [[ "${cmd}" =~ [\;\|\&\$\`\<\>\(\)\{\}] ]]; then
    hm_err "Niedozwolone metaznaki w komendzie fleet (;|&\$\`<>(){})."
    return 1
  fi
  return 0
}

hm_fleet_remote() {
  local name="$1" remote_cmd="$2"
  local line user host port tags qcmd remote_one
  hm_fleet_validate_cmd "${remote_cmd}" || return 1
  line="$(hm_fleet_host_line "${name}")" || {
    hm_err "Brak hosta w inwentarzu: ${name}"
    return 1
  }
  IFS=$'\t' read -r _ user host port tags _ <<<"${line}"
  hm_fleet_ssh_target "${user}" "${host}" "${port}"
  # Jedna zdalna komenda z printf %q — bez interpretacji ; $() przez shell sshd.
  qcmd="$(printf '%q' "${remote_cmd}")"
  remote_one="${HM_FLEET_REMOTE_BIN} -c ${qcmd}"
  local -a ssh_cmd=("${HM_FLEET_SSH_CMD[@]}" -- "${remote_one}")
  local rc=0 out
  if declare -F hm_run_timeout >/dev/null 2>&1; then
    out="$(hm_run_timeout "${HM_FLEET_TIMEOUT}" "${ssh_cmd[@]}" 2>&1)" || rc=$?
  elif command -v timeout >/dev/null 2>&1; then
    out="$(timeout "${HM_FLEET_TIMEOUT}s" "${ssh_cmd[@]}" 2>&1)" || rc=$?
  else
    out="$("${ssh_cmd[@]}" 2>&1)" || rc=$?
  fi
  HM_FLEET_LAST_OUT="${out}"
  HM_FLEET_LAST_RC="${rc}"
  return "${rc}"
}

hm_fleet_is_destructive() {
  local cmd="${1:-}"
  [[ -z "${cmd}" ]] && return 1
  # Cała linia (także po ;|&) — nie tylko pierwsze słowo.
  if printf '%s\n' "${cmd}" | grep -Eqi '(^|[[:space:]/;|&])(uninstall|delete|purge|drop|revoke|destroy|wipe|erase|format|truncate|poweroff|reboot|shutdown|halt)([[:space:]/;|&]|$)'; then
    return 0
  fi
  if printf '%s\n' "${cmd}" | grep -Eqi '(webs[[:space:]]+(delete|remove|destroy)|users[[:space:]]+del|backup[[:space:]]+prune|openvpn[[:space:]]+(revoke|uninstall)|uninstall-hmtools)'; then
    return 0
  fi
  return 1
}

hm_fleet_run_cleanup() {
  local pid
  for pid in "${HM_FLEET_RUN_PIDS[@]:-}"; do
    [[ -n "${pid}" ]] || continue
    kill -TERM "${pid}" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  HM_FLEET_RUN_PIDS=()
  if [[ -n "${HM_FLEET_RUN_TMP:-}" && -d "${HM_FLEET_RUN_TMP}" ]]; then
    rm -rf "${HM_FLEET_RUN_TMP}"
    HM_FLEET_RUN_TMP=""
  fi
}

hm_fleet_run_trap() {
  hm_fleet_run_cleanup
  exit 130
}

hm_fleet_parse_common_flags() {
  HM_FLEET_OPT_TAGS=""
  HM_FLEET_OPT_LIMIT="${HM_FLEET_PARALLEL}"
  HM_FLEET_OPT_TIMEOUT="${HM_FLEET_TIMEOUT}"
  HM_FLEET_OPT_YES=0
  HM_FLEET_OPT_HOST=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tags)
        HM_FLEET_OPT_TAGS="${2:-}"
        shift 2 || true
        ;;
      --tags=*)
        HM_FLEET_OPT_TAGS="${1#*=}"
        shift
        ;;
      --limit|--parallel)
        HM_FLEET_OPT_LIMIT="${2:-8}"
        shift 2 || true
        ;;
      --limit=*|--parallel=*)
        HM_FLEET_OPT_LIMIT="${1#*=}"
        shift
        ;;
      --timeout)
        HM_FLEET_OPT_TIMEOUT="${2:-120}"
        shift 2 || true
        ;;
      --timeout=*)
        HM_FLEET_OPT_TIMEOUT="${1#*=}"
        shift
        ;;
      --yes|-y)
        HM_FLEET_OPT_YES=1
        shift
        ;;
      *)
        break
        ;;
    esac
  done
  [[ "${HM_FLEET_OPT_LIMIT}" =~ ^[0-9]+$ ]] || HM_FLEET_OPT_LIMIT=8
  [[ "${HM_FLEET_OPT_TIMEOUT}" =~ ^[0-9]+$ ]] || HM_FLEET_OPT_TIMEOUT=120
  HM_FLEET_TIMEOUT="${HM_FLEET_OPT_TIMEOUT}"
  return 0
}

hm_fleet_run_worker() {
  local name="$1" remote_cmd="$2" outf rcf
  outf="${HM_FLEET_RUN_TMP}/${name}.out"
  rcf="${HM_FLEET_RUN_TMP}/${name}.rc"
  hm_fleet_remote "${name}" "${remote_cmd}" || true
  printf '%s\n' "${HM_FLEET_LAST_OUT:-}" >"${outf}"
  printf '%s\n' "${HM_FLEET_LAST_RC:-1}" >"${rcf}"
}

hm_fleet_run_pool() {
  local remote_cmd="$1"
  shift
  local -a hosts=( "$@" )
  [[ "${#hosts[@]}" -gt 0 ]] || {
    hm_warn "Brak hostów (filtr tagów / inwentarz pusty)."
    return 1
  }

  HM_FLEET_RUN_TMP="$(mktemp -d "${TMPDIR:-/tmp}/fleet-run.XXXXXX")" || return 1
  HM_FLEET_RUN_PIDS=()
  trap 'hm_fleet_run_trap' INT TERM

  local max="${HM_FLEET_OPT_LIMIT}" i=0 running=0 name
  local collect_rc=0 last_rc=0

  for name in "${hosts[@]}"; do
    while [[ "${running}" -ge "${max}" ]]; do
      if wait -n 2>/dev/null; then
        :
      else
        wait 2>/dev/null || true
      fi
      running=$((running - 1))
    done
    hm_fleet_run_worker "${name}" "${remote_cmd}" &
    HM_FLEET_RUN_PIDS+=( "$!" )
    running=$((running + 1))
    i=$((i + 1))
  done
  while [[ "${running}" -gt 0 ]]; do
    if wait -n 2>/dev/null; then
      :
    else
      wait 2>/dev/null || true
    fi
    running=$((running - 1))
  done

  trap - INT TERM
  HM_FLEET_RUN_PIDS=()

  for name in "${hosts[@]}"; do
    last_rc=0
    if [[ -f "${HM_FLEET_RUN_TMP}/${name}.rc" ]]; then
      last_rc="$(cat "${HM_FLEET_RUN_TMP}/${name}.rc" 2>/dev/null || echo 1)"
    else
      last_rc=124
    fi
    [[ "${last_rc}" =~ ^[0-9]+$ ]] || last_rc=1
    if [[ "${last_rc}" -ne 0 ]]; then
      collect_rc=1
    fi
    if [[ "${last_rc}" -eq 0 ]]; then
      echo "${C_BOLD}[${name}]${C_RESET} ${C_GREEN}(0) OK${C_RESET}"
    else
      echo "${C_BOLD}[${name}]${C_RESET} ${C_RED}(${last_rc}) FAIL${C_RESET}"
    fi
    if [[ -f "${HM_FLEET_RUN_TMP}/${name}.out" ]]; then
      sed 's/^/  /' "${HM_FLEET_RUN_TMP}/${name}.out"
    fi
    echo "  ---"
  done

  rm -rf "${HM_FLEET_RUN_TMP}"
  HM_FLEET_RUN_TMP=""
  return "${collect_rc}"
}

hm_fleet_add() {
  local name="${1:-}" target="${2:-}"
  shift 2 || true
  local tags=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tags)
        tags="${2:-}"
        shift 2 || true
        ;;
      --tags=*)
        tags="${1#*=}"
        shift
        ;;
      *)
        hm_err "Nieznany argument: $1"
        return 1
        ;;
    esac
  done
  [[ -n "${name}" && -n "${target}" ]] || {
    hm_err "Użycie: fleet add <nazwa> <user@host[:port]> [--tags a,b]"
    return 1
  }
  hm_fleet_valid_name "${name}" || {
    hm_err "Niepoprawna nazwa hosta: ${name}"
    return 1
  }
  hm_fleet_ensure_state || return 1
  if hm_fleet_host_line "${name}" >/dev/null 2>&1; then
    hm_err "Host już istnieje: ${name} (najpierw fleet remove)"
    return 1
  fi
  hm_fleet_parse_target "${target}" || return 1
  hm_fleet_ssh_keyscan "${HM_FLEET_HOST}" "${HM_FLEET_PORT}" || return 1
  local stamp
  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
  (
    umask 077
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${name}" "${HM_FLEET_USER}" "${HM_FLEET_HOST}" "${HM_FLEET_PORT}" "${tags}" "${stamp}" \
      >>"${HM_FLEET_INVENTORY}"
  )
  chmod 0600 "${HM_FLEET_INVENTORY}" 2>/dev/null || true
  hm_ok "Dodano ${name} → ${HM_FLEET_USER}@${HM_FLEET_HOST}:${HM_FLEET_PORT}"
  return 0
}

hm_fleet_list() {
  hm_fleet_ensure_state || return 1
  local -a hosts=()
  mapfile -t hosts < <(hm_fleet_select_hosts "" "")
  if [[ "${#hosts[@]}" -eq 0 ]]; then
    hm_info "Inwentarz pusty (${HM_FLEET_INVENTORY})."
    return 0
  fi
  hm_table_begin LRRLL
  hm_table_row NAZWA USER HOST PORT TAGI
  local name line user host port tags
  for name in "${hosts[@]}"; do
    line="$(hm_fleet_host_line "${name}")" || continue
    IFS=$'\t' read -r _ user host port tags _ <<<"${line}"
    hm_table_row "${name}" "${user}" "${host}" "${port}" "${tags:-—}"
  done
  hm_table_print
  return 0
}

hm_fleet_remove() {
  local name="${1:-}"
  [[ -n "${name}" ]] || {
    hm_err "Użycie: fleet remove <nazwa>"
    return 1
  }
  hm_fleet_ensure_state || return 1
  if ! hm_fleet_host_line "${name}" >/dev/null 2>&1; then
    hm_err "Brak hosta: ${name}"
    return 1
  fi
  local line new=""
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" == \#* ]] && continue
    [[ "${line%%$'\t'*}" == "${name}" ]] && continue
    new+="${line}"$'\n'
  done <"${HM_FLEET_INVENTORY}"
  hm_fleet_inv_header >"${HM_FLEET_INVENTORY}"
  printf '%s' "${new}" >>"${HM_FLEET_INVENTORY}"
  chmod 0600 "${HM_FLEET_INVENTORY}" 2>/dev/null || true
  hm_ok "Usunięto ${name} z inwentarza."
  return 0
}

hm_fleet_test() {
  local one="${1:-}"
  hm_fleet_ensure_state || return 1
  local -a hosts=()
  mapfile -t hosts < <(hm_fleet_select_hosts "${one}" "")
  [[ "${#hosts[@]}" -gt 0 ]] || {
    hm_warn "Brak hostów do testu."
    return 1
  }
  local name rc=0 fail=0
  for name in "${hosts[@]}"; do
    if hm_fleet_remote "${name}" "doctor --json"; then
      hm_ok "${name}: SSH OK"
    else
      rc=1
      fail=$((fail + 1))
      hm_err "${name}: połączenie nieudane (rc=${HM_FLEET_LAST_RC:-?})"
      [[ -n "${HM_FLEET_LAST_OUT:-}" ]] && printf '  %s\n' "${HM_FLEET_LAST_OUT}"
    fi
  done
  [[ "${fail}" -eq 0 ]] && hm_ok "Test: ${#hosts[@]} host(ów) OK."
  return "${rc}"
}

hm_fleet_confirm_destructive() {
  local remote_cmd="$1"
  shift
  local -a hosts=( "$@" )
  [[ "${#hosts[@]}" -lt 2 ]] && return 0
  [[ "${HM_FLEET_OPT_YES}" -eq 1 ]] && return 0
  local -a plan=( "Zdalna komenda: ${remote_cmd}" "Hosty (${#hosts[@]}):" )
  local h
  for h in "${hosts[@]}"; do
    plan+=( "  • ${h}" )
  done
  plan+=( "SSH: klucze tylko, bez haseł" )
  if ! hm_confirm_plan "fleet run — operacja destrukcyjna" \
    "Potwierdź wykonanie na WSZYSTKICH wymienionych hostach." \
    "${plan[@]}"; then
    return 1
  fi
  return 0
}

hm_fleet_run() {
  local remote_cmd="$1"
  shift || true
  hm_fleet_parse_common_flags "$@"
  hm_fleet_ensure_state || return 1
  [[ -n "${remote_cmd}" ]] || {
    hm_err "Użycie: fleet run [opcje] -- \"<komenda hmtools>\""
    return 1
  }
  hm_fleet_validate_cmd "${remote_cmd}" || return 1
  local -a hosts=()
  mapfile -t hosts < <(hm_fleet_select_hosts "" "${HM_FLEET_OPT_TAGS}")
  if hm_fleet_is_destructive "${remote_cmd}"; then
    hm_fleet_confirm_destructive "${remote_cmd}" "${hosts[@]}" || return 1
  fi
  hm_fleet_run_pool "${remote_cmd}" "${hosts[@]}"
}

hm_fleet_agg_remote_all() {
  local remote_cmd="$1"
  hm_fleet_parse_common_flags "${@:2}"
  hm_fleet_ensure_state || return 1
  local -a hosts=()
  mapfile -t hosts < <(hm_fleet_select_hosts "" "${HM_FLEET_OPT_TAGS}")
  [[ "${#hosts[@]}" -gt 0 ]] || {
    hm_warn "Brak hostów."
    return 1
  }
  HM_FLEET_RUN_TMP="$(mktemp -d "${TMPDIR:-/tmp}/fleet-agg.XXXXXX")" || return 1
  HM_FLEET_RUN_PIDS=()
  trap 'hm_fleet_run_trap' INT TERM
  local max="${HM_FLEET_OPT_LIMIT}" running=0 name
  for name in "${hosts[@]}"; do
    while [[ "${running}" -ge "${max}" ]]; do
      wait -n 2>/dev/null || wait 2>/dev/null || true
      running=$((running - 1))
    done
    hm_fleet_run_worker "${name}" "${remote_cmd}" &
    HM_FLEET_RUN_PIDS+=( "$!" )
    running=$((running + 1))
  done
  while [[ "${running}" -gt 0 ]]; do
    wait -n 2>/dev/null || wait 2>/dev/null || true
    running=$((running - 1))
  done
  trap - INT TERM
  HM_FLEET_RUN_PIDS=()
  HM_FLEET_AGG_HOSTS=( "${hosts[@]}" )
  return 0
}

hm_fleet_agg_finish() {
  trap - INT TERM 2>/dev/null || true
  HM_FLEET_RUN_PIDS=()
  rm -rf "${HM_FLEET_RUN_TMP:-}"
  HM_FLEET_RUN_TMP=""
}

hm_fleet_health() {
  hm_fleet_agg_remote_all "health --check --json" "$@" || return $?
  hm_table_begin LLR
  hm_table_row HOST OK "DISK %" ALERTY
  local name rc body ok disk alerts
  for name in "${HM_FLEET_AGG_HOSTS[@]}"; do
    rc=1
    body=""
    [[ -f "${HM_FLEET_RUN_TMP}/${name}.out" ]] && body="$(cat "${HM_FLEET_RUN_TMP}/${name}.out" 2>/dev/null || true)"
    [[ -f "${HM_FLEET_RUN_TMP}/${name}.rc" ]] && rc="$(cat "${HM_FLEET_RUN_TMP}/${name}.rc" 2>/dev/null || echo 1)"
    if [[ "${rc}" -ne 0 ]]; then
      hm_table_row "${name}" "ERR" "?" "ssh rc=${rc}"
      continue
    fi
    ok="$(printf '%s' "${body}" | sed -n 's/.*"ok":\s*\(true\|false\).*/\1/p' | head -1)"
    disk="$(printf '%s' "${body}" | sed -n 's/.*"disk_used":\([0-9]*\).*/\1/p' | head -1)"
    alerts="$(printf '%s' "${body}" | tr -d '\n' | grep -o '"alerts":\[[^]]*\]' | head -1)"
    alerts="${alerts#\"alerts\":}"
    [[ -z "${ok}" ]] && ok="?"
    [[ -z "${disk}" ]] && disk="?"
    hm_table_row "${name}" "${ok}" "${disk}" "${alerts:-[]}"
  done
  hm_table_print
  hm_fleet_agg_finish
  return 0
}

hm_fleet_update_check() {
  hm_fleet_agg_remote_all "update check --json" "$@" || return $?
  hm_table_begin LRRRR
  hm_table_row HOST UPGR SEC REBOOT CP
  local name rc body up sec reb cp
  for name in "${HM_FLEET_AGG_HOSTS[@]}"; do
    rc=1
    body=""
    [[ -f "${HM_FLEET_RUN_TMP}/${name}.out" ]] && body="$(cat "${HM_FLEET_RUN_TMP}/${name}.out" 2>/dev/null || true)"
    [[ -f "${HM_FLEET_RUN_TMP}/${name}.rc" ]] && rc="$(cat "${HM_FLEET_RUN_TMP}/${name}.rc" 2>/dev/null || echo 1)"
    if [[ "${rc}" -ne 0 ]]; then
      hm_table_row "${name}" "?" "?" "?" "ssh"
      continue
    fi
    up="$(printf '%s' "${body}" | sed -n 's/.*"upgradable":\([0-9]*\).*/\1/p' | head -1)"
    sec="$(printf '%s' "${body}" | sed -n 's/.*"security":\([0-9]*\).*/\1/p' | head -1)"
    reb="$(printf '%s' "${body}" | sed -n 's/.*"reboot":"\([^"]*\)".*/\1/p' | head -1)"
    cp="$(printf '%s' "${body}" | sed -n 's/.*"cyberpanel":"\([^"]*\)".*/\1/p' | head -1)"
    hm_table_row "${name}" "${up:-?}" "${sec:-?}" "${reb:-?}" "${cp:-?}"
  done
  hm_table_print
  hm_fleet_agg_finish
  return 0
}

hm_fleet_backup_status() {
  hm_fleet_agg_remote_all "backup list --json" "$@" || return $?
  hm_table_begin LRR
  hm_table_row HOST SNAPSHOTS OSTATNI OK
  local name rc body n stamp ok
  for name in "${HM_FLEET_AGG_HOSTS[@]}"; do
    rc=1
    body=""
    [[ -f "${HM_FLEET_RUN_TMP}/${name}.out" ]] && body="$(cat "${HM_FLEET_RUN_TMP}/${name}.out" 2>/dev/null || true)"
    [[ -f "${HM_FLEET_RUN_TMP}/${name}.rc" ]] && rc="$(cat "${HM_FLEET_RUN_TMP}/${name}.rc" 2>/dev/null || echo 1)"
    if [[ "${rc}" -ne 0 ]]; then
      hm_table_row "${name}" "?" "?" "ssh"
      continue
    fi
    n="$(python3 -c 'import json,sys
try:
 d=json.load(sys.stdin)
 print(len(d.get("snapshots") or []))
except Exception:
 print("?")' <<<"${body}" 2>/dev/null)"
    stamp="$(python3 -c 'import json,sys
try:
 d=json.load(sys.stdin)
 s=d.get("snapshots") or []
 if not s: print("-"); sys.exit(0)
 s=sorted(s,key=lambda x:x.get("stamp",""),reverse=True)
 print(s[0].get("stamp","?"))
except Exception:
 print("?")' <<<"${body}" 2>/dev/null)"
    ok="$(python3 -c 'import json,sys
try:
 d=json.load(sys.stdin)
 s=d.get("snapshots") or []
 if not s: print("-"); sys.exit(0)
 s=sorted(s,key=lambda x:x.get("stamp",""),reverse=True)
 print("ok" if s[0].get("ok") else "fail")
except Exception:
 print("?")' <<<"${body}" 2>/dev/null)"
    hm_table_row "${name}" "${n:-?}" "${stamp:-?}" "${ok:-?}"
  done
  hm_table_print
  hm_fleet_agg_finish
  return 0
}

hm_fleet_ssl() {
  hm_fleet_agg_remote_all "ssl --json" "$@" || return $?
  hm_table_begin LRRR
  hm_table_row HOST CERTY WKRÓTCE WYGASŁE
  local name rc body total soon exp
  for name in "${HM_FLEET_AGG_HOSTS[@]}"; do
    rc=1
    body=""
    [[ -f "${HM_FLEET_RUN_TMP}/${name}.out" ]] && body="$(cat "${HM_FLEET_RUN_TMP}/${name}.out" 2>/dev/null || true)"
    [[ -f "${HM_FLEET_RUN_TMP}/${name}.rc" ]] && rc="$(cat "${HM_FLEET_RUN_TMP}/${name}.rc" 2>/dev/null || echo 1)"
    if [[ "${rc}" -ne 0 ]]; then
      hm_table_row "${name}" "?" "?" "?"
      continue
    fi
    read -r total soon exp <<<"$(python3 -c 'import json,sys
try:
 d=json.load(sys.stdin)
 rows=d.get("certs") or []
 t=len(rows)
 so=sum(1 for r in rows if str(r.get("status","")).upper() in ("WKRÓTCE","SOON"))
 ex=sum(1 for r in rows if str(r.get("status","")).upper() in ("WYGASŁ","WYGAS","EXPIRED"))
 print(t,so,ex)
except Exception:
 print("? ? ?")' <<<"${body}" 2>/dev/null)"
    hm_table_row "${name}" "${total}" "${soon}" "${exp}"
  done
  hm_table_print
  hm_fleet_agg_finish
  return 0
}

hm_fleet_report() {
  hm_fleet_agg_remote_all "report weekly --json" "$@" || return $?
  local name rc body issues sections
  echo "${C_BOLD}fleet report — zbiorczo${C_RESET}"
  for name in "${HM_FLEET_AGG_HOSTS[@]}"; do
    rc=1
    body=""
    [[ -f "${HM_FLEET_RUN_TMP}/${name}.out" ]] && body="$(cat "${HM_FLEET_RUN_TMP}/${name}.out" 2>/dev/null || true)"
    [[ -f "${HM_FLEET_RUN_TMP}/${name}.rc" ]] && rc="$(cat "${HM_FLEET_RUN_TMP}/${name}.rc" 2>/dev/null || echo 1)"
    echo
    echo "${C_BOLD}== ${name}${C_RESET} (rc=${rc})"
    if [[ "${rc}" -ne 0 ]]; then
      hm_err "Brak raportu (SSH/timeout)"
      continue
    fi
    issues="$(python3 -c 'import json,sys
try:
 d=json.load(sys.stdin)
 sec=d.get("sections") or []
 def n(s):
  v=s.get("issues")
  if v is None: v=s.get("issue")
  return 1 if v else 0
 print(sum(n(s) for s in sec if isinstance(s,dict)))
except Exception:
 print("?")' <<<"${body}" 2>/dev/null)"
    sections="$(python3 -c 'import json,sys
try:
 d=json.load(sys.stdin)
 for s in d.get("sections") or []:
  if not isinstance(s,dict): continue
  t=s.get("title") or "?"
  iss=s.get("issues")
  if iss is None: iss=s.get("issue") or 0
  print(f"  - {t}: issues={iss}")
except Exception:
 print("  (parse error)")' <<<"${body}" 2>/dev/null)"
    echo "  Sekcje z problemami: ${issues}"
    printf '%s\n' "${sections}"
  done
  hm_fleet_agg_finish
  return 0
}

cmd_fleet() {
  local sub="${1:-}"
  shift || true
  case "${sub}" in
    add)
      hm_fleet_add "$@"
      ;;
    list|ls)
      hm_fleet_list
      ;;
    remove|rm|del)
      hm_fleet_remove "${1:-}"
      ;;
    test)
      hm_fleet_test "${1:-}"
      ;;
    run)
      local -a flag_args=() remote_cmd="" found=0
      while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--" ]]; then
          shift
          remote_cmd="$*"
          found=1
          break
        fi
        case "$1" in
          --tags|--limit|--parallel|--timeout)
            flag_args+=( "$1" "${2:-}" )
            shift 2 || true
            ;;
          --tags=*|--limit=*|--parallel=*|--timeout=*|--yes|-y)
            flag_args+=( "$1" )
            shift
            ;;
          *)
            hm_err "fleet run: nieznana flaga lub brak -- przed komendą: $1"
            return 1
            ;;
        esac
      done
      [[ "${found}" -eq 1 ]] || {
        hm_err "Użycie: fleet run [opcje] -- \"<komenda>\""
        return 1
      }
      hm_fleet_run "${remote_cmd}" "${flag_args[@]}"
      ;;
    health)
      hm_fleet_health "$@"
      ;;
    update)
      if [[ "${1:-}" == "check" ]]; then
        shift || true
        hm_fleet_update_check "$@"
        return $?
      fi
      hm_err "Użycie: fleet update check"
      return 1
      ;;
    backup)
      if [[ "${1:-}" == "status" ]]; then
        shift || true
        hm_fleet_backup_status "$@"
        return $?
      fi
      hm_err "Użycie: fleet backup status"
      return 1
      ;;
    ssl)
      hm_fleet_ssl "$@"
      ;;
    report)
      hm_fleet_report "$@"
      ;;
    help|-h|--help)
      hm_help_topic fleet 2>/dev/null || true
      return 0
      ;;
    "")
      hm_help_topic fleet 2>/dev/null || true
      return 0
      ;;
    *)
      hm_err "Nieznana podkomenda fleet: ${sub}"
      hm_help_topic fleet 2>/dev/null || true
      return 1
      ;;
  esac
}

_hm_cmd_register fleet cmd_fleet 0