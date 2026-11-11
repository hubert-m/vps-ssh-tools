#!/usr/bin/env bash
# monitor http — uptime stron. Hasło basic-auth zostaje w pliku konfiguracji, nie w logu.

_hm_cmd_help monitor <<'EOF'
Użycie:
  monitor http [domena] [--keyword s] [--expect 200] [--timeout 10] [--resolve] [--json]
  monitor add <domena> [--keyword s] [--expect 200] [--timeout 10] [--max-ms N] [--fails N] [--url URL]
  monitor remove <domena>
  monitor list
  monitor watch install|status|disable

Alert po N kolejnych porażkach (domyślnie 2), jeden na awarię, potem „wróciło”.
EOF

hm_monitor_dir() {
  printf '%s' "${HM_MONITOR_DIR:-/var/lib/hmtools/monitor}"
}

hm_monitor_ensure() {
  local d
  d="$(hm_monitor_dir)"
  mkdir -p "${d}/config" "${d}/state" 2>/dev/null || true
  chmod 0700 "${d}" "${d}/config" "${d}/state" 2>/dev/null || true
}

hm_monitor_domain_ok() {
  [[ "${1:-}" =~ ^[A-Za-z0-9._-]+$ ]]
}

hm_monitor_redact() {
  local u="${1:-}" scheme rest auth hostpath
  case "${u}" in
    *://*@*)
      scheme="${u%%://*}"
      rest="${u#*://}"
      hostpath="${rest#*@}"
      printf '%s://%s' "${scheme}" "${hostpath}"
      ;;
    *) printf '%s' "${u}" ;;
  esac
}

hm_monitor_note() {
  local msg="$1"
  [[ -n "${HM_MONITOR_LOG:-}" ]] || return 0
  printf '%s\n' "${msg}" >> "${HM_MONITOR_LOG}"
}

hm_monitor_config_path() {
  printf '%s/config/%s' "$(hm_monitor_dir)" "$1"
}

hm_monitor_state_path() {
  printf '%s/state/%s' "$(hm_monitor_dir)" "$1"
}

hm_monitor_write_kv() {
  local file="$1"
  shift
  local k v
  : > "${file}"
  chmod 0600 "${file}" 2>/dev/null || true
  while [[ $# -ge 2 ]]; do
    k="$1"
    v="$2"
    shift 2
    printf '%s=%s\n' "${k}" "${v}" >> "${file}"
  done
}

hm_monitor_read_kv() {
  local file="$1" k v
  HM_MON_KEYWORD=""
  HM_MON_EXPECT="200"
  HM_MON_TIMEOUT="10"
  HM_MON_MAX_MS="0"
  HM_MON_FAILS_NEEDED="2"
  HM_MON_URL=""
  HM_MON_FAILS="0"
  HM_MON_ALERT="0"
  [[ -f "${file}" ]] || return 0
  while IFS='=' read -r k v || [[ -n "${k}" ]]; do
    [[ -n "${k}" && "${k}" != \#* ]] || continue
    case "${k}" in
      keyword) HM_MON_KEYWORD="${v}" ;;
      expect) HM_MON_EXPECT="${v}" ;;
      timeout) HM_MON_TIMEOUT="${v}" ;;
      max_ms) HM_MON_MAX_MS="${v}" ;;
      fails_needed) HM_MON_FAILS_NEEDED="${v}" ;;
      url) HM_MON_URL="${v}" ;;
      fails) HM_MON_FAILS="${v}" ;;
      alert) HM_MON_ALERT="${v}" ;;
    esac
  done < "${file}"
}

hm_monitor_load() {
  hm_monitor_read_kv "$(hm_monitor_config_path "$1")"
  local keyword="${HM_MON_KEYWORD}" expect="${HM_MON_EXPECT}" timeout="${HM_MON_TIMEOUT}"
  local max_ms="${HM_MON_MAX_MS}" need="${HM_MON_FAILS_NEEDED}" url="${HM_MON_URL}"
  hm_monitor_read_kv "$(hm_monitor_state_path "$1")"
  HM_MON_KEYWORD="${keyword}"
  HM_MON_EXPECT="${expect}"
  HM_MON_TIMEOUT="${timeout}"
  HM_MON_MAX_MS="${max_ms}"
  HM_MON_FAILS_NEEDED="${need}"
  HM_MON_URL="${url}"
}

hm_monitor_save_state() {
  hm_monitor_write_kv "$(hm_monitor_state_path "$1")" fails "$2" alert "$3"
}

