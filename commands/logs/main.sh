#!/usr/bin/env bash
# logs (global) — logs system … (mail/ftp/auth/cyberpanel/modsec/lsws/mysql)


_hm_cmd_help logs <<'EOF'
Użycie (globalnie lub w kontekście):
  logs system mail|ftp|auth|cyberpanel|modsec|lsws|mysql [N]
      [--grep TEXT] [--follow|-f] [--since 1h] [--errors]
  logs clean <cyberpanel|mail|…>   Truncate z kopią ogona (potwierdzenie)
  logs search [--ip X] [--url REGEX] [--status 5xx|404|…] [--since 2h]
      [--site d1,d2] [--limit 200] [--count-by ip|url|site]
  logs rotate status|fix         Status rotacji / propozycja logrotate+journald

W kontekście strony bez „system”:
  logs [N] | errors | stats | follow   — logi vhosta (jak dotychczas)
EOF

# Ścieżki logów wg OS_FAMILY (Debian vs RHEL) + fallbacki
hm_logs_system_paths() {
  local kind="$1"
  hm_detect_all 2>/dev/null || true
  case "${kind}" in
    mail)
      echo "/var/log/mail.log"
      echo "/var/log/maillog"
      echo "/var/log/mail.err"
      ;;
    ftp)
      echo "/var/log/pureftpd.log"
      echo "/var/log/pure-ftpd/pure-ftpd.log"
      echo "/var/log/messages"
      ;;
    auth)
      echo "/var/log/auth.log"
      echo "/var/log/secure"
      ;;
    cyberpanel)
      echo "/usr/local/CyberCP/logs/cyberpanel.log"
      echo "/var/log/cyberpanel/cyberpanel.log"
      echo "/usr/local/lscpd/logs/error.log"
      ;;
    modsec|modsecurity)
      echo "/usr/local/lsws/logs/modsec_audit.log"
      echo "/usr/local/lsws/logs/modsec.log"
      echo "/var/log/modsec_audit.log"
      echo "/var/log/httpd/modsec_audit.log"
      ;;
    lsws|ols)
      [[ -n "${OLS_ROOT:-}" ]] && echo "${OLS_ROOT}/logs/error.log"
      echo "/usr/local/lsws/logs/error.log"
      echo "/usr/local/lsws/logs/stderr.log"
      ;;
    mysql|mariadb)
      echo "/var/log/mysql/error.log"
      echo "/var/log/mysql.err"
      echo "/var/log/mariadb/mariadb.log"
      echo "/var/lib/mysql/$(hostname).err"
      ;;
    *)
      return 1
      ;;
  esac
}

hm_logs_system_journal_unit() {
  local kind="$1"
  case "${kind}" in
    mail) echo "postfix" ;;
    ftp) echo "pure-ftpd" ;;
    auth) echo "ssh" ;;
    cyberpanel) echo "lscpd" ;;
    lsws|ols) echo "lsws" ;;
    mysql|mariadb) echo "mariadb" ;;
    *) echo "" ;;
  esac
}

hm_logs_system_find_files() {
  local kind="$1"
  local f
  while IFS= read -r f; do
    [[ -n "${f}" && -f "${f}" && -r "${f}" ]] && printf '%s\n' "${f}"
  done < <(hm_logs_system_paths "${kind}")
}

