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
# Supervisor / Chrome (headless) / Docker
SUPERVISOR="no"
SUPERVISOR_SOURCE=""
SUPERVISOR_CTL=""
SUPERVISOR_CONF=""
CHROME="no"
CHROME_BIN=""
CHROME_SOURCE=""
CHROME_VERSION=""
DOCKER="no"
DOCKER_SOURCE=""
DOCKER_BIN=""
DOCKER_COMPOSE=""
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

hm_detect_docker() {
  # DOCKER=yes tylko gdy docker CLI działa (daemon dostępny opcjonalnie sprawdzany przy komendzie).
  DOCKER="no"
  DOCKER_SOURCE=""
  DOCKER_BIN=""
  DOCKER_COMPOSE=""

  if hm_have_cmd docker; then
    DOCKER_BIN="$(command -v docker)"
  elif [[ -x /usr/bin/docker ]]; then
    DOCKER_BIN="/usr/bin/docker"
  fi

  if [[ -n "${DOCKER_BIN}" && -x "${DOCKER_BIN}" ]]; then
    DOCKER="yes"
    DOCKER_SOURCE="bin:docker"
    if "${DOCKER_BIN}" compose version >/dev/null 2>&1; then
      DOCKER_COMPOSE="plugin"
      DOCKER_SOURCE="bin:docker+compose-plugin"
    elif hm_have_cmd docker-compose; then
      DOCKER_COMPOSE="standalone"
      DOCKER_SOURCE="bin:docker+docker-compose"
    fi
  fi

  if [[ -n "${FORCE_DOCKER:-}" ]]; then
    case "${FORCE_DOCKER}" in
      yes)
        DOCKER="yes"
        DOCKER_SOURCE="override:FORCE_DOCKER"
        if [[ -z "${DOCKER_BIN}" ]]; then
          hm_have_cmd docker && DOCKER_BIN="$(command -v docker)"
        fi
        ;;
      no)
        DOCKER="no"
        DOCKER_SOURCE="override:FORCE_DOCKER"
        DOCKER_BIN=""
        DOCKER_COMPOSE=""
        ;;
    esac
  fi
  # Tylko zmienne DOCKER_* — bez stdout (psuje $(find_site) / archive / restore).
}

hm_detect_supervisor() {
  # SUPERVISOR=yes tylko gdy jest usable supervisorctl (nie sam conf / unit).
  SUPERVISOR="no"
  SUPERVISOR_SOURCE=""
  SUPERVISOR_CTL=""
  SUPERVISOR_CONF=""

  if hm_have_cmd supervisorctl; then
    SUPERVISOR_CTL="$(command -v supervisorctl)"
  elif [[ -x /usr/bin/supervisorctl ]]; then
    SUPERVISOR_CTL="/usr/bin/supervisorctl"
  fi

  local conf
  for conf in \
    /etc/supervisor/supervisord.conf \
    /etc/supervisord.conf \
    /etc/supervisor.conf
  do
    if [[ -f "${conf}" ]]; then
      SUPERVISOR_CONF="${conf}"
      break
    fi
  done

  local systemd_hit=""
  if hm_have_cmd systemctl; then
    local unit
    for unit in supervisord supervisor; do
      if systemctl is-active --quiet "${unit}" 2>/dev/null \
        || systemctl is-enabled --quiet "${unit}" 2>/dev/null; then
        systemd_hit="${unit}"
        break
      fi
    done
  fi

  if [[ -n "${SUPERVISOR_CTL}" && -x "${SUPERVISOR_CTL}" ]]; then
    SUPERVISOR="yes"
    SUPERVISOR_SOURCE="bin:supervisorctl"
    if [[ -n "${systemd_hit}" ]]; then
      SUPERVISOR_SOURCE="systemd:${systemd_hit}+ctl"
    elif [[ -n "${SUPERVISOR_CONF}" ]]; then
      SUPERVISOR_SOURCE="bin:supervisorctl+conf"
    fi
  elif [[ -n "${SUPERVISOR_CONF}" || -n "${systemd_hit}" ]]; then
    # conf/unit bez ctl — nie oznaczaj jako gotowe narzędzie
    SUPERVISOR="no"
    if [[ -n "${SUPERVISOR_CONF}" ]]; then
      SUPERVISOR_SOURCE="conf-only:${SUPERVISOR_CONF}"
    else
      SUPERVISOR_SOURCE="systemd-only:${systemd_hit}"
    fi
  fi
}

