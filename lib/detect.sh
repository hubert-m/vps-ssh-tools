#!/usr/bin/env bash
# Auto-detekcja OS, panelu, webservera i silnika DB (szybka, po ścieżkach / CLI / API)

if [[ -n "${HMTOOLS_DETECT_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_DETECT_LOADED=1

# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

OS_ID=""
OS_ID_LIKE=""
OS_VERSION=""
OS_PRETTY=""
OS_FAMILY="unknown"   # debian | rhel | unknown
OS_SUPPORTED=0        # 1 = Ubuntu/Debian/Alma/Rocky/CentOS/RHEL
PKG_MANAGER="unknown" # apt | dnf | yum | unknown
PANEL="unknown"
WEBSERVER="unknown"
DB_ENGINE="unknown"
PANEL_SOURCE=""
WEBSERVER_SOURCE=""
OLS_ROOT=""
OLS_BIN=""
OLS_CTRL=""
OLS_CONF=""
OLS_VHOSTS=""
CYBERPANEL_ROOT=""
MYSQL_SOCKET=""
# dodatkowe sygnały (spacja): np. "nginx apache webmin"
STACK_EXTRA=""
# 1 = REPL/dispatch tylko uninstall-hmtools (+ help/exit/detect/version)
HMTOOLS_RESTRICTED=0

hm_detect_os() {
  OS_ID=""
  OS_ID_LIKE=""
  OS_VERSION=""
  OS_PRETTY=""
  OS_FAMILY="unknown"
  OS_SUPPORTED=0
  if [[ -r /etc/os-release ]]; then
    # jeden odczyt — bez eksportu zmiennych do bieżącej powłoki
    local line
    while IFS= read -r line || [[ -n "${line}" ]]; do
      case "${line}" in
        ID=*)
          OS_ID="${line#ID=}"
          OS_ID="${OS_ID#\"}"; OS_ID="${OS_ID%\"}"
          ;;
        ID_LIKE=*)
          OS_ID_LIKE="${line#ID_LIKE=}"
          OS_ID_LIKE="${OS_ID_LIKE#\"}"; OS_ID_LIKE="${OS_ID_LIKE%\"}"
          ;;
        VERSION_ID=*)
          OS_VERSION="${line#VERSION_ID=}"
          OS_VERSION="${OS_VERSION#\"}"; OS_VERSION="${OS_VERSION%\"}"
          ;;
        PRETTY_NAME=*)
          OS_PRETTY="${line#PRETTY_NAME=}"
          OS_PRETTY="${OS_PRETTY#\"}"; OS_PRETTY="${OS_PRETTY%\"}"
          ;;
      esac
    done < /etc/os-release
  fi
  [[ -n "${OS_PRETTY}" ]] || OS_PRETTY="$(uname -s 2>/dev/null || echo unknown)"
  [[ -n "${OS_ID}" ]] || OS_ID="unknown"

  case "${OS_ID}" in
    ubuntu|debian|linuxmint|pop)
      OS_FAMILY="debian"
      OS_SUPPORTED=1
      ;;
    almalinux|rocky|centos|rhel|fedora)
      OS_FAMILY="rhel"
      OS_SUPPORTED=1
      ;;
    *)
      if [[ " ${OS_ID_LIKE} " == *" debian "* ]] || [[ " ${OS_ID_LIKE} " == *" ubuntu "* ]]; then
        OS_FAMILY="debian"
        OS_SUPPORTED=1
      elif [[ " ${OS_ID_LIKE} " == *" rhel "* ]] || [[ " ${OS_ID_LIKE} " == *" fedora "* ]] || [[ " ${OS_ID_LIKE} " == *" centos "* ]]; then
        OS_FAMILY="rhel"
        OS_SUPPORTED=1
      fi
      ;;
  esac
}

hm_os_is_supported() {
  [[ "${ALLOW_UNSUPPORTED_OS:-0}" == "1" ]] && return 0
  [[ "${OS_SUPPORTED:-0}" -eq 1 ]]
}

