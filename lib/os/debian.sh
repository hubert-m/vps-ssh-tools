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
    # Skuteczny DENY/REJECT (przed ALLOW) → OK (idempotent). ALLOW from IP ≠ ban.
    if _hm_os_ufw_has_deny_from "${ip}"; then
      return 0
    fi
    # Nieskuteczny DENY za ALLOW: ufw „Skipping inserting existing rule” przy prepend.
    # Usuń martwe DENY/REJECT, potem prepend na [1].
    _hm_os_ufw_remove_ineffective_full_deny "${ip}" || true

    # ufw = first match: DENY musi być PRZED ALLOW 22/80/443.
    if ufw prepend deny from "${ip}" >/dev/null 2>&1; then
      if _hm_os_ufw_has_deny_from "${ip}"; then
        return 0
      fi
      hm_warn "ufw prepend: brak skutecznego DENY dla ${ip} (przed ALLOW) — nieudane."
    elif ufw insert 1 deny from "${ip}" >/dev/null 2>&1; then
      if _hm_os_ufw_has_deny_from "${ip}"; then
        return 0
      fi
      hm_warn "ufw insert 1: brak skutecznego DENY dla ${ip} — nieudane."
    else
      # ponów: usuń „existing” i prepend
      _hm_os_ufw_remove_ineffective_full_deny "${ip}" || true
      ufw --force delete deny from "${ip}" >/dev/null 2>&1 || true
      ufw --force delete reject from "${ip}" >/dev/null 2>&1 || true
      if ufw prepend deny from "${ip}" >/dev/null 2>&1 \
        && _hm_os_ufw_has_deny_from "${ip}"; then
        return 0
      fi
      hm_warn "ufw prepend/insert nieudane dla ${ip} — bez append (martwy ban za ALLOW)."
    fi
    # Przy ufw NIE raportuj sukcesu samym iptables (DROP znika po reboot / ufw-reload).
    hm_err "Firewall (ufw): nie ustawiono trwałego DENY przed ALLOW dla ${ip}."
    return 1
  fi
  if [[ "${ip}" == *:* ]] && hm_have_cmd ip6tables; then
    ip6tables -I INPUT -s "${ip}" -j DROP && return 0
  fi
  if [[ "${ip}" != *:* ]] && hm_have_cmd iptables; then
    iptables -I INPUT -s "${ip}" -j DROP && return 0
  fi
  return 1
}

# Pełny ban: DENY/REJECT z To=Anywhere|Anywhere (v6) i From=IP (ew. /32|/128),
# stojący PRZED pierwszą regułą ALLOW tej samej rodziny (v4/v6).
# DENY dopisany za ALLOW 22/80/443 jest nieskuteczny (ufw = first match) → nie liczy się.
# Port-specific (np. „80 DENY from IP”) ≠ ban — stdin = ufw status [numbered].
_hm_os_ufw_parse_has_full_deny() {
  local ip="${1:-}"
  [[ -n "${ip}" ]] || return 1
  awk -v ip="${ip}" '
    BEGIN { found = 0; seen_allow_v4 = 0; seen_allow_v6 = 0 }
    {
      line = $0
      # status numbered: "[ 1] Anywhere ..." / "[10] ..."
      sub(/^[[:space:]]*\[[[:space:]]*[0-9]+\][[:space:]]*/, "", line)
      # Pomiń nagłówki
      if (line ~ /^To[[:space:]]+Action/ || line ~ /^--+/) next
      if (line ~ /^Status:/ || line ~ /^[[:space:]]*$/) next

      # Śledź pierwszą ALLOW per rodzina (v6 jeśli linia zawiera "(v6)")
      if (line ~ /[[:space:]]ALLOW([[:space:]]|$)/) {
        if (line ~ /\(v6\)/) seen_allow_v6 = 1
        else seen_allow_v4 = 1
      }

      # To musi być Anywhere / Anywhere (v6) — bez portu/protokołu
      if (line ~ /^Anywhere \(v6\)[[:space:]]+(DENY|REJECT)([[:space:]]+(IN|OUT))?[[:space:]]+/) {
        # nieskuteczne, jeśli wcześniej był już ALLOW v6
        if (seen_allow_v6) next
        rest = line
        sub(/^Anywhere \(v6\)[[:space:]]+(DENY|REJECT)([[:space:]]+(IN|OUT))?[[:space:]]+/, "", rest)
      } else if (line ~ /^Anywhere[[:space:]]+(DENY|REJECT)([[:space:]]+(IN|OUT))?[[:space:]]+/) {
        if (seen_allow_v4) next
        rest = line
        sub(/^Anywhere[[:space:]]+(DENY|REJECT)([[:space:]]+(IN|OUT))?[[:space:]]+/, "", rest)
      } else {
        next
      }
      # From: pierwszy token (IP lub IP/32|128)
      n = split(rest, a, /[[:space:]]+/)
      if (n < 1) next
      from = a[1]
      gsub(/\/(32|128)$/, "", from)
      if (from == ip) { found = 1; exit }
    }
    END { exit found ? 0 : 1 }
  '
}