# uid, tryb (ostatnie 3+ cyfry) i nazwa właściciela. Jedna linia: "uid mode user".
# HM_CHROME_STAT_FILE (test): linie uid<TAB>mode<TAB>user<TAB>ścieżka, ostatnia wygrywa.
# Brak wpisu w pliku = ścieżka niezaufana (nie sięgamy do prawdziwego stat).
hm_chrome_stat_owner_mode() {
  local path="$1" uid="" mode="" user="" u m n p
  [[ -n "${path}" ]] || return 1
  if [[ -n "${HM_CHROME_STAT_FILE:-}" ]]; then
    [[ -f "${HM_CHROME_STAT_FILE}" ]] || return 1
    while IFS=$'\t' read -r u m n p || [[ -n "${u:-}" ]]; do
      [[ "${p:-}" == "${path}" ]] || continue
      uid="${u}"
      mode="${m}"
      user="${n}"
    done < "${HM_CHROME_STAT_FILE}"
    [[ -n "${uid}" && -n "${mode}" ]] || return 1
    printf '%s %s %s' "${uid}" "${mode}" "${user}"
    return 0
  fi
  if [[ ! -e "${path}" && ! -L "${path}" ]]; then
    return 1
  fi
  uid="$(stat -c '%u' -- "${path}" 2>/dev/null || stat -f '%u' "${path}" 2>/dev/null || true)"
  mode="$(stat -c '%a' -- "${path}" 2>/dev/null || stat -f '%OLp' "${path}" 2>/dev/null || true)"
  user="$(stat -c '%U' -- "${path}" 2>/dev/null || true)"
  [[ -n "${uid}" && -n "${mode}" ]] || return 1
  printf '%s %s %s' "${uid}" "${mode}" "${user}"
}

# 0 = zapis dla grupy albo innych (niezaufane).
hm_chrome_mode_group_or_other_write() {
  local mode="$1" last="" group=""
  mode="${mode//[^0-9]/}"
  [[ -n "${mode}" ]] || return 0
  last="${mode: -1}"
  if [[ "${#mode}" -ge 2 ]]; then
    group="${mode: -2:1}"
  else
    group="0"
  fi
  case "${group}${last}" in
    *2*|*3*|*6*|*7*) return 0 ;;
  esac
  return 1
}

hm_chrome_component_trusted() {
  local path="$1" pair="" uid="" rest="" mode=""
  pair="$(hm_chrome_stat_owner_mode "${path}")" || return 1
  uid="${pair%% *}"
  rest="${pair#* }"
  mode="${rest%% *}"
  [[ "${uid}" == "0" ]] || return 1
  if hm_chrome_mode_group_or_other_write "${mode}"; then
    return 1
  fi
  return 0
}

