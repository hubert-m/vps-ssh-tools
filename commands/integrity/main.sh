#!/usr/bin/env bash
# integrity — checksumy WP dla wszystkich stron i baseline plików systemowych.

_hm_cmd_help integrity <<'EOF'
Użycie:
  integrity wp [--all|domena] [--json]
                             core + plugin verify-checksums jako user strony
  integrity baseline create|update
                             sha256 dla ścieżek (domyślnie /usr/bin, /usr/sbin,
                             /etc, /usr/local/lsws/conf, /usr/local/CyberCP)
  integrity check [--json] [--since RRRR-MM-DD] [--notify]
                             nowe / zmienione / usunięte względem baseline
  integrity schedule enable|disable|status
                             cron check --notify

Baseline: plik 0600 poza docrootem (HM_INTEGRITY_DB).
Symlinki nie są rozwijane. Po update security|packages|ols|cyberpanel
baseline można odświeżyć osobnym potwierdzeniem.
EOF

hm_integrity_db() {
  printf '%s' "${HM_INTEGRITY_DB:-/var/lib/hmtools/integrity/baseline.tsv}"
}

hm_integrity_roots() {
  local raw="${HM_INTEGRITY_PATHS:-/usr/bin:/usr/sbin:/etc:/usr/local/lsws/conf:/usr/local/CyberCP}"
  local part
  IFS=':' read -r -a _hm_int_roots <<< "${raw}"
  for part in "${_hm_int_roots[@]}"; do
    [[ -n "${part}" ]] && printf '%s\n' "${part}"
  done
}

hm_integrity_json_escape() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "${s}"
}

hm_integrity_b64enc() {
  if printf '' | base64 -w0 >/dev/null 2>&1; then
    base64 -w0
  else
    base64 | tr -d '\n\r'
  fi
}

hm_integrity_b64dec() {
  base64 -d 2>/dev/null || base64 -D 2>/dev/null
}

hm_integrity_db_ok() {
  local db="$1"
  case "${db}" in
    *"/public_html/"*|*"wp-content"*)
      hm_err "Baseline nie może leżeć w docroocie (${db})."
      return 1
      ;;
  esac
  return 0
}

hm_integrity_hash_path() {
  local path="$1" target="" sum=""
  if [[ -L "${path}" ]]; then
    target="$(readlink "${path}" 2>/dev/null || true)"
    printf 'link:%s' "${target}"
    return 0
  fi
  [[ -f "${path}" ]] || return 1
  if hm_have_cmd sha256sum; then
    sum="$(sha256sum -- "${path}" 2>/dev/null | awk '{print $1}' || true)"
    sum="${sum#\\}"
  elif hm_have_cmd openssl; then
    sum="$(openssl dgst -sha256 "${path}" 2>/dev/null | awk '{print $NF}' || true)"
  else
    return 1
  fi
  [[ "${sum}" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
  printf '%s' "${sum}"
}

hm_integrity_scan_to() {
  local dest="$1"
  shift
  local root path hash b64 db
  db="$(hm_integrity_db)"
  : > "${dest}"
  for root in "$@"; do
    [[ -n "${root}" && -d "${root}" && ! -L "${root}" ]] || continue
    while IFS= read -r -d '' path; do
      [[ -n "${path}" ]] || continue
      [[ "${path}" == "${db}" ]] && continue
      hash="$(hm_integrity_hash_path "${path}")" || continue
      b64="$(printf '%s' "${path}" | hm_integrity_b64enc)"
      [[ -n "${b64}" ]] || continue
      printf '%s %s\n' "${hash}" "${b64}" >> "${dest}"
    done < <(find -P "${root}" \( -type f -o -type l \) -print0 2>/dev/null || true)
  done
}

hm_integrity_baseline_write() {
  local db dir tmp roots=() root
  db="$(hm_integrity_db)"
  hm_integrity_db_ok "${db}" || return 1
  dir="$(dirname "${db}")"
  mkdir -p "${dir}"
  chmod 0700 "${dir}" 2>/dev/null || true
  while IFS= read -r root; do
    [[ -n "${root}" ]] && roots+=("${root}")
  done < <(hm_integrity_roots)
  tmp="${db}.tmp"
  hm_integrity_scan_to "${tmp}" "${roots[@]}"
  mv -f "${tmp}" "${db}"
  chmod 0600 "${db}" 2>/dev/null || true
  hm_ok "Baseline: ${db}"
}

hm_integrity_baseline() {
  local action="${1:-}"
  case "${action}" in
    create|update) hm_integrity_baseline_write ;;
    *)
      hm_err "Użycie: integrity baseline create|update"
      return 1
      ;;
  esac
}