cmd_logs_system() {
  local kind="${1:-}"
  shift || true
  local lines=80 grep_pat="" follow=0 since="" errors_only=0
  local arg
  # kind może być po flagach? najpierw kind
  case "${kind}" in
    mail|ftp|auth|cyberpanel|modsec|modsecurity|lsws|ols|mysql|mariadb) ;;
    --since|--grep|--errors|--follow|-f|help|-h|--help|"")
      if [[ "${kind}" == "help" || "${kind}" == "-h" || "${kind}" == "--help" || -z "${kind}" ]]; then
        echo "Użycie: logs system mail|ftp|auth|cyberpanel|modsec|lsws|mysql [N] [--grep T] [--follow] [--since 1h] [--errors]"
        return 0
      fi
      # flagi przed kind — wróć
      set -- "${kind}" "$@"
      kind=""
      ;;
    *)
      if [[ "${kind}" =~ ^[0-9]+$ ]]; then
        lines="${kind}"
        kind="${1:-}"
        shift || true
      fi
      ;;
  esac

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --grep)
        grep_pat="${2:-}"; shift 2 || true ;;
      --grep=*)
        grep_pat="${1#*=}"; shift ;;
      --follow|-f|follow)
        follow=1; shift ;;
      --since)
        since="${2:-}"; shift 2 || true ;;
      --since=*)
        since="${1#*=}"; shift ;;
      --errors|--error)
        errors_only=1; shift ;;
      help|-h|--help)
        echo "Użycie: logs system <kind> [N] [--grep T] [--follow] [--since 1h] [--errors]"
        return 0
        ;;
      *)
        if [[ "$1" =~ ^[0-9]+$ ]]; then
          lines="$1"; shift
        elif [[ -z "${kind}" ]]; then
          kind="$1"; shift
        else
          hm_err "Nieznany argument: $1"
          return 1
        fi
        ;;
    esac
  done

  case "${kind}" in
    mail|ftp|auth|cyberpanel|modsec|modsecurity|lsws|ols|mysql|mariadb) ;;
    *)
      hm_err "Użycie: logs system mail|ftp|auth|cyberpanel|modsec|lsws|mysql …"
      return 1
      ;;
  esac

  local -a files=()
  local f
  while IFS= read -r f; do
    [[ -n "${f}" ]] && files+=("${f}")
  done < <(hm_logs_system_find_files "${kind}")

  local junit
  junit="$(hm_logs_system_journal_unit "${kind}")"

  if [[ "${follow}" -eq 1 ]]; then
    if [[ "${#files[@]}" -gt 0 ]]; then
      hm_info "tail -F (Ctrl+C wraca do hmtools) — ${files[*]}"
      # shellcheck disable=SC2086
      tail -F "${files[@]}" 2>/dev/null || true
      return 0
    fi
    if [[ -n "${junit}" ]] && hm_have_cmd journalctl; then
      hm_info "journalctl -u ${junit} -f (Ctrl+C wraca)"
      journalctl -u "${junit}" -f --no-pager 2>/dev/null || true
      return 0
    fi
    hm_err "Brak pliku logu / journal dla ${kind}."
    return 1
  fi

  echo "${C_BOLD}logs system — ${kind}${C_RESET}"
  local any=0
  if [[ "${#files[@]}" -gt 0 ]]; then
    for f in "${files[@]}"; do
      any=1
      echo "---- ${f} (ostatnie ${lines}) ----"
      local out=""
      if [[ -n "${since}" ]] && hm_have_cmd journalctl; then
        # pliki: użyj find mtime? prościej: tail + grep
        :
      fi
      if [[ "${errors_only}" -eq 1 ]]; then
        out="$(grep -Eih 'error|fail|crit|fatal|panic|denied|reject' "${f}" 2>/dev/null | tail -n "${lines}" || true)"
      elif [[ -n "${grep_pat}" ]]; then
        out="$(grep -F "${grep_pat}" "${f}" 2>/dev/null | tail -n "${lines}" || true)"
      else
        out="$(tail -n "${lines}" "${f}" 2>/dev/null || true)"
      fi
      if [[ -n "${out}" ]]; then
        printf '%s\n' "${out}"
      else
        echo "  (brak dopasowań / pusto)"
      fi
      echo
    done
  fi

  # journal fallback / uzupełnienie przy --since lub braku plików
  if [[ -n "${junit}" ]] && hm_have_cmd journalctl; then
    if [[ "${any}" -eq 0 || -n "${since}" ]]; then
      any=1
      echo "---- journalctl -u ${junit}${since:+ --since ${since}} ----"
      local -a jargs=(-u "${junit}" -n "${lines}" --no-pager)
      [[ -n "${since}" ]] && jargs+=(--since "${since}")
      local jout
      jout="$(journalctl "${jargs[@]}" 2>/dev/null || true)"
      if [[ "${errors_only}" -eq 1 ]]; then
        jout="$(printf '%s\n' "${jout}" | grep -Eih 'error|fail|crit|fatal|panic|denied|reject' || true)"
      fi
      if [[ -n "${grep_pat}" ]]; then
        jout="$(printf '%s\n' "${jout}" | grep -F "${grep_pat}" || true)"
      fi
      if [[ -n "${jout}" ]]; then
        printf '%s\n' "${jout}" | sed 's/^/  /'
      else
        echo "  (brak)"
      fi
    fi
  fi

  if [[ "${any}" -eq 0 ]]; then
    hm_warn "Brak czytelnych logów dla ${kind} (sprawdzono ścieżki Debian/RHEL + journal)."
    hm_info "Szukane ścieżki:"
    hm_logs_system_paths "${kind}" | sed 's/^/  /'
    return 1
  fi
  return 0
}