hm_detect_ols_paths() {
  OLS_ROOT=""
  OLS_BIN=""
  OLS_CTRL=""
  OLS_CONF=""
  OLS_VHOSTS=""
  local cand
  for cand in /usr/local/lsws /usr/local/litespeed; do
    if [[ -d "${cand}" ]]; then
      OLS_ROOT="${cand}"
      break
    fi
  done
  [[ -n "${OLS_ROOT}" ]] || return 1
  OLS_BIN="${OLS_ROOT}/bin/lshttpd"
  [[ -x "${OLS_ROOT}/bin/openlitespeed" ]] && OLS_BIN="${OLS_ROOT}/bin/openlitespeed"
  OLS_CTRL="${OLS_ROOT}/bin/lswsctrl"
  if [[ -f "${OLS_ROOT}/conf/httpd_config.conf" ]]; then
    OLS_CONF="${OLS_ROOT}/conf/httpd_config.conf"
  elif [[ -f "${OLS_ROOT}/conf/httpd.conf" ]]; then
    OLS_CONF="${OLS_ROOT}/conf/httpd.conf"
  fi
  OLS_VHOSTS="${OLS_ROOT}/conf/vhosts"
  return 0
}

hm_detect_webserver() {
  WEBSERVER="unknown"
  WEBSERVER_SOURCE=""
  local -a extra=()

  if hm_detect_ols_paths; then
    if [[ -n "${OLS_CONF}" && "${OLS_CONF}" == *httpd.conf ]]; then
      WEBSERVER="litespeed"
    else
      WEBSERVER="openlitespeed"
    fi
    WEBSERVER_SOURCE="path:${OLS_ROOT}"
  fi

  # Nginx / Apache — ścieżki (szybkie); mogą współistnieć z panelem / OLS
  if [[ -d /etc/nginx ]] || hm_have_cmd nginx; then
    if [[ "${WEBSERVER}" == "unknown" ]]; then
      WEBSERVER="nginx"
      WEBSERVER_SOURCE="path:/etc/nginx"
    else
      extra+=("nginx")
    fi
  fi
  if [[ -d /etc/apache2 || -d /etc/httpd ]] || hm_have_cmd apache2 || hm_have_cmd httpd; then
    if [[ "${WEBSERVER}" == "unknown" ]]; then
      WEBSERVER="apache"
      if [[ -d /etc/apache2 ]]; then
        WEBSERVER_SOURCE="path:/etc/apache2"
      else
        WEBSERVER_SOURCE="path:/etc/httpd"
      fi
    else
      extra+=("apache")
    fi
  fi

  # Fallback: proces / systemd (tylko gdy nadal unknown)
  if [[ "${WEBSERVER}" == "unknown" ]]; then
    if pgrep -x lshttpd >/dev/null 2>&1 || pgrep -x openlitespeed >/dev/null 2>&1; then
      WEBSERVER="openlitespeed"
      WEBSERVER_SOURCE="process"
    elif systemctl is-active --quiet lshttpd 2>/dev/null || systemctl is-active --quiet lsws 2>/dev/null; then
      WEBSERVER="openlitespeed"
      WEBSERVER_SOURCE="systemd"
    elif systemctl is-active --quiet nginx 2>/dev/null; then
      WEBSERVER="nginx"
      WEBSERVER_SOURCE="systemd"
    elif systemctl is-active --quiet apache2 2>/dev/null || systemctl is-active --quiet httpd 2>/dev/null; then
      WEBSERVER="apache"
      WEBSERVER_SOURCE="systemd"
    fi
  fi

  if [[ "${#extra[@]}" -gt 0 ]]; then
    STACK_EXTRA="$(IFS=' '; echo "${extra[*]}")"
  fi
}

