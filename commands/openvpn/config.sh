#!/usr/bin/env bash
# openvpn config set — stan, render, kopia, restart, rollback.

hm_ovpn_config_canon() {
  case "${1:-}" in
    port|PORT) printf 'PORT' ;;
    proto|PROTO) printf 'PROTO' ;;
    dns|DNS) printf 'DNS' ;;
    endpoint|ENDPOINT) printf 'ENDPOINT' ;;
    subnet|SUBNET) printf 'SUBNET' ;;
    ipv6|IPV6) printf 'IPV6' ;;
    mode|MODE) printf 'MODE' ;;
    client-to-client|CLIENT_TO_CLIENT) printf 'CLIENT_TO_CLIENT' ;;
    max-clients|MAX_CLIENTS) printf 'MAX_CLIENTS' ;;
    keepalive|KEEPALIVE) printf 'KEEPALIVE' ;;
    *) return 1 ;;
  esac
}

hm_ovpn_config_show() {
  local file line key
  file="$(hm_ovpn_state_file)"
  [[ -f "${file}" ]] || { hm_info "Brak pliku stanu."; return 0; }
  while IFS= read -r line || [[ -n "${line}" ]]; do
    key="${line%%=*}"
    hm_ovpn_config_canon "${key}" >/dev/null || continue
    printf '%s\n' "${line}"
  done < "${file}"
  printf 'conf=%s\n' "$(hm_ovpn_conf_file)"
  printf 'state=%s\n' "${file}"
  printf 'pki=%s\n' "$(hm_ovpn_pki)"
  if [[ -f "$(hm_ovpn_conf_file)" ]]; then
    grep -E '^(data-ciphers|cipher) ' "$(hm_ovpn_conf_file)" || true
  fi
}

hm_ovpn_cidr_ok() {
  local cidr="$1" re
  re='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/(8|16|24|32)$'
  [[ "${cidr}" =~ $re ]]
}

hm_ovpn_mask_for() {
  case "${1:-24}" in
    8) printf '255.0.0.0' ;;
    16) printf '255.255.0.0' ;;
    32) printf '255.255.255.255' ;;
    *) printf '255.255.255.0' ;;
  esac
}

hm_ovpn_ip_parts() {
  local ip="$1" re
  re='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'
  [[ "${ip}" =~ $re ]]
}

hm_ovpn_ip_in_subnet() {
  local ip="$1" cidr="$2" net prefix
  local ia ib ic id na nb nc nd
  hm_ovpn_ip_parts "${ip}" || return 1
  hm_ovpn_cidr_ok "${cidr}" || return 1
  net="${cidr%%/*}"
  prefix="${cidr#*/}"
  IFS=. read -r ia ib ic id <<< "${ip}"
  IFS=. read -r na nb nc nd <<< "${net}"
  case "${prefix}" in
    8) [[ "${ia}" == "${na}" ]] || return 1 ;;
    16) [[ "${ia}" == "${na}" && "${ib}" == "${nb}" ]] || return 1 ;;
    24) [[ "${ia}" == "${na}" && "${ib}" == "${nb}" && "${ic}" == "${nc}" ]] || return 1 ;;
    32) [[ "${ip}" == "${net}" ]] || return 1 ;;
  esac
  if [[ "${ip}" == "${net}" ]]; then
    return 1
  fi
  case "${prefix}" in
    24)
      [[ "${id}" == "255" || "${id}" == "0" || "${id}" == "1" ]] && return 1
      ;;
    16)
      [[ "${ic}" == "255" && "${id}" == "255" ]] && return 1
      [[ "${ic}" == "0" && "${id}" == "1" ]] && return 1
      ;;
  esac
  return 0
}

hm_ovpn_ccd_dir() {
  printf '%s/ccd' "$(hm_ovpn_etc)"
}

hm_ovpn_ccd_ip_used() {
  local ip="$1" skip="${2:-}" file
  [[ -d "$(hm_ovpn_ccd_dir)" ]] || return 1
  for file in "$(hm_ovpn_ccd_dir)/"*; do
    [[ -f "${file}" ]] || continue
    [[ "$(basename "${file}")" == "${skip}" ]] && continue
    grep -q "ifconfig-push ${ip} " "${file}" && return 0
  done
  return 1
}

