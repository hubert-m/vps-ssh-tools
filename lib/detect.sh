#!/usr/bin/env bash
# Auto-detekcja panelu, webservera i silnika DB

if [[ -n "${HMTOOLS_DETECT_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_DETECT_LOADED=1

# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

PANEL="unknown"
WEBSERVER="unknown"
DB_ENGINE="unknown"
OLS_ROOT=""
OLS_BIN=""
OLS_CTRL=""
OLS_CONF=""
OLS_VHOSTS=""
CYBERPANEL_ROOT=""
MYSQL_SOCKET=""

hm_detect_all() {
  PANEL="unknown"
  WEBSERVER="unknown"
  DB_ENGINE="unknown"
  OLS_ROOT=""
  OLS_BIN=""
  OLS_CTRL=""
  OLS_CONF=""
  OLS_VHOSTS=""
  CYBERPANEL_ROOT=""
  MYSQL_SOCKET=""

  # --- OpenLiteSpeed / LiteSpeed ---
  for cand in /usr/local/lsws /usr/local/litespeed; do
    if [[ -d "${cand}" ]]; then
      OLS_ROOT="${cand}"
      break
    fi
  done

  if [[ -n "${OLS_ROOT}" ]]; then
    OLS_BIN="${OLS_ROOT}/bin/lshttpd"
    [[ -x "${OLS_ROOT}/bin/openlitespeed" ]] && OLS_BIN="${OLS_ROOT}/bin/openlitespeed"
    OLS_CTRL="${OLS_ROOT}/bin/lswsctrl"
    if [[ -f "${OLS_ROOT}/conf/httpd_config.conf" ]]; then
      OLS_CONF="${OLS_ROOT}/conf/httpd_config.conf"
      WEBSERVER="openlitespeed"
    elif [[ -f "${OLS_ROOT}/conf/httpd.conf" ]]; then
      OLS_CONF="${OLS_ROOT}/conf/httpd.conf"
      WEBSERVER="litespeed"
    else
      WEBSERVER="openlitespeed"
    fi
    OLS_VHOSTS="${OLS_ROOT}/conf/vhosts"
  fi

  # Fallback: proces / systemd
  if [[ "${WEBSERVER}" == "unknown" ]]; then
    if pgrep -x lshttpd >/dev/null 2>&1 || pgrep -x openlitespeed >/dev/null 2>&1; then
      WEBSERVER="openlitespeed"
    elif systemctl is-active --quiet lshttpd 2>/dev/null || systemctl is-active --quiet lsws 2>/dev/null; then
      WEBSERVER="openlitespeed"
    elif systemctl is-active --quiet nginx 2>/dev/null; then
      WEBSERVER="nginx"
    elif systemctl is-active --quiet apache2 2>/dev/null || systemctl is-active --quiet httpd 2>/dev/null; then
      WEBSERVER="apache"
    fi
  fi

  # --- Panel ---
  if [[ -d /usr/local/CyberCP ]] || hm_have_cmd cyberpanel; then
    PANEL="cyberpanel"
    CYBERPANEL_ROOT="/usr/local/CyberCP"
    [[ -d /usr/local/CyberCP ]] || CYBERPANEL_ROOT=""
  elif [[ -d /www/server/panel ]] || hm_have_cmd bt; then
    PANEL="aapanel"
  elif [[ -d /usr/local/directadmin ]]; then
    PANEL="directadmin"
  elif [[ -d /usr/local/cpanel ]]; then
    PANEL="cpanel"
  fi

  # --- MySQL / MariaDB ---
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

hm_detect_print() {
  hm_detect_all
  cat <<EOF
Wykryte środowisko:
  PANEL         : ${PANEL}
  WEBSERVER     : ${WEBSERVER}
  DB_ENGINE     : ${DB_ENGINE}
  OLS_ROOT      : ${OLS_ROOT:--}
  OLS_CONF      : ${OLS_CONF:--}
  OLS_VHOSTS    : ${OLS_VHOSTS:--}
  CYBERPANEL    : ${CYBERPANEL_ROOT:--}
  MYSQL_SOCKET  : ${MYSQL_SOCKET:--}
EOF
}
