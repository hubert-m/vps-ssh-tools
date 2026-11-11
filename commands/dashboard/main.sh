#!/usr/bin/env bash
# Panel tylko do odczytu: statyczny HTML z --json, nasłuch na loopback.


_HM_DASH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=html.sh
source "${_HM_DASH_DIR}/html.sh"

_hm_cmd_help dashboard <<'EOF'
Użycie:
  dashboard build [--out KATALOG]
      Statyczny index.html z danych --json (health, usługi, kopie, certy,
      domeny, uptime, aktualizacje, security audit).
  dashboard serve [--port 8765] [--python] [--dry-run]
      Nasłuch tylko na 127.0.0.1. Inny adres jest odrzucany.
      --python: python3 -m http.server --bind 127.0.0.1
  dashboard schedule enable|disable [--yes]
  dashboard publish --domain D --allow IP [--yes]
      Opcjonalny vhost. Ostrzeżenie: to wychodzi poza tunel SSH.

Podgląd przez tunel: ssh -L 8765:127.0.0.1:8765 user@host
EOF

hm_dashboard_out_dir() {
  local dir="${1:-${HM_DASHBOARD_DIR:-/var/lib/hmtools/dashboard}}"
  printf '%s' "${dir}"
}

hm_dashboard_build() {
  local out=""
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --out)
        out="${2:-}"
        [[ -n "${out}" ]] || {
          hm_err "Użycie: dashboard build --out KATALOG"
          return 1
        }
        shift 2 || true
        ;;
      --out=*)
        out="${1#*=}"
        shift
        ;;
      *)
        hm_err "Nieznana flaga: ${1}"
        return 1
        ;;
    esac
  done
  if ! declare -F hm_json_emit >/dev/null 2>&1; then
    hm_err "Brak danych --json. Najpierw załaduj moduł metrics."
    return 1
  fi
  out="$(hm_dashboard_out_dir "${out}")"
  mkdir -p "${out}" || {
    hm_err "Nie mogę utworzyć ${out}."
    return 1
  }
  local work html tmp_html now
  work="$(mktemp -d "${TMP_DIR:-/tmp}/hmtools-dash.XXXXXX")" || return 1
  hm_json_emit webs >"${work}/webs.json" 2>/dev/null || : >"${work}/webs.json"
  hm_json_emit services >"${work}/services.json" 2>/dev/null || : >"${work}/services.json"
  hm_json_emit backup_list >"${work}/backup.json" 2>/dev/null || : >"${work}/backup.json"
  hm_json_emit ssl >"${work}/ssl.json" 2>/dev/null || : >"${work}/ssl.json"
  hm_json_emit security_status >"${work}/security.json" 2>/dev/null || : >"${work}/security.json"
  if declare -F hm_json_table >/dev/null 2>&1 && declare -F hm_rows_http >/dev/null 2>&1; then
    hm_json_table checks "domain:s,up:b,code:s" hm_rows_http >"${work}/http.json" 2>/dev/null || : >"${work}/http.json"
  else
    : >"${work}/http.json"
  fi
  if declare -F hm_health_check >/dev/null 2>&1; then
    hm_health_check --json >"${work}/health.json" 2>/dev/null || true
  else
    : >"${work}/health.json"
  fi
  if declare -F cmd_security_audit >/dev/null 2>&1; then
    cmd_security_audit --json >"${work}/audit.json" 2>/dev/null || true
  else
    : >"${work}/audit.json"
  fi

  now="${HM_DASHBOARD_NOW:-}"
  [[ -n "${now}" ]] || now="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)"
  tmp_html="${work}/index.html"
  {
    printf '%s\n' '<!DOCTYPE html>' '<html lang="pl">' '<head>' \
      '<meta charset="utf-8">' '<title>hmtools</title>' '</head>' '<body>'
    printf '<h1>%s</h1>\n' "$(hm_html_escape "hmtools")"
    printf '<p>%s</p>\n' "$(hm_html_escape "Wygenerowano: ${now}")"
    if [[ -s "${work}/health.json" ]]; then
      local health ok_v disk_v
      health="$(cat "${work}/health.json")"
      ok_v="$(hm_html_field "${health}" "ok")"
      disk_v="$(hm_html_field "${health}" "disk_used")"
      printf '<h2>%s</h2>\n<table>\n' "$(hm_html_escape "Health")"
      hm_html_kv ok "${ok_v}"
      hm_html_kv disk_used "${disk_v}"
      printf '</table>\n'
    else
      printf '<h2>%s</h2>\n<p>brak danych</p>\n' "$(hm_html_escape "Health")"
    fi
    hm_html_table_json "Domeny" "${work}/webs.json" domain php ssl status
    hm_html_table_json "Certyfikaty" "${work}/ssl.json" domain status days expiry
    hm_html_table_json "Usługi" "${work}/services.json" name active enabled
    hm_html_table_json "Kopie" "${work}/backup.json" scope stamp age_seconds ok
    hm_html_table_json "Uptime" "${work}/http.json" domain up code
    if [[ -s "${work}/security.json" ]]; then
      local sec upd bans
      sec="$(cat "${work}/security.json")"
      upd="$(hm_html_field "${sec}" "updates_pending")"
      bans="$(hm_html_field "${sec}" "bans")"
      printf '<h2>%s</h2>\n<table>\n' "$(hm_html_escape "Aktualizacje")"
      hm_html_kv updates_pending "${upd}"
      hm_html_kv bans "${bans}"
      printf '</table>\n'
    fi
    hm_html_table_json "Audyt" "${work}/audit.json" id status desc
    printf '%s\n' '</body>' '</html>'
  } >"${tmp_html}"
  mv -f "${tmp_html}" "${out}/index.html" || {
    rm -rf "${work}"
    hm_err "Zapis ${out}/index.html nie powiódł się."
    return 1
  }
  rm -rf "${work}"
  printf '%s\n' "${out}/index.html"
}

