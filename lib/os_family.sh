#!/usr/bin/env bash
# Publiczne API różnic OS_FAMILY (debian | rhel) — osobna oś od menedżera pakietów.
# Adaptery: lib/os/debian.sh | lib/os/rhel.sh; opcjonalnie lib/os/overrides/${OS_ID}.sh

if [[ -n "${HMTOOLS_OS_FAMILY_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_OS_FAMILY_LOADED=1

HMTOOLS_OS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/os"
HM_OS_BACKEND_KEY=""

hm_os_family_id() {
  case "${OS_FAMILY:-unknown}" in
    debian|rhel) printf '%s' "${OS_FAMILY}" ;;
    *)
      # heurystyka gdy detect jeszcze nie ustawil
      if [[ -d /etc/httpd ]] || hm_have_cmd dnf || hm_have_cmd yum; then
        printf 'rhel'
      else
        printf 'debian'
      fi
      ;;
  esac
}

hm_os_bind() {
  local fam key
  fam="$(hm_os_family_id)"
  key="${fam}:${OS_ID:-}"
  if [[ "${HM_OS_BACKEND_KEY}" == "${key}" ]]; then
    return 0
  fi
  case "${fam}" in
    debian)
      # shellcheck source=os/debian.sh
      source "${HMTOOLS_OS_DIR}/debian.sh"
      ;;
    rhel)
      # shellcheck source=os/rhel.sh
      source "${HMTOOLS_OS_DIR}/rhel.sh"
      ;;
    *)
      # shellcheck source=os/debian.sh
      source "${HMTOOLS_OS_DIR}/debian.sh"
      fam="debian"
      ;;
  esac
  if [[ -n "${OS_ID:-}" && -f "${HMTOOLS_OS_DIR}/overrides/${OS_ID}.sh" ]]; then
    # shellcheck disable=SC1090
    source "${HMTOOLS_OS_DIR}/overrides/${OS_ID}.sh"
  fi
  HM_OS_BACKEND_KEY="${key}"
  return 0
}

_hm_os_do_web_group() { printf 'nogroup'; }
_hm_os_do_web_user_for() {
  case "${1:-nginx}" in
    apache|nginx) printf 'www-data' ;;
    *) printf 'nobody' ;;
  esac
}
_hm_os_do_web_group_for() {
  case "${1:-nginx}" in
    apache|nginx) printf 'www-data' ;;
    *) printf 'nogroup' ;;
  esac
}
_hm_os_do_nginx_conf_dir() { printf '/etc/nginx/sites-available'; }
_hm_os_do_nginx_sites_enabled() { return 0; }
_hm_os_do_apache_unit() { printf 'apache2'; }
_hm_os_do_apache_error_log() { return 1; }
_hm_os_do_firewall_status() { hm_warn "Firewall: brak adaptera OS."; return 1; }
_hm_os_do_firewall_ban() { return 1; }
_hm_os_do_firewall_unban() { return 1; }
_hm_os_do_firewall_list() { _hm_os_do_firewall_status; }
# allow/deny: $1=port $2=proto(tcp|udp|any) $3=from_ip(opcjonalne) $4=comment
_hm_os_do_firewall_allow() { return 1; }
_hm_os_do_firewall_deny() { return 1; }
# remove: $1=numer_reguły LUB "port/proto" LUB "from:IP"
_hm_os_do_firewall_remove() { return 1; }
# whitelist IP (allow from + ideally before deny)
_hm_os_do_firewall_whitelist() { return 1; }

# --- CSF helpers (warstwa przed adapterem rodziny) ---------------------------
hm_os_firewall_backend() {
  if hm_have_cmd csf; then
    printf 'csf'
  elif hm_have_cmd ufw; then
    printf 'ufw'
  elif hm_have_cmd firewall-cmd; then
    printf 'firewalld'
  elif hm_have_cmd iptables; then
    printf 'iptables'
  else
    printf 'none'
  fi
}

