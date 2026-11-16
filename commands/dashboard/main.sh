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
  dashboard publish --domain D --allow IP[,IP…] [--yes]
      Vhost OLS + basic auth (htpasswd). Ostrzeżenie: poza tunelem SSH.
  dashboard session --domain D --allow IP[,IP…] [--user U]
      Panel na czas procesu SSH: vhost tymczasowy, login/hasło na TTY,
      przywrócenie konfiguracji przy EXIT/HUP/TERM.

Podgląd przez tunel: ssh -L 8765:127.0.0.1:8765 user@host
EOF

# Stan sesji (przywracanie po trap).
HM_DASH_SESSION_ACTIVE=0
HM_DASH_SESSION_VHOST=""
HM_DASH_SESSION_VHOST_BAK=""
HM_DASH_SESSION_MAP=""
HM_DASH_SESSION_AUTH=""
HM_DASH_SESSION_CREATED_VHOST=0

hm_dashboard_htpasswd_line() {
  local user="$1" pass="$2" hash=""
  if declare -F hm_have_cmd >/dev/null 2>&1 && hm_have_cmd htpasswd; then
    htpasswd -nbB "${user}" "${pass}" 2>/dev/null \
      || htpasswd -nb "${user}" "${pass}" 2>/dev/null \
      || true
    return 0
  fi
  if declare -F hm_have_cmd >/dev/null 2>&1 && hm_have_cmd openssl; then
    hash="$(openssl passwd -apr1 "${pass}" 2>/dev/null || openssl passwd -1 "${pass}" 2>/dev/null || true)"
  fi
  if [[ -z "${hash}" ]] && declare -F hm_have_cmd >/dev/null 2>&1 && hm_have_cmd python3; then
    hash="$(PASS="${pass}" python3 - <<'PY' 2>/dev/null || true
import crypt, os
print(crypt.crypt(os.environ["PASS"], crypt.METHOD_MD5))
PY
)"
  fi
  [[ -n "${hash}" ]] || return 1
  printf '%s:%s\n' "${user}" "${hash}"
}