hm_detect_panel() {
  PANEL="unknown"
  PANEL_SOURCE=""
  CYBERPANEL_ROOT=""

  # cPanel — katalog + sygnał UAPI/WHMAPI (pewniejsze niż same pliki)
  if [[ -d /usr/local/cpanel ]]; then
    PANEL="cpanel"
    PANEL_SOURCE="path:/usr/local/cpanel"
    if [[ -x /usr/local/cpanel/bin/uapi ]] || hm_have_cmd uapi || hm_have_cmd whmapi1; then
      PANEL_SOURCE="api:uapi"
    fi
    return 0
  fi

  # Plesk — katalog + CLI / XML-RPC tooling
  if [[ -d /usr/local/psa || -f /etc/psa/psa.conf ]]; then
    PANEL="plesk"
    PANEL_SOURCE="path:/usr/local/psa"
    if hm_have_cmd plesk || [[ -x /usr/sbin/plesk || -x /usr/local/psa/bin/plesk ]]; then
      PANEL_SOURCE="api:plesk-cli"
    fi
    return 0
  fi

  # CyberPanel
  if [[ -d /usr/local/CyberCP ]] || hm_have_cmd cyberpanel; then
    PANEL="cyberpanel"
    CYBERPANEL_ROOT="/usr/local/CyberCP"
    [[ -d /usr/local/CyberCP ]] || CYBERPANEL_ROOT=""
    PANEL_SOURCE="path:${CYBERPANEL_ROOT:-cyberpanel-cli}"
    return 0
  fi

  # DirectAdmin
  if [[ -d /usr/local/directadmin ]]; then
    PANEL="directadmin"
    PANEL_SOURCE="path:/usr/local/directadmin"
    return 0
  fi

  # aaPanel / BT
  if [[ -d /www/server/panel ]] || hm_have_cmd bt; then
    PANEL="aapanel"
    PANEL_SOURCE="path:/www/server/panel"
    return 0
  fi

  # Webmin (panel administracyjny, nie pełny hosting panel)
  if [[ -f /etc/webmin/miniserv.conf || -d /usr/share/webmin ]] || hm_have_cmd webmin; then
    PANEL="webmin"
    PANEL_SOURCE="path:/etc/webmin"
    return 0
  fi
}

hm_detect_db() {
  DB_ENGINE="unknown"
  MYSQL_SOCKET=""
  local sock
  for sock in /var/lib/mysql/mysql.sock /run/mysqld/mysqld.sock /tmp/mysql.sock /var/run/mysqld/mysqld.sock; do
    if [[ -S "${sock}" ]]; then
      MYSQL_SOCKET="${sock}"
      break
    fi
  done

  if hm_have_cmd mariadb || [[ -d /etc/mysql/mariadb.conf.d ]] || systemctl is-active --quiet mariadb 2>/dev/null; then
    DB_ENGINE="mariadb"
  elif hm_have_cmd mysql || systemctl is-active --quiet mysql 2>/dev/null || systemctl is-active --quiet mysqld 2>/dev/null; then
    DB_ENGINE="mysql"
  fi
}

hm_detect_apply_overrides() {
  # Ręczne nadpisanie z hmtools.conf (gdy auto-detekcja się myli)
  if [[ -n "${FORCE_PANEL:-}" ]]; then
    PANEL="${FORCE_PANEL}"
    PANEL_SOURCE="override:FORCE_PANEL"
  fi
  if [[ -n "${FORCE_WEBSERVER:-}" ]]; then
    WEBSERVER="${FORCE_WEBSERVER}"
    WEBSERVER_SOURCE="override:FORCE_WEBSERVER"
  fi
  if [[ -n "${FORCE_DB_ENGINE:-}" ]]; then
    DB_ENGINE="${FORCE_DB_ENGINE}"
  fi
  if [[ -n "${FORCE_SITES_ROOT:-}" && -z "${SITES_ROOT:-}" ]]; then
    SITES_ROOT="${FORCE_SITES_ROOT}"
  fi
  if [[ "${ALLOW_UNSUPPORTED_OS:-0}" == "1" ]]; then
    OS_SUPPORTED=1
  fi
}

hm_detect_pkg_manager() {
  PKG_MANAGER="unknown"
  if type hm_pkg_manager >/dev/null 2>&1; then
    PKG_MANAGER="$(hm_pkg_manager 2>/dev/null || echo unknown)"
  elif hm_have_cmd apt-get; then
    PKG_MANAGER="apt"
  elif hm_have_cmd dnf; then
    PKG_MANAGER="dnf"
  elif hm_have_cmd yum; then
    PKG_MANAGER="yum"
  fi
  # spójność z rodziną OS (gdy CLI obecne)
  if [[ "${PKG_MANAGER}" == "unknown" ]]; then
    case "${OS_FAMILY}" in
      debian) PKG_MANAGER="apt" ;;
      rhel) PKG_MANAGER="dnf" ;;
    esac
  fi
}

hm_detect_all() {
  STACK_EXTRA=""
  HMTOOLS_RESTRICTED=0
  hm_detect_os
  hm_detect_webserver
  hm_detect_panel
  hm_detect_db
  hm_detect_pkg_manager
  hm_detect_apply_overrides
  if ! hm_os_is_supported; then
    HMTOOLS_RESTRICTED=1
  fi
}

# --- Ścieżki / usługi zależne od dystrybucji i WWW -------------------------