_hm_os_csf_tcp_in_get() {
  local conf="${CSF_CONF:-/etc/csf/csf.conf}"
  [[ -f "${conf}" ]] || return 1
  awk -F= '/^TCP_IN[[:space:]]*=/{
    v=$2; gsub(/"/,"",v); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); print v; exit
  }' "${conf}"
}

_hm_os_csf_tcp_in_set() {
  local ports="$1"
  local conf="${CSF_CONF:-/etc/csf/csf.conf}"
  [[ -f "${conf}" ]] || return 1
  local tmp
  tmp="$(mktemp)"
  awk -v p="${ports}" '
    BEGIN{done=0}
    /^TCP_IN[[:space:]]*=/ {
      print "TCP_IN = \"" p "\""
      done=1; next
    }
    { print }
    END { if (!done) print "TCP_IN = \"" p "\"" }
  ' "${conf}" > "${tmp}"
  cat "${tmp}" > "${conf}"
  rm -f "${tmp}"
}

_hm_os_csf_port_in_list() {
  local port="$1" list="$2"
  [[ -n "${port}" && -n "${list}" ]] || return 1
  case ",${list}," in
    *",${port},"*) return 0 ;;
    *) return 1 ;;
  esac
}

_hm_os_csf_allow_port() {
  local port="$1"
  local list new
  list="$(_hm_os_csf_tcp_in_get)" || return 1
  if _hm_os_csf_port_in_list "${port}" "${list}"; then
    return 0
  fi
  if [[ -n "${list}" ]]; then
    new="${list},${port}"
  else
    new="${port}"
  fi
  _hm_os_csf_tcp_in_set "${new}" || return 1
  csf -r >/dev/null 2>&1 || true
  return 0
}

_hm_os_csf_deny_port() {
  local port="$1"
  local list new
  list="$(_hm_os_csf_tcp_in_get)" || return 1
  if ! _hm_os_csf_port_in_list "${port}" "${list}"; then
    return 0
  fi
  new="$(printf '%s' "${list}" | tr ',' '\n' | awk -v p="${port}" '$0!="" && $0!=p' | paste -sd',' -)"
  _hm_os_csf_tcp_in_set "${new}" || return 1
  csf -r >/dev/null 2>&1 || true
  return 0
}

_hm_os_csf_whitelist_ip() {
  local ip="$1"
  [[ -n "${ip}" ]] || return 1
  csf -a "${ip}" "hmtools whitelist" >/dev/null 2>&1 || \
    echo "${ip} # hmtools whitelist $(date -u +%Y%m%d)" >> /etc/csf/csf.allow 2>/dev/null || return 1
  csf -r >/dev/null 2>&1 || true
  return 0
}

# Grupa procesu WWW (OLS preferuje żywą grupę procesu; fallback = rodzina OS)
hm_os_web_group() {
  local g
  g="$(ps -o group= -C lshttpd 2>/dev/null | head -1 | tr -d ' ')"
  if [[ -z "${g}" ]]; then
    g="$(ps -o group= -C openlitespeed 2>/dev/null | head -1 | tr -d ' ')"
  fi
  if [[ -n "${g}" && "${g}" != "root" ]]; then
    printf '%s' "${g}"
    return 0
  fi
  hm_os_bind || true
  _hm_os_do_web_group
}

# User i grupa procesu WWW dla nginx, apache albo ols (nie mylić z grupą OLS „nogroup”).
hm_os_web_user_for() {
  local kind="${1:-nginx}"
  hm_os_bind || true
  _hm_os_do_web_user_for "${kind}"
}

hm_os_web_group_for() {
  local kind="${1:-nginx}"
  hm_os_bind || true
  _hm_os_do_web_group_for "${kind}"
}

# Katalog vhostów nginx i czy rodzina OS włącza je symlinkiem sites-enabled.
hm_os_nginx_conf_dir() {
  hm_os_bind || true
  _hm_os_do_nginx_conf_dir
}

