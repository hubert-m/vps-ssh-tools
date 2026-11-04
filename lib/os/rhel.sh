#!/usr/bin/env bash
# Adapter OS_FAMILY=rhel. Funkcje _hm_os_do_* — kontrakt lib/os_family.sh.

_hm_os_do_web_group() {
  if getent group nobody >/dev/null 2>&1; then
    printf 'nobody'
    return 0
  fi
  if getent group nogroup >/dev/null 2>&1; then
    printf 'nogroup'
    return 0
  fi
  printf 'nobody'
}

_hm_os_do_apache_unit() {
  printf 'httpd'
}

_hm_os_do_apache_error_log() {
  if [[ -f /var/log/httpd/error_log ]]; then
    printf '%s' /var/log/httpd/error_log
    return 0
  fi
  if [[ -f /var/log/apache2/error.log ]]; then
    printf '%s' /var/log/apache2/error.log
    return 0
  fi
  return 1
}

_hm_os_do_firewall_status() {
  if hm_have_cmd firewall-cmd; then
    firewall-cmd --list-all 2>/dev/null | head -50 || true
    return 0
  fi
  if hm_have_cmd iptables; then
    iptables -L -n 2>/dev/null | head -40 || true
    return 0
  fi
  hm_warn "Brak firewall-cmd / iptables w PATH."
  return 1
}

_hm_os_firewall_family() {
  local ip="${1:-}"
  if [[ "${ip}" == *:* ]]; then
    printf 'ipv6'
  else
    printf 'ipv4'
  fi
}

_hm_os_do_firewall_ban() {
  local ip="${1:-}"
  [[ -n "${ip}" ]] || return 1
  local family
  family="$(_hm_os_firewall_family "${ip}")"
  if hm_have_cmd firewall-cmd; then
    firewall-cmd --permanent --add-rich-rule="rule family=${family} source address=${ip} drop" 2>/dev/null \
      && firewall-cmd --reload 2>/dev/null \
      && return 0
    firewall-cmd --add-rich-rule="rule family=${family} source address=${ip} drop" 2>/dev/null && return 0
  fi
  if [[ "${family}" == "ipv6" ]] && hm_have_cmd ip6tables; then
    ip6tables -I INPUT -s "${ip}" -j DROP && return 0
  fi
  if [[ "${family}" == "ipv4" ]] && hm_have_cmd iptables; then
    iptables -I INPUT -s "${ip}" -j DROP && return 0
  fi
  return 1
}

_hm_os_do_firewall_unban() {
  local ip="${1:-}"
  [[ -n "${ip}" ]] || return 1
  local ok=0 family
  family="$(_hm_os_firewall_family "${ip}")"
  if hm_have_cmd firewall-cmd; then
    if firewall-cmd --permanent --remove-rich-rule="rule family=${family} source address=${ip} drop" 2>/dev/null; then
      firewall-cmd --reload 2>/dev/null || true
      ok=1
    fi
    firewall-cmd --remove-rich-rule="rule family=${family} source address=${ip} drop" 2>/dev/null && ok=1
  fi
  if [[ "${family}" == "ipv6" ]] && hm_have_cmd ip6tables; then
    while ip6tables -D INPUT -s "${ip}" -j DROP 2>/dev/null; do
      ok=1
    done
  fi
  if [[ "${family}" == "ipv4" ]] && hm_have_cmd iptables; then
    while iptables -D INPUT -s "${ip}" -j DROP 2>/dev/null; do
      ok=1
    done
  fi
  [[ "${ok}" -eq 1 ]]
}

_hm_os_do_firewall_list() {
  _hm_os_do_firewall_status
}