hm_web_error_log_guess() {
  # typowa ścieżka error loga (pierwsza istniejąca)
  case "${WEBSERVER}" in
    openlitespeed|litespeed)
      [[ -n "${OLS_ROOT}" && -f "${OLS_ROOT}/logs/error.log" ]] && { echo "${OLS_ROOT}/logs/error.log"; return 0; }
      ;;
    nginx)
      [[ -f /var/log/nginx/error.log ]] && { echo /var/log/nginx/error.log; return 0; }
      ;;
    apache)
      [[ -f /var/log/apache2/error.log ]] && { echo /var/log/apache2/error.log; return 0; }
      [[ -f /var/log/httpd/error_log ]] && { echo /var/log/httpd/error_log; return 0; }
      ;;
  esac
  return 1
}

hm_service_unit_for_web() {
  case "${WEBSERVER}" in
    openlitespeed|litespeed) echo "lsws" ;;
    nginx) echo "nginx" ;;
    apache)
      if [[ "${OS_FAMILY}" == "rhel" ]] || [[ -d /etc/httpd ]]; then
        echo "httpd"
      else
        echo "apache2"
      fi
      ;;
    *) echo "" ;;
  esac
}

hm_service_reload() {
  # uniwersalny reload: OLS → lswsctrl; inaczej systemctl/service
  local unit="${1:-}"
  [[ -n "${unit}" ]] || unit="$(hm_service_unit_for_web)"
  case "${unit}" in
    lsws|lshttpd|openlitespeed)
      hm_ols_reload_soft && return 0
      ;;
  esac
  [[ -n "${unit}" ]] || return 1
  if hm_have_cmd systemctl; then
    systemctl reload "${unit}" 2>/dev/null && return 0
    systemctl restart "${unit}" 2>/dev/null && return 0
  fi
  if hm_have_cmd service; then
    service "${unit}" reload 2>/dev/null && return 0
    service "${unit}" restart 2>/dev/null && return 0
  fi
  return 1
}

hm_pkg_install() {
  # hm_pkg_install <pakiet…> — apt vs dnf/yum
  local pm
  pm="${PKG_MANAGER:-}"
  [[ -n "${pm}" && "${pm}" != "unknown" ]] || pm="$(hm_pkg_manager 2>/dev/null || true)"
  case "${pm}" in
    apt) hm_run apt-get install -y "$@" ;;
    dnf) hm_run dnf install -y "$@" ;;
    yum) hm_run yum install -y "$@" ;;
    *)
      hm_err "Brak wspieranego menedżera pakietów (apt/dnf/yum)."
      return 1
      ;;
  esac
}

hm_detect_tool_hints() {
  # Sugerowane komendy hmtools pod wykryty stos (stdout, jedna linia / punkt)
  case "${PANEL}" in
    cyberpanel)
      echo "webs, use, ols, php, update-php, backup, perms, ssl, mysql"
      ;;
    cpanel)
      echo "mysql, backup (list/restore), health — natywne webs/ols OLS ograniczone; cPanel UAPI poza zakresem hmtools"
      ;;
    plesk)
      echo "mysql, backup, health — Plesk CLI/API poza zakresem; webs/ols tylko przy OLS"
      ;;
    webmin|directadmin|aapanel)
      echo "mysql, backup, health, disk — panel-specific: ograniczona auto-konfiguracja vhostów"
      ;;
    *)
      case "${WEBSERVER}" in
        openlitespeed|litespeed)
          echo "ols, webs, php, backup, perms, htaccess, cache, proxy"
          ;;
        nginx)
          echo "mysql, backup, health, disk — brak natywnego ols; webs jeśli vhosty w znanym layoutcie"
          ;;
        apache)
          echo "mysql, backup, health, disk — brak natywnego ols; webs jeśli vhosty w znanym layoutcie"
          ;;
        *)
          echo "health, disk, mysql, backup — uzupełnij FORCE_PANEL / FORCE_WEBSERVER w hmtools.conf"
          ;;
      esac
      ;;
  esac
}