hm_chrome_chain_trusted() {
  local path="$1" cur=""
  [[ "${path}" == /* ]] || return 1
  cur="${path%/}"
  [[ -n "${cur}" ]] || cur="/"
  while [[ "${cur}" != "/" ]]; do
    hm_chrome_component_trusted "${cur}" || return 1
    cur="$(dirname "${cur}")"
  done
  hm_chrome_component_trusted "/"
}

# Plik i każdy katalog nadrzędny: właściciel root i brak zapisu grupy/innych.
# To samo dla ścieżki po rozwiązaniu symlinków.
hm_chrome_path_trusted() {
  local path="$1" canon=""
  [[ -n "${path}" ]] || return 1
  hm_chrome_chain_trusted "${path}" || return 1
  canon="$(readlink -f "${path}" 2>/dev/null || true)"
  if [[ -n "${canon}" && "${canon}" != "${path}" ]]; then
    hm_chrome_chain_trusted "${canon}" || return 1
  fi
  return 0
}

# Wersja bez uruchamiania binarki (katalog linux-<ver>, plik VERSION albo abi).
hm_chrome_version_passive() {
  local bin="$1" dir="" ver=""
  [[ -n "${bin}" ]] || return 1
  if [[ "${bin}" =~ /linux-([0-9][0-9A-Za-z._-]*)/chrome-linux(64)?/chrome$ ]]; then
    printf 'Chrome %s' "${BASH_REMATCH[1]}"
    return 0
  fi
  dir="$(dirname "${bin}")"
  if [[ -f "${dir}/VERSION" && ! -L "${dir}/VERSION" ]]; then
    ver="$(head -1 "${dir}/VERSION" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "${ver}" =~ ^[0-9][0-9A-Za-z._-]*$ ]]; then
      printf 'Chrome %s' "${ver}"
      return 0
    fi
  fi
  if [[ -f "${dir}/abi" && ! -L "${dir}/abi" ]]; then
    ver="$(head -1 "${dir}/abi" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "${ver}" =~ ^[0-9][0-9A-Za-z._-]*$ ]]; then
      printf 'Chrome %s' "${ver}"
      return 0
    fi
  fi
  return 1
}

# Niezaufaną binarkę uruchamiaj tylko jako jej właściciel (nigdy jako root).
# Odmowa zrzucenia uprawnień: kod 126, bez exec.
hm_chrome_run_as_owner() {
  local bin="$1" pair="" uid="" rest="" mode="" user=""
  shift
  [[ -n "${bin}" && -x "${bin}" ]] || return 126
  pair="$(hm_chrome_stat_owner_mode "${bin}")" || return 126
  uid="${pair%% *}"
  rest="${pair#* }"
  mode="${rest%% *}"
  user="${rest#* }"
  [[ "${user}" != "${mode}" ]] || user=""
  if [[ "$(id -u)" -ne 0 || -z "${user}" || "${user}" == "root" || "${uid}" == "0" ]]; then
    return 126
  fi
  if hm_have_cmd runuser; then
    runuser -u "${user}" -- "${bin}" "$@"
    return $?
  fi
  if hm_have_cmd sudo; then
    sudo -u "${user}" -- "${bin}" "$@"
    return $?
  fi
  return 126
}

# Lenive pobranie wersji Chrome — nie wołać przy każdym starcie hmtools.
# Ścieżka spoza roota (Puppeteer, unit usera): bez exec, wersja z katalogu albo CDP.
hm_chrome_fetch_version() {
  local bin="${1:-${CHROME_BIN:-}}" ver=""
  CHROME_VERSION=""
  [[ -n "${bin}" ]] || return 1
  [[ -e "${bin}" || -L "${bin}" ]] || return 1
  if ! hm_chrome_path_trusted "${bin}"; then
    ver="$(hm_chrome_version_passive "${bin}" 2>/dev/null || true)"
    if [[ -z "${ver}" && -n "${CHROME_CDP_BROWSER:-}" && "${CHROME_CDP_BROWSER}" != "yes" ]]; then
      ver="${CHROME_CDP_BROWSER}"
    fi
    [[ -n "${ver}" ]] || return 1
    CHROME_VERSION="${ver}"
    return 0
  fi
  [[ -x "${bin}" ]] || return 1
  ver="$(hm_run_timeout 3 "${bin}" --version 2>/dev/null | head -1 | tr -s ' ' | sed 's/[[:space:]]*$//' || true)"
  CHROME_VERSION="${ver}"
  [[ -n "${ver}" ]]
}

# Binarka z działającego unit systemd (MainPID → /proc/PID/exe) lub ExecStart.
hm_chrome_bin_from_systemd() {
  local unit="${1:-}"
  local pid exe line
  [[ -n "${unit}" ]] || return 1
  hm_have_cmd systemctl || return 1
  systemctl cat "${unit}" >/dev/null 2>&1 || return 1

  pid="$(systemctl show -p MainPID --value "${unit}" 2>/dev/null || true)"
  if [[ -n "${pid}" && "${pid}" != "0" && -r "/proc/${pid}/exe" ]]; then
    exe="$(readlink -f "/proc/${pid}/exe" 2>/dev/null || true)"
    if [[ -n "${exe}" && -x "${exe}" ]]; then
      printf '%s' "${exe}"
      return 0
    fi
  fi
  # fallback: pierwszy token ścieżki z ExecStart=
  line="$(systemctl show -p ExecStart --value "${unit}" 2>/dev/null | head -1 || true)"
  # format: { path=/foo/chrome ; argv[]=... }
  if [[ "${line}" =~ path=([^[:space:];]+) ]]; then
    exe="${BASH_REMATCH[1]}"
    if [[ -x "${exe}" ]]; then
      printf '%s' "${exe}"
      return 0
    fi
  fi
  return 1
}

# Najnowsza binarka Puppeteer pod /home/*/.cache/puppeteer/chrome/
# HM_CHROME_HOME_ROOT — jeden katalog zamiast /home i /root (testy).
hm_chrome_bin_from_puppeteer() {
  local cand newest="" newest_mtime=0 mt root
  local -a roots=()
  if [[ -n "${HM_CHROME_HOME_ROOT:-}" ]]; then
    roots=("${HM_CHROME_HOME_ROOT}")
  else
    roots=(/home /root)
  fi
  # typowe layouty Chrome for Testing (Puppeteer)
  for root in "${roots[@]}"; do
  for cand in \
    "${root}"/*/.cache/puppeteer/chrome/linux-*/chrome-linux64/chrome \
    "${root}"/*/.cache/puppeteer/chrome/linux-*/chrome-linux/chrome \
    "${root}"/.cache/puppeteer/chrome/linux-*/chrome-linux64/chrome \
    "${root}"/.cache/puppeteer/chrome/linux-*/chrome-linux/chrome
  do
    [[ -e "${cand}" ]] || continue
    [[ -x "${cand}" ]] || continue
    mt="$(stat -c '%Y' "${cand}" 2>/dev/null || stat -f '%m' "${cand}" 2>/dev/null || echo 0)"
    if [[ "${mt}" -ge "${newest_mtime}" ]]; then
      newest_mtime="${mt}"
      newest="${cand}"
    fi
  done
  done
  [[ -n "${newest}" ]] || return 1
  printf '%s' "${newest}"
  return 0
}

# CDP DevTools (np. chrome --remote-debugging-port=9222)
hm_chrome_cdp_probe() {
  local url="${1:-http://127.0.0.1:9222}"
  local base port raw
  CHROME_CDP_URL=""
  CHROME_CDP_BROWSER=""
  # FORCE_CHROME_CDP=http://127.0.0.1:9222 lub samo 9222
  if [[ -n "${FORCE_CHROME_CDP:-}" ]]; then
    if [[ "${FORCE_CHROME_CDP}" =~ ^[0-9]+$ ]]; then
      url="http://127.0.0.1:${FORCE_CHROME_CDP}"
    else
      url="${FORCE_CHROME_CDP}"
    fi
  fi
  base="${url%/}"
  [[ "${base}" == http://* || "${base}" == https://* ]] || base="http://${base}"

  if ! hm_have_cmd curl; then
    return 1
  fi
  raw="$(curl -sf --max-time 2 "${base}/json/version" 2>/dev/null || true)"
  [[ -n "${raw}" ]] || return 1
  CHROME_CDP_URL="${base}"
  CHROME_CDP_BROWSER="$(printf '%s' "${raw}" | sed -n 's/.*"Browser"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  [[ -n "${CHROME_CDP_BROWSER}" ]] || CHROME_CDP_BROWSER="yes"
  return 0
}

hm_detect_chrome() {
  CHROME="no"
  CHROME_BIN=""
  CHROME_SOURCE=""
  CHROME_VERSION=""
  CHROME_SERVICE=""
  CHROME_CDP_URL=""
  CHROME_CDP_BROWSER=""

  local name bin unit

  for name in google-chrome-stable google-chrome chromium chromium-browser chrome; do
    if hm_have_cmd "${name}"; then
      bin="$(command -v "${name}")"
      CHROME="yes"
      CHROME_BIN="${bin}"
      CHROME_SOURCE="bin:${name}"
      # wersja dopiero w detect / chrome / health (hm_chrome_fetch_version)
      hm_chrome_cdp_probe 2>/dev/null || true
      return 0
    fi
  done

  for bin in \
    /usr/bin/google-chrome-stable \
    /usr/bin/google-chrome \
    /usr/bin/chromium \
    /usr/bin/chromium-browser \
    /snap/bin/chromium \
    /opt/google/chrome/chrome
  do
    if [[ -x "${bin}" ]]; then
      CHROME="yes"
      CHROME_BIN="${bin}"
      CHROME_SOURCE="path:${bin}"
      hm_chrome_cdp_probe 2>/dev/null || true
      return 0
    fi
  done

  # systemd: chrome-headless / chromium-headless (Puppeteer daemon na VPS)
  for unit in chrome-headless chromium-headless google-chrome-headless; do
    bin="$(hm_chrome_bin_from_systemd "${unit}" 2>/dev/null || true)"
    if [[ -n "${bin}" && -x "${bin}" ]]; then
      CHROME="yes"
      CHROME_BIN="${bin}"
      CHROME_SOURCE="systemd:${unit}"
      CHROME_SERVICE="${unit}"
      hm_chrome_cdp_probe 2>/dev/null || true
      return 0
    fi
  done

  # Puppeteer cache (Chrome for Testing) — bez wpisu w PATH
  bin="$(hm_chrome_bin_from_puppeteer 2>/dev/null || true)"
  if [[ -n "${bin}" && -x "${bin}" ]]; then
    CHROME="yes"
    CHROME_BIN="${bin}"
    CHROME_SOURCE="puppeteer:${bin}"
    hm_chrome_cdp_probe 2>/dev/null || true
    return 0
  fi

  # Sam CDP (binarka niedostępna, ale DevTools żyje)
  if hm_chrome_cdp_probe 2>/dev/null; then
    CHROME="yes"
    CHROME_BIN=""
    CHROME_SOURCE="cdp:${CHROME_CDP_URL}"
    CHROME_VERSION="${CHROME_CDP_BROWSER}"
    return 0
  fi
}

hm_detect_apply_overrides() {
  # Ręczne nadpisanie z hmtools.conf (gdy auto-detekcja się myli)
  # Ostrzeżenia FORCE_* — max 1× na proces (detect wołany wielokrotnie).
  if [[ -n "${FORCE_PANEL:-}" ]]; then
    case "${FORCE_PANEL}" in
      cyberpanel|cpanel|plesk|webmin|directadmin|aapanel|unknown)
        PANEL="${FORCE_PANEL}"
        PANEL_SOURCE="override:FORCE_PANEL"
        if [[ "${PANEL}" != "cyberpanel" ]]; then
          CYBERPANEL_ROOT=""
        elif [[ -z "${CYBERPANEL_ROOT}" && -d /usr/local/CyberCP ]]; then
          CYBERPANEL_ROOT="/usr/local/CyberCP"
        fi
        ;;
      *)
        if [[ "${_HM_FORCE_PANEL_WARNED:-0}" != "1" ]]; then
          _HM_FORCE_PANEL_WARNED=1
          hm_warn "FORCE_PANEL='${FORCE_PANEL}' spoza listy (cyberpanel|cpanel|plesk|webmin|directadmin|aapanel|unknown) — ignoruję."
        fi
        ;;
    esac
  fi
  if [[ -n "${FORCE_WEBSERVER:-}" ]]; then
    case "${FORCE_WEBSERVER}" in
      openlitespeed|litespeed|nginx|apache|unknown)
        WEBSERVER="${FORCE_WEBSERVER}"
        WEBSERVER_SOURCE="override:FORCE_WEBSERVER"
        ;;
      *)
        if [[ "${_HM_FORCE_WEBSERVER_WARNED:-0}" != "1" ]]; then
          _HM_FORCE_WEBSERVER_WARNED=1
          hm_warn "FORCE_WEBSERVER='${FORCE_WEBSERVER}' spoza listy (openlitespeed|litespeed|nginx|apache|unknown) — ignoruję."
        fi
        ;;
    esac
  fi
  if [[ -n "${FORCE_DB_ENGINE:-}" ]]; then
    case "${FORCE_DB_ENGINE}" in
      mariadb|mysql|unknown) DB_ENGINE="${FORCE_DB_ENGINE}" ;;
      *)
        if [[ "${_HM_FORCE_DB_WARNED:-0}" != "1" ]]; then
          _HM_FORCE_DB_WARNED=1
          hm_warn "FORCE_DB_ENGINE='${FORCE_DB_ENGINE}' spoza listy (mariadb|mysql|unknown) — ignoruję."
        fi
        ;;
    esac
  fi
  if [[ -n "${FORCE_SITES_ROOT:-}" && -z "${SITES_ROOT:-}" ]]; then
    SITES_ROOT="${FORCE_SITES_ROOT}"
  fi
  if [[ -n "${FORCE_PKG_MANAGER:-}" ]]; then
    case "${FORCE_PKG_MANAGER}" in
      apt|dnf|yum)
        PKG_MANAGER="${FORCE_PKG_MANAGER}"
        # ostrzeż gdy wymuszono CLI, którego nie ma w PATH (1×)
        if [[ "${_HM_FORCE_PKG_PATH_WARNED:-0}" != "1" ]]; then
          case "${FORCE_PKG_MANAGER}" in
            apt)
              if ! hm_have_cmd apt-get; then
                _HM_FORCE_PKG_PATH_WARNED=1
                hm_warn "FORCE_PKG_MANAGER=apt, ale brak apt-get w PATH."
              fi
              ;;
            dnf)
              if ! hm_have_cmd dnf; then
                _HM_FORCE_PKG_PATH_WARNED=1
                hm_warn "FORCE_PKG_MANAGER=dnf, ale brak dnf w PATH."
              fi
              ;;
            yum)
              if ! hm_have_cmd yum; then
                _HM_FORCE_PKG_PATH_WARNED=1
                hm_warn "FORCE_PKG_MANAGER=yum, ale brak yum w PATH."
              fi
              ;;
          esac
        fi
        ;;
      *)
        if [[ "${_HM_FORCE_PKG_WARNED:-0}" != "1" ]]; then
          _HM_FORCE_PKG_WARNED=1
          hm_warn "FORCE_PKG_MANAGER='${FORCE_PKG_MANAGER}' spoza listy (apt|dnf|yum) — ignoruję."
        fi
        ;;
    esac
  fi
  if [[ -n "${FORCE_SUPERVISOR:-}" ]]; then
    case "${FORCE_SUPERVISOR}" in
      yes)
        SUPERVISOR="yes"
        SUPERVISOR_SOURCE="override:FORCE_SUPERVISOR"
        if [[ -z "${SUPERVISOR_CTL}" ]]; then
          if hm_have_cmd supervisorctl; then
            SUPERVISOR_CTL="$(command -v supervisorctl)"
          elif [[ -x /usr/bin/supervisorctl ]]; then
            SUPERVISOR_CTL="/usr/bin/supervisorctl"
          fi
        fi
        ;;
      no)
        SUPERVISOR="no"
        SUPERVISOR_SOURCE="override:FORCE_SUPERVISOR"
        SUPERVISOR_CTL=""
        ;;
    esac
  fi
  if [[ -n "${FORCE_CHROME_BIN:-}" ]]; then
    if [[ -x "${FORCE_CHROME_BIN}" ]]; then
      CHROME="yes"
      CHROME_BIN="${FORCE_CHROME_BIN}"
      CHROME_SOURCE="override:FORCE_CHROME_BIN"
      CHROME_VERSION=""
    elif [[ "${_HM_FORCE_CHROME_WARNED:-0}" != "1" ]]; then
      _HM_FORCE_CHROME_WARNED=1
      hm_warn "FORCE_CHROME_BIN nie jest wykonywalne: ${FORCE_CHROME_BIN}"
    fi
  fi
  if [[ "${ALLOW_UNSUPPORTED_OS:-0}" == "1" ]]; then
    OS_SUPPORTED=1
  fi
}