cmd_logs_clean() {
  local kind="${1:-}"
  [[ -n "${kind}" ]] || { hm_err "Użycie: logs clean <cyberpanel|mail|ftp|auth|modsec|lsws|mysql>"; return 1; }
  case "${kind}" in
    mail|ftp|auth|cyberpanel|modsec|modsecurity|lsws|ols|mysql|mariadb) ;;
    *) hm_err "Nieznany kind: ${kind}"; return 1 ;;
  esac
  local -a files=()
  local f
  while IFS= read -r f; do
    [[ -n "${f}" ]] && files+=("${f}")
  done < <(hm_logs_system_find_files "${kind}")
  [[ "${#files[@]}" -gt 0 ]] || { hm_err "Brak plików logu dla ${kind}."; return 1; }

  local -a steps=()
  for f in "${files[@]}"; do
    steps+=("Kopia ogona (ostatnie 200 linii) → ${f}.hmtools.tail + truncate ${f}")
  done
  if ! hm_confirm_plan "logs clean — ${kind}" \
    "Przycięcie logów (truncate) — dane historyczne poza ogonem znikną z pliku." \
    "${steps[@]}"; then
    return 0
  fi
  for f in "${files[@]}"; do
    local bak="${f}.hmtools.tail.$(date +%Y%m%d%H%M%S)"
    tail -n 200 "${f}" > "${bak}" 2>/dev/null || true
    chmod 600 "${bak}" 2>/dev/null || true
    : > "${f}" || truncate -s 0 "${f}" 2>/dev/null || true
    hm_ok "Wyczyszczono ${f} (ogon: ${bak})"
  done
}

# Bezpieczny regex: tylko litery/cyfry i metaznaki regex; bez $() / ` / ; / newline.
hm_logs_safe_regex() {
  local r="${1:-}"
  [[ -n "${r}" ]] || return 1
  [[ "${r}" != *$'\n'* && "${r}" != *'`'* && "${r}" != *'$('* && "${r}" != *';'* ]] || return 1
  [[ "${#r}" -le 256 ]] || return 1
  return 0
}

hm_logs_parse_since_epoch() {
  local since="${1:-}" now
  now="$(date +%s)"
  [[ -n "${since}" ]] || { printf '%s' 0; return 0; }
  if [[ "${since}" =~ ^([0-9]+)([smhd])$ ]]; then
    local n="${BASH_REMATCH[1]}" u="${BASH_REMATCH[2]}" sec=0
    case "${u}" in
      s) sec="${n}" ;;
      m) sec=$((n * 60)) ;;
      h) sec=$((n * 3600)) ;;
      d) sec=$((n * 86400)) ;;
    esac
    printf '%s' "$((now - sec))"
    return 0
  fi
  if date -d "${since}" +%s >/dev/null 2>&1; then
    date -d "${since}" +%s
    return 0
  fi
  printf '%s' 0
}

# Epoch → YYYYMMDDHHMMSS (porównanie stringów w awk, bez mktime).
hm_logs_epoch_cmp() {
  local ep="${1:-0}"
  [[ "${ep}" =~ ^[0-9]+$ && "${ep}" -gt 0 ]] || { printf '%s' 0; return 0; }
  if date -d "@${ep}" +%Y%m%d%H%M%S >/dev/null 2>&1; then
    date -d "@${ep}" +%Y%m%d%H%M%S
    return 0
  fi
  if date -r "${ep}" +%Y%m%d%H%M%S >/dev/null 2>&1; then
    date -r "${ep}" +%Y%m%d%H%M%S
    return 0
  fi
  printf '%s' 0
}