hm_monitor_fetch() {
  local url="$1" timeout="$2" outfile="$3" resolve="$4" rc=0 bare
  bare="$(hm_monitor_redact "${url}")"
  HM_MON_META=""
  if [[ -n "${HM_MONITOR_CURL:-}" ]]; then
    if [[ -n "${resolve}" ]]; then
      HM_MON_META="$("${HM_MONITOR_CURL}" --resolve "${resolve}" --max-time "${timeout}" --output "${outfile}" "${bare}")" || rc=$?
    else
      HM_MON_META="$("${HM_MONITOR_CURL}" --max-time "${timeout}" --output "${outfile}" "${bare}")" || rc=$?
    fi
    hm_monitor_note "curl ${bare}"
    return "${rc}"
  fi
  local cfg
  cfg="$(mktemp "${TMPDIR:-/tmp}/hm-mon-curl.XXXXXX")"
  chmod 0600 "${cfg}" 2>/dev/null || true
  {
    printf 'url = "%s"\n' "${bare}"
    printf 'output = "%s"\n' "${outfile}"
    printf 'max-time = "%s"\n' "${timeout}"
    printf 'max-redirs = "5"\n'
    printf 'location\n'
    printf 'silent\n'
    printf 'show-error\n'
    printf 'write-out = "%%{http_code} %%{time_total} %%{num_redirects}\\n"\n'
    if [[ -n "${resolve}" ]]; then
      printf 'resolve = "%s"\n' "${resolve}"
    fi
    case "${url}" in
      *://*@*)
        local auth
        auth="${url#*://}"
        auth="${auth%%@*}"
        printf 'user = "%s"\n' "${auth}"
        ;;
    esac
  } > "${cfg}"
  HM_MON_META="$(curl --config "${cfg}")" || rc=$?
  rm -f "${cfg}"
  hm_monitor_note "curl ${bare}"
  return "${rc}"
}

hm_monitor_tls_days() {
  local host="$1" file end epoch now days
  if [[ -n "${HM_MONITOR_TLS_DIR:-}" ]]; then
    file="${HM_MONITOR_TLS_DIR}/${host}"
    [[ -f "${file}" ]] || return 1
    tr -d '[:space:]' < "${file}"
    return 0
  fi
  if declare -F hm_have_cmd >/dev/null 2>&1; then
    hm_have_cmd openssl || return 1
  elif ! command -v openssl >/dev/null 2>&1; then
    return 1
  fi
  end="$(openssl s_client -connect "${host}:443" -servername "${host}" </dev/null 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
  [[ -n "${end}" ]] || return 1
  epoch="$(date -d "${end}" +%s 2>/dev/null || true)"
  [[ "${epoch}" =~ ^[0-9]+$ ]] || return 1
  now="$(date +%s)"
  days="$(( (epoch - now) / 86400 ))"
  printf '%s' "${days}"
}

