#!/usr/bin/env bash
# openvpn install — pakiety, PKI, hm.conf, NAT. Ścieżki da się podmienić w testach.

hm_ovpn_etc() { printf '%s' "${HM_OVPN_ETC:-/etc/openvpn/server}"; }

hm_ovpn_state_file() { printf '%s/hmtools.state' "$(hm_ovpn_etc)"; }

hm_ovpn_conf_file() { printf '%s/hm.conf' "$(hm_ovpn_etc)"; }

hm_ovpn_group_name() {
  case "${OS_FAMILY:-debian}" in
    rhel|redhat) printf 'nobody' ;;
    *) printf 'nogroup' ;;
  esac
}

hm_ovpn_packages() {
  case "${OS_FAMILY:-debian}" in
    rhel|redhat) printf '%s\n' epel-release openvpn easy-rsa ;;
    *) printf '%s\n' openvpn easy-rsa ;;
  esac
}

hm_ovpn_subnet_pair() {
  local cidr="${1:-10.8.0.0/24}" net mask
  net="${cidr%%/*}"
  case "${cidr#*/}" in
    24) mask="255.255.255.0" ;;
    16) mask="255.255.0.0" ;;
    *) mask="255.255.255.0"; net="${net%%/*}" ;;
  esac
  printf '%s %s' "${net}" "${mask}"
}

hm_ovpn_render_conf() {
  local etc="$1" port="$2" proto="$3" cidr="$4" group="$5" ver="${6:-2.6}" dns="${7:-}"
  local pair ciphers
  pair="$(hm_ovpn_subnet_pair "${cidr}")"
  if [[ "${ver}" == 2.4* ]]; then
    ciphers=$'cipher AES-256-GCM\nncp-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305'
  else
    ciphers="data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305"
  fi
  cat <<EOF
port ${port}
proto ${proto}
dev tun
topology subnet
server ${pair}
${ciphers}
tls-version-min 1.2
ca ${etc}/hm/pki/ca.crt
cert ${etc}/hm/pki/issued/server.crt
key ${etc}/hm/pki/private/server.key
tls-crypt $(hm_ovpn_tls_key_path)
auth SHA256
dh none
remote-cert-tls client
crl-verify ${etc}/crl.pem
user nobody
group ${group}
persist-key
persist-tun
keepalive 10 120
client-config-dir ${etc}/ccd
status /run/openvpn-server/status-hm.log 30
status-version 3
management /run/openvpn-server/hm.sock unix
verb 3
EOF
  if [[ "${proto}" == "udp" ]]; then
    printf 'explicit-exit-notify 1\n'
  fi
  if [[ -n "${dns}" ]]; then
    local ip
    local IFS=','
    for ip in ${dns}; do
      printf 'push "dhcp-option DNS %s"\n' "${ip}"
    done
  fi
}

hm_ovpn_port_busy() {
  local port="$1" file="${HM_OVPN_SS_FILE:-}" line
  if [[ -n "${file}" ]]; then
    [[ -f "${file}" ]] || return 1
    grep -q ":${port} " "${file}"
    return
  fi
  [[ "${HMTOOLS_TEST:-}" == "1" ]] && return 1
  command -v ss >/dev/null 2>&1 || return 1
  line="$(ss -Hlun "sport = :${port}" 2>/dev/null || true)"
  [[ -n "${line}" ]]
}

hm_ovpn_subnet_used() {
  local cidr="${1%%/*}" file="${HM_OVPN_ROUTES:-}"
  if [[ -n "${file}" ]]; then
    [[ -f "${file}" ]] || return 1
    grep -q "${cidr}" "${file}"
    return
  fi
  [[ "${HMTOOLS_TEST:-}" == "1" ]] && return 1
  command -v ip >/dev/null 2>&1 || return 1
  ip -o route show 2>/dev/null | grep -q "${cidr}"
}

hm_ovpn_os_ok() {
  local id
  if [[ -n "${HM_OVPN_OS_OK:-}" ]]; then
    [[ "${HM_OVPN_OS_OK}" == "1" ]]
    return
  fi
  case "${OS_FAMILY:-}" in
    debian|rhel|redhat) return 0 ;;
  esac
  [[ -r /etc/os-release ]] || return 1
  id="$(. /etc/os-release && printf '%s' "${ID:-}")"
  case "${id}" in
    ubuntu|debian|linuxmint|raspbian|almalinux|rocky|rhel|centos|fedora) return 0 ;;
    *) return 1 ;;
  esac
}