# Jedno awk: filtr IP/URL/status + czas linii CLF [dd/Mon/yyyy:HH:MM:SS …].
hm_logs_search_awk() {
  local domain="$1" ip="$2" url="$3" status="$4" since_cmp="$5" until_cmp="$6"
  awk -v domain="${domain}" -v ip="${ip}" -v url="${url}" -v status="${status}" \
      -v since_cmp="${since_cmp}" -v until_cmp="${until_cmp}" '
    BEGIN {
      split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", _m, " ")
      for (i = 1; i <= 12; i++) mon[_m[i]] = sprintf("%02d", i)
    }
    function line_cmp(s,   m, dd, mo, yy, hh, mi, ss) {
      if (!match(s, /\[[0-9]{2}\/[A-Za-z]{3}\/[0-9]{4}:[0-9]{2}:[0-9]{2}:[0-9]{2}/)) return ""
      m = substr(s, RSTART + 1, RLENGTH - 1)
      dd = substr(m, 1, 2); mo = substr(m, 4, 3); yy = substr(m, 8, 4)
      hh = substr(m, 13, 2); mi = substr(m, 16, 2); ss = substr(m, 19, 2)
      if (!(mo in mon)) return ""
      return yy mon[mo] dd hh mi ss
    }
    {
      if (since_cmp != "0" || until_cmp != "0") {
        ts = line_cmp($0)
        if (ts == "") next
        if (since_cmp != "0" && ts < since_cmp) next
        if (until_cmp != "0" && ts > until_cmp) next
      }
      if (ip != "" && index($0, ip) == 0) next
      if (url != "" && $0 !~ url) next
      if (status != "") {
        if (status == "5xx" || status == "5XX") {
          if ($0 !~ /[[:space:]]5[0-9]{2}[[:space:]]/) next
        } else if (status == "4xx" || status == "4XX") {
          if ($0 !~ /[[:space:]]4[0-9]{2}[[:space:]]/) next
        } else if (index($0, " " status " ") == 0) next
      }
      printf "%s\t%s\n", domain, $0
    }
  '
}

# Lista plików access (+ .gz) dla domeny: ścieżka TAB domena
hm_logs_search_files_for_domain() {
  local domain="$1" f
  if declare -F hm_site_context_push >/dev/null 2>&1 && declare -F hm_site_log_candidates >/dev/null 2>&1; then
    hm_site_context_push "${domain}" 2>/dev/null || true
    while IFS= read -r f; do
      [[ -n "${f}" && -f "${f}" ]] || continue
      case "${f}" in
        *error*) continue ;;
      esac
      printf '%s\t%s\n' "${f}" "${domain}"
      if [[ -f "${f}.1.gz" ]]; then printf '%s\t%s\n' "${f}.1.gz" "${domain}"; fi
      if [[ -f "${f}.gz" ]]; then printf '%s\t%s\n' "${f}.gz" "${domain}"; fi
    done < <(hm_site_log_candidates "${domain}" access 2>/dev/null || true)
    hm_site_context_pop 2>/dev/null || true
    return 0
  fi
  # Fixture / test: HM_LOGS_SEARCH_ROOT/<domain>/access.log
  if [[ -n "${HM_LOGS_SEARCH_ROOT:-}" ]]; then
    for f in \
      "${HM_LOGS_SEARCH_ROOT}/${domain}/access.log" \
      "${HM_LOGS_SEARCH_ROOT}/${domain}/access.log.gz" \
      "${HM_LOGS_SEARCH_ROOT}/${domain}.access_log" \
      "${HM_LOGS_SEARCH_ROOT}/${domain}.access_log.gz"
    do
      [[ -f "${f}" ]] && printf '%s\t%s\n' "${f}" "${domain}"
    done
  fi
}