hm_detect_pkg_manager() {
  PKG_MANAGER="unknown"
  if [[ -n "${FORCE_PKG_MANAGER:-}" ]]; then
    case "${FORCE_PKG_MANAGER}" in
      apt|dnf|yum) PKG_MANAGER="${FORCE_PKG_MANAGER}" ;;
    esac
  fi
  # Najpierw rodzina OS — na RHEL przypadkowy apt-get nie wygrywa z dnf/yum
  if [[ "${PKG_MANAGER}" == "unknown" ]]; then
    case "${OS_FAMILY:-}" in
      rhel)
        if hm_have_cmd dnf; then
          PKG_MANAGER="dnf"
        elif hm_have_cmd yum; then
          PKG_MANAGER="yum"
        fi
        ;;
      debian)
        if hm_have_cmd apt-get; then
          PKG_MANAGER="apt"
        fi
        ;;
    esac
  fi
  if [[ "${PKG_MANAGER}" == "unknown" ]] && type hm_pkg_id >/dev/null 2>&1; then
    PKG_MANAGER="$(hm_pkg_id 2>/dev/null || echo unknown)"
  fi
  if [[ "${PKG_MANAGER}" == "unknown" ]]; then
    if hm_have_cmd apt-get; then
      PKG_MANAGER="apt"
    elif hm_have_cmd dnf; then
      PKG_MANAGER="dnf"
    elif hm_have_cmd yum; then
      PKG_MANAGER="yum"
    fi
  fi
  # spójność z rodziną OS (gdy CLI nieobecne)
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
  hm_detect_supervisor
  hm_detect_chrome
  hm_detect_docker
  hm_detect_apply_overrides
  if ! hm_os_is_supported; then
    HMTOOLS_RESTRICTED=1
  fi
  # wiązanie strategii pakietów / OS_FAMILY (po znanym OS_ID + PKG_MANAGER)
  if type hm_pkg_bind >/dev/null 2>&1; then
    HM_PKG_BACKEND_KEY=""
    hm_pkg_bind 2>/dev/null || true
  fi
  if type hm_os_bind >/dev/null 2>&1; then
    HM_OS_BACKEND_KEY=""
    hm_os_bind 2>/dev/null || true
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
      if type hm_os_apache_error_log >/dev/null 2>&1 && hm_os_apache_error_log; then
        return 0
      fi
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
      if type hm_os_apache_unit >/dev/null 2>&1; then
        hm_os_apache_unit
      elif [[ "${OS_FAMILY}" == "rhel" ]] || [[ -d /etc/httpd ]]; then
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