hm_ovpn_default_iface() {
  local dev
  if [[ -n "${HM_OVPN_IFACE:-}" ]]; then
    printf '%s' "${HM_OVPN_IFACE}"
    return 0
  fi
  if [[ "${HMTOOLS_TEST:-}" != "1" ]] && command -v ip >/dev/null 2>&1; then
    dev="$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
    if [[ -n "${dev}" ]]; then
      printf '%s' "${dev}"
      return 0
    fi
  fi
  printf '%s' eth0
}

hm_ovpn_validate_install() {
  local port="$1" proto="$2" dns="$3" ip re
  [[ "${port}" =~ ^[0-9]+$ ]] || { hm_err "Zły port."; return 1; }
  [[ "${port}" -ge 1 && "${port}" -le 65535 ]] || { hm_err "Zły port."; return 1; }
  case "${proto}" in
    udp|tcp) ;;
    *) hm_err "Zły proto. Dozwolone: udp albo tcp."; return 1 ;;
  esac
  if [[ "${dns}" == custom:* ]]; then
    ip="${dns#custom:}"
    re='^([0-9]{1,3}\.){3}[0-9]{1,3}(,([0-9]{1,3}\.){3}[0-9]{1,3})*$'
    [[ "${ip}" =~ ${re} ]] || { hm_err "Zły adres DNS."; return 1; }
  fi
}

