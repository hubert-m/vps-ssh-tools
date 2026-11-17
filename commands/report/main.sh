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

# Tylko realne problemy (nie high=0 / FAIL=0 / słowo fail2ban).
hm_report_body_has_issue() {
  local body="$1"
  printf '%s\n' "${body}" | grep -Eqi 'failed|wygasa|WYGAS|reboot|ERROR|problem' && return 0
  printf '%s\n' "${body}" | grep -Eq 'critical=[1-9]|high=[1-9]|medium=[1-9]|FAIL=[1-9]|WARN=[1-9]|bans?=[1-9]' && return 0
  printf '%s\n' "${body}" | grep -Eq '(^|[[:space:]])FAIL([[:space:]]|:|$)' && return 0
  return 1
}

hm_json_escape() {
  local s="$1"
  if command -v python3 >/dev/null 2>&1; then
    BODY="${s}" python3 -c 'import json,os; print(json.dumps(os.environ.get("BODY",""), ensure_ascii=False)[1:-1], end="")' 2>/dev/null && return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    local q
    q="$(printf '%s' "${s}" | jq -Rs . 2>/dev/null)" || true
    if [[ -n "${q}" && "${q}" == \"*\" ]]; then
      printf '%s' "${q:1:${#q}-2}"
      return 0
    fi
  fi
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  s="$(printf '%s' "${s}" | tr -d '\000-\010\013\014\016-\037')"
  printf '%s' "${s}"
}

hm_report_fmt_bytes() {
  local n="$1"
  [[ "${n}" =~ ^[0-9]+$ ]] || { printf '%s' "${n}"; return 0; }
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec --suffix=B "${n}" 2>/dev/null && return 0
  fi
  printf '%s B' "${n}"
}

hm_report_format_traffic() {
  local line key val
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" =~ ^(rx|tx):\ *([0-9]+)[[:space:]]*$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      printf '%s: %s\n' "${key}" "$(hm_report_fmt_bytes "${val}")"
    else
      printf '%s\n' "${line}"
    fi
  done <<< "$1"
}

hm_report_push() {
  local title="$1" body="$2" issue=0
  body="$(hm_report_humanize "${title}" "${body}")"
  if hm_report_body_has_issue "${body}"; then
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

# JSON → czytelny tekst (poczta).
hm_report_humanize() {
  local title="$1" body="$2" out=""
  body="${body#"${body%%[![:space:]]*}"}"
  body="${body%"${body##*[![:space:]]}"}"
  case "${body}" in
    \{*|\[*) ;;
    *)
      printf '%s' "${body}"
      return 0
      ;;
  esac
  if command -v python3 >/dev/null 2>&1; then
    out="$(
      TITLE="${title}" BODY="${body}" python3 - <<'PY' 2>/dev/null || true
import json, os, sys
title = os.environ.get("TITLE", "")
raw = os.environ.get("BODY", "")
try:
    data = json.loads(raw)
except Exception:
    print(raw)
    sys.exit(0)

def line(*parts):
    print(" ".join(str(p) for p in parts if p is not None))

if title == "Aktualizacje" and isinstance(data, dict):
    c = int(data.get("critical", 0) or 0)
    h = int(data.get("high", 0) or 0)
    m = int(data.get("medium", 0) or 0)
    low = int(data.get("low", 0) or 0)
    line(f"Aktualizacje: critical={c} high={h} medium={m} low={low}")
    items = data.get("items") or []
    for it in items[:12]:
        if not isinstance(it, dict):
            continue
        line(f"  [{it.get('severity','?')}] {it.get('subject') or it.get('id') or '?'}")
    if len(items) > 12:
        line(f"  … +{len(items)-12} więcej")
elif title == "Audyt" and isinstance(data, dict):
    score = data.get("score", "?")
    checks = data.get("checks") or []
    fails = [c for c in checks if isinstance(c, dict) and c.get("status") == "FAIL"]
    warns = [c for c in checks if isinstance(c, dict) and c.get("status") == "WARN"]
    line(f"Audyt: {score}/100  FAIL={len(fails)} WARN={len(warns)} checks={len(checks)}")
    for c in fails[:15]:
        line(f"  FAIL {c.get('id','?')}: {c.get('desc','')}")
    if len(fails) > 15:
        line(f"  … +{len(fails)-15} FAIL")
elif title == "Zasoby":
    rows = data if isinstance(data, list) else [data]
    any_data = False
    for row in rows:
        if not isinstance(row, dict):
            continue
        metric = row.get("metric") or row.get("name") or "?"
        if row.get("empty") is True:
            line(f"{metric}: brak danych")
            continue
        any_data = True
        bits = []
        for k in ("avg", "p95", "max", "value", "unit", "scope"):
            if k in row and row[k] not in (None, ""):
                bits.append(f"{k}={row[k]}")
        if not bits:
            bits = [f"{k}={v}" for k, v in row.items() if k not in ("metric", "name", "empty")]
        line(f"{metric}: " + (", ".join(bits) if bits else "ok"))
    if not any_data and rows:
        line("(uruchom stats collect / stats week)")
elif title == "Kopie" and isinstance(data, dict) and "snapshots" in data:
    snaps = data.get("snapshots") or []
    if not snaps:
        line("Brak lokalnych snapshotów backup.")
    else:
        latest = {}
        for s in snaps:
            if not isinstance(s, dict):
                continue
            scope = s.get("scope") or "?"
            stamp = s.get("stamp") or ""
            if scope not in latest or stamp > latest[scope].get("stamp", ""):
                latest[scope] = s
        for scope, s in sorted(latest.items()):
            ok = "OK" if s.get("ok") is True else "FAIL"
            age = s.get("age_seconds")
            age_h = f"{int(age)//3600}h" if isinstance(age, (int, float)) else "?"
            line(f"{scope}: {s.get('stamp')} {ok} (wiek {age_h})")
elif title == "Usługi" and isinstance(data, dict) and "services" in data:
    svcs = data.get("services") or []
    failed = [s for s in svcs if isinstance(s, dict) and str(s.get("active", "")).lower() not in ("active", "running")]
    line(f"Usługi: {len(svcs)} zainstalowanych, nieaktywnych={len(failed)}")
    for s in failed[:20]:
        line(f"  {s.get('name') or s.get('unit')}: {s.get('active')}")
    if not failed:
        line("Brak usług w stanie failed/inactive.")
elif title == "Certyfikaty" and isinstance(data, dict) and "certs" in data:
    certs = data.get("certs") or []
    if not certs:
        line("Brak certyfikatów.")
    else:
        for c in certs[:30]:
            if not isinstance(c, dict):
                continue
            dom = c.get("domain") or "?"
            days = c.get("days")
            st = c.get("status") or ""
            if days is None:
                line(f"{dom}: {st or '?'}")
            else:
                try:
                    d = int(days)
                except Exception:
                    d = days
                if isinstance(d, int) and d < 30:
                    line(f"{dom}: wygasa za {d}d ({st or 'WKRÓTCE'})")
                else:
                    line(f"{dom}: {d}d ({st or 'OK'})")
        if len(certs) > 30:
            line(f"… +{len(certs)-30} więcej")
elif title == "Dysk" and isinstance(data, dict) and "filesystems" in data:
    fss = data.get("filesystems") or []
    if not fss:
        line("Brak systemów plików.")
    else:
        for fs in fss[:20]:
            if not isinstance(fs, dict):
                continue
            mount = fs.get("mount") or "?"
            used = fs.get("used_percent")
            avail = fs.get("avail_kb")
            fstype = fs.get("fstype") or ""
            bits = [f"{used}%" if used is not None else "?", f"avail_kb={avail}" if avail is not None else None]
            if fstype:
                bits.append(fstype)
            line(f"{mount}: " + " ".join(str(b) for b in bits if b is not None))
else:
    if isinstance(data, dict):
        keys = ", ".join(list(data.keys())[:8])
        line(f"(json) klucze: {keys}")
    elif isinstance(data, list):
        line(f"(json) {len(data)} pozycji")
    else:
        print(raw)
PY
    )"
    if [[ -n "${out}" ]]; then
      printf '%s' "${out}"
      return 0
    fi
  fi
  case "${title}" in
    Aktualizacje)
      printf '%s' "${body}" | tr ',' '\n' | grep -E '"(critical|high|medium|low)"' | tr -d '{}"' | sed 's/^/  /' | head -8
      ;;
    Audyt)
      if printf '%s' "${body}" | grep -qoE '"score":[0-9]+'; then
        printf 'Audyt: %s/100\n' "$(printf '%s' "${body}" | sed -n 's/.*"score":\([0-9]*\).*/\1/p' | head -1)"
      fi
      printf '%s' "${body}" | tr '{}' '\n' | grep -F '"status":"FAIL"' | head -10 || true
      ;;
    Zasoby)
      if printf '%s' "${body}" | grep -q '"empty":true'; then
        printf 'Zasoby: brak danych (stats collect)\n'
      else
        printf '%s\n' "${body}" | head -c 400
      fi
      ;;
    Certyfikaty)
      printf '%s' "${body}" | tr '{}' '\n' | grep -E '"domain"|"days"|"status"' | head -20 || printf '%s\n' "${body}" | head -c 400
      ;;
    Dysk)
      printf '%s' "${body}" | tr '{}' '\n' | grep -E '"mount"|"used_percent"' | head -20 || printf '%s\n' "${body}" | head -c 400
      ;;
    *)
      printf '%s\n' "${body}" | head -c 500
      ;;
  esac
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
    services)
      declare -F cmd_services >/dev/null 2>&1 && out="$(cmd_services "${@:2}" 2>/dev/null || true)"
      ;;
    ssl)
      declare -F cmd_ssl >/dev/null 2>&1 && out="$(cmd_ssl "${@:2}" 2>/dev/null || true)"
      ;;
    disk)
      declare -F cmd_disk >/dev/null 2>&1 && out="$(cmd_disk "${@:2}" 2>/dev/null || true)"
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

