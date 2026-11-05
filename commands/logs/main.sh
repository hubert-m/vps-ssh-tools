#!/usr/bin/env bash
# logs (global) — logs system … (mail/ftp/auth/cyberpanel/modsec/lsws/mysql)


_hm_cmd_help logs <<'EOF'
Użycie (globalnie lub w kontekście):
  logs system mail|ftp|auth|cyberpanel|modsec|lsws|mysql [N]
      [--grep TEXT] [--follow|-f] [--since 1h] [--errors]
  logs clean <cyberpanel|mail|…>   Truncate z kopią ogona (potwierdzenie)

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
      hm_err "Użycie: logs system …  |  logs clean …  |  (w kontekście) logs [N]"
      return 1
      ;;
  esac
}

_hm_cmd_register logs cmd_logs 0