hm_ovpn_config_value_ok() {
  local key="$1" val="$2" cur
  case "${key}" in
    PORT)
      [[ "${val}" =~ ^[0-9]+$ ]] || { hm_err "Port poza zakresem."; return 1; }
      [[ "${val}" -ge 1 && "${val}" -le 65535 ]] || { hm_err "Port poza zakresem."; return 1; }
      cur="$(hm_ovpn_state_value PORT 2>/dev/null || true)"
      if [[ "${val}" != "${cur}" ]] && hm_ovpn_port_busy "${val}"; then
        hm_err "Port ${val} jest zajęty."
        return 1
      fi
      ;;
    PROTO)
      [[ "${val}" == "udp" || "${val}" == "tcp" ]] || { hm_err "Protokół: udp albo tcp."; return 1; }
      ;;
    DNS)
      case "${val}" in
        quad9|cloudflare|google|adguard|system) ;;
        *)
          [[ "${val}" =~ ^[0-9.]+(,[0-9.]+)*$ ]] || { hm_err "Zły DNS."; return 1; }
          ;;
      esac
      ;;
    ENDPOINT)
      [[ "${val}" =~ ^[A-Za-z0-9.:_-]+$ ]] || { hm_err "Zły endpoint."; return 1; }
      ;;
    SUBNET)
      hm_ovpn_cidr_ok "${val}" || { hm_err "Zły CIDR."; return 1; }
      if hm_ovpn_subnet_used "${val}"; then
        hm_err "Podsieć ${val} koliduje z istniejącą trasą."
        return 1
      fi
      ;;
    IPV6|CLIENT_TO_CLIENT)
      [[ "${val}" == "on" || "${val}" == "off" ]] || { hm_err "Wartość: on albo off."; return 1; }
      ;;
    MODE)
      [[ "${val}" == "full" || "${val}" == "split" ]] || { hm_err "Tryb: full albo split."; return 1; }
      ;;
    MAX_CLIENTS)
      [[ "${val}" =~ ^[0-9]+$ && "${val}" -ge 1 ]] || { hm_err "Zła liczba klientów."; return 1; }
      ;;
    ROUTES)
      [[ -z "${val}" ]] && return 0
      local one
      while IFS= read -r one; do
        [[ -n "${one}" ]] || continue
        hm_ovpn_cidr_ok "${one}" || { hm_err "Zły CIDR."; return 1; }
      done < <(printf '%s\n' "${val}" | tr ',' '\n')
      ;;
    KEEPALIVE)
      [[ "${val}" =~ ^[0-9]+[[:space:]]+[0-9]+$ ]] || { hm_err "Keepalive: dwie liczby."; return 1; }
      ;;
    *)
      hm_err "Niedozwolony klucz konfiguracji."
      return 1
      ;;
  esac
}

hm_ovpn_state_put() {
  local file="$1" key="$2" val="$3" tmp
  tmp="$(mktemp)"
  if [[ -f "${file}" ]]; then
    grep -v -E "^${key}=" "${file}" > "${tmp}" || true
  fi
  printf '%s=%s\n' "${key}" "${val}" >> "${tmp}"
  mv -f "${tmp}" "${file}"
}