# Kopie: lista snapshotów / historia verify — nie „backup status” (pomoc konfiguracji).
hm_report_backup_body() {
  local out="" hist root line scope stamp
  if declare -F hm_json_emit >/dev/null 2>&1; then
    out="$(hm_json_emit backup_list 2>/dev/null || true)"
    if [[ -n "${out}" && "${out}" != '{"snapshots":[]}' ]]; then
      printf '%s' "${out}"
      return 0
    fi
  fi
  hist="${HM_BACKUP_VERIFY_HISTORY:-/var/lib/hmtools/backup-verify/history.jsonl}"
  if [[ -f "${hist}" ]]; then
    out="$(tail -n 8 "${hist}" 2>/dev/null || true)"
    if [[ -n "${out}" ]]; then
      printf 'Ostatnie backup verify:\n%s\n' "${out}"
      return 0
    fi
  fi
  root="${HM_BACKUP_LOCAL_ROOT:-${BACKUP_LOCAL_ROOT:-/backup/hmtools}}"
  if [[ -d "${root}" ]]; then
    out=""
    while IFS= read -r line; do
      [[ -n "${line}" ]] || continue
      scope="$(basename "$(dirname "${line}")")"
      stamp="$(basename "${line}")"
      if [[ -e "${line}/FAILED" ]]; then
        out+="${scope}: ${stamp} FAIL"$'\n'
      else
        out+="${scope}: ${stamp} OK"$'\n'
      fi
    done < <(find "${root}" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | sort | tail -n 20)
    if [[ -n "${out}" ]]; then
      printf '%s' "${out}"
      return 0
    fi
  fi
  # ostatnia szansa: list bez status/help
  out="$(hm_report_capture backup list 2>/dev/null || true)"
  case "${out}" in
    *"Backup — cele"*|*"Dodaj:"*|*"backup target add"*)
      printf ''
      ;;
    *)
      printf '%s' "${out}"
      ;;
  esac
}

