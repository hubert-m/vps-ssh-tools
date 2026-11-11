#!/usr/bin/env bash
# status, who, kick, log — odczyt pliku status v3 i journala.

hm_ovpn_status_level() {
  local level="OK"
  if [[ "${HM_OVPN_ACTIVE:-}" == "failed" ]]; then
    level="BŁĄD"
  elif [[ ! -f "$(hm_ovpn_tls_key_path)" ]]; then
    level="UWAGA"
  fi
  printf '%s' "${level}"
}

hm_ovpn_each_client() {
  local file="$1" line cn real vpn rx tx cipher
  [[ -f "${file}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" == CLIENT_LIST,* ]] || continue
    cn="$(printf '%s\n' "${line}" | awk -F, '{print $2}')"
    real="$(printf '%s\n' "${line}" | awk -F, '{print $3}')"
    vpn="$(printf '%s\n' "${line}" | awk -F, '{print $4}')"
    rx="$(printf '%s\n' "${line}" | awk -F, '{print $6}')"
    tx="$(printf '%s\n' "${line}" | awk -F, '{print $7}')"
    cipher="$(printf '%s\n' "${line}" | awk -F, '{print $NF}')"
    [[ -n "${cn}" ]] || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${cn}" "${real}" "${vpn}" "${rx:-0}" "${tx:-0}" "${cipher}"
  done < "${file}"
}

hm_ovpn_status() {
  local json=0 n="0" revoked="0" ep port proto level
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json=1; shift ;;
      *) shift ;;
    esac
  done
  if ! hm_ovpn_installed; then
    hm_info "OpenVPN nie jest zainstalowany. Podgląd: openvpn install --dry-run"
    return 0
  fi
  ep="$(hm_ovpn_state_value ENDPOINT 2>/dev/null || true)"
  port="$(hm_ovpn_state_value PORT 2>/dev/null || true)"
  proto="$(hm_ovpn_state_value PROTO 2>/dev/null || true)"
  if [[ -f "$(hm_ovpn_pki)/index.txt" ]]; then
    n="$(grep -c '^V' "$(hm_ovpn_pki)/index.txt" 2>/dev/null || true)"
    revoked="$(grep -c '^R' "$(hm_ovpn_pki)/index.txt" 2>/dev/null || true)"
    [[ "${n}" =~ ^[0-9]+$ ]] || n="0"
    [[ "${revoked}" =~ ^[0-9]+$ ]] || revoked="0"
  fi
  level="$(hm_ovpn_status_level)"
  if [[ "${json}" -eq 1 ]]; then
    printf '{"endpoint":"%s","port":"%s","proto":"%s","clients":%s,"revoked":%s,"level":"%s"}\n' \
      "${ep}" "${port:-1194}" "${proto:-udp}" "${n}" "${revoked}" "${level}"
    return 0
  fi
  printf 'instancja: %s\n' "$(hm_ovpn_instance)"
  printf 'endpoint: %s\n' "${ep:-brak}"
  printf 'port: %s/%s\n' "${port:-1194}" "${proto:-udp}"
  printf 'klienci: %s\n' "${n}"
  printf 'uniewaznieni: %s\n' "${revoked}"
  printf 'unit: %s\n' "${HM_OVPN_ACTIVE:-nieznany}"
  if [[ -f "$(hm_ovpn_etc)/crl.pem" ]]; then
    printf 'crl: jest\n'
  else
    printf 'crl: brak\n'
  fi
  printf '%s\n' "${level}"
}

hm_ovpn_who() {
  local json=0 file line cn real vpn rx tx cipher rxh txh
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json=1; shift ;;
      *) shift ;;
    esac
  done
  file="${HM_OVPN_STATUS:-$(hm_ovpn_etc)/status-hm.log}"
  [[ -f "${file}" ]] || { hm_info "Brak pliku statusu."; return 0; }
  if [[ "${json}" -eq 0 ]] && declare -F hm_table_begin >/dev/null 2>&1; then
    hm_table_begin LLLLLL
    hm_table_row CN REAL VPN RX TX SZYFR
  fi
  while IFS=$'\t' read -r cn real vpn rx tx cipher; do
    [[ -n "${cn}" ]] || continue
    if [[ "${json}" -eq 1 ]]; then
      cn="${cn//\"/}"
      printf '{"cn":"%s","real":"%s","vpn":"%s","rx":"%s","tx":"%s","cipher":"%s"}\n' \
        "${cn}" "${real}" "${vpn}" "${rx}" "${tx}" "${cipher}"
      continue
    fi
    if declare -F hm_table_begin >/dev/null 2>&1; then
      rxh="${rx}"
      txh="${tx}"
      if declare -F hm_human_size >/dev/null 2>&1; then
        rxh="$(hm_human_size "${rx:-0}")"
        txh="$(hm_human_size "${tx:-0}")"
      fi
      hm_table_row "${cn}" "${real:--}" "${vpn:--}" "${rxh}" "${txh}" "${cipher:--}"
    else
      printf '%s\n' "${cn}"
    fi
  done < <(hm_ovpn_each_client "${file}")
  if [[ "${json}" -eq 0 ]] && declare -F hm_table_print >/dev/null 2>&1; then
    hm_table_print
  fi
}