hm_os_nginx_sites_enabled() {
  hm_os_bind || true
  _hm_os_do_nginx_sites_enabled
}

hm_os_apache_unit() {
  hm_os_bind || return 1
  _hm_os_do_apache_unit
}

hm_os_apache_error_log() {
  hm_os_bind || return 1
  _hm_os_do_apache_error_log
}

hm_os_firewall_status() {
  hm_os_bind || return 1
  # CSF / uniwersalne warstwy — przed adapterem rodziny
  if hm_have_cmd csf; then
    echo "backend: csf"
    local tin
    tin="$(_hm_os_csf_tcp_in_get 2>/dev/null || true)"
    [[ -n "${tin}" ]] && echo "TCP_IN: ${tin}"
    csf -l 2>/dev/null | head -40 || true
    return 0
  fi
  echo "backend: $(hm_os_firewall_backend)"
  _hm_os_do_firewall_status
}

hm_os_firewall_list() {
  hm_os_bind || return 1
  if hm_have_cmd csf; then
    hm_os_firewall_status
    return $?
  fi
  _hm_os_do_firewall_list "$@"
}

hm_os_firewall_allow() {
  # $1=port $2=proto $3=from $4=comment
  local port="${1:-}" proto="${2:-tcp}" from="${3:-}" comment="${4:-}"
  hm_os_bind || return 1
  if hm_have_cmd csf; then
    if [[ -n "${from}" ]]; then
      _hm_os_csf_whitelist_ip "${from}" || true
    fi
    _hm_os_csf_allow_port "${port}"
    return $?
  fi
  _hm_os_do_firewall_allow "${port}" "${proto}" "${from}" "${comment}"
}

hm_os_firewall_deny() {
  local port="${1:-}" proto="${2:-tcp}" from="${3:-}" comment="${4:-}"
  hm_os_bind || return 1
  if hm_have_cmd csf; then
    if [[ -n "${from}" ]]; then
      csf -d "${from}" "${comment:-hmtools deny}" >/dev/null 2>&1 || return 1
      csf -r >/dev/null 2>&1 || true
      return 0
    fi
    _hm_os_csf_deny_port "${port}"
    return $?
  fi
  _hm_os_do_firewall_deny "${port}" "${proto}" "${from}" "${comment}"
}

hm_os_firewall_remove() {
  local spec="${1:-}"
  hm_os_bind || return 1
  if hm_have_cmd csf; then
    # numer nieobsługiwany — expect port or IP
    if [[ "${spec}" =~ ^[0-9]+$ ]]; then
      _hm_os_csf_deny_port "${spec}"
      return $?
    fi
    if [[ "${spec}" == *.* || "${spec}" == *:* ]]; then
      csf -ar "${spec}" >/dev/null 2>&1 || csf -dr "${spec}" >/dev/null 2>&1 || return 1
      csf -r >/dev/null 2>&1 || true
      return 0
    fi
    local port="${spec%%/*}"
    _hm_os_csf_deny_port "${port}"
    return $?
  fi
  _hm_os_do_firewall_remove "${spec}"
}

hm_os_firewall_whitelist() {
  local ip="${1:-}"
  hm_os_bind || return 1
  if hm_have_cmd csf; then
    _hm_os_csf_whitelist_ip "${ip}"
    return $?
  fi
  _hm_os_do_firewall_whitelist "${ip}"
}

hm_os_firewall_ban() {
  hm_os_bind || return 1
  if hm_have_cmd csf; then
    csf -d "${1}" "hmtools ban" >/dev/null 2>&1 || return 1
    csf -r >/dev/null 2>&1 || true
    return 0
  fi
  _hm_os_do_firewall_ban "$@"
}

hm_os_firewall_unban() {
  hm_os_bind || return 1
  if hm_have_cmd csf; then
    csf -dr "${1}" >/dev/null 2>&1 || return 1
    csf -r >/dev/null 2>&1 || true
    return 0
  fi
  _hm_os_do_firewall_unban "$@"
}