hm_ovpn_render_from_state() {
  local port proto cidr dns group ver mode ipv6 c2c max keep routes cidr_one net mask
  port="$(hm_ovpn_state_value PORT 2>/dev/null || true)"
  proto="$(hm_ovpn_state_value PROTO 2>/dev/null || true)"
  cidr="$(hm_ovpn_state_value SUBNET 2>/dev/null || true)"
  [[ -n "${port}" && -n "${proto}" && -n "${cidr}" ]] || return 1
  dns="$(hm_ovpn_state_value DNS 2>/dev/null || true)"
  [[ -n "${dns}" ]] || dns="quad9"
  group="$(hm_ovpn_group_name)"
  ver="${HM_OVPN_VERSION:-2.6.0}"
  hm_ovpn_render_conf "$(hm_ovpn_etc)" "${port}" "${proto}" "${cidr}" "${group}" "${ver}" "$(hm_ovpn_dns_ips "${dns}")"
  mode="$(hm_ovpn_state_value MODE 2>/dev/null || true)"
  ipv6="$(hm_ovpn_state_value IPV6 2>/dev/null || true)"
  c2c="$(hm_ovpn_state_value CLIENT_TO_CLIENT 2>/dev/null || true)"
  max="$(hm_ovpn_state_value MAX_CLIENTS 2>/dev/null || true)"
  keep="$(hm_ovpn_state_value KEEPALIVE 2>/dev/null || true)"
  routes="$(hm_ovpn_state_value ROUTES 2>/dev/null || true)"
  if [[ "${mode}" == "full" ]]; then
    printf '%s\n' 'push "redirect-gateway def1 bypass-dhcp"'
  fi
  if [[ "${ipv6}" == "on" ]]; then
    printf '%s\n' 'server-ipv6 fd42:42:42::/64'
  fi
  if [[ "${c2c}" == "on" ]]; then
    printf '%s\n' 'client-to-client'
  fi
  if [[ -n "${max}" ]]; then
    printf 'max-clients %s\n' "${max}"
  fi
  if [[ "${mode}" == "split" || -z "${mode}" ]]; then
    while IFS= read -r cidr_one; do
      [[ -n "${cidr_one}" ]] || continue
      net="${cidr_one%%/*}"
      mask="$(hm_ovpn_mask_for "${cidr_one#*/}")"
      printf 'push "route %s %s"\n' "${net}" "${mask}"
    done < <(printf '%s\n' "${routes}" | tr ',' '\n')
  fi
  if [[ -n "${keep}" ]]; then
    printf 'keepalive %s\n' "${keep}"
  fi
}

hm_ovpn_fw_port() {
  local action="$1" port="$2" proto="$3"
  [[ -n "${HM_OVPN_FW_LOG:-}" ]] && printf '%s %s/%s\n' "${action}" "${port}" "${proto}" >> "${HM_OVPN_FW_LOG}"
  [[ "${HMTOOLS_TEST:-}" == "1" ]] && return 0
  if [[ "${action}" == "allow" ]] && declare -F hm_os_firewall_allow >/dev/null 2>&1; then
    hm_os_firewall_allow "${port}" "${proto}" "" "hmtools-openvpn" || true
  elif [[ "${action}" == "remove" ]] && declare -F hm_os_firewall_remove >/dev/null 2>&1; then
    hm_os_firewall_remove "${port}/${proto}" || true
  fi
}

hm_ovpn_config_active() {
  if [[ -n "${HM_OVPN_ACTIVE:-}" ]]; then
    [[ "${HM_OVPN_ACTIVE}" == "active" ]]
    return
  fi
  if [[ "${HMTOOLS_TEST:-}" == "1" ]]; then
    return 0
  fi
  hm_ovpn_systemctl is-active "openvpn-server@$(hm_ovpn_instance)" >/dev/null 2>&1
}

hm_ovpn_config_apply() {
  local key="$1" val="$2" dry="$3"
  local file conf oldport oldproto newport newproto bak rendered
  file="$(hm_ovpn_state_file)"
  conf="$(hm_ovpn_conf_file)"
  [[ -f "${file}" ]] || { hm_err "Brak pliku stanu."; return 1; }
  hm_ovpn_config_value_ok "${key}" "${val}" || return 1
  if [[ "${key}" == "CLIENT_TO_CLIENT" && "${val}" == "on" ]]; then
    hm_warn "client-to-client pozwala klientom widzieć się nawzajem."
  fi
  oldport="$(hm_ovpn_state_value PORT 2>/dev/null || true)"
  oldproto="$(hm_ovpn_state_value PROTO 2>/dev/null || true)"
  rendered="$(mktemp)"
  cp -f "${file}" "${rendered}.state"
  hm_ovpn_state_put "${rendered}.state" "${key}" "${val}"
  local saved_state
  saved_state="$(hm_ovpn_state_file)"
  if HM_OVPN_ETC="$(dirname "${rendered}.state")" true; then
    :
  fi
  # render czyta hm_ovpn_state_file, więc podstawiamy kopię na czas renderu
  local render_dir
  render_dir="$(mktemp -d)"
  cp -f "${rendered}.state" "${render_dir}/hmtools.state"
  if HM_OVPN_STATE_FILE="${render_dir}/hmtools.state" hm_ovpn_render_using "${render_dir}/hmtools.state" > "${rendered}"; then
    :
  else
    : > "${rendered}"
  fi
  if [[ "${dry}" -eq 1 ]]; then
    if [[ -f "${conf}" && -s "${rendered}" ]]; then
      diff -u "${conf}" "${rendered}" || true
    else
      hm_info "dry-run: brak zmian w plikach"
      diff -u "${file}" "${rendered}.state" || true
    fi
    rm -rf "${rendered}" "${rendered}.state" "${render_dir}"
    return 0
  fi
  mkdir -p "$(hm_ovpn_etc)/.hmtools-backup"
  bak="$(mktemp -d "$(hm_ovpn_etc)/.hmtools-backup/cfg.XXXXXX")"
  cp -f "${file}" "${bak}/hmtools.state"
  [[ -f "${conf}" ]] && cp -f "${conf}" "${bak}/hm.conf"
  if declare -F hm_ovpn_backup_cmd >/dev/null 2>&1; then
    BACKUP_LOCAL_ROOT="${bak}" hm_ovpn_backup_cmd --local >/dev/null || true
  fi
  mv -f "${rendered}.state" "${file}"
  if [[ -s "${rendered}" ]]; then
    mv -f "${rendered}" "${conf}"
  else
    rm -f "${rendered}"
  fi
  rm -rf "${render_dir}"
  newport="$(hm_ovpn_state_value PORT 2>/dev/null || true)"
  newproto="$(hm_ovpn_state_value PROTO 2>/dev/null || true)"
  if [[ -n "${newport}" && "${newport}" != "${oldport}" ]]; then
    hm_ovpn_fw_port allow "${newport}" "${newproto:-udp}"
  fi
  if [[ -s "${conf}" ]]; then
    if ! hm_ovpn_systemctl restart "openvpn-server@$(hm_ovpn_instance)" || ! hm_ovpn_config_active; then
      cp -f "${bak}/hmtools.state" "${file}"
      [[ -f "${bak}/hm.conf" ]] && cp -f "${bak}/hm.conf" "${conf}"
      if [[ -n "${newport}" && "${newport}" != "${oldport}" ]]; then
        hm_ovpn_fw_port remove "${newport}" "${newproto:-udp}"
      fi
      hm_ovpn_systemctl restart "openvpn-server@$(hm_ovpn_instance)" >/dev/null 2>&1 || true
      hm_err "Restart nieudany. Przywrócono poprzedni hm.conf i stan."
      return 1
    fi
  fi
  if [[ -n "${oldport}" && "${newport}" != "${oldport}" ]]; then
    hm_ovpn_fw_port remove "${oldport}" "${oldproto:-udp}"
  fi
  if [[ -f "${conf}" && -f "${bak}/hm.conf" ]]; then
    diff -u "${bak}/hm.conf" "${conf}" || true
  fi
  if [[ "${key}" == "PORT" || "${key}" == "PROTO" || "${key}" == "ENDPOINT" ]]; then
    hm_warn "Profile klientów trzeba wyeksportować ponownie: openvpn client export --all"
  fi
  hm_ok "config ${key}"
}

hm_ovpn_render_using() {
  local state="$1"
  local port proto cidr dns group ver mode ipv6 c2c max keep routes cidr_one net mask line
  port="$(grep '^PORT=' "${state}" | head -n 1 || true)"
  port="${port#PORT=}"
  proto="$(grep '^PROTO=' "${state}" | head -n 1 || true)"
  proto="${proto#PROTO=}"
  cidr="$(grep '^SUBNET=' "${state}" | head -n 1 || true)"
  cidr="${cidr#SUBNET=}"
  [[ -n "${port}" && -n "${proto}" && -n "${cidr}" ]] || return 1
  dns="$(grep '^DNS=' "${state}" | head -n 1 || true)"
  dns="${dns#DNS=}"
  [[ -n "${dns}" ]] || dns="quad9"
  mode="$(grep '^MODE=' "${state}" | head -n 1 || true)"
  mode="${mode#MODE=}"
  ipv6="$(grep '^IPV6=' "${state}" | head -n 1 || true)"
  ipv6="${ipv6#IPV6=}"
  c2c="$(grep '^CLIENT_TO_CLIENT=' "${state}" | head -n 1 || true)"
  c2c="${c2c#CLIENT_TO_CLIENT=}"
  max="$(grep '^MAX_CLIENTS=' "${state}" | head -n 1 || true)"
  max="${max#MAX_CLIENTS=}"
  keep="$(grep '^KEEPALIVE=' "${state}" | head -n 1 || true)"
  keep="${keep#KEEPALIVE=}"
  routes="$(grep '^ROUTES=' "${state}" | head -n 1 || true)"
  routes="${routes#ROUTES=}"
  group="$(hm_ovpn_group_name)"
  ver="${HM_OVPN_VERSION:-2.6.0}"
  hm_ovpn_render_conf "$(hm_ovpn_etc)" "${port}" "${proto}" "${cidr}" "${group}" "${ver}" "$(hm_ovpn_dns_ips "${dns}")"
  [[ "${mode}" == "full" ]] && printf '%s\n' 'push "redirect-gateway def1 bypass-dhcp"'
  [[ "${ipv6}" == "on" ]] && printf '%s\n' 'server-ipv6 fd42:42:42::/64'
  [[ "${c2c}" == "on" ]] && printf '%s\n' 'client-to-client'
  [[ -n "${max}" ]] && printf 'max-clients %s\n' "${max}"
  if [[ "${mode}" != "full" && -n "${routes}" ]]; then
    while IFS= read -r cidr_one; do
      [[ -n "${cidr_one}" ]] || continue
      net="${cidr_one%%/*}"
      mask="$(hm_ovpn_mask_for "${cidr_one#*/}")"
      printf 'push "route %s %s"\n' "${net}" "${mask}"
    done < <(printf '%s\n' "${routes}" | tr ',' '\n')
  fi
  if [[ -n "${keep}" ]]; then
    printf 'keepalive %s\n' "${keep}"
  fi
}

hm_ovpn_config_set() {
  local dry=0 key="" val="" canon="" a
  local -a args=()
  for a in "$@"; do
    if [[ "${a}" == "--dry-run" ]]; then
      dry=1
    else
      args+=("${a}")
    fi
  done
  key="${args[0]:-}"
  val="${args[1]:-}"
  canon="$(hm_ovpn_config_canon "${key}")" || { hm_err "Niedozwolony klucz konfiguracji."; return 1; }
  if [[ "${canon}" == "KEEPALIVE" && -n "${args[2]:-}" ]]; then
    val="${args[1]} ${args[2]}"
  fi
  [[ -n "${val}" ]] || { hm_err "Brak wartości."; return 1; }
  hm_ovpn_config_apply "${canon}" "${val}" "${dry}"
}

hm_ovpn_config() {
  local sub="${1:-show}"
  case "${sub}" in
    show|"") hm_ovpn_config_show ;;
    set)
      shift || true
      hm_ovpn_config_set "$@"
      ;;
    *)
      hm_err "Użycie: openvpn config show|set <klucz> <wartość>"
      return 1
      ;;
  esac
}