_hm_os_do_firewall_allow() {
  local port="${1:-}" proto="${2:-tcp}" from="${3:-}" comment="${4:-}"
  [[ -n "${port}" ]] || return 1
  [[ "${proto}" == "any" ]] && proto="tcp"
  if hm_have_cmd firewall-cmd; then
    if [[ -n "${from}" ]]; then
      local family
      family="$(_hm_os_firewall_family "${from}")"
      firewall-cmd --permanent --add-rich-rule="rule family=${family} source address=${from} port port=${port} protocol=${proto} accept" 2>/dev/null \
        && firewall-cmd --reload 2>/dev/null && return 0
      return 1
    fi
    if [[ "${proto}" == "tcp" ]]; then
      firewall-cmd --permanent --add-port="${port}/tcp" 2>/dev/null \
        && firewall-cmd --reload 2>/dev/null && return 0
    else
      firewall-cmd --permanent --add-port="${port}/${proto}" 2>/dev/null \
        && firewall-cmd --reload 2>/dev/null && return 0
    fi
    return 1
  fi
  if hm_have_cmd iptables; then
    if [[ -n "${from}" ]]; then
      iptables -I INPUT -p "${proto}" -s "${from}" --dport "${port}" -j ACCEPT && return 0
    else
      iptables -I INPUT -p "${proto}" --dport "${port}" -j ACCEPT && return 0
    fi
  fi
  return 1
}

_hm_os_do_firewall_deny() {
  local port="${1:-}" proto="${2:-tcp}" from="${3:-}" comment="${4:-}"
  [[ -n "${port}" ]] || return 1
  [[ "${proto}" == "any" ]] && proto="tcp"
  if hm_have_cmd firewall-cmd; then
    if [[ -n "${from}" ]]; then
      local family
      family="$(_hm_os_firewall_family "${from}")"
      firewall-cmd --permanent --add-rich-rule="rule family=${family} source address=${from} port port=${port} protocol=${proto} drop" 2>/dev/null \
        && firewall-cmd --reload 2>/dev/null && return 0
      return 1
    fi
    # brak bezpośredniego „deny port” — rich-rule drop na porcie
    firewall-cmd --permanent --add-rich-rule="rule family=ipv4 port port=${port} protocol=${proto} drop" 2>/dev/null \
      && firewall-cmd --reload 2>/dev/null && return 0
    return 1
  fi
  if hm_have_cmd iptables; then
    if [[ -n "${from}" ]]; then
      iptables -I INPUT -p "${proto}" -s "${from}" --dport "${port}" -j DROP && return 0
    else
      iptables -I INPUT -p "${proto}" --dport "${port}" -j DROP && return 0
    fi
  fi
  return 1
}

_hm_os_do_firewall_remove() {
  local spec="${1:-}"
  [[ -n "${spec}" ]] || return 1
  if ! hm_have_cmd firewall-cmd; then
    return 1
  fi
  # from:IP
  if [[ "${spec}" == from:* ]]; then
    local ip="${spec#from:}" family
    family="$(_hm_os_firewall_family "${ip}")"
    firewall-cmd --permanent --remove-rich-rule="rule family=${family} source address=${ip} accept" 2>/dev/null || true
    firewall-cmd --permanent --remove-rich-rule="rule family=${family} source address=${ip} drop" 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
    return 0
  fi
  local port proto="tcp"
  if [[ "${spec}" == */* ]]; then
    port="${spec%%/*}"
    proto="${spec##*/}"
  elif [[ "${spec}" =~ ^[0-9]+$ ]]; then
    port="${spec}"
  else
    return 1
  fi
  firewall-cmd --permanent --remove-port="${port}/${proto}" 2>/dev/null || true
  firewall-cmd --permanent --remove-rich-rule="rule family=ipv4 port port=${port} protocol=${proto} drop" 2>/dev/null || true
  firewall-cmd --reload 2>/dev/null || true
  return 0
}

_hm_os_do_firewall_whitelist() {
  local ip="${1:-}"
  [[ -n "${ip}" ]] || return 1
  local family
  family="$(_hm_os_firewall_family "${ip}")"
  if hm_have_cmd firewall-cmd; then
    firewall-cmd --permanent --add-rich-rule="rule family=${family} source address=${ip} accept" 2>/dev/null \
      && firewall-cmd --reload 2>/dev/null && return 0
    return 1
  fi
  if [[ "${family}" == "ipv6" ]] && hm_have_cmd ip6tables; then
    ip6tables -I INPUT -s "${ip}" -j ACCEPT && return 0
  fi
  if [[ "${family}" == "ipv4" ]] && hm_have_cmd iptables; then
    iptables -I INPUT -s "${ip}" -j ACCEPT && return 0
  fi
  return 1
}