hm_dashboard_http_response() {
  local dir="${1:-}" req="${2:-}" path="" file=""
  path="$(printf '%s\n' "${req}" | awk 'NR==1 { print $2 }')"
  case "${path}" in
    ""|"/") path="/index.html" ;;
    /index.html) ;;
    *) path="" ;;
  esac
  if [[ -z "${path}" || "${path}" == *..* || "${path}" != "/index.html" ]]; then
    printf 'HTTP/1.0 404 Not Found\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nnie znaleziono\n'
    return 0
  fi
  file="${dir}/index.html"
  if [[ ! -f "${file}" ]]; then
    printf 'HTTP/1.0 404 Not Found\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nnie znaleziono\n'
    return 0
  fi
  printf 'HTTP/1.0 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\n'
  cat "${file}"
}

hm_dashboard_serve() {
  local port=8765 bind="127.0.0.1" py=0 dry=0 dir=""
  dir="$(hm_dashboard_out_dir)"
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --port)
        port="${2:-}"
        shift 2 || true
        ;;
      --port=*)
        port="${1#*=}"
        shift
        ;;
      --bind)
        bind="${2:-}"
        shift 2 || true
        ;;
      --bind=*)
        bind="${1#*=}"
        shift
        ;;
      --python) py=1; shift ;;
      --dry-run) dry=1; shift ;;
      --out)
        dir="${2:-}"
        shift 2 || true
        ;;
      --out=*)
        dir="${1#*=}"
        shift
        ;;
      *)
        hm_err "Nieznana flaga: ${1}"
        return 1
        ;;
    esac
  done
  [[ "${port}" =~ ^[0-9]+$ && "${port}" -ge 1 && "${port}" -le 65535 ]] || {
    hm_err "Port musi być liczbą 1..65535."
    return 1
  }
  case "${bind}" in
    127.0.0.1|::1) ;;
    localhost) bind="127.0.0.1" ;;
    *)
      hm_err "Nasłuch tylko na 127.0.0.1 lub ::1."
      return 1
      ;;
  esac
  printf 'bind=%s\nport=%s\n' "${bind}" "${port}"
  printf 'ssh -L %s:%s:%s user@host\n' "${port}" "${bind}" "${port}"
  if [[ "${dry}" -eq 1 || "${HM_DASHBOARD_DRY:-}" == "1" ]]; then
    if [[ "${py}" -eq 1 ]]; then
      printf 'cmd=python3 -m http.server --bind %s %s\n' "${bind}" "${port}"
    else
      printf 'cmd=bash-http --bind %s --port %s\n' "${bind}" "${port}"
    fi
    return 0
  fi
  if [[ ! -f "${dir}/index.html" ]]; then
    hm_err "Brak ${dir}/index.html. Najpierw: dashboard build"
    return 1
  fi
  if [[ "${py}" -eq 1 ]]; then
    command -v python3 >/dev/null 2>&1 || {
      hm_err "Brak python3."
      return 1
    }
    exec python3 -m http.server "${port}" --bind "${bind}" --directory "${dir}"
  fi
  hm_info "Plik jest statyczny. Nasłuch loopback: dashboard serve --python"
  printf '%s\n' "${dir}/index.html"
}