hm_ovpn_route_edit() {
  local action="${1:-list}" cidr="${2:-}" cur next
  case "${action}" in
    list)
      cur="$(hm_ovpn_state_value ROUTES 2>/dev/null || true)"
      printf '%s\n' "${cur:-}"
      ;;
    add)
      hm_ovpn_cidr_ok "${cidr}" || { hm_err "Zły CIDR."; return 1; }
      cur="$(hm_ovpn_state_value ROUTES 2>/dev/null || true)"
      case ",${cur}," in
        *",${cidr},"*) hm_info "Trasa już jest."; return 0 ;;
      esac
      if [[ -n "${cur}" ]]; then
        next="${cur},${cidr}"
      else
        next="${cidr}"
      fi
      hm_ovpn_state_put "$(hm_ovpn_state_file)" MODE split
      hm_ovpn_config_apply ROUTES "${next}" 0
      ;;
    del)
      cur="$(hm_ovpn_state_value ROUTES 2>/dev/null || true)"
      next=""
      while IFS= read -r one; do
        [[ -n "${one}" && "${one}" != "${cidr}" ]] || continue
        if [[ -z "${next}" ]]; then
          next="${one}"
        else
          next="${next},${one}"
        fi
      done < <(printf '%s\n' "${cur}" | tr ',' '\n')
      hm_ovpn_config_apply ROUTES "${next}" 0
      ;;
    *)
      hm_err "Użycie: openvpn route add|del|list <CIDR>"
      return 1
      ;;
  esac
}