hm_monitor_judge() {
  local rc="$1" expect="$2" keyword="$3" body="$4" max_ms="$5"
  local code="" secs="" redirs="" ms="0"
  HM_MON_CODE="-"
  HM_MON_MS="-"
  [[ -n "${HM_MON_TLS:-}" ]] || HM_MON_TLS="-"
  HM_MON_STATUS="FAIL"
  HM_MON_REASON="nieznany"
  if [[ "${rc}" -eq 28 ]]; then
    HM_MON_REASON="timeout"
    return 0
  fi
  if [[ "${rc}" -eq 47 ]]; then
    HM_MON_REASON="pętla przekierowań"
    return 0
  fi
  read -r code secs redirs <<<"${HM_MON_META}"
  [[ "${code}" =~ ^[0-9]+$ ]] || code="0"
  [[ "${redirs}" =~ ^[0-9]+$ ]] || redirs="0"
  HM_MON_CODE="${code}"
  if [[ "${secs}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    ms="$(awk -v s="${secs}" 'BEGIN { printf "%.0f", s * 1000 }')"
  fi
  HM_MON_MS="${ms}"
  if [[ "${rc}" -eq 35 || "${rc}" -eq 51 || "${rc}" -eq 60 ]]; then
    if [[ "${HM_MON_TLS}" =~ ^-[0-9]+$ ]]; then
      HM_MON_REASON="tls wygasł"
    else
      HM_MON_REASON="tls błąd"
    fi
    return 0
  fi
  if [[ "${redirs}" -ge 5 ]]; then
    HM_MON_REASON="pętla przekierowań"
    return 0
  fi
  if [[ "${code}" != "${expect}" ]]; then
    HM_MON_REASON="kod ${code}"
    return 0
  fi
  if [[ -n "${keyword}" ]]; then
    if ! grep -F -q -- "${keyword}" "${body}" 2>/dev/null; then
      HM_MON_REASON="brak keyword"
      return 0
    fi
  fi
  if [[ "${max_ms}" =~ ^[0-9]+$ && "${max_ms}" -gt 0 && "${ms}" =~ ^[0-9]+$ && "${ms}" -gt "${max_ms}" ]]; then
    HM_MON_REASON="wolno ${ms}ms"
    return 0
  fi
  if [[ "${HM_MON_TLS}" =~ ^-[0-9]+$ ]]; then
    HM_MON_REASON="tls wygasł"
    return 0
  fi
  HM_MON_STATUS="OK"
  HM_MON_REASON="ok"
}

hm_monitor_alert() {
  local domain="$1" status="$2" reason="$3" need fails alert
  need="${HM_MON_FAILS_NEEDED:-2}"
  fails="${HM_MON_FAILS:-0}"
  alert="${HM_MON_ALERT:-0}"
  [[ "${need}" =~ ^[0-9]+$ ]] || need=2
  [[ "${fails}" =~ ^[0-9]+$ ]] || fails=0
  if [[ "${status}" == "FAIL" ]]; then
    fails=$((fails + 1))
    if [[ "${fails}" -ge "${need}" && "${alert}" != "1" ]]; then
      if declare -F hm_notify >/dev/null 2>&1; then
        hm_notify error "monitor http" "${domain} FAIL ${reason}" "monitor-http-${domain}" || true
      fi
      hm_monitor_note "ALERT ${domain} ${reason}"
      alert=1
    fi
  else
    if [[ "${alert}" == "1" ]]; then
      if declare -F hm_notify >/dev/null 2>&1; then
        hm_notify ok "monitor http" "${domain} wróciło" "monitor-http-${domain}" || true
      fi
      hm_monitor_note "RECOVERY ${domain} wróciło"
    fi
    fails=0
    alert=0
  fi
  HM_MON_FAILS="${fails}"
  HM_MON_ALERT="${alert}"
  hm_monitor_save_state "${domain}" "${fails}" "${alert}"
}

hm_monitor_check_domain() {
  local domain="$1" resolve_flag="$2" kw_over="$3" exp_over="$4" to_over="$5"
  local url body rc=0 resolve=""
  hm_monitor_load "${domain}"
  [[ -n "${kw_over}" ]] && HM_MON_KEYWORD="${kw_over}"
  [[ -n "${exp_over}" ]] && HM_MON_EXPECT="${exp_over}"
  [[ -n "${to_over}" ]] && HM_MON_TIMEOUT="${to_over}"
  if [[ -n "${HM_MON_URL}" ]]; then
    url="${HM_MON_URL}"
  else
    url="https://${domain}/"
  fi
  body="$(mktemp "${TMPDIR:-/tmp}/hm-mon-body.XXXXXX")"
  if [[ "${resolve_flag}" -eq 1 ]]; then
    resolve="${domain}:443:127.0.0.1"
  fi
  hm_monitor_fetch "${url}" "${HM_MON_TIMEOUT}" "${body}" "${resolve}" || rc=$?
  HM_MON_TLS="-"
  case "${url}" in
    https://*)
      local days
      days="$(hm_monitor_tls_days "${domain}" 2>/dev/null || true)"
      [[ "${days}" =~ ^-?[0-9]+$ ]] && HM_MON_TLS="${days}"
      ;;
  esac
  hm_monitor_judge "${rc}" "${HM_MON_EXPECT}" "${HM_MON_KEYWORD}" "${body}" "${HM_MON_MAX_MS}"
  rm -f "${body}"
  hm_monitor_alert "${domain}" "${HM_MON_STATUS}" "${HM_MON_REASON}"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${domain}" "${HM_MON_CODE}" "${HM_MON_MS}" "${HM_MON_TLS}" "${HM_MON_STATUS}" "${HM_MON_REASON}"
}

hm_monitor_targets() {
  local one="$1" d f any=0
  if [[ -n "${one}" ]]; then
    printf '%s\n' "${one}"
    return 0
  fi
  d="$(hm_monitor_dir)/config"
  if [[ -d "${d}" ]]; then
    for f in "${d}/"*; do
      [[ -f "${f}" ]] || continue
      any=1
      basename "${f}"
    done
  fi
  if [[ "${any}" -eq 0 && -n "${HM_SITES_LIST+x}" ]]; then
    for f in "${HM_SITES_LIST[@]:-}"; do
      [[ -n "${f}" ]] && printf '%s\n' "${f}"
    done
  fi
}

hm_monitor_status() {
  local json=0 latest first=1 line dom code ms tls status reason
  [[ "${1:-}" == "--json" ]] && json=1
  latest="$(hm_monitor_dir)/latest.txt"
  if [[ ! -s "${latest}" ]]; then
    [[ "${json}" -eq 1 ]] && printf '[]\n'
    return 0
  fi
  if [[ "${json}" -eq 0 ]]; then
    cat "${latest}"
    return 0
  fi
  printf '['
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    IFS=$'\t' read -r dom code ms tls status reason <<<"${line}"
    [[ "${first}" -eq 1 ]] || printf ','
    first=0
    printf '{"domain":"%s","code":"%s","ms":"%s","tls":"%s","status":"%s","reason":"%s"}' \
      "${dom}" "${code}" "${ms}" "${tls}" "${status}" "${reason}"
  done < "${latest}"
  printf ']\n'
}

hm_monitor_http() {
  if [[ "${1:-}" == "status" ]]; then
    shift
    hm_monitor_status "$@"
    return 0
  fi
  local domain="" keyword="" expect="" timeout="" json=0 resolve=0 quiet=0 a
  local line any=0 first=1
  while [[ $# -gt 0 ]]; do
    a="$1"
    shift
    case "${a}" in
      --json) json=1 ;;
      --resolve) resolve=1 ;;
      --quiet) quiet=1 ;;
      --keyword)
        keyword="${1:-}"
        shift || true
        ;;
      --keyword=*) keyword="${a#--keyword=}" ;;
      --expect)
        expect="${1:-}"
        shift || true
        ;;
      --expect=*) expect="${a#--expect=}" ;;
      --timeout)
        timeout="${1:-}"
        shift || true
        ;;
      --timeout=*) timeout="${a#--timeout=}" ;;
      *)
        domain="${a}"
        ;;
    esac
  done
  if [[ -n "${domain}" ]] && ! hm_monitor_domain_ok "${domain}"; then
    hm_err "Zła domena"
    return 1
  fi
  hm_monitor_ensure
  local latest
  latest="$(hm_monitor_dir)/latest.txt"
  : > "${latest}"
  if [[ "${json}" -eq 1 ]]; then
    printf '['
  elif [[ "${quiet}" -eq 0 ]]; then
    printf '%-24s %6s %8s %6s %s\n' "domena" "kod" "ms" "tls" "wynik"
  fi
  while IFS= read -r a; do
    [[ -n "${a}" ]] || continue
    line="$(hm_monitor_check_domain "${a}" "${resolve}" "${keyword}" "${expect}" "${timeout}")"
    printf '%s\n' "${line}" >> "${latest}"
    if [[ "${line}" == *$'\tFAIL\t'* ]]; then
      any=1
    fi
    if [[ "${json}" -eq 1 ]]; then
      local dom code ms tls status reason
      IFS=$'\t' read -r dom code ms tls status reason <<<"${line}"
      [[ "${first}" -eq 1 ]] || printf ','
      first=0
      printf '{"domain":"%s","code":"%s","ms":"%s","tls":"%s","status":"%s","reason":"%s"}' \
        "${dom}" "${code}" "${ms}" "${tls}" "${status}" "${reason}"
    elif [[ "${quiet}" -eq 0 ]]; then
      local dom code ms tls status reason
      IFS=$'\t' read -r dom code ms tls status reason <<<"${line}"
      printf '%-24s %6s %8s %6s %s %s\n' "${dom}" "${code}" "${ms}" "${tls}" "${status}" "${reason}"
    fi
  done < <(hm_monitor_targets "${domain}")
  if [[ "${json}" -eq 1 ]]; then
    printf ']\n'
  fi
  [[ "${any}" -eq 0 ]]
}

