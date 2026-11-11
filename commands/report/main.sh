#!/usr/bin/env bash
# report weekly — zbiorczy raport stanu, bez sekretów w treści.

_hm_cmd_help report <<'EOF'
Użycie:
  report weekly [--send] [--json] [--html] [--issues-only]
  report schedule enable|disable|status
EOF

hm_report_cron_file() { printf '%s' "${HM_REPORT_CRON:-/etc/cron.d/hmtools-report}"; }

hm_report_section_note() {
  local title="$1" note="$2"
  HM_REPORT_TITLES+=("${title}")
  HM_REPORT_BODIES+=("${note}")
  HM_REPORT_ISSUES+=("0")
}

hm_html_escape() {
  local s="$1" q='"'
  s="${s//&/\&amp;}"
  s="${s//</\&lt;}"
  s="${s//>/\&gt;}"
  s="${s//${q}/\&quot;}"
  printf '%s' "${s}"
}

hm_report_push() {
  local title="$1" body="$2" issue=0
  if printf '%s\n' "${body}" | grep -Eq 'FAIL|failed|wygasa|reboot|ban|ERROR|problem'; then
    issue=1
  fi
  HM_REPORT_TITLES+=("${title}")
  HM_REPORT_BODIES+=("${body}")
  HM_REPORT_ISSUES+=("${issue}")
}

hm_report_read_or_skip() {
  local title="$1" file="${2:-}" missing="$3"
  if [[ -z "${file}" || ! -f "${file}" ]]; then
    hm_report_section_note "${title}" "pominięto — ${missing}"
    return 0
  fi
  hm_report_push "${title}" "$(cat "${file}")"
}