hm_logs_search_iter_sites() {
  local filter="${1:-}" d
  local -a sites=()
  if [[ -n "${filter}" ]]; then
    IFS=',' read -r -a sites <<< "${filter}"
  elif declare -F hm_discover_sites >/dev/null 2>&1; then
    hm_discover_sites 2>/dev/null || true
    sites=("${HM_SITES_LIST[@]+"${HM_SITES_LIST[@]}"}")
  elif [[ -n "${HM_LOGS_SEARCH_SITES:-}" ]]; then
    IFS=',' read -r -a sites <<< "${HM_LOGS_SEARCH_SITES}"
  fi
  for d in "${sites[@]+"${sites[@]}"}"; do
    d="$(printf '%s' "${d}" | tr -d '[:space:]')"
    [[ -n "${d}" ]] || continue
    printf '%s\n' "${d}"
  done
}

hm_logs_search_match_line() {
  local line="$1" ip="$2" url="$3" status="$4"
  if [[ -n "${ip}" ]]; then
    printf '%s' "${line}" | grep -Fq -- "${ip}" || return 1
  fi
  if [[ -n "${url}" ]]; then
    printf '%s\n' "${line}" | grep -Eq -- "${url}" || return 1
  fi
  if [[ -n "${status}" ]]; then
    case "${status}" in
      5xx|5XX) printf '%s\n' "${line}" | grep -Eq '[[:space:]]5[0-9]{2}[[:space:]]' || return 1 ;;
      4xx|4XX) printf '%s\n' "${line}" | grep -Eq '[[:space:]]4[0-9]{2}[[:space:]]' || return 1 ;;
      *)
        [[ "${status}" =~ ^[0-9]{3}$ ]] || return 1
        printf '%s' "${line}" | grep -Fq -- " ${status} " || return 1
        ;;
    esac
  fi
  return 0
}

cmd_logs_search() {
  local ip="" url="" status="" since="" until="" sites="" limit=200 count_by=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ip) ip="${2:-}"; shift 2 || true ;;
      --ip=*) ip="${1#*=}"; shift ;;
      --url) url="${2:-}"; shift 2 || true ;;
      --url=*) url="${1#*=}"; shift ;;
      --status) status="${2:-}"; shift 2 || true ;;
      --status=*) status="${1#*=}"; shift ;;
      --since) since="${2:-}"; shift 2 || true ;;
      --since=*) since="${1#*=}"; shift ;;
      --until) until="${2:-}"; shift 2 || true ;;
      --until=*) until="${1#*=}"; shift ;;
      --site|--sites) sites="${2:-}"; shift 2 || true ;;
      --site=*|--sites=*) sites="${1#*=}"; shift ;;
      --limit) limit="${2:-200}"; shift 2 || true ;;
      --limit=*) limit="${1#*=}"; shift ;;
      --count-by) count_by="${2:-}"; shift 2 || true ;;
      --count-by=*) count_by="${1#*=}"; shift ;;
      help|-h|--help)
        echo "Użycie: logs search [--ip X] [--url REGEX] [--status 5xx] [--since 2h] [--site d1,d2] [--limit N] [--count-by ip|url|site]"
        return 0
        ;;
      *) hm_err "Nieznany argument: $1"; return 1 ;;
    esac
  done
  [[ "${limit}" =~ ^[0-9]+$ && "${limit}" -ge 1 && "${limit}" -le 10000 ]] || {
    hm_err "--limit musi być 1–10000"; return 1
  }
  if [[ -n "${url}" ]] && ! hm_logs_safe_regex "${url}"; then
    hm_err "Niebezpieczny lub zbyt długi --url regex."; return 1
  fi
  if [[ -n "${ip}" ]] && ! [[ "${ip}" =~ ^[0-9A-Fa-f.:]+$ ]]; then
    hm_err "Nieprawidłowe --ip."; return 1
  fi
  case "${count_by}" in
    ""|ip|url|site) ;;
    *) hm_err "--count-by: ip|url|site"; return 1 ;;
  esac

  local domain file n=0 tmpout since_ep until_ep since_cmp until_cmp
  since_ep="$(hm_logs_parse_since_epoch "${since}")"
  until_ep="$(hm_logs_parse_since_epoch "${until}")"
  since_cmp="$(hm_logs_epoch_cmp "${since_ep}")"
  until_cmp="$(hm_logs_epoch_cmp "${until_ep}")"
  tmpout="$(mktemp)"
  echo "${C_BOLD}logs search${C_RESET}${ip:+ ip=${ip}}${url:+ url=${url}}${status:+ status=${status}}"
  while IFS= read -r domain; do
    [[ -n "${domain}" ]] || continue
    while IFS=$'\t' read -r file _dom; do
      [[ -n "${file}" && -f "${file}" ]] || continue
      {
        if [[ "${file}" == *.gz ]]; then
          zcat -f -- "${file}" 2>/dev/null || gzip -dc -- "${file}" 2>/dev/null || true
        else
          cat -- "${file}" 2>/dev/null || true
        fi
      } | hm_logs_search_awk "${domain}" "${ip}" "${url}" "${status}" "${since_cmp}" "${until_cmp}"
    done < <(hm_logs_search_files_for_domain "${domain}")
  done < <(hm_logs_search_iter_sites "${sites}") > "${tmpout}"

  if [[ -n "${count_by}" ]]; then
    awk -F'\t' -v mode="${count_by}" '
      NF < 2 { next }
      mode == "site" { k=$1 }
      mode == "ip" { split($2, a, /[[:space:]]+/); k=a[1] }
      mode == "url" {
        n=split($2, a, /[[:space:]]+/); k="?"
        for (i=1;i<=n;i++) if (a[i] ~ /^\// || a[i] ~ /^https?:/) { k=a[i]; break }
        if (k=="?" && n>=7) k=a[7]
      }
      { c[k]++ }
      END { for (k in c) printf "%8d  %s\n", c[k], k }
    ' "${tmpout}" | sort -nr | head -n "${limit}"
  else
    while IFS=$'\t' read -r domain line || [[ -n "${line}" ]]; do
      [[ -n "${line}" ]] || continue
      n=$((n + 1))
      [[ "${n}" -le "${limit}" ]] || break
      printf '%-24s %s\n' "${domain}" "${line}"
    done < "${tmpout}"
    [[ "${n}" -eq 0 ]] && echo "  (brak dopasowań)"
  fi
  rm -f "${tmpout}"
  return 0
}