hm_monitor_add() {
  local domain="" keyword="" expect="200" timeout="10" max_ms="0" fails="2" url="" a
  while [[ $# -gt 0 ]]; do
    a="$1"
    shift
    case "${a}" in
      --keyword) keyword="${1:-}"; shift || true ;;
      --keyword=*) keyword="${a#--keyword=}" ;;
      --expect) expect="${1:-200}"; shift || true ;;
      --expect=*) expect="${a#--expect=}" ;;
      --timeout) timeout="${1:-10}"; shift || true ;;
      --timeout=*) timeout="${a#--timeout=}" ;;
      --max-ms) max_ms="${1:-0}"; shift || true ;;
      --max-ms=*) max_ms="${a#--max-ms=}" ;;
      --fails) fails="${1:-2}"; shift || true ;;
      --fails=*) fails="${a#--fails=}" ;;
      --url) url="${1:-}"; shift || true ;;
      --url=*) url="${a#--url=}" ;;
      *) domain="${a}" ;;
    esac
  done
  hm_monitor_domain_ok "${domain}" || { hm_err "Zła domena"; return 1; }
  case "${url}" in
    *$'\n'*|*$'\t'*) hm_err "URL zawiera niedozwolony znak"; return 1 ;;
  esac
  hm_monitor_ensure
  hm_monitor_write_kv "$(hm_monitor_config_path "${domain}")" \
    keyword "${keyword}" expect "${expect}" timeout "${timeout}" \
    max_ms "${max_ms}" fails_needed "${fails}" url "${url}"
  echo "monitor add ${domain}"
}