hm_report_capture() {
  local out=""
  case "$1" in
    stats)
      declare -F cmd_stats >/dev/null 2>&1 && out="$(cmd_stats "${@:2}" 2>/dev/null || true)"
      ;;
    security)
      declare -F cmd_security >/dev/null 2>&1 && out="$(cmd_security "${@:2}" 2>/dev/null || true)"
      ;;
    monitor)
      declare -F cmd_monitor >/dev/null 2>&1 && out="$(cmd_monitor "${@:2}" 2>/dev/null || true)"
      ;;
    vuln)
      declare -F cmd_vuln >/dev/null 2>&1 && out="$(cmd_vuln "${@:2}" 2>/dev/null || true)"
      ;;
    backup)
      declare -F cmd_backup >/dev/null 2>&1 && out="$(cmd_backup "${@:2}" 2>/dev/null || true)"
      ;;
  esac
  if [[ -z "${out}" && $# -gt 0 && "${HMTOOLS_TEST:-}" != "1" ]]; then
    local bin=""
    bin="$(command -v hmtools 2>/dev/null || true)"
    if [[ -n "${bin}" ]]; then
      out="$("${bin}" "$@" 2>/dev/null || true)"
    fi
  fi
  printf '%s' "${out}"
}

hm_report_take() {
  local title="$1" file="${2:-}" missing="$3"
  shift 3
  if [[ -n "${file}" ]]; then
    hm_report_read_or_skip "${title}" "${file}" "${missing}"
    return 0
  fi
  if [[ $# -eq 0 ]]; then
    hm_report_section_note "${title}" "pominięto — ${missing}"
    return 0
  fi
  local body
  body="$(hm_report_capture "$@")"
  case "${body}" in
    ""|"[]"|"{}")
      hm_report_section_note "${title}" "pominięto — ${missing}"
      ;;
    *)
      hm_report_push "${title}" "${body}"
      ;;
  esac
}

hm_report_collect() {
  HM_REPORT_TITLES=()
  HM_REPORT_BODIES=()
  HM_REPORT_ISSUES=()
  hm_report_take "Usługi" "${HM_REPORT_SERVICES:-}" "brak modułu usług"
  hm_report_take "Strony" "${HM_REPORT_HTTP:-}" "brak monitor http" monitor http status --json
  hm_report_take "Kopie" "${HM_REPORT_BACKUP:-}" "brak backup" backup status
  hm_report_take "Certyfikaty" "${HM_REPORT_SSL:-}" "brak ssl"
  hm_report_take "Aktualizacje" "${HM_REPORT_UPDATES:-}" "brak aktualizacji" vuln os --json
  hm_report_take "Bany" "${HM_REPORT_BANS:-}" "brak fail2ban"
  hm_report_take "Dysk" "${HM_REPORT_DISK:-}" "brak statystyk dysku"
  hm_report_take "Zasoby" "${HM_REPORT_STATS:-}" "brak stats" stats week --json
  hm_report_take "Audyt" "${HM_REPORT_AUDIT:-}" "brak security audit" security audit --json
}

hm_report_text() {
  local i issues="${1:-0}"
  printf 'Raport tygodniowy\n'
  for i in "${!HM_REPORT_TITLES[@]}"; do
    if [[ "${issues}" -eq 1 && "${HM_REPORT_ISSUES[$i]}" -eq 0 ]]; then
      continue
    fi
    printf '\n## %s\n%s\n' "${HM_REPORT_TITLES[$i]}" "${HM_REPORT_BODIES[$i]}"
  done
}

hm_report_html() {
  local i issues="${1:-0}"
  printf '<html><body><h1>Raport tygodniowy</h1>\n'
  for i in "${!HM_REPORT_TITLES[@]}"; do
    if [[ "${issues}" -eq 1 && "${HM_REPORT_ISSUES[$i]}" -eq 0 ]]; then
      continue
    fi
    local title body
    title="$(hm_html_escape "${HM_REPORT_TITLES[$i]}")"
    body="$(hm_html_escape "${HM_REPORT_BODIES[$i]}")"
    printf '<h2>%s</h2><pre>%s</pre>\n' "${title}" "${body}"
  done
  printf '</body></html>\n'
}

hm_report_json() {
  local i first=1 issues="${1:-0}"
  printf '{"report":"weekly","sections":['
  for i in "${!HM_REPORT_TITLES[@]}"; do
    if [[ "${issues}" -eq 1 && "${HM_REPORT_ISSUES[$i]}" -eq 0 ]]; then
      continue
    fi
    [[ "${first}" -eq 0 ]] && printf ','
    first=0
    local title body
    title="${HM_REPORT_TITLES[$i]//\"/\\\"}"
    body="${HM_REPORT_BODIES[$i]//\\/\\\\}"
    body="${body//\"/\\\"}"
    body="${body//$'\n'/\\n}"
    printf '{"title":"%s","body":"%s","issue":%s}' "${title}" "${body}" "${HM_REPORT_ISSUES[$i]}"
  done
  printf ']}\n'
}

hm_report_weekly() {
  local send=0 fmt="text" issues=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --send) send=1; shift ;;
      --json) fmt="json"; shift ;;
      --html) fmt="html"; shift ;;
      --issues-only) issues=1; shift ;;
      --dry-run) shift ;;
      *) hm_err "Nieznana flaga: $1"; return 1 ;;
    esac
  done
  hm_report_collect
  local text json
  text="$(hm_report_text "${issues}")"
  json="$(hm_report_json "${issues}")"
  case "${fmt}" in
    json) printf '%s\n' "${json}" ;;
    html) hm_report_html "${issues}" ;;
    *) printf '%s\n' "${text}" ;;
  esac
  if [[ "${send}" -eq 1 ]]; then
    hm_notify info "Raport tygodniowy" "${text}" "report.weekly"
    if declare -F hm_notify_send_webhook >/dev/null 2>&1; then
      hm_notify_send_webhook "Raport tygodniowy" "${json}" info || true
    fi
  fi
}

hm_report_schedule() {
  local action="${1:-status}" file
  file="$(hm_report_cron_file)"
  case "${action}" in
    enable)
      mkdir -p "$(dirname "${file}")"
      printf '%s\n' '# hmtools-report' '15 6 * * 1 root hmtools report weekly --send' > "${file}"
      hm_ok "Cron: ${file}"
      ;;
    disable)
      if [[ -f "${file}" ]] && grep -q 'hmtools-report' "${file}"; then
        rm -f "${file}"
        hm_ok "Usunięto ${file}"
      else
        hm_warn "To nie jest plik hmtools-report."
        return 1
      fi
      ;;
    status)
      if [[ -f "${file}" ]]; then
        hm_ok "Cron zainstalowany: ${file}"
      else
        hm_warn "Brak crona raportu."
        return 1
      fi
      ;;
    *)
      hm_err "Użycie: report schedule enable|disable|status"
      return 1
      ;;
  esac
}

cmd_report() {
  local sub="${1:-}"
  shift || true
  case "${sub}" in
    weekly) hm_report_weekly "$@" ;;
    schedule) hm_report_schedule "$@" ;;
    help|-h|--help|"") hm_help_topic report ;;
    *)
      hm_err "Użycie: report weekly|schedule"
      return 1
      ;;
  esac
}

_hm_cmd_register report cmd_report 0