hm_integrity_since_epoch() {
  local day="$1" epoch=""
  [[ "${day}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || {
    hm_err "since: oczekuję RRRR-MM-DD"
    return 1
  }
  epoch="$(date -d "${day} 00:00:00" +%s 2>/dev/null || true)"
  [[ -n "${epoch}" ]] || {
    hm_err "Nie da się odczytać daty ${day}."
    return 1
  }
  printf '%s' "${epoch}"
}

hm_integrity_mtime() {
  stat -c '%Y' -- "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null || printf '0'
}

hm_integrity_check() {
  local json=0 notify=0 since="" a db now old_hash b64 path hash kind
  local -a added=() changed=() removed=()
  while [[ $# -gt 0 ]]; do
    a="$1"
    shift
    case "${a}" in
      --json) json=1 ;;
      --notify) notify=1 ;;
      --since)
        since="${1:-}"
        shift || true
        ;;
      --since=*) since="${a#--since=}" ;;
      *)
        hm_err "Nieznany argument: ${a}"
        return 1
        ;;
    esac
  done
  db="$(hm_integrity_db)"
  [[ -f "${db}" ]] || {
    hm_err "Brak baseline. Najpierw: integrity baseline create"
    return 1
  }
  local since_epoch=0
  if [[ -n "${since}" ]]; then
    since_epoch="$(hm_integrity_since_epoch "${since}")" || return 1
  fi
  declare -A old=()
  while read -r old_hash b64; do
    [[ -n "${b64}" ]] || continue
    old["${b64}"]="${old_hash}"
  done < "${db}"
  local roots=() root scan
  while IFS= read -r root; do
    [[ -n "${root}" ]] && roots+=("${root}")
  done < <(hm_integrity_roots)
  scan="$(mktemp "${TMPDIR:-/tmp}/hm-integrity.XXXXXX")"
  hm_integrity_scan_to "${scan}" "${roots[@]}"
  declare -A seen=()
  while read -r hash b64; do
    [[ -n "${b64}" ]] || continue
    seen["${b64}"]=1
    path="$(printf '%s' "${b64}" | hm_integrity_b64dec || true)"
    [[ -n "${path}" ]] || continue
    if [[ -z "${old[${b64}]+x}" ]]; then
      kind="added"
    elif [[ "${old[${b64}]}" != "${hash}" ]]; then
      kind="changed"
    else
      continue
    fi
    if [[ "${since_epoch}" -gt 0 && "${kind}" != "removed" ]]; then
      local mt
      mt="$(hm_integrity_mtime "${path}")"
      [[ "${mt}" =~ ^[0-9]+$ ]] || mt=0
      [[ "${mt}" -ge "${since_epoch}" ]] || continue
    fi
    case "${kind}" in
      added) added+=("${path}") ;;
      changed) changed+=("${path}") ;;
    esac
  done < "${scan}"
  for b64 in "${!old[@]}"; do
    [[ -n "${seen[${b64}]+x}" ]] && continue
    path="$(printf '%s' "${b64}" | hm_integrity_b64dec || true)"
    [[ -n "${path}" ]] && removed+=("${path}")
  done
  rm -f "${scan}"
  HM_INT_ADDED=("${added[@]+"${added[@]}"}")
  HM_INT_CHANGED=("${changed[@]+"${changed[@]}"}")
  HM_INT_REMOVED=("${removed[@]+"${removed[@]}"}")
  if [[ "${json}" -eq 1 ]]; then
    hm_integrity_print_json
  else
    hm_integrity_print_text
  fi
  if [[ "${notify}" -eq 1 ]]; then
    local n=$(( ${#HM_INT_ADDED[@]} + ${#HM_INT_CHANGED[@]} + ${#HM_INT_REMOVED[@]} ))
    if [[ "${n}" -gt 0 ]] && declare -F hm_notify >/dev/null 2>&1; then
      hm_notify warning "Integralność" "Zmiany plików: ${n} (nowe ${#HM_INT_ADDED[@]}, zmienione ${#HM_INT_CHANGED[@]}, usunięte ${#HM_INT_REMOVED[@]})." "integrity.check"
    fi
  fi
}

hm_integrity_print_text() {
  local p show
  echo "${C_BOLD}integrity check${C_RESET}"
  echo "  nowe      : ${#HM_INT_ADDED[@]}"
  echo "  zmienione : ${#HM_INT_CHANGED[@]}"
  echo "  usunięte  : ${#HM_INT_REMOVED[@]}"
  for p in "${HM_INT_ADDED[@]+"${HM_INT_ADDED[@]}"}"; do
    show="$(hm_integrity_json_escape "${p}")"
    printf '  + %s\n' "${show}"
  done
  for p in "${HM_INT_CHANGED[@]+"${HM_INT_CHANGED[@]}"}"; do
    show="$(hm_integrity_json_escape "${p}")"
    printf '  ~ %s\n' "${show}"
  done
  for p in "${HM_INT_REMOVED[@]+"${HM_INT_REMOVED[@]}"}"; do
    show="$(hm_integrity_json_escape "${p}")"
    printf '  - %s\n' "${show}"
  done
}

hm_integrity_print_json() {
  local p first=1
  printf '{"added":['
  for p in "${HM_INT_ADDED[@]+"${HM_INT_ADDED[@]}"}"; do
    [[ "${first}" -eq 1 ]] || printf ','
    first=0
    printf '"%s"' "$(hm_integrity_json_escape "${p}")"
  done
  printf '],"changed":['
  first=1
  for p in "${HM_INT_CHANGED[@]+"${HM_INT_CHANGED[@]}"}"; do
    [[ "${first}" -eq 1 ]] || printf ','
    first=0
    printf '"%s"' "$(hm_integrity_json_escape "${p}")"
  done
  printf '],"removed":['
  first=1
  for p in "${HM_INT_REMOVED[@]+"${HM_INT_REMOVED[@]}"}"; do
    [[ "${first}" -eq 1 ]] || printf ','
    first=0
    printf '"%s"' "$(hm_integrity_json_escape "${p}")"
  done
  printf ']}\n'
}

hm_integrity_site_user() {
  local domain="$1" d u
  if [[ -n "${HM_INTEGRITY_USER_FILE:-}" && -f "${HM_INTEGRITY_USER_FILE}" ]]; then
    while read -r d u _; do
      [[ "${d}" == "${domain}" ]] || continue
      printf '%s' "${u}"
      return 0
    done < "${HM_INTEGRITY_USER_FILE}"
  fi
  if declare -F hm_access_require_site_user >/dev/null 2>&1; then
    hm_access_require_site_user "${domain}"
    return $?
  fi
  return 1
}

hm_integrity_wp_exec() {
  local user="$1"
  shift
  [[ -n "${user}" && "${user}" != "root" ]] || {
    hm_err "WP-CLI tylko jako user strony, nie jako root."
    return 1
  }
  if [[ "$(id -u)" -eq 0 ]]; then
    if hm_have_cmd runuser; then
      runuser -u "${user}" -- "$@"
      return $?
    fi
    hm_err "Nie uruchamiam WP-CLI jako root (brak runuser)."
    return 1
  fi
  if [[ "$(id -un)" == "${user}" ]]; then
    "$@"
    return $?
  fi
  hm_err "Nie uruchamiam WP-CLI jako root."
  return 1
}

hm_integrity_wp_bin() {
  if [[ -n "${HM_INTEGRITY_WP_BIN:-}" ]]; then
    printf '%s' "${HM_INTEGRITY_WP_BIN}"
    return 0
  fi
  if hm_have_cmd wp; then
    command -v wp
    return 0
  fi
  hm_err "Brak WP-CLI."
  return 1
}

hm_integrity_wp() {
  local json=0 only="" a domain user bin core plug
  local -a domains=() rows=()
  while [[ $# -gt 0 ]]; do
    a="$1"
    shift
    case "${a}" in
      --json) json=1 ;;
      --all) only="" ;;
      -*)
        hm_err "Nieznany argument: ${a}"
        return 1
        ;;
      *) only="${a}" ;;
    esac
  done
  if [[ -n "${HM_INTEGRITY_SITES:-}" ]]; then
    for domain in ${HM_INTEGRITY_SITES}; do
      domains+=("${domain}")
    done
  elif declare -F hm_discover_sites >/dev/null 2>&1; then
    hm_discover_sites || true
    for domain in "${HM_SITES_LIST[@]+"${HM_SITES_LIST[@]}"}"; do
      [[ -n "${domain}" ]] || continue
      if declare -F hm_wp_site_is_wp >/dev/null 2>&1; then
        hm_wp_site_is_wp "${domain}" || continue
      fi
      domains+=("${domain}")
    done
  fi
  bin="$(hm_integrity_wp_bin)" || return 1
  if [[ "${json}" -eq 0 ]]; then
    hm_table_begin
    hm_table_row "Domena" "Core" "Wtyczki"
  fi
  local first=1
  [[ "${json}" -eq 1 ]] && printf '{"sites":['
  for domain in "${domains[@]}"; do
    [[ -n "${only}" && "${domain}" != "${only}" ]] && continue
    user="$(hm_integrity_site_user "${domain}")" || {
      hm_warn "Pomijam ${domain}: brak usera strony."
      continue
    }
    core="ok"
    plug="ok"
    hm_integrity_wp_exec "${user}" "${bin}" --path="/home/${domain}/public_html" core verify-checksums >/dev/null || core="różnice"
    hm_integrity_wp_exec "${user}" "${bin}" --path="/home/${domain}/public_html" plugin verify-checksums --all >/dev/null || plug="różnice"
    if [[ "${json}" -eq 1 ]]; then
      [[ "${first}" -eq 1 ]] || printf ','
      first=0
      printf '{"domain":"%s","core":"%s","plugins":"%s"}' \
        "$(hm_integrity_json_escape "${domain}")" \
        "$(hm_integrity_json_escape "${core}")" \
        "$(hm_integrity_json_escape "${plug}")"
    else
      hm_table_row "${domain}" "${core}" "${plug}"
    fi
  done
  if [[ "${json}" -eq 1 ]]; then
    printf ']}\n'
  else
    hm_table_print 2
  fi
}