_hm_os_ufw_has_deny_from() {
  local ip="${1:-}"
  [[ -n "${ip}" ]] || return 1
  # numbered = jawna kolejność reguł (ważne dla pozycji DENY vs ALLOW)
  local out=""
  out="$(ufw status numbered 2>/dev/null)" || out="$(ufw status 2>/dev/null)" || return 1
  printf '%s\n' "${out}" | _hm_os_ufw_parse_has_full_deny "${ip}"
}

# Jak parse_has_full_deny, ale IGNORUJE pozycję (także DENY za ALLOW).
_hm_os_ufw_parse_has_any_full_deny() {
  local ip="${1:-}"
  [[ -n "${ip}" ]] || return 1
  awk -v ip="${ip}" '
    BEGIN { found = 0 }
    {
      line = $0
      sub(/^[[:space:]]*\[[[:space:]]*[0-9]+\][[:space:]]*/, "", line)
      if (line ~ /^To[[:space:]]+Action/ || line ~ /^--+/) next
      if (line ~ /^Status:/ || line ~ /^[[:space:]]*$/) next
      if (line ~ /^Anywhere \(v6\)[[:space:]]+(DENY|REJECT)([[:space:]]+(IN|OUT))?[[:space:]]+/) {
        rest = line
        sub(/^Anywhere \(v6\)[[:space:]]+(DENY|REJECT)([[:space:]]+(IN|OUT))?[[:space:]]+/, "", rest)
      } else if (line ~ /^Anywhere[[:space:]]+(DENY|REJECT)([[:space:]]+(IN|OUT))?[[:space:]]+/) {
        rest = line
        sub(/^Anywhere[[:space:]]+(DENY|REJECT)([[:space:]]+(IN|OUT))?[[:space:]]+/, "", rest)
      } else {
        next
      }
      n = split(rest, a, /[[:space:]]+/)
      if (n < 1) next
      from = a[1]
      gsub(/\/(32|128)$/, "", from)
      if (from == ip) { found = 1; exit }
    }
    END { exit found ? 0 : 1 }
  '
}

_hm_os_ufw_has_any_full_deny() {
  local ip="${1:-}" out=""
  [[ -n "${ip}" ]] || return 1
  out="$(ufw status numbered 2>/dev/null)" || out="$(ufw status 2>/dev/null)" || return 1
  printf '%s\n' "${out}" | _hm_os_ufw_parse_has_any_full_deny "${ip}"
}

# Usuń pełne DENY/REJECT dla IP, które NIE stoją przed ALLOW (nieskuteczne / blokują prepend).
_hm_os_ufw_remove_ineffective_full_deny() {
  local ip="${1:-}"
  local i=0 removed=0
  [[ -n "${ip}" ]] || return 1
  while [[ "${i}" -lt 20 ]]; do
    i=$((i + 1))
    # już skuteczny → nic do roboty
    if _hm_os_ufw_has_deny_from "${ip}"; then
      [[ "${removed}" -gt 0 ]] && return 0
      return 1
    fi
    # brak jakiegokolwiek pełnego DENY → koniec
    if ! _hm_os_ufw_has_any_full_deny "${ip}"; then
      [[ "${removed}" -gt 0 ]] && return 0
      return 1
    fi
    hm_info "Usuwam nieskuteczny DENY/REJECT ufw dla ${ip} (za ALLOW) przed prepend…"
    ufw --force delete deny from "${ip}" >/dev/null 2>&1 \
      || ufw delete deny from "${ip}" >/dev/null 2>&1 \
      || true
    ufw --force delete reject from "${ip}" >/dev/null 2>&1 \
      || ufw delete reject from "${ip}" >/dev/null 2>&1 \
      || true
    removed=$((removed + 1))
  done
  [[ "${removed}" -gt 0 ]]
}

# Alias (stare wywołania) — tylko DENY/REJECT
_hm_os_ufw_status_has_ip() {
  _hm_os_ufw_has_deny_from "$@"
}

_hm_os_do_firewall_unban() {
  local ip="${1:-}"
  [[ -n "${ip}" ]] || return 1
  local ok=0
  if hm_have_cmd ufw; then
    if _hm_os_ufw_has_deny_from "${ip}"; then
      if ufw delete deny from "${ip}"; then
        ok=1
      else
        hm_warn "ufw delete deny from ${ip} zakończyło się błędem."
      fi
    fi
  fi
  if [[ "${ip}" == *:* ]] && hm_have_cmd ip6tables; then
    while ip6tables -D INPUT -s "${ip}" -j DROP 2>/dev/null; do
      ok=1
    done
  fi
  if [[ "${ip}" != *:* ]] && hm_have_cmd iptables; then
    while iptables -D INPUT -s "${ip}" -j DROP 2>/dev/null; do
      ok=1
    done
  fi
  [[ "${ok}" -eq 1 ]]
}