# hm_pkg_install — w lib/pkg.sh (adapter apt/rpm)

hm_detect_tool_hints() {
  # Sugerowane komendy hmtools pod wykryty stos (stdout, jedna linia / punkt)
  local base extra=""
  case "${PANEL}" in
    cyberpanel)
      base="webs, use, ols, php, update-php, update, backup, perms, ssl, mysql"
      ;;
    cpanel)
      base="mysql, backup (list/restore), health — natywne webs/ols OLS ograniczone; cPanel UAPI poza zakresem hmtools"
      ;;
    plesk)
      base="mysql, backup, health — Plesk CLI/API poza zakresem; webs/ols tylko przy OLS"
      ;;
    webmin|directadmin|aapanel)
      base="mysql, backup, health, disk — panel-specific: ograniczona auto-konfiguracja vhostów"
      ;;
    *)
      case "${WEBSERVER}" in
        openlitespeed|litespeed)
          base="ols, webs, php, backup, perms, htaccess, cache, proxy"
          ;;
        nginx)
          base="mysql, backup, health, disk — brak natywnego ols; webs jeśli vhosty w znanym layoutcie"
          ;;
        apache)
          base="mysql, backup, health, disk — brak natywnego ols; webs jeśli vhosty w znanym layoutcie"
          ;;
        *)
          base="health, disk, mysql, backup — uzupełnij FORCE_PANEL / FORCE_WEBSERVER w hmtools.conf"
          ;;
      esac
      ;;
  esac
  [[ "${SUPERVISOR:-no}" == "yes" ]] && extra="${extra}, supervisor"
  [[ "${CHROME:-no}" == "yes" ]] && extra="${extra}, chrome"
  [[ "${DOCKER:-no}" == "yes" ]] && extra="${extra}, docker"
  if hm_have_cmd postqueue || hm_have_cmd postfix; then
    extra="${extra}, mail"
  fi
  echo "${base}${extra}"
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
  echo "  SUPERVISOR  : ${SUPERVISOR}${SUPERVISOR_SOURCE:+  [${SUPERVISOR_SOURCE}]}"
  if [[ "${SUPERVISOR}" == "yes" && -n "${SUPERVISOR_CTL}" ]]; then
    echo "  SUPERV_CTL  : ${SUPERVISOR_CTL}"
  fi
  [[ -n "${SUPERVISOR_CONF}" ]] && echo "  SUPERV_CONF : ${SUPERVISOR_CONF}"
  echo "  CHROME      : ${CHROME}${CHROME_SOURCE:+  [${CHROME_SOURCE}]}"
  [[ -n "${CHROME_BIN}" ]] && echo "  CHROME_BIN  : ${CHROME_BIN}"
  if [[ "${CHROME}" == "yes" && -n "${CHROME_BIN}" ]]; then
    if [[ -z "${CHROME_VERSION}" ]]; then
      hm_chrome_fetch_version "${CHROME_BIN}" || true
    fi
    [[ -n "${CHROME_VERSION}" ]] && echo "  CHROME_VER  : ${CHROME_VERSION}"
  fi
  echo "  DOCKER      : ${DOCKER}${DOCKER_SOURCE:+  [${DOCKER_SOURCE}]}"
  [[ -n "${DOCKER_BIN}" ]] && echo "  DOCKER_BIN  : ${DOCKER_BIN}"
  [[ -n "${DOCKER_COMPOSE}" ]] && echo "  COMPOSE     : ${DOCKER_COMPOSE}"
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
  echo "    FORCE_PANEL=…   FORCE_WEBSERVER=…   FORCE_DB_ENGINE=…   FORCE_PKG_MANAGER=…"
  echo "    FORCE_SUPERVISOR=yes|no   FORCE_DOCKER=yes|no   FORCE_CHROME_BIN=/ścieżka   ALLOW_UNSUPPORTED_OS=1"
  echo
}

hm_detect_banner() {
  # krótka karta na start REPL
  local hints
  hints="$(hm_detect_tool_hints)"
  hm_ok "Wykryty stos — OS: ${OS_PRETTY:-?} [${OS_FAMILY}/${PKG_MANAGER}] · panel=${PANEL} · www=${WEBSERVER} · db=${DB_ENGINE} · supervisor=${SUPERVISOR:-no} · docker=${DOCKER:-no} · chrome=${CHROME:-no}"
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