hm_integrity_schedule() {
  local action="${1:-status}" file
  file="${HM_INTEGRITY_CRON:-/etc/cron.d/hmtools-integrity}"
  case "${action}" in
    enable)
      mkdir -p "$(dirname "${file}")"
      printf '%s\n' '# hmtools-integrity' '30 4 * * * root hmtools integrity check --notify' > "${file}"
      hm_ok "Cron: ${file}"
      ;;
    disable)
      if [[ -f "${file}" ]] && grep -q 'hmtools-integrity' "${file}"; then
        rm -f "${file}"
        hm_ok "Usunięto ${file}"
      else
        hm_warn "To nie jest plik hmtools-integrity."
        return 1
      fi
      ;;
    status)
      if [[ -f "${file}" ]]; then
        hm_ok "Cron zainstalowany: ${file}"
      else
        hm_warn "Brak crona integralności."
        return 1
      fi
      ;;
    *)
      hm_err "Użycie: integrity schedule enable|disable|status"
      return 1
      ;;
  esac
}

hm_integrity_after_update() {
  local db
  db="$(hm_integrity_db)"
  [[ -f "${db}" ]] || return 0
  if ! declare -F hm_confirm_plan >/dev/null 2>&1; then
    return 0
  fi
  if hm_confirm_plan "integrity baseline" \
    "Aktualizacja zmieniła pliki systemowe. Odświeżyć baseline, żeby check nie zgłaszał tych różnic?" \
    "Ponowny zapis skrótów sha256"; then
    hm_integrity_baseline_write
  fi
}

cmd_integrity() {
  local sub="${1:-}"
  shift || true
  case "${sub}" in
    wp) hm_integrity_wp "$@" ;;
    baseline) hm_integrity_baseline "$@" ;;
    check) hm_integrity_check "$@" ;;
    schedule) hm_integrity_schedule "$@" ;;
    help|-h|--help|"") hm_help_topic integrity ;;
    *)
      hm_err "Użycie: integrity wp|baseline|check|schedule"
      return 1
      ;;
  esac
}

_hm_cmd_register integrity cmd_integrity 0
