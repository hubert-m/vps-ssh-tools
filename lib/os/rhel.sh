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
