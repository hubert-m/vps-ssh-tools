#!/usr/bin/env bash
# Auto-detekcja OS, panelu, webservera i silnika DB (szybka, po ścieżkach / CLI / API)

if [[ -n "${HMTOOLS_DETECT_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_DETECT_LOADED=1

# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

OS_ID=""
OS_VERSION=""
OS_PRETTY=""
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

hm_detect_os() {
  OS_ID=""
  OS_VERSION=""
  OS_PRETTY=""
  if [[ -r /etc/os-release ]]; then
    # jeden odczyt — bez eksportu zmiennych do bieżącej powłoki
    local line
    while IFS= read -r line || [[ -n "${line}" ]]; do
      case "${line}" in
        ID=*)
          OS_ID="${line#ID=}"
          OS_ID="${OS_ID#\"}"; OS_ID="${OS_ID%\"}"
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
}

hm_detect_all() {
  STACK_EXTRA=""
  hm_detect_os
  hm_detect_webserver
  hm_detect_panel
  hm_detect_db
  hm_detect_apply_overrides
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
  echo "  OS          : ${OS_PRETTY}${OS_ID:+ (${OS_ID}${OS_VERSION:+ ${OS_VERSION}})}"
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
  echo "  ${C_DIM}Sugerowane narzędzia hmtools:${C_RESET}"
  echo "    ${hints}"
  echo
  echo "  ${C_DIM}Nadpisanie (gdy auto się myli) w ${HMTOOLS_CONF:-hmtools.conf}:${C_RESET}"
  echo "    FORCE_PANEL=…   FORCE_WEBSERVER=…   FORCE_DB_ENGINE=…"
  echo
}

hm_detect_banner() {
  # krótka karta na start REPL
  local hints
  hints="$(hm_detect_tool_hints)"
  hm_ok "Wykryty stos — OS: ${OS_PRETTY:-?} · panel=${PANEL} · www=${WEBSERVER} · db=${DB_ENGINE}"
  hm_info "Narzędzia: ${hints}"
  hm_info "Szczegóły: detect   | nadpisanie: FORCE_* w hmtools.conf"
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