hm_dashboard_parse_allow() {
  local raw="$1" a out="" first=1
  IFS=',' read -r -a parts <<< "${raw}"
  local p
  for p in "${parts[@]}"; do
    p="$(printf '%s' "${p}" | tr -d '[:space:]')"
    [[ -n "${p}" ]] || continue
    case "${p}" in
      0.0.0.0|::|::0)
        hm_err "Allow ${p} jest odrzucone."
        return 1
        ;;
    esac
    if [[ "${p}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]{1,2})?$ ]]; then
      :
    elif [[ "${p}" == *:* ]]; then
      # IPv6 / IPv6/CIDR (uproszczona walidacja)
      [[ "${p}" =~ ^[0-9A-Fa-f:]+(/[0-9]{1,3})?$ ]] || {
        hm_err "Nieprawidłowy adres allow: ${p}"
        return 1
      }
    else
      hm_err "Nieprawidłowy adres allow: ${p}"
      return 1
    fi
    if [[ "${first}" -eq 1 ]]; then
      out="${p}"
      first=0
    else
      out="${out}, ${p}"
    fi
  done
  [[ -n "${out}" ]] || {
    hm_err "Podaj allowlistę: --allow IP[,IP…]"
    return 1
  }
  printf '%s' "${out}"
}

hm_dashboard_write_vhconf() {
  local dest="$1" docroot="$2" auth="$3" allow="$4"
  cat >"${dest}" <<EOF
docRoot                   ${docroot}

realm                     Basic Realm {
  userDB  {
    location              ${auth}
  }
}

accessControl  {
  allow                   ${allow}
}

context / {
  location                \$DOC_ROOT/
  allowBrowse             1
  realm                   Basic Realm
  addDefaultCharset       off
}
EOF
}

hm_dashboard_ols_map_file() {
  printf '%s' "${HM_DASHBOARD_OLS_MAP:-${OLS_CONF:-/usr/local/lsws/conf/httpd_config.conf}}"
}

hm_dashboard_ols_attach() {
  local domain="$1" vhost_dir="$2" mapf marker
  mapf="$(hm_dashboard_ols_map_file)"
  marker="# hmtools-dashboard:${domain}"
  [[ -f "${mapf}" ]] || {
    if [[ "${HMTOOLS_TEST:-}" == "1" ]]; then
      mkdir -p "$(dirname "${mapf}")"
      : >"${mapf}"
    else
      hm_warn "Brak ${mapf} — pomijam mapowanie listenera."
      return 0
    fi
  }
  if ! grep -Fq "${marker}" "${mapf}" 2>/dev/null; then
    {
      printf '\n%s BEGIN\n' "${marker}"
      printf 'virtualhost %s {\n  vhRoot %s\n  configFile %s/vhconf.conf\n  allowSymbolLink 1\n  enableScript 1\n  restrained 1\n}\n' \
        "${domain}" "${vhost_dir}" "${vhost_dir}"
      printf '%s END\n' "${marker}"
    } >>"${mapf}"
  fi
  HM_DASH_SESSION_MAP="${mapf}"
}

hm_dashboard_ols_detach() {
  local domain="$1" mapf marker
  mapf="${HM_DASH_SESSION_MAP:-$(hm_dashboard_ols_map_file)}"
  marker="# hmtools-dashboard:${domain}"
  [[ -f "${mapf}" ]] || return 0
  if grep -Fq "${marker} BEGIN" "${mapf}" 2>/dev/null; then
    local tmp
    tmp="$(mktemp)"
    awk -v b="${marker} BEGIN" -v e="${marker} END" '
      index($0,b){skip=1; next}
      index($0,e){skip=0; next}
      !skip{print}
    ' "${mapf}" >"${tmp}" && mv -f "${tmp}" "${mapf}"
  fi
}

hm_dashboard_ols_reload() {
  if [[ -n "${HM_DASHBOARD_RELOAD_LOG:-}" ]]; then
    printf 'reload\n' >> "${HM_DASHBOARD_RELOAD_LOG}"
  fi
  if [[ "${HMTOOLS_TEST:-}" == "1" || "${HM_DASHBOARD_DRY:-}" == "1" ]]; then
    return 0
  fi
  if declare -F hm_ols_reload_soft >/dev/null 2>&1; then
    hm_ols_reload_soft || true
  fi
}

hm_dashboard_session_cleanup() {
  local domain="${HM_DASH_SESSION_DOMAIN:-}" rc=0
  [[ "${HM_DASH_SESSION_ACTIVE}" -eq 1 ]] || return 0
  HM_DASH_SESSION_ACTIVE=0
  trap - EXIT HUP TERM INT
  if [[ -n "${domain}" ]]; then
    hm_dashboard_ols_detach "${domain}" || true
  fi
  if [[ -n "${HM_DASH_SESSION_VHOST_BAK}" && -f "${HM_DASH_SESSION_VHOST_BAK}" \
        && -n "${HM_DASH_SESSION_VHOST}" ]]; then
    mv -f "${HM_DASH_SESSION_VHOST_BAK}" "${HM_DASH_SESSION_VHOST}" || rc=1
  elif [[ "${HM_DASH_SESSION_CREATED_VHOST}" -eq 1 && -n "${HM_DASH_SESSION_VHOST}" ]]; then
    rm -f "${HM_DASH_SESSION_VHOST}"
    rmdir "$(dirname "${HM_DASH_SESSION_VHOST}")" 2>/dev/null || true
  fi
  [[ -n "${HM_DASH_SESSION_AUTH}" && -f "${HM_DASH_SESSION_AUTH}" ]] && rm -f "${HM_DASH_SESSION_AUTH}"
  hm_dashboard_ols_reload || true
  hm_info "dashboard session: przywrócono konfigurację."
  return "${rc}"
}

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
  local domain="" allow_raw="" yes=0 user="hmtools"
  local vhost auth pass allow line vhdir
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --domain)
        domain="${2:-}"
        shift 2 || true
        ;;
      --domain=*) domain="${1#*=}"; shift ;;
      --allow)
        allow_raw="${2:-}"
        shift 2 || true
        ;;
      --allow=*) allow_raw="${1#*=}"; shift ;;
      --user)
        user="${2:-hmtools}"
        shift 2 || true
        ;;
      --user=*) user="${1#*=}"; shift ;;
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
  allow="$(hm_dashboard_parse_allow "${allow_raw}")" || return 1
  if [[ "${yes}" -ne 1 ]]; then
    hm_err "Publikacja wymaga --yes."
    return 1
  fi
  vhdir="${HM_DASHBOARD_VHOST_DIR:-/usr/local/lsws/conf/vhosts/hm-dashboard-${domain}}"
  vhost="${HM_DASHBOARD_VHOST:-${vhdir}/vhconf.conf}"
  auth="${HM_DASHBOARD_AUTH:-/etc/hmtools/dashboard-${domain}.htpasswd}"
  mkdir -p "$(dirname "${vhost}")" "$(dirname "${auth}")" || {
    hm_err "Nie mogę utworzyć katalogów vhost."
    return 1
  }
  if [[ -f "${vhost}" && ! -L "${vhost}" ]]; then
    cp -a "${vhost}" "${vhost}.hmbak.$(date +%Y%m%d%H%M%S)" || true
  fi
  if [[ -f "${auth}" && ! -L "${auth}" ]]; then
    cp -a "${auth}" "${auth}.hmbak.$(date +%Y%m%d%H%M%S)" || true
  fi
  if [[ -n "${HM_DASHBOARD_PASS:-}" ]]; then
    pass="${HM_DASHBOARD_PASS}"
  else
    pass="$(od -An -tx1 -N 16 /dev/urandom 2>/dev/null | tr -d ' \n' || true)"
  fi
  [[ -n "${pass}" ]] || {
    hm_err "Nie mogę utworzyć hasła basic auth."
    return 1
  }
  line="$(hm_dashboard_htpasswd_line "${user}" "${pass}")" || {
    hm_err "Nie mogę wygenerować hasha htpasswd (htpasswd/openssl/python3)."
    return 1
  }
  if ! ( umask 077; printf '%s\n' "${line}" >"${auth}"; ); then
    hm_err "Zapis ${auth} nie powiódł się."
    return 1
  fi
  chmod 0600 "${auth}" 2>/dev/null || true
  hm_dashboard_write_vhconf "${vhost}" "$(hm_dashboard_out_dir)" "${auth}" "${allow}"
  hm_dashboard_ols_attach "${domain}" "$(dirname "${vhost}")"
  hm_dashboard_ols_reload
  if declare -F hm_print_secret >/dev/null 2>&1; then
    hm_print_secret "login: ${user}" "hasło: ${pass}"
  else
    hm_info "login=${user} (hasło tylko na TTY / HM_SECRET_FILE)"
  fi
  printf '%s\n' "${vhost}"
}