hm_detect_print() {
  hm_detect_all
  local hints extra_line=""
  hints="$(hm_detect_tool_hints)"
  [[ -n "${STACK_EXTRA}" ]] && extra_line="  + inne WWW   : ${STACK_EXTRA}"

  echo
  printf '%s%s%s\n' "${C_BOLD}" "══════════════════════════════════════════════════════════════" "${C_RESET}"
  printf '%s%s%s\n' "${C_BOLD}" "  Wykryty stos oprogramowania VPS" "${C_RESET}"
  printf '%s%s%s\n' "${C_BOLD}" "══════════════════════════════════════════════════════════════" "${C_RESET}"
  local os_ok="nie"
  [[ "${OS_SUPPORTED}" -eq 1 ]] && os_ok="tak"
  echo "  OS          : ${OS_PRETTY}${OS_ID:+ (${OS_ID}${OS_VERSION:+ ${OS_VERSION}})}"
  echo "  OS_FAMILY   : ${OS_FAMILY}  (wsparcie: ${os_ok})"
  echo "  PKG_MANAGER : ${PKG_MANAGER}"
  echo "  PANEL       : ${PANEL}${PANEL_SOURCE:+  [${PANEL_SOURCE}]}"
  echo "  WEBSERVER   : ${WEBSERVER}${WEBSERVER_SOURCE:+  [${WEBSERVER_SOURCE}]}"
  [[ -n "${extra_line}" ]] && echo "${extra_line}"
  echo "  DB_ENGINE   : ${DB_ENGINE}"
  echo "  OLS_ROOT    : ${OLS_ROOT:--}"
  echo "  OLS_CONF    : ${OLS_CONF:--}"
  echo "  OLS_VHOSTS  : ${OLS_VHOSTS:--}"
  echo "  CYBERPANEL  : ${CYBERPANEL_ROOT:--}"
  echo "  MYSQL_SOCK  : ${MYSQL_SOCKET:--}"
  echo
  if [[ "${HMTOOLS_RESTRICTED}" -eq 1 ]]; then
    hm_warn "  System nieobsługiwany — dozwolone: uninstall-hmtools, help, version, detect, exit"
    echo "  ${C_DIM}Wymuszenie: ALLOW_UNSUPPORTED_OS=1 w hmtools.conf${C_RESET}"
  else
    echo "  ${C_DIM}Sugerowane narzędzia hmtools:${C_RESET}"
    echo "    ${hints}"
  fi
  echo
  echo "  ${C_DIM}Nadpisanie (gdy auto się myli) w ${HMTOOLS_CONF:-hmtools.conf}:${C_RESET}"
  echo "    FORCE_PANEL=…   FORCE_WEBSERVER=…   FORCE_DB_ENGINE=…   ALLOW_UNSUPPORTED_OS=1"
  echo
}

hm_detect_banner() {
  # krótka karta na start REPL
  local hints
  hints="$(hm_detect_tool_hints)"
  hm_ok "Wykryty stos — OS: ${OS_PRETTY:-?} [${OS_FAMILY}/${PKG_MANAGER}] · panel=${PANEL} · www=${WEBSERVER} · db=${DB_ENGINE}"
  if [[ "${HMTOOLS_RESTRICTED:-0}" -eq 1 ]]; then
    hm_err "Niewspierany lub nierozpoznany system (${OS_ID:-unknown})."
    hm_warn "Dozwolone komendy: uninstall-hmtools | help | version | detect | exit"
    hm_info "Lista OS: Ubuntu, Debian, AlmaLinux, Rocky Linux, CentOS, RHEL. Bypass: ALLOW_UNSUPPORTED_OS=1"
  else
    hm_info "Narzędzia: ${hints}"
    hm_info "Szczegóły: detect   | nadpisanie: FORCE_* w hmtools.conf"
  fi
}

hm_dispatch_allowed_when_restricted() {
  # 0 = dozwolone w trybie HMTOOLS_RESTRICTED
  case "${1:-}" in
    ""|uninstall-hmtools|help|h|\?|exit|quit|q|version|ver|detect|env) return 0 ;;
    *) return 1 ;;
  esac
}

hm_ols_reload_soft() {
  # wspólny reload OLS (lswsctrl → systemctl → service)
  hm_detect_all 2>/dev/null || true
  if [[ -n "${OLS_CTRL:-}" && -x "${OLS_CTRL}" ]]; then
    "${OLS_CTRL}" reload 2>/dev/null && return 0
  fi
  if hm_have_cmd systemctl; then
    systemctl reload lsws 2>/dev/null && return 0
    systemctl reload lshttpd 2>/dev/null && return 0
  fi
  service lsws reload 2>/dev/null && return 0
  return 1
}