hm_ovpn_kick() {
  local name="${1:-}" yes=0
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y) yes=1; shift ;;
      *) shift ;;
    esac
  done
  hm_ovpn_name_ok "${name}" || { hm_err "Zła nazwa klienta."; return 1; }
  local file="${HM_OVPN_STATUS:-$(hm_ovpn_etc)/status-hm.log}"
  if [[ -f "${file}" ]] && ! grep -q "CLIENT_LIST,${name}," "${file}"; then
    hm_err "Nie ma klienta ${name}."
    return 1
  fi
  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "openvpn kick ${name}" "To nie jest revoke. Klient może połączyć się ponownie." --yes "kill ${name}" || return 1
  elif declare -F hm_confirm_plan >/dev/null 2>&1; then
    hm_confirm_plan "openvpn kick ${name}" "To nie jest revoke. Klient może połączyć się ponownie." "kill ${name}" || return 1
  fi
  hm_ovpn_mgmt_kill "${name}"
  hm_ovpn_audit "kick ${name}"
  hm_info "Klient może połączyć się ponownie. To nie jest revoke."
}

hm_ovpn_log_error() {
  local line="$1"
  case "${line}" in
    *"TLS handshake failed"*|*"VERIFY ERROR"*|*"tls-crypt unwrap error"*|*"AUTH_FAILED"*) return 0 ;;
    *) return 1 ;;
  esac
}

hm_ovpn_log() {
  local n=0 errors=0 client="" file line tmp
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --errors) errors=1; shift ;;
      --client) client="${2:-}"; shift 2 || true ;;
      --follow) shift ;;
      --json) shift ;;
      ''|*[!0-9]*) shift ;;
      *) n="$1"; shift ;;
    esac
  done
  file="${HM_OVPN_JOURNAL:-$(hm_ovpn_applog)}"
  [[ -f "${file}" ]] || { hm_info "Brak applog."; return 0; }
  tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    hm_ovpn_redact_line "${line}" >/dev/null || continue
    if [[ "${errors}" -eq 1 ]] && ! hm_ovpn_log_error "${line}"; then
      continue
    fi
    if [[ -n "${client}" && "${line}" != *"${client}"* ]]; then
      continue
    fi
    printf '%s\n' "${line}" >> "${tmp}"
  done < "${file}"
  if [[ "${n}" -gt 0 ]]; then
    tail -n "${n}" "${tmp}"
  else
    cat "${tmp}"
  fi
  rm -f "${tmp}"
}

hm_ovpn_traffic() {
  local file="${HM_OVPN_TRAFFIC:-/var/lib/hmtools/openvpn/traffic.tsv}" days=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --days) days="${2:-0}"; shift 2 || true ;;
      *) shift ;;
    esac
  done
  [[ "${days}" =~ ^[0-9]+$ ]] || days=0
  [[ -f "${file}" ]] || { hm_info "Brak historii ruchu."; return 0; }
  awk -F'\t' -v days="${days}" '
    NF >= 3 && $1 != "cn" { sent[$1]+=$2; recv[$1]+=$3 }
    END { for (c in sent) printf "%s\t%s\t%s\n", c, sent[c], recv[c] }
  ' "${file}"
}

hm_health_openvpn_alerts() {
  [[ -f "$(hm_ovpn_conf_file)" ]] || return 0
  if [[ "${HM_OVPN_ACTIVE:-}" == "failed" ]]; then
    printf 'openvpn:unit:failed\n'
  fi
  if [[ "${HM_OVPN_FORWARD_NOW:-}" == "0" && "${HM_OVPN_ACTIVE:-}" == "active" ]]; then
    printf 'openvpn:ip_forward:0\n'
  fi
}

hm_ovpn_health_section() {
  local notify=0 line rc=0
  [[ "${1:-}" == "--notify" ]] && notify=1
  if [[ ! -f "$(hm_ovpn_conf_file)" ]]; then
    return 0
  fi
  printf 'OpenVPN\n'
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    printf '  %s\n' "${line}"
    rc=1
    if [[ "${notify}" -eq 1 ]] && declare -F hm_notify >/dev/null 2>&1; then
      hm_notify error "OpenVPN" "${line}" "health.openvpn"
    fi
  done < <(hm_health_openvpn_alerts)
  return "${rc}"
}