hm_ovpn_foreign_conf() {
  local etc f
  etc="$(hm_ovpn_etc)"
  [[ -d "${etc}" ]] || return 1
  for f in "${etc}"/*.conf; do
    [[ -f "${f}" ]] || continue
    [[ "$(basename "${f}")" == "hm.conf" ]] && continue
    return 0
  done
  return 1
}

hm_ovpn_same_install() {
  local file port="$1" proto="$2" cidr="$3"
  file="$(hm_ovpn_state_file)"
  [[ -f "${file}" ]] || return 1
  grep -q "^PORT=${port}$" "${file}" || return 1
  grep -q "^PROTO=${proto}$" "${file}" || return 1
  grep -q "^SUBNET=${cidr}$" "${file}" || return 1
}

hm_ovpn_dns_ips() {
  local spec="${1:-quad9}"
  case "${spec}" in
    cloudflare) printf '1.1.1.1,1.0.0.1' ;;
    quad9) printf '9.9.9.9,149.112.112.112' ;;
    google) printf '8.8.8.8,8.8.4.4' ;;
    adguard) printf '94.140.14.14,94.140.15.15' ;;
    custom:*) printf '%s' "${spec#custom:}" ;;
    system) printf '%s' "${HM_OVPN_SYSTEM_DNS:-1.1.1.1}" ;;
    *) printf '%s' "${spec}" ;;
  esac
}

hm_ovpn_nat_unit_path() {
  if [[ -n "${HM_OVPN_NAT_UNIT:-}" ]]; then
    printf '%s' "${HM_OVPN_NAT_UNIT}"
    return 0
  fi
  if [[ "${HMTOOLS_TEST:-}" == "1" ]]; then
    printf '%s/hmtools-openvpn-nat.service' "$(hm_ovpn_etc)"
    return 0
  fi
  printf '%s' /etc/systemd/system/hmtools-openvpn-nat.service
}

hm_ovpn_systemctl() {
  [[ -n "${HM_OVPN_CALL_LOG:-}" ]] && printf 'systemctl %s\n' "$*" >> "${HM_OVPN_CALL_LOG}"
  if [[ "${HM_OVPN_SYSTEMCTL_FAIL:-}" == "1" ]]; then
    return 1
  fi
  if [[ "${HMTOOLS_TEST:-}" == "1" ]]; then
    return 0
  fi
  systemctl "$@"
}

hm_ovpn_fw_exec() {
  local log="${HM_OVPN_CALL_LOG:-}"
  [[ -n "${log}" ]] && printf '%s\n' "$*" >> "${log}"
  if [[ "${HMTOOLS_TEST:-}" == "1" ]]; then
    return 0
  fi
  "$@"
}

hm_ovpn_gen_tls_key() {
  local dest="$1" bin
  if [[ -s "${dest}" ]]; then
    return 0
  fi
  mkdir -p "$(dirname "${dest}")"
  [[ -n "${HM_OVPN_CALL_LOG:-}" ]] && printf 'openvpn --genkey secret %s\n' "${dest}" >> "${HM_OVPN_CALL_LOG}"
  if [[ "${HMTOOLS_TEST:-}" == "1" && "${HM_OVPN_GENKEY_LIVE:-}" != "1" ]]; then
    printf '%s\n' '-----BEGIN OpenVPN Static key V1-----' 'mock-tls' '-----END OpenVPN Static key V1-----' > "${dest}"
  else
    bin="$(command -v openvpn 2>/dev/null || true)"
    [[ -n "${bin}" ]] || { hm_err "Brak openvpn do wygenerowania klucza tls-crypt."; return 1; }
    if ! "${bin}" --genkey secret "${dest}" >/dev/null 2>&1; then
      "${bin}" --genkey --secret "${dest}" >/dev/null 2>&1 || { hm_err "Nie udało się wygenerować klucza tls-crypt."; return 1; }
    fi
  fi
  chmod 0600 "${dest}" || true
}

hm_ovpn_strip_markers() {
  local file="$1"
  [[ -f "${file}" ]] || return 0
  awk '
    /BEGIN hmtools-openvpn/ {skip=1; next}
    /END hmtools-openvpn/ {skip=0; next}
    skip==0 {print}
  ' "${file}" > "${file}.tmp" && mv "${file}.tmp" "${file}"
}

hm_ovpn_rollback() {
  local etc pki
  hm_warn "Wycofuję niedokończoną instalację OpenVPN."
  etc="$(hm_ovpn_etc)"
  pki="${etc}/hm/pki"
  hm_ovpn_systemctl disable --now "openvpn-server@$(hm_ovpn_instance)" >/dev/null 2>&1 || true
  rm -f "$(hm_ovpn_conf_file)" "$(hm_ovpn_state_file)" "${etc}/crl.pem"
  case "${pki}" in
    "${etc}/"*) rm -rf "${pki}" ;;
  esac
  hm_ovpn_strip_markers "${HM_OVPN_UFW_RULES:-/etc/ufw/before.rules}"
  hm_ovpn_strip_markers "${HM_OVPN_CSF_POST:-/etc/csf/csfpost.sh}"
  rm -f "$(hm_ovpn_nat_unit_path)"
}

hm_ovpn_nat_apply() {
  local fw="${HM_OVPN_FW:-iptables}" cidr="$1" iface="${2:-eth0}" port="$3" proto="$4"
  local rules log unit script
  log="${HM_OVPN_CALL_LOG:-}"
  case "${fw}" in
    ufw)
      rules="${HM_OVPN_UFW_RULES:-/etc/ufw/before.rules}"
      mkdir -p "$(dirname "${rules}")"
      if [[ ! -f "${rules}" ]] || ! grep -q 'BEGIN hmtools-openvpn' "${rules}"; then
        cat >> "${rules}" <<EOF
# BEGIN hmtools-openvpn
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s ${cidr} -o ${iface} -j MASQUERADE
COMMIT
# END hmtools-openvpn
EOF
      fi
      hm_ovpn_fw_exec ufw route allow in on tun0 out on "${iface}" || true
      hm_ovpn_fw_exec ufw allow "${port}/${proto}" || true
      ;;
    firewalld)
      hm_ovpn_fw_exec firewall-cmd --permanent --add-masquerade || true
      hm_ovpn_fw_exec firewall-cmd --permanent --add-port="${port}/${proto}" || true
      hm_ovpn_fw_exec firewall-cmd --permanent --zone=trusted --add-interface=tun0 || true
      hm_ovpn_fw_exec firewall-cmd --reload || true
      ;;
    csf)
      rules="${HM_OVPN_CSF_POST:-/etc/csf/csfpost.sh}"
      mkdir -p "$(dirname "${rules}")"
      if [[ ! -f "${rules}" ]] || ! grep -q 'BEGIN hmtools-openvpn' "${rules}"; then
        cat >> "${rules}" <<EOF
# BEGIN hmtools-openvpn
iptables -t nat -C POSTROUTING -s ${cidr} -o ${iface} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s ${cidr} -o ${iface} -j MASQUERADE
# END hmtools-openvpn
EOF
      fi
      ;;
    *)
      unit="$(hm_ovpn_nat_unit_path)"
      script="${unit}.sh"
      mkdir -p "$(dirname "${unit}")"
      cat > "${script}" <<EOF
#!/bin/sh
iptables -t nat -C POSTROUTING -s ${cidr} -o ${iface} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s ${cidr} -o ${iface} -j MASQUERADE
EOF
      chmod 0755 "${script}" || true
      cat > "${unit}" <<EOF
[Unit]
Description=hmtools OpenVPN NAT
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh ${script}

[Install]
WantedBy=multi-user.target
EOF
      hm_ovpn_systemctl enable hmtools-openvpn-nat.service || true
      [[ -n "${log}" ]] && printf 'iptables MASQUERADE %s via %s\n' "${cidr}" "${iface}" >> "${log}"
      ;;
  esac
}

hm_ovpn_write_state() {
  local port="$1" proto="$2" cidr="$3" endpoint="$4" pki="$5"
  cat > "$(hm_ovpn_state_file)" <<EOF
PORT=${port}
PROTO=${proto}
SUBNET=${cidr}
ENDPOINT=${endpoint}
PKI=${pki}
PREV_FORWARD=${HM_OVPN_PREV_FORWARD:-0}
EOF
}

hm_ovpn_install() {
  local yes=0 port="1194" proto="udp" dns="quad9" ipv6=0 endpoint="" cidr="10.8.0.0/24"
  local first="" dry=0 force=0 rsa=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y) yes=1; shift ;;
      --port) port="${2:-1194}"; shift 2 || true ;;
      --port=*) port="${1#*=}"; shift ;;
      --proto) proto="${2:-udp}"; shift 2 || true ;;
      --proto=*) proto="${1#*=}"; shift ;;
      --dns) dns="${2:-quad9}"; shift 2 || true ;;
      --dns=*) dns="${1#*=}"; shift ;;
      --ipv6) ipv6=1; shift ;;
      --endpoint) endpoint="${2:-}"; shift 2 || true ;;
      --endpoint=*) endpoint="${1#*=}"; shift ;;
      --subnet) cidr="${2:-10.8.0.0/24}"; shift 2 || true ;;
      --subnet=*) cidr="${1#*=}"; shift ;;
      --first-client) first="${2:-}"; shift 2 || true ;;
      --first-client=*) first="${1#*=}"; shift ;;
      --dry-run) dry=1; shift ;;
      --force) force=1; shift ;;
      --rsa) rsa=1; shift ;;
      *) hm_err "Nieznana flaga: $1"; return 1 ;;
    esac
  done
  [[ -n "${endpoint}" ]] || endpoint="${HM_OVPN_ENDPOINT:-vpn.example}"
  hm_ovpn_validate_install "${port}" "${proto}" "${dns}" || return 1
  if ! hm_ovpn_os_ok; then
    hm_err "Nieobsługiwany system. OpenVPN nie został zainstalowany."
    return 1
  fi
  if [[ ! -e "${HM_OVPN_TUN:-/dev/net/tun}" ]]; then
    hm_err "Brak /dev/net/tun. Na OpenVZ lub LXC włącz urządzenie tun, zanim zainstalujesz OpenVPN."
    return 1
  fi
  if hm_ovpn_port_busy "${port}"; then
    hm_err "Port ${port} jest zajęty."
    return 1
  fi
  if hm_ovpn_subnet_used "${cidr}"; then
    hm_err "Podsieć ${cidr} koliduje z istniejącą trasą."
    return 1
  fi
  if [[ ! -f "$(hm_ovpn_state_file)" ]] && hm_ovpn_foreign_conf && [[ "${force}" -ne 1 ]]; then
    hm_err "Obca konfiguracja OpenVPN. Nic nie nadpisuję. Użyj --force."
    return 1
  fi
  if hm_ovpn_same_install "${port}" "${proto}" "${cidr}"; then
    hm_info "bez zmian"
    return 0
  fi
  local -a steps=("pakiety openvpn easy-rsa" "PKI" "hm.conf" "NAT" "systemd openvpn-server@hm")
  [[ -n "${first}" ]] && steps+=("pierwszy klient ${first}")
  if [[ "${dry}" -eq 1 ]]; then
    hm_info "dry-run: brak zmian w systemie"
    printf 'plan: %s\n' "${steps[*]}"
    return 0
  fi
  if [[ "${force}" -eq 1 ]] && declare -F hm_confirm_plan_critical >/dev/null 2>&1; then
    hm_confirm_plan_critical "openvpn install --force" "Nadpisanie obcej konfiguracji." "${steps[@]}" || return 1
  elif [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "openvpn install" "Serwer VPN i NAT." --yes "${steps[@]}" || return 1
  else
    hm_confirm_plan "openvpn install" "Serwer VPN i NAT." "${steps[@]}" || return 1
  fi
  local pkg
  while IFS= read -r pkg; do
    [[ -n "${pkg}" ]] || continue
    hm_pkg_install "${pkg}" || return 1
  done < <(hm_ovpn_packages)
  local etc pki group ver dns_ips iface
  etc="$(hm_ovpn_etc)"
  pki="${etc}/hm/pki"
  group="$(hm_ovpn_group_name)"
  ver="${HM_OVPN_VERSION:-2.6.0}"
  dns_ips="$(hm_ovpn_dns_ips "${dns}")"
  iface="$(hm_ovpn_default_iface)"
  mkdir -p "${pki}/issued" "${pki}/private" "${etc}/ccd"
  export EASYRSA_PKI="${pki}" EASYRSA_BATCH=1
  export EASYRSA_ALGO="ec" EASYRSA_CURVE="secp384r1"
  [[ "${rsa}" -eq 1 ]] && export EASYRSA_ALGO="rsa" EASYRSA_KEY_SIZE="3072"
  if ! hm_ovpn_easyrsa init-pki \
    || ! hm_ovpn_easyrsa build-ca nopass \
    || ! hm_ovpn_easyrsa build-server-full server nopass \
    || ! hm_ovpn_easyrsa gen-crl; then
    hm_ovpn_rollback
    return 1
  fi
  if [[ ! -f "${pki}/crl.pem" ]]; then
    printf 'CRL\n' > "${pki}/crl.pem"
  fi
  cp -f "${pki}/crl.pem" "${etc}/crl.pem"
  chmod 0644 "${etc}/crl.pem" || true
  if ! hm_ovpn_gen_tls_key "$(hm_ovpn_tls_key_path)"; then
    hm_ovpn_rollback
    return 1
  fi
  hm_ovpn_render_conf "${etc}" "${port}" "${proto}" "${cidr}" "${group}" "${ver}" "${dns_ips}" > "$(hm_ovpn_conf_file)"
  if [[ "${ipv6}" -eq 1 ]]; then
    printf 'server-ipv6 fd42:42:42::/64\n' >> "$(hm_ovpn_conf_file)"
  fi
  local sysctl="${HM_OVPN_SYSCTL_D:-/etc/sysctl.d}/99-hmtools-openvpn.conf"
  mkdir -p "$(dirname "${sysctl}")"
  printf 'net.ipv4.ip_forward=1\n' > "${sysctl}"
  [[ "${ipv6}" -eq 1 ]] && printf 'net.ipv6.conf.all.forwarding=1\n' >> "${sysctl}"
  hm_ovpn_nat_apply "${cidr}" "${iface}" "${port}" "${proto}"
  if ! hm_ovpn_systemctl enable --now "openvpn-server@$(hm_ovpn_instance)"; then
    hm_ovpn_rollback
    return 1
  fi
  hm_ovpn_write_state "${port}" "${proto}" "${cidr}" "${endpoint}" "${pki}"
  if [[ -n "${first}" ]]; then
    if ! HM_OVPN_PKI="${pki}" hm_ovpn_client_add "${first}" --yes --no-export; then
      hm_err "Serwer jest zainstalowany, ale pierwszy klient nie powstał."
      return 1
    fi
  fi
  hm_ok "OpenVPN zainstalowany (${endpoint}:${port}/${proto})."
}
