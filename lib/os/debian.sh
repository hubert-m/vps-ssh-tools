#!/usr/bin/env bash
# Adapter OS_FAMILY=debian. Funkcje _hm_os_do_* — kontrakt lib/os_family.sh.

_hm_os_do_web_group() {
  # preferencja Debian; runtime OLS nadpisuje w hm_os_web_group
  if getent group nogroup >/dev/null 2>&1; then
    printf 'nogroup'
    return 0
  fi
  if getent group nobody >/dev/null 2>&1; then
    printf 'nobody'
    return 0
  fi
  printf 'nogroup'
}

_hm_os_do_apache_unit() {
  printf 'apache2'
}

_hm_os_do_apache_error_log() {
  if [[ -f /var/log/apache2/error.log ]]; then
    printf '%s' /var/log/apache2/error.log
    return 0
  fi
  return 1
}

_hm_os_do_firewall_status() {
  if hm_have_cmd ufw; then
    ufw status numbered 2>/dev/null | head -40 || ufw status 2>/dev/null | head -40 || true
    return 0
  fi
  if hm_have_cmd iptables; then
    iptables -L -n 2>/dev/null | head -40 || true
    return 0
  fi
  hm_warn "Brak ufw / iptables w PATH."
  return 1
}

_hm_os_do_firewall_ban() {
  local ip="${1:-}"
  [[ -n "${ip}" ]] || return 1
  if hm_have_cmd ufw; then
    ufw deny from "${ip}" && return 0
  fi
  if hm_have_cmd iptables; then
    iptables -I INPUT -s "${ip}" -j DROP && return 0
  fi
  return 1
}

_hm_os_do_firewall_unban() {
  local ip="${1:-}"
  [[ -n "${ip}" ]] || return 1
  local ok=0
  if hm_have_cmd ufw; then
    if ufw status 2>/dev/null | grep -q "${ip}"; then
      ufw delete deny from "${ip}" 2>/dev/null || true
      ok=1
    fi
  fi
  if hm_have_cmd iptables; then
    while iptables -D INPUT -s "${ip}" -j DROP 2>/dev/null; do
      ok=1
    done
  fi
  [[ "${ok}" -eq 1 ]]
}