cmd_logs_rotate_status() {
  local -a paths=()
  local f conf
  paths+=(
    /etc/logrotate.d/lsws
    /etc/logrotate.d/openlitespeed
    /etc/logrotate.d/nginx
    /etc/logrotate.d/apache2
    /etc/logrotate.d/httpd
    /etc/logrotate.d/rsyslog
    /etc/logrotate.d/hmtools
  )
  echo "${C_BOLD}logs rotate status${C_RESET}"
  echo "Konfiguracje logrotate:"
  for conf in "${paths[@]}"; do
    if [[ -f "${conf}" ]]; then
      printf '  OK   %s\n' "${conf}"
    else
      printf '  BRAK %s\n' "${conf}"
    fi
  done
  if [[ -n "${HM_LOGS_SEARCH_ROOT:-}" ]]; then
    echo "Logi (fixture):"
    find "${HM_LOGS_SEARCH_ROOT}" -type f \( -name '*.log' -o -name '*_log' \) -printf '  %s\t%p\n' 2>/dev/null \
      || find "${HM_LOGS_SEARCH_ROOT}" -type f \( -name '*.log' -o -name '*_log' \) -exec ls -la {} \; 2>/dev/null | sed 's/^/  /'
  else
    echo "Największe logi OLS/stron (jeśli istnieją):"
    for f in /usr/local/lsws/logs/*.log /usr/local/lsws/logs/*_log /var/log/nginx/*.log; do
      [[ -f "${f}" ]] || continue
      ls -lh "${f}" 2>/dev/null | awk '{print "  " $5 "\t" $9}'
    done | head -n 20
  fi
  if [[ -f /etc/systemd/journald.conf ]]; then
    local max
    max="$(grep -E '^SystemMaxUse=' /etc/systemd/journald.conf 2>/dev/null | tail -1 || true)"
    echo "journald SystemMaxUse: ${max:-'(domyślne / nieustawione)'}"
  fi
}

cmd_logs_rotate_fix() {
  local conf="${HM_LOGS_ROTATE_CONF:-/etc/logrotate.d/hmtools-sites}"
  local body journal_max="${HM_LOGS_JOURNAL_MAX:-500M}"
  body="$(cat <<EOF
# hmtools — rotacja access/error stron (propozycja)
/home/*/logs/*.log
/home/*/logs/*_log
/usr/local/lsws/logs/*.log
/usr/local/lsws/logs/*_log
{
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    sharedscripts
    postrotate
        [ -x /usr/local/lsws/bin/lswsctrl ] && /usr/local/lsws/bin/lswsctrl reopen 2>/dev/null || true
    endscript
}
EOF
)"
  if [[ "${HMTOOLS_TEST:-}" == "1" ]]; then
    conf="${HM_LOGS_ROTATE_CONF:-}"
    [[ -n "${conf}" ]] || conf="$(mktemp)"
    printf '%s\n' "${body}" > "${conf}"
    if hm_have_cmd logrotate; then
      logrotate -d "${conf}" >/dev/null 2>&1 && hm_ok "logrotate -d OK (${conf})" || hm_warn "logrotate -d ostrzeżenia"
    else
      hm_ok "Zapisano fixture ${conf} (brak logrotate w PATH)"
    fi
    printf 'SystemMaxUse=%s\n' "${journal_max}"
    return 0
  fi
  local -a steps=(
    "Zapis ${conf} (logrotate stron/OLS)"
    "Walidacja: logrotate -d ${conf}"
    "Opcjonalnie SystemMaxUse=${journal_max} w journald.conf"
  )
  hm_confirm_plan "logs rotate fix" "Propozycja rotacji logów stron i limitu journald." "${steps[@]}" || return 0
  local tmp
  tmp="$(mktemp)"
  printf '%s\n' "${body}" > "${tmp}"
  if hm_have_cmd logrotate; then
    if ! logrotate -d "${tmp}" >/dev/null 2>&1; then
      hm_err "logrotate -d nie przeszedł — nie zapisuję."
      rm -f "${tmp}"
      return 1
    fi
  fi
  mkdir -p "$(dirname "${conf}")"
  mv -f "${tmp}" "${conf}"
  chmod 644 "${conf}"
  hm_ok "Zapisano ${conf}"
  if [[ -f /etc/systemd/journald.conf ]] && ! grep -qE '^SystemMaxUse=' /etc/systemd/journald.conf; then
    printf '\n# hmtools\nSystemMaxUse=%s\n' "${journal_max}" >> /etc/systemd/journald.conf
    hm_ok "Dodano SystemMaxUse=${journal_max} do journald.conf (wymaga restart journald)."
  fi
}

cmd_logs_rotate() {
  local sub="${1:-status}"
  shift || true
  case "${sub}" in
    status) cmd_logs_rotate_status "$@" ;;
    fix|apply) cmd_logs_rotate_fix "$@" ;;
    help|-h|--help) echo "Użycie: logs rotate status|fix"; return 0 ;;
    *) hm_err "Użycie: logs rotate status|fix"; return 1 ;;
  esac
}

cmd_logs() {
  local sub="${1:-}"
  case "${sub}" in
    system|sys)
      shift || true
      cmd_logs_system "$@"
      ;;
    clean|truncate)
      shift || true
      cmd_logs_clean "$@"
      ;;
    search)
      shift || true
      cmd_logs_search "$@"
      ;;
    rotate)
      shift || true
      cmd_logs_rotate "$@"
      ;;
    help|-h|--help)
      hm_help_topic logs
      ;;
    *)
      # w kontekście strony — deleguj do site logs (gdy wywołane globalnie z args)
      if [[ -n "${HM_SITE_DOMAIN:-}" ]] && declare -F cmd_site_logs >/dev/null 2>&1; then
        cmd_site_logs "$@"
        return $?
      fi
      if [[ -z "${sub}" ]]; then
        hm_help_topic logs
        return 0
      fi
      hm_err "Użycie: logs system …  |  logs search …  |  logs rotate …  |  logs clean …  |  (w kontekście) logs [N]"
      return 1
      ;;
  esac
}

_hm_cmd_register logs cmd_logs 0