hm_dashboard_session() {
  local domain="" allow_raw="" user="hmtools" allow pass line vhdir vhost auth created=0
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --domain) domain="${2:-}"; shift 2 || true ;;
      --domain=*) domain="${1#*=}"; shift ;;
      --allow) allow_raw="${2:-}"; shift 2 || true ;;
      --allow=*) allow_raw="${1#*=}"; shift ;;
      --user) user="${2:-hmtools}"; shift 2 || true ;;
      --user=*) user="${1#*=}"; shift ;;
      *)
        hm_err "Nieznana flaga: ${1}"
        return 1
        ;;
    esac
  done
  if ! declare -F hm_is_valid_domain >/dev/null 2>&1 || ! hm_is_valid_domain "${domain}"; then
    hm_err "Użycie: dashboard session --domain D --allow IP[,IP…]"
    return 1
  fi
  allow="$(hm_dashboard_parse_allow "${allow_raw}")" || return 1
  # Osobny kontekst — nie nadpisuj istniejącego vhosta domeny produkcyjnej.
  vhdir="${HM_DASHBOARD_VHOST_DIR:-/usr/local/lsws/conf/vhosts/hm-dashboard-session-${domain}}"
  vhost="${vhdir}/vhconf.conf"
  auth="${HM_DASHBOARD_AUTH:-/etc/hmtools/dashboard-session-${domain}.htpasswd}"
  mkdir -p "${vhdir}" "$(dirname "${auth}")" || return 1
  if [[ -f "${vhost}" && ! -L "${vhost}" ]]; then
    HM_DASH_SESSION_VHOST_BAK="${vhost}.hmbak.session"
    cp -a "${vhost}" "${HM_DASH_SESSION_VHOST_BAK}"
  else
    created=1
  fi
  if [[ -n "${HM_DASHBOARD_PASS:-}" ]]; then
    pass="${HM_DASHBOARD_PASS}"
  else
    pass="$(od -An -tx1 -N 16 /dev/urandom 2>/dev/null | tr -d ' \n' || true)"
  fi
  [[ -n "${pass}" ]] || {
    hm_err "Nie mogę utworzyć hasła."
    return 1
  }
  line="$(hm_dashboard_htpasswd_line "${user}" "${pass}")" || {
    hm_err "Brak htpasswd/openssl/python3 do hasha."
    return 1
  }
  ( umask 077; printf '%s\n' "${line}" >"${auth}"; )
  chmod 0600 "${auth}" 2>/dev/null || true
  # Zbuduj HTML jeśli brak
  if [[ ! -f "$(hm_dashboard_out_dir)/index.html" ]]; then
    hm_dashboard_build >/dev/null || true
  fi
  hm_dashboard_write_vhconf "${vhost}" "$(hm_dashboard_out_dir)" "${auth}" "${allow}"
  HM_DASH_SESSION_ACTIVE=1
  HM_DASH_SESSION_DOMAIN="${domain}"
  HM_DASH_SESSION_VHOST="${vhost}"
  HM_DASH_SESSION_AUTH="${auth}"
  HM_DASH_SESSION_CREATED_VHOST="${created}"
  trap 'hm_dashboard_session_cleanup' EXIT HUP TERM INT
  hm_dashboard_ols_attach "${domain}" "${vhdir}"
  hm_dashboard_ols_reload
  if declare -F hm_print_secret >/dev/null 2>&1; then
    hm_print_secret "login: ${user}" "hasło: ${pass}" "URL: https://${domain}/"
  else
    hm_info "Panel: https://${domain}/  login=${user}"
  fi
  hm_info "Panel żyje do Ctrl+C / końca sesji SSH (HUP)."
  if [[ "${HMTOOLS_TEST:-}" == "1" || "${HM_DASHBOARD_DRY:-}" == "1" ]]; then
    printf 'session=active domain=%s vhost=%s\n' "${domain}" "${vhost}"
    hm_dashboard_session_cleanup
    return 0
  fi
  # Blokuj do sygnału (jak żywy proces SSH).
  while true; do
    sleep 3600 &
    wait $! || true
  done
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
    session)
      hm_dashboard_session "$@"
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