hm_ovpn_client_ip() {
  local name="${1:-}" ip="${2:-}" cidr mask ccd
  hm_ovpn_name_ok "${name}" || { hm_err "Zła nazwa klienta."; return 1; }
  ccd="$(hm_ovpn_ccd_dir)/${name}"
  if [[ -z "${ip}" ]]; then
    [[ -f "${ccd}" ]] || { hm_err "Brak stałego IP dla ${name}."; return 1; }
    awk '{print $2; exit}' "${ccd}"
    return 0
  fi
  if [[ "${ip}" == "--clear" ]]; then
    rm -f "${ccd}"
    hm_info "Wpis ccd zniknie przy następnym połączeniu klienta."
    return 0
  fi
  cidr="$(hm_ovpn_state_value SUBNET 2>/dev/null || true)"
  [[ -n "${cidr}" ]] || cidr="10.8.0.0/24"
  if ! hm_ovpn_ip_in_subnet "${ip}" "${cidr}"; then
    hm_err "IP spoza podsieci albo adres serwera."
    return 1
  fi
  if hm_ovpn_ccd_ip_used "${ip}" "${name}"; then
    hm_err "To IP jest już przypisane."
    return 1
  fi
  mask="$(hm_ovpn_mask_for "${cidr#*/}")"
  mkdir -p "$(hm_ovpn_ccd_dir)"
  if [[ -f "${ccd}" ]]; then
    grep -v '^ifconfig-push ' "${ccd}" > "${ccd}.tmp" || true
    printf 'ifconfig-push %s %s\n' "${ip}" "${mask}" >> "${ccd}.tmp"
    mv -f "${ccd}.tmp" "${ccd}"
  else
    printf 'ifconfig-push %s %s\n' "${ip}" "${mask}" > "${ccd}"
  fi
  hm_info "Stałe IP zadziała przy następnym połączeniu klienta."
}

hm_ovpn_client_route() {
  local name="${1:-}" action="${2:-}" cidr="${3:-}" net mask ccd
  hm_ovpn_name_ok "${name}" || { hm_err "Zła nazwa klienta."; return 1; }
  [[ "${action}" == "add" ]] || { hm_err "Użycie: openvpn client route <nazwa> add <CIDR>"; return 1; }
  hm_ovpn_cidr_ok "${cidr}" || { hm_err "Zły CIDR."; return 1; }
  net="${cidr%%/*}"
  mask="$(hm_ovpn_mask_for "${cidr#*/}")"
  ccd="$(hm_ovpn_ccd_dir)/${name}"
  mkdir -p "$(hm_ovpn_ccd_dir)"
  touch "${ccd}"
  grep -q "iroute ${net} ${mask}" "${ccd}" || printf 'iroute %s %s\n' "${net}" "${mask}" >> "${ccd}"
  hm_ovpn_route_edit add "${cidr}"
  hm_info "Trasa klienta zadziała przy następnym połączeniu."
}