hm_report_services_body() {
  local out failed
  if declare -F hm_json_emit >/dev/null 2>&1; then
    out="$(hm_json_emit services 2>/dev/null || true)"
    if [[ -n "${out}" && "${out}" != '{"services":[]}' ]]; then
      printf '%s' "${out}"
      return 0
    fi
  fi
  out="$(hm_report_capture services list 2>/dev/null || true)"
  if [[ -n "${out}" ]]; then
    printf '%s' "${out}"
    return 0
  fi
  if command -v systemctl >/dev/null 2>&1; then
    failed="$(systemctl --failed --no-legend --plain 2>/dev/null || true)"
    if [[ -n "${failed}" ]]; then
      printf 'systemctl --failed:\n%s\n' "${failed}"
      return 0
    fi
    printf 'Brak jednostek w stanie failed.\n'
    return 0
  fi
  printf ''
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

hm_report_take_body() {
  local title="$1" missing="$2" body="$3"
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
  local body
  HM_REPORT_TITLES=()
  HM_REPORT_BODIES=()
  HM_REPORT_ISSUES=()

  if [[ -n "${HM_REPORT_SERVICES:-}" ]]; then
    hm_report_read_or_skip "Usługi" "${HM_REPORT_SERVICES}" "brak danych usług"
  else
    body="$(hm_report_services_body)"
    hm_report_take_body "Usługi" "brak modułu usług (services list / systemctl)" "${body}"
  fi

  hm_report_take "Strony" "${HM_REPORT_HTTP:-}" "brak monitor http (monitor add)" monitor http status --json

  if [[ -n "${HM_REPORT_BACKUP:-}" ]]; then
    hm_report_read_or_skip "Kopie" "${HM_REPORT_BACKUP}" "brak backup"
  else
    body="$(hm_report_backup_body)"
    hm_report_take_body "Kopie" "brak snapshotów backup (backup list / verify)" "${body}"
  fi

  if [[ -n "${HM_REPORT_SSL:-}" ]]; then
    hm_report_read_or_skip "Certyfikaty" "${HM_REPORT_SSL}" "brak ssl"
  else
    hm_report_take "Certyfikaty" "" "brak ssl (ssl / brak stron)" ssl --json
  fi

  hm_report_take "Aktualizacje" "${HM_REPORT_UPDATES:-}" "brak aktualizacji (vuln os)" vuln os --json

  if [[ -n "${HM_REPORT_BANS:-}" ]]; then
    hm_report_read_or_skip "Bany" "${HM_REPORT_BANS}" "brak fail2ban"
  else
    hm_report_take "Bany" "" "brak fail2ban (security fail2ban)" security fail2ban
  fi

  if [[ -n "${HM_REPORT_DISK:-}" ]]; then
    hm_report_read_or_skip "Dysk" "${HM_REPORT_DISK}" "brak statystyk dysku"
  else
    hm_report_take "Dysk" "" "brak dysku (disk)" disk --json
  fi

  hm_report_take "Zasoby" "${HM_REPORT_STATS:-}" "brak stats (stats week)" stats week --json
  hm_report_take "Audyt" "${HM_REPORT_AUDIT:-}" "brak security audit" security audit --json

  if declare -F hm_traffic_summary >/dev/null 2>&1; then
    local traffic
    traffic="$(hm_traffic_summary || true)"
    if [[ -n "${traffic}" ]]; then
      traffic="$(hm_report_format_traffic "${traffic}")"
      hm_report_push "Ruch" "${traffic}"
    fi
  fi
  if declare -F hm_dns_watch_summary >/dev/null 2>&1; then
    local domains
    domains="$(hm_dns_watch_summary || true)"
    if [[ -n "${domains}" ]]; then
      hm_report_push "Domeny" "${domains}"
    fi
  fi
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
    title="$(hm_json_escape "${HM_REPORT_TITLES[$i]}")"
    body="$(hm_json_escape "${HM_REPORT_BODIES[$i]}")"
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