hm_dashboard_schedule() {
  local action="${1:-}"
  shift || true
  local yes=0 cron bin
  cron="${HM_DASHBOARD_CRON:-/etc/cron.d/hmtools-dashboard}"
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --yes|-y) yes=1; shift ;;
      *)
        hm_err "Nieznana flaga: ${1}"
        return 1
        ;;
    esac
  done
  case "${action}" in
    enable)
      bin="hmtools"
      if [[ -n "${HMTOOLS_ROOT:-}" && -x "${HMTOOLS_ROOT}/hmtools" ]]; then
        bin="${HMTOOLS_ROOT}/hmtools"
      fi
      local line="*/15 * * * * root ${bin} dashboard build"
      if [[ "${yes}" -ne 1 ]]; then
        hm_confirm_plan "dashboard schedule" "Cron przebuduje HTML." "${line}" || return 1
      fi
      mkdir -p "$(dirname "${cron}")" || {
        hm_err "Nie mogę utworzyć katalogu cron."
        return 1
      }
      printf '%s\n%s\n' "# hmtools dashboard" "${line}" >"${cron}" || {
        hm_err "Zapis ${cron} nie powiódł się."
        return 1
      }
      printf '%s\n' "${cron}"
      ;;
    disable)
      if [[ -f "${cron}" ]]; then
        rm -f "${cron}" || {
          hm_err "Nie mogę usunąć ${cron}."
          return 1
        }
      fi
      printf '%s\n' "${cron}"
      ;;
    *)
      hm_err "Użycie: dashboard schedule enable|disable [--yes]"
      return 1
      ;;
  esac
}

hm_dashboard_publish() {
  local domain="" allow="" yes=0
  local vhost auth pass
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --domain)
        domain="${2:-}"
        shift 2 || true
        ;;
      --domain=*) domain="${1#*=}"; shift ;;
      --allow)
        allow="${2:-}"
        shift 2 || true
        ;;
      --allow=*) allow="${1#*=}"; shift ;;
      --yes|-y) yes=1; shift ;;
      *)
        hm_err "Nieznana flaga: ${1}"
        return 1
        ;;
    esac
  done
  hm_warn "Panel poza tunelem SSH. Zostaw dashboard serve na 127.0.0.1, jeśli publikacja nie jest potrzebna."
  if ! declare -F hm_is_valid_domain >/dev/null 2>&1 || ! hm_is_valid_domain "${domain}"; then
    hm_err "Podaj poprawną domenę: --domain"
    return 1
  fi
  [[ "${allow}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    hm_err "Podaj allowlistę IPv4: --allow"
    return 1
  }
  [[ "${allow}" != "0.0.0.0" ]] || {
    hm_err "Allow 0.0.0.0 jest odrzucone."
    return 1
  }
  if [[ "${yes}" -ne 1 ]]; then
    hm_err "Publikacja wymaga --yes."
    return 1
  fi
  vhost="${HM_DASHBOARD_VHOST:-/usr/local/lsws/conf/vhosts/hm-dashboard/vhconf.conf}"
  auth="${HM_DASHBOARD_AUTH:-/etc/hmtools/dashboard.auth}"
  mkdir -p "$(dirname "${vhost}")" "$(dirname "${auth}")" || {
    hm_err "Nie mogę utworzyć katalogów vhost."
    return 1
  }
  if [[ -n "${HM_DASHBOARD_PASS:-}" ]]; then
    pass="${HM_DASHBOARD_PASS}"
  else
    pass="$(od -An -tx1 -N 16 /dev/urandom 2>/dev/null | tr -d ' \n' || true)"
  fi
  [[ -n "${pass}" ]] || {
    hm_err "Nie mogę utworzyć hasła basic auth."
    return 1
  }
  umask 077
  printf 'hmtools:%s\n' "${pass}" >"${auth}" || {
    hm_err "Zapis ${auth} nie powiódł się."
    return 1
  }
  chmod 0600 "${auth}" 2>/dev/null || true
  cat >"${vhost}" <<EOF
docRoot $(hm_dashboard_out_dir)
realm hmtools
userFile ${auth}
allow ${allow}
note loopback-serve-pozostaje-domyslne
EOF
  hm_info "Hasło basic auth jest w pliku auth, poza HTML."
  printf '%s\n' "${vhost}"
}

cmd_dashboard() {
  local sub="${1:-}"
  shift || true
  case "${sub}" in
    build)
      hm_dashboard_build "$@"
      ;;
    serve)
      hm_dashboard_serve "$@"
      ;;
    schedule)
      hm_dashboard_schedule "$@"
      ;;
    publish)
      hm_dashboard_publish "$@"
      ;;
    help|-h|--help|"")
      hm_help_topic dashboard
      ;;
    *)
      hm_err "Nieznane: dashboard ${sub}. dashboard help"
      return 1
      ;;
  esac
}

_hm_cmd_register dashboard cmd_dashboard 0