hm_monitor_remove() {
  local domain="${1:-}"
  hm_monitor_domain_ok "${domain}" || { hm_err "Zła domena"; return 1; }
  rm -f "$(hm_monitor_config_path "${domain}")" "$(hm_monitor_state_path "${domain}")"
  echo "monitor remove ${domain}"
}

hm_monitor_list() {
  local d f domain
  d="$(hm_monitor_dir)/config"
  [[ -d "${d}" ]] || { echo "monitor: pusto"; return 0; }
  for f in "${d}/"*; do
    [[ -f "${f}" ]] || continue
    domain="$(basename "${f}")"
    hm_monitor_read_kv "${f}"
    if [[ -n "${HM_MON_URL}" && "${HM_MON_URL}" == *"://"*@* ]]; then
      printf '%s  expect=%s keyword=%s auth=yes\n' "${domain}" "${HM_MON_EXPECT}" "${HM_MON_KEYWORD:+set}"
    else
      printf '%s  expect=%s keyword=%s\n' "${domain}" "${HM_MON_EXPECT}" "${HM_MON_KEYWORD:+set}"
    fi
  done
}

hm_monitor_watch() {
  local sub="${1:-status}" f bin
  f="${HM_MONITOR_CRON:-/etc/cron.d/hmtools-monitor}"
  bin="$(command -v hmtools 2>/dev/null || echo "${HMTOOLS_ROOT:-/opt/hmtools}/bin/hmtools")"
  case "${sub}" in
    status|show|"")
      if [[ -f "${f}" ]]; then
        echo "monitor watch: włączony (${f})"
      else
        echo "monitor watch: wyłączony"
      fi
      ;;
    install|enable|on)
      if declare -F hm_confirm_plan >/dev/null 2>&1; then
        hm_confirm_plan "monitor watch install" \
          "Cron co 5 min sprawdza strony i woła notify. Hasła nie trafiają do logu." \
          "Zapis ${f}" || return 1
      fi
      mkdir -p "$(dirname "${f}")" 2>/dev/null || true
      cat > "${f}" <<EOF
# hmtools — monitor http
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""
*/5 * * * * root ${bin} -c "monitor http --quiet" >> ${LOG_DIR:-/hm-tools/logs}/monitor.log 2>&1
EOF
      chmod 644 "${f}" 2>/dev/null || true
      echo "monitor watch: włączony (${f})"
      ;;
    disable|off)
      if [[ ! -f "${f}" ]]; then
        echo "monitor watch: już wyłączony"
        return 0
      fi
      if declare -F hm_confirm_plan >/dev/null 2>&1; then
        hm_confirm_plan "monitor watch disable" \
          "Zatrzymanie sprawdzania stron." \
          "Usunięcie ${f}" || return 1
      fi
      rm -f "${f}"
      echo "monitor watch: wyłączony"
      ;;
    *)
      hm_err "Użycie: monitor watch install|status|disable"
      return 1
      ;;
  esac
}

cmd_monitor() {
  local sub="${1:-http}"
  shift || true
  case "${sub}" in
    http) hm_monitor_http "$@" ;;
    add) hm_monitor_add "$@" ;;
    remove|rm|delete) hm_monitor_remove "$@" ;;
    list|ls) hm_monitor_list ;;
    watch) hm_monitor_watch "${1:-status}" ;;
    help|-h|--help) hm_help_topic monitor 2>/dev/null || true ;;
    *)
      hm_err "Użycie: monitor http|add|remove|list|watch"
      return 1
      ;;
  esac
}

_hm_cmd_register monitor cmd_monitor 0
