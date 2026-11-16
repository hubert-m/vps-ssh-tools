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
  local cidr="${1:-10.8.0.0/24}" net bits mask
  net="${cidr%%/*}"
  bits="${cidr#*/}"
  [[ "${bits}" =~ ^[0-9]+$ ]] || bits=24
  case "${bits}" in
    8) mask="255.0.0.0" ;;
    16) mask="255.255.0.0" ;;
    24) mask="255.255.255.0" ;;
    28) mask="255.255.255.240" ;;
    30) mask="255.255.255.252" ;;
    *)
      hm_err "Nieobsługiwana maska /${bits} (użyj /8,/16,/24,/28,/30)."
      return 1
      ;;
  esac
  printf '%s %s' "${net}" "${mask}"
}

hm_ovpn_render_conf() {
  local etc="$1" port="$2" proto="$3" cidr="$4" group="$5" ver="${6:-2.6}" dns="${7:-}"
  local pair ciphers
  pair="$(hm_ovpn_subnet_pair "${cidr}")" || return 1
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
crl-verify ${etc}/hm/crl.pem
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
  local full="${1:-}" net="${1%%/*}" bits file="${HM_OVPN_ROUTES:-}" line
  bits="${full#*/}"
  if [[ -n "${file}" ]]; then
    [[ -f "${file}" ]] || return 1
    grep -Eq "(^| )${net}(/| |$)|${full}" "${file}"
    return
  fi
  [[ "${HMTOOLS_TEST:-}" == "1" ]] && return 1
  command -v ip >/dev/null 2>&1 || return 1
  while IFS= read -r line; do
    [[ "${line}" == "${net}"* || "${line}" == *" ${net}/"* || "${line}" == "${full}"* ]] && return 0
    # Nakładanie /24: ten sam prefiks trzech oktetów.
    if [[ "${bits}" == "24" && "${net}" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\. ]]; then
      [[ "${line}" == "${BASH_REMATCH[1]}."* ]] && return 0
    fi
  done < <(ip -o route show 2>/dev/null || true)
  return 1
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

hm_ovpn_detect_endpoint() {
  local ip
  if [[ -n "${HM_OVPN_PUBLIC_IP:-}" ]]; then
    printf '%s' "${HM_OVPN_PUBLIC_IP}"
    return 0
  fi
  if [[ "${HMTOOLS_TEST:-}" == "1" ]]; then
    return 1
  fi
  if command -v ip >/dev/null 2>&1; then
    ip="$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
    if [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      printf '%s' "${ip}"
      return 0
    fi
  fi
  return 1
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
  local etc root f
  etc="$(hm_ovpn_etc)"
  root="$(dirname "${etc}")"
  for f in "${etc}"/*.conf "${root}"/*.conf; do
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

# Już jest instalacja hmtools — nie wolno wołać init-pki (kasuje CA/klientów).
hm_ovpn_already_installed() {
  [[ -f "$(hm_ovpn_state_file)" || -f "$(hm_ovpn_conf_file)" ]] && return 0
  local pki
  pki="$(hm_ovpn_etc)/hm/pki"
  [[ -f "${pki}/ca.crt" || -f "${pki}/index.txt" ]] && return 0
  return 1
}

hm_ovpn_read_forward() {
  local v
  if [[ -n "${HM_OVPN_PREV_FORWARD:-}" ]]; then
    printf '%s' "${HM_OVPN_PREV_FORWARD}"
    return 0
  fi
  # test: żywa wartość z pliku stanu (nie hardkoduj 0 — Docker często ma 1)
  if [[ -n "${HM_OVPN_FORWARD_STATE:-}" && -f "${HM_OVPN_FORWARD_STATE}" ]]; then
    v="$(tr -d '[:space:]' < "${HM_OVPN_FORWARD_STATE}")"
    [[ "${v}" =~ ^[01]$ ]] || v=0
    printf '%s' "${v}"
    return 0
  fi
  if [[ "${HMTOOLS_TEST:-}" == "1" ]]; then
    printf '0'
    return 0
  fi
  v="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || true)"
  [[ "${v}" =~ ^[01]$ ]] || v=0
  printf '%s' "${v}"
}

hm_ovpn_detect_fw() {
  if [[ -n "${HM_OVPN_FW:-}" ]]; then
    printf '%s' "${HM_OVPN_FW}"
    return 0
  fi
  if declare -F hm_os_firewall_backend >/dev/null 2>&1; then
    hm_os_firewall_backend
    return $?
  fi
  printf 'iptables'
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
  local file="$1" tmp mode owner
  [[ -f "${file}" ]] || return 0
  # BEGIN bez END → nic nie ruszaj (unikaj obcięcia before.rules / SSH)
  if grep -q 'BEGIN hmtools-openvpn' "${file}" && ! grep -q 'END hmtools-openvpn' "${file}"; then
    hm_warn "Niesparowany marker hmtools-openvpn w ${file} — pomijam strip."
    return 1
  fi
  mode="$(stat -c '%a' -- "${file}" 2>/dev/null || stat -f '%OLp' "${file}" 2>/dev/null || true)"
  owner="$(stat -c '%u:%g' -- "${file}" 2>/dev/null || true)"
  tmp="$(mktemp "${file}.XXXXXX")"
  awk '
    /BEGIN hmtools-openvpn/ {skip=1; next}
    /END hmtools-openvpn/ {skip=0; next}
    skip==0 {print}
  ' "${file}" > "${tmp}" || { rm -f "${tmp}"; return 1; }
  # zachowaj tryb/właściciela (cat>file zamiast mv)
  cat "${tmp}" > "${file}" || { rm -f "${tmp}"; return 1; }
  rm -f "${tmp}"
  if [[ -n "${mode}" ]]; then
    chmod "${mode}" -- "${file}" 2>/dev/null || chmod "${mode}" "${file}" 2>/dev/null || true
  fi
  if [[ -n "${owner}" && "$(id -u)" -eq 0 ]]; then
    chown "${owner}" -- "${file}" 2>/dev/null || chown "${owner}" "${file}" 2>/dev/null || true
  fi
  return 0
}

hm_ovpn_state_get() {
  local key="$1" file line
  file="$(hm_ovpn_state_file)"
  [[ -f "${file}" ]] || return 1
  line="$(grep -E "^${key}=" "${file}" | head -n 1 || true)"
  [[ -n "${line}" ]] || return 1
  printf '%s' "${line#*=}"
}

hm_ovpn_pkg_remove() {
  local pkg="$1" log="${HM_OVPN_CALL_LOG:-}"
  [[ -n "${log}" ]] && printf 'pkg remove %s\n' "${pkg}" >> "${log}"
  if [[ "${HMTOOLS_TEST:-}" == "1" ]]; then
    return 0
  fi
  if declare -F hm_pkg_remove >/dev/null 2>&1; then
    hm_pkg_remove "${pkg}" || true
  fi
}

hm_ovpn_restore_forward() {
  local prev="$1" live="${HM_OVPN_FORWARD_STATE:-}"
  # tylko jawna wartość 0/1 — nigdy domyślne 0 „w ciemno”
  [[ "${prev}" =~ ^[01]$ ]] || return 0
  [[ -n "${live}" ]] && printf '%s\n' "${prev}" > "${live}"
  [[ -n "${HM_OVPN_CALL_LOG:-}" ]] && printf 'sysctl net.ipv4.ip_forward=%s\n' "${prev}" >> "${HM_OVPN_CALL_LOG}"
  if [[ "${HMTOOLS_TEST:-}" != "1" ]] && command -v sysctl >/dev/null 2>&1; then
    sysctl -w "net.ipv4.ip_forward=${prev}" >/dev/null 2>&1 || true
  fi
}

hm_ovpn_export_dir_safe() {
  local profiles="$1"
  case "${profiles}" in
    /|"${HOME}"|"${HOME}/"|/root|/root/|/home|/home/|/etc|/etc/|/var|/var/) return 1 ;;
  esac
  case "${profiles}" in
    /root/hmtools-openvpn/clients|/root/hmtools-openvpn/clients/*) return 0 ;;
    */hmtools-openvpn/clients|*/hmtools-openvpn/clients/) return 0 ;;
  esac
  # test / jawny HM_OVPN_EXPORT pod katalogiem tymczasowym — tylko gdy kończy się na /clients
  [[ -n "${HM_OVPN_EXPORT:-}" && "${profiles}" == "${HM_OVPN_EXPORT}" && "${profiles}" == */clients ]] && return 0
  return 1
}

hm_ovpn_fw_cleanup() {
  local fw="$1" port="$2" proto="$3" iface="${4:-eth0}" cidr="${5:-}"
  [[ -n "${port}" && -n "${proto}" ]] || return 0
  case "${fw}" in
    ufw)
      hm_ovpn_fw_exec ufw delete allow "${port}/${proto}" || true
      hm_ovpn_fw_exec ufw delete route allow in on tun0 out on "${iface}" || true
      ;;
    firewalld)
      hm_ovpn_fw_exec firewall-cmd --permanent --remove-masquerade || true
      hm_ovpn_fw_exec firewall-cmd --permanent --remove-port="${port}/${proto}" || true
      hm_ovpn_fw_exec firewall-cmd --permanent --zone=trusted --remove-interface=tun0 || true
      hm_ovpn_fw_exec firewall-cmd --reload || true
      ;;
    csf|iptables|*)
      if [[ -n "${cidr}" ]]; then
        hm_ovpn_fw_exec iptables -t nat -D POSTROUTING -s "${cidr}" -o "${iface}" -j MASQUERADE || true
      fi
      ;;
  esac
  if declare -F hm_os_firewall_remove >/dev/null 2>&1 && [[ "${HMTOOLS_TEST:-}" != "1" ]]; then
    hm_os_firewall_remove "${port}/${proto}" || true
  fi
}

hm_ovpn_uninstall() {
  local yes=0 dry=0 force=0 keep_pki=0 keep_profiles=0 no_backup=0 purge=0
  local state etc prev fw copy="" removed="" kept="" has_manifest=0
  local port proto iface cidr profiles pki jail filter cron
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y) yes=1; shift ;;
      --dry-run) dry=1; shift ;;
      --force) force=1; shift ;;
      --keep-pki) keep_pki=1; shift ;;
      --keep-profiles) keep_profiles=1; shift ;;
      --no-backup) no_backup=1; shift ;;
      --purge-packages) purge=1; shift ;;
      *) hm_err "Nieznana flaga: $1"; return 1 ;;
    esac
  done
  state="$(hm_ovpn_state_file)"
  etc="$(hm_ovpn_etc)"
  [[ -f "${state}" ]] && has_manifest=1
  if [[ "${has_manifest}" -eq 0 && "${force}" -ne 1 ]]; then
    hm_err "Brak manifestu hmtools. Nic nie usuwam. Użyj --force, żeby zdjąć tylko bloki hmtools."
    return 1
  fi
  local -a steps=()
  if [[ "${has_manifest}" -eq 1 ]]; then
    if [[ "${no_backup}" -eq 1 ]]; then
      steps+=("pominąć pełną kopię")
    else
      steps+=("pełna kopia OpenVPN")
    fi
    steps+=("stop openvpn-server@$(hm_ovpn_instance)" "zdjąć NAT i firewall hmtools" "przywrócić ip_forward z manifestu" "usunąć sysctl, cron i jail" "usunąć hm.conf / hm/")
    [[ "${keep_pki}" -eq 0 ]] && steps+=("usunąć PKI")
    [[ "${purge}" -eq 1 ]] && steps+=("usunąć pakiety openvpn i easy-rsa")
  else
    steps+=("zdjąć tylko markery hmtools (obca instalacja — bez PKI/ccd/profili)")
  fi
  if [[ "${dry}" -eq 1 ]]; then
    hm_info "dry-run: brak zmian w systemie"
    printf 'plan: %s\n' "${steps[*]}"
    return 0
  fi
  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan_critical "OPENVPN" "openvpn uninstall" "Znika serwer VPN hmtools." --yes "${steps[@]}" || return 1
  else
    hm_confirm_plan_critical "OPENVPN" "openvpn uninstall" "Znika serwer VPN hmtools." "${steps[@]}" || return 1
  fi

  # --force bez manifestu: wyłącznie markery + drop-iny hmtools
  if [[ "${has_manifest}" -eq 0 ]]; then
    hm_ovpn_strip_markers "${HM_OVPN_UFW_RULES:-/etc/ufw/before.rules}" || true
    hm_ovpn_strip_markers "${HM_OVPN_CSF_POST:-/etc/csf/csfpost.sh}" || true
    rm -f "${HM_OVPN_SYSCTL_D:-/etc/sysctl.d}/99-hmtools-openvpn.conf"
    cron="$(hm_ovpn_cron_file)"
    [[ -f "${cron}" && "$(grep -c 'hmtools-openvpn' "${cron}" 2>/dev/null || true)" -gt 0 ]] && rm -f "${cron}"
    jail="${HM_OVPN_F2B_JAIL:-${HM_OVPN_F2B_DIR:-/etc/fail2ban/jail.d}/hmtools-openvpn.conf}"
    [[ -f "${jail}" ]] && rm -f "${jail}"
    if declare -F hm_ovpn_f2b_filter >/dev/null 2>&1; then
      filter="$(hm_ovpn_f2b_filter)"
      [[ -f "${filter}" ]] && rm -f "${filter}"
    fi
    rm -f "$(hm_ovpn_nat_unit_path)" "$(hm_ovpn_nat_unit_path).sh" 2>/dev/null || true
    # tylko hm.conf — bez hm/pki, ccd, obcego crl, profili, ip_forward
    [[ -f "$(hm_ovpn_conf_file)" ]] && rm -f "$(hm_ovpn_conf_file)"
    kept="${kept}obca instalacja (PKI/ccd/profile/ip_forward nietknięte)"$'\n'
    removed="${removed}markery i drop-iny hmtools"$'\n'
    printf 'usunieto:\n%s' "${removed}"
    printf 'zostaje:\n%s' "${kept}"
    return 0
  fi

  if [[ "${no_backup}" -eq 1 ]]; then
    hm_warn "Pomijam pełną kopię OpenVPN."
    kept="${kept}kopia (pominieta)"$'\n'
  else
    if declare -F hm_ovpn_backup_cmd >/dev/null 2>&1; then
      local before archive
      before="$(hm_ovpn_backup_local_dir 2>/dev/null || true)"
      [[ -n "${HM_OVPN_BACKUP_DIR:-}" ]] && export BACKUP_LOCAL_ROOT="${HM_OVPN_BACKUP_DIR}"
      if hm_ovpn_backup_cmd --local >/dev/null; then
        copy="$(hm_ovpn_backup_latest "${BACKUP_LOCAL_ROOT:-${before}}" 2>/dev/null || true)"
        [[ -z "${copy}" && -n "${before}" ]] && copy="$(hm_ovpn_backup_latest "${before}" 2>/dev/null || true)"
      else
        hm_err "Pełna kopia przed uninstall nieudana."
        return 1
      fi
    elif [[ -d "$(hm_ovpn_pki)" ]]; then
      copy="${HM_OVPN_BACKUP_DIR:-$(hm_ovpn_root)/backups}/pki-$(date -u +%Y%m%d%H%M%S)"
      hm_ovpn_backup "${copy}" || return 1
    fi
  fi
  hm_ovpn_systemctl disable --now "openvpn-server@$(hm_ovpn_instance)" >/dev/null 2>&1 || true
  hm_ovpn_systemctl disable --now hmtools-openvpn-nat.service >/dev/null 2>&1 || true
  hm_ovpn_strip_markers "${HM_OVPN_UFW_RULES:-/etc/ufw/before.rules}" || true
  hm_ovpn_strip_markers "${HM_OVPN_CSF_POST:-/etc/csf/csfpost.sh}" || true
  fw="$(hm_ovpn_state_get FW 2>/dev/null || true)"
  [[ -n "${fw}" ]] || fw="${HM_OVPN_FW:-iptables}"
  port="$(hm_ovpn_state_get PORT 2>/dev/null || true)"
  proto="$(hm_ovpn_state_get PROTO 2>/dev/null || true)"
  cidr="$(hm_ovpn_state_get SUBNET 2>/dev/null || true)"
  iface="$(hm_ovpn_state_get IFACE 2>/dev/null || true)"
  [[ -n "${iface}" ]] || iface="$(hm_ovpn_default_iface 2>/dev/null || echo eth0)"
  hm_ovpn_fw_cleanup "${fw}" "${port}" "${proto}" "${iface}" "${cidr}"
  prev="$(hm_ovpn_state_get PREV_FORWARD 2>/dev/null || true)"
  rm -f "${HM_OVPN_SYSCTL_D:-/etc/sysctl.d}/99-hmtools-openvpn.conf"
  if [[ "${prev}" =~ ^[01]$ ]]; then
    hm_ovpn_restore_forward "${prev}"
  else
    kept="${kept}ip_forward (brak PREV_FORWARD — bez zmian)"$'\n'
  fi
  cron="$(hm_ovpn_cron_file)"
  if [[ -f "${cron}" ]] && grep -q 'hmtools-openvpn' "${cron}"; then
    rm -f "${cron}"
    removed="${removed}cron"$'\n'
  fi
  jail="${HM_OVPN_F2B_JAIL:-${HM_OVPN_F2B_DIR:-/etc/fail2ban/jail.d}/hmtools-openvpn.conf}"
  if [[ -f "${jail}" ]]; then
    rm -f "${jail}"
    removed="${removed}jail fail2ban"$'\n'
  fi
  if declare -F hm_ovpn_f2b_filter >/dev/null 2>&1; then
    filter="$(hm_ovpn_f2b_filter)"
    if [[ -f "${filter}" ]]; then
      rm -f "${filter}"
      removed="${removed}filter fail2ban"$'\n'
    fi
  fi
  rm -f "$(hm_ovpn_nat_unit_path)" "$(hm_ovpn_nat_unit_path).sh"
  rm -f "$(hm_ovpn_conf_file)" "$(hm_ovpn_tls_key_path)"
  # crl i ccd tylko z drzewa hmtools
  [[ -f "${etc}/hm/crl.pem" ]] && rm -f "${etc}/hm/crl.pem"
  [[ -d "${etc}/ccd" ]] && rm -rf "${etc}/ccd"
  if [[ "${keep_pki}" -eq 1 ]]; then
    kept="${kept}PKI"$'\n'
  else
    pki="$(hm_ovpn_state_get PKI 2>/dev/null || true)"
    if [[ -z "${pki}" ]]; then
      kept="${kept}PKI (brak ścieżki w manifeście)"$'\n'
    else
      case "${pki}" in
        /|/etc|/etc/openvpn) kept="${kept}PKI (odmowa ścieżki)"$'\n' ;;
        "${etc}/hm/pki"|"${etc}/hm/pki/"|*/hm/pki|*/hm/pki/)
          rm -rf "${pki}"
          removed="${removed}PKI"$'\n'
          ;;
        *) kept="${kept}PKI (spoza hmtools)"$'\n' ;;
      esac
    fi
  fi
  # posprzątaj pusty etc/hm (nie kasuj gdy PKI zostawione)
  if [[ -d "${etc}/hm" ]]; then
    rmdir "${etc}/hm" 2>/dev/null || true
  fi
  if [[ "${keep_profiles}" -eq 1 ]]; then
    kept="${kept}profile"$'\n'
  else
    profiles="$(hm_ovpn_export_dir)"
    if hm_ovpn_export_dir_safe "${profiles}"; then
      rm -rf "${profiles}"
      removed="${removed}profile"$'\n'
    else
      kept="${kept}profile (odmowa ścieżki ${profiles})"$'\n'
      hm_warn "Odmowa kasowania profili poza allowlistą: ${profiles}"
    fi
  fi
  if [[ "${purge}" -eq 1 ]]; then
    if hm_ovpn_foreign_conf; then
      kept="${kept}pakiety (obca konfiguracja)"$'\n'
    elif [[ "$(hm_ovpn_state_get PACKAGES 2>/dev/null || true)" == "yes" ]]; then
      hm_ovpn_pkg_remove openvpn
      hm_ovpn_pkg_remove easy-rsa
      removed="${removed}pakiety"$'\n'
    else
      kept="${kept}pakiety (nie instalował ich hmtools)"$'\n'
    fi
  fi
  rm -f "${state}"
  removed="${removed}hm.conf i manifest"$'\n'
  printf 'usunieto:\n%s' "${removed}"
  [[ -n "${kept}" ]] && printf 'zostaje:\n%s' "${kept}"
  if [[ -n "${copy}" ]]; then
    printf 'kopia: %s\n' "${copy}"
  fi
}

hm_ovpn_rollback() {
  local etc pki sysctl unit_sh
  hm_warn "Wycofuję niedokończoną instalację OpenVPN."
  etc="$(hm_ovpn_etc)"
  pki="${etc}/hm/pki"
  hm_ovpn_systemctl disable --now "openvpn-server@$(hm_ovpn_instance)" >/dev/null 2>&1 || true
  hm_ovpn_systemctl disable --now hmtools-openvpn-nat.service >/dev/null 2>&1 || true
  rm -f "$(hm_ovpn_conf_file)" "$(hm_ovpn_state_file)" "${etc}/hm/crl.pem"
  rm -f "$(hm_ovpn_tls_key_path)"
  case "${pki}" in
    "${etc}/hm/"*|"${etc}/"*) rm -rf "${pki}" "${etc}/hm" 2>/dev/null || true ;;
  esac
  sysctl="${HM_OVPN_SYSCTL_D:-/etc/sysctl.d}/99-hmtools-openvpn.conf"
  rm -f "${sysctl}"
  unit_sh="$(hm_ovpn_nat_unit_path 2>/dev/null || true)"
  [[ -n "${unit_sh}" ]] && rm -f "${unit_sh}" "${unit_sh%.service}.sh" 2>/dev/null || true
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
        chmod 0755 "${rules}" 2>/dev/null || true
      fi
      hm_ovpn_fw_exec iptables -t nat -C POSTROUTING -s "${cidr}" -o "${iface}" -j MASQUERADE \
        || hm_ovpn_fw_exec iptables -t nat -A POSTROUTING -s "${cidr}" -o "${iface}" -j MASQUERADE || true
      hm_ovpn_fw_exec csf -r || hm_warn "Nie przeładowano CSF (csf -r)."
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
      hm_ovpn_systemctl enable --now hmtools-openvpn-nat.service || true
      hm_ovpn_fw_exec iptables -t nat -C POSTROUTING -s "${cidr}" -o "${iface}" -j MASQUERADE \
        || hm_ovpn_fw_exec iptables -t nat -A POSTROUTING -s "${cidr}" -o "${iface}" -j MASQUERADE || true
      [[ -n "${log}" ]] && printf 'iptables MASQUERADE %s via %s\n' "${cidr}" "${iface}" >> "${log}"
      ;;
  esac
}

hm_ovpn_write_state() {
  local port="$1" proto="$2" cidr="$3" endpoint="$4" pki="$5"
  local dns="${6:-quad9}" ipv6_flag="${7:-0}" prev ipv6_val=off
  prev="$(hm_ovpn_read_forward)"
  [[ "${ipv6_flag}" == "1" || "${ipv6_flag}" == "on" ]] && ipv6_val=on
  cat > "$(hm_ovpn_state_file)" <<EOF
PORT=${port}
PROTO=${proto}
SUBNET=${cidr}
ENDPOINT=${endpoint}
PKI=${pki}
PREV_FORWARD=${prev}
DNS=${dns}
IPV6=${ipv6_val}
MODE=split
EOF
}

# Odśwież NAT po zmianie SUBNET (marker hmtools-openvpn / skrypt unitu).
hm_ovpn_nat_refresh() {
  local new_cidr="$1" iface="${2:-}" port="${3:-}" proto="${4:-}"
  local fw rules unit script old_block
  [[ -n "${new_cidr}" ]] || return 1
  fw="${HM_OVPN_FW:-$(hm_ovpn_state_value FW 2>/dev/null || true)}"
  [[ -n "${fw}" ]] || fw="iptables"
  [[ -n "${iface}" ]] || iface="$(hm_ovpn_state_value IFACE 2>/dev/null || true)"
  [[ -n "${iface}" ]] || iface="$(hm_ovpn_default_iface)"
  [[ -n "${port}" ]] || port="$(hm_ovpn_state_value PORT 2>/dev/null || true)"
  [[ -n "${proto}" ]] || proto="$(hm_ovpn_state_value PROTO 2>/dev/null || true)"
  case "${fw}" in
    ufw)
      rules="${HM_OVPN_UFW_RULES:-/etc/ufw/before.rules}"
      if [[ -f "${rules}" ]] && grep -q 'BEGIN hmtools-openvpn' "${rules}"; then
        hm_ovpn_strip_markers "${rules}"
      fi
      HM_OVPN_FW=ufw hm_ovpn_nat_apply "${new_cidr}" "${iface}" "${port}" "${proto}"
      ;;
    csf)
      rules="${HM_OVPN_CSF_POST:-/etc/csf/csfpost.sh}"
      if [[ -f "${rules}" ]] && grep -q 'BEGIN hmtools-openvpn' "${rules}"; then
        hm_ovpn_strip_markers "${rules}"
      fi
      HM_OVPN_FW=csf hm_ovpn_nat_apply "${new_cidr}" "${iface}" "${port}" "${proto}"
      ;;
    firewalld)
      HM_OVPN_FW=firewalld hm_ovpn_nat_apply "${new_cidr}" "${iface}" "${port}" "${proto}"
      ;;
    *)
      unit="$(hm_ovpn_nat_unit_path)"
      script="${unit}.sh"
      mkdir -p "$(dirname "${unit}")"
      cat > "${script}" <<EOF
#!/bin/sh
iptables -t nat -C POSTROUTING -s ${new_cidr} -o ${iface} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s ${new_cidr} -o ${iface} -j MASQUERADE
EOF
      chmod 0755 "${script}" || true
      [[ -n "${HM_OVPN_CALL_LOG:-}" ]] && printf 'iptables MASQUERADE %s via %s\n' "${new_cidr}" "${iface}" >> "${HM_OVPN_CALL_LOG}"
      ;;
  esac
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
  if hm_ovpn_same_install "${port}" "${proto}" "${cidr}"; then
    hm_info "bez zmian"
    return 0
  fi
  if hm_ovpn_already_installed; then
    hm_err "OpenVPN hmtools już zainstalowany. Zmiany: openvpn config set … (nie init-pki — nie kasuję CA/klientów)."
    return 1
  fi
  if hm_ovpn_foreign_conf && [[ "${force}" -ne 1 ]]; then
    hm_err "Obca konfiguracja OpenVPN. Nic nie nadpisuję. Użyj --force."
    return 1
  fi
  local -a steps=("pakiety openvpn easy-rsa" "PKI" "hm.conf" "NAT" "systemd openvpn-server@hm")
  [[ -n "${first}" ]] && steps+=("pierwszy klient ${first}")
  if [[ "${dry}" -eq 1 ]]; then
    hm_info "dry-run: brak zmian w systemie"
    printf 'plan: %s\n' "${steps[*]}"
    return 0
  fi
  if [[ -z "${endpoint}" ]]; then
    endpoint="$(hm_ovpn_detect_endpoint || true)"
  fi
  if [[ -z "${endpoint}" ]]; then
    hm_err "Podaj --endpoint (publiczne IP albo FQDN). Nie używam placeholdera vpn.example."
    return 1
  fi
  if [[ "${force}" -eq 1 ]] && declare -F hm_confirm_plan_critical >/dev/null 2>&1; then
    if [[ "${yes}" -eq 1 ]]; then
      hm_confirm_plan_critical "OPENVPN" "openvpn install --force" "Nadpisanie obcej konfiguracji." --yes "${steps[@]}" || return 1
    else
      hm_confirm_plan_critical "OPENVPN" "openvpn install --force" "Nadpisanie obcej konfiguracji." "${steps[@]}" || return 1
    fi
  elif [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "openvpn install" "Serwer VPN i NAT." --yes "${steps[@]}" || return 1
  else
    hm_confirm_plan "openvpn install" "Serwer VPN i NAT." "${steps[@]}" || return 1
  fi
  local pkg packages_installed=0
  while IFS= read -r pkg; do
    [[ -n "${pkg}" ]] || continue
    hm_pkg_install "${pkg}" || return 1
    packages_installed=1
  done < <(hm_ovpn_packages)
  local etc pki group ver dns_ips iface fw
  etc="$(hm_ovpn_etc)"
  pki="${etc}/hm/pki"
  group="$(hm_ovpn_group_name)"
  ver="${HM_OVPN_VERSION:-}"
  if [[ -z "${ver}" ]] && command -v openvpn >/dev/null 2>&1; then
    ver="$(openvpn --version 2>/dev/null | head -1 | awk '{print $2}' || true)"
  fi
  [[ -n "${ver}" ]] || ver="2.6.0"
  dns_ips="$(hm_ovpn_dns_ips "${dns}")"
  iface="$(hm_ovpn_default_iface)"
  fw="$(hm_ovpn_detect_fw)"
  HM_OVPN_FW="${fw}"
  mkdir -p "${pki}/issued" "${pki}/private" "${etc}/ccd" "${etc}/hm"
  if [[ -f "${pki}/ca.crt" || -f "${pki}/index.txt" ]]; then
    hm_err "PKI już istnieje (${pki}). Odmowa init-pki."
    return 1
  fi
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
  cp -f "${pki}/crl.pem" "${etc}/hm/crl.pem"
  chmod 0644 "${etc}/hm/crl.pem" || true
  if ! hm_ovpn_gen_tls_key "$(hm_ovpn_tls_key_path)"; then
    hm_ovpn_rollback
    return 1
  fi
  hm_ovpn_render_conf "${etc}" "${port}" "${proto}" "${cidr}" "${group}" "${ver}" "${dns_ips}" > "$(hm_ovpn_conf_file)" || {
    hm_ovpn_rollback
    return 1
  }
  if [[ "${ipv6}" -eq 1 ]]; then
    printf 'server-ipv6 fd42:42:42::/64\n' >> "$(hm_ovpn_conf_file)"
  fi
  local sysctl="${HM_OVPN_SYSCTL_D:-/etc/sysctl.d}/99-hmtools-openvpn.conf"
  mkdir -p "$(dirname "${sysctl}")"
  HM_OVPN_PREV_FORWARD="$(hm_ovpn_read_forward)"
  printf 'net.ipv4.ip_forward=1\n' > "${sysctl}"
  [[ "${ipv6}" -eq 1 ]] && printf 'net.ipv6.conf.all.forwarding=1\n' >> "${sysctl}"
  hm_ovpn_nat_apply "${cidr}" "${iface}" "${port}" "${proto}"
  if ! hm_ovpn_systemctl enable --now "openvpn-server@$(hm_ovpn_instance)"; then
    hm_ovpn_rollback
    return 1
  fi
  hm_ovpn_write_state "${port}" "${proto}" "${cidr}" "${endpoint}" "${pki}" "${dns}" "${ipv6}"
  {
    printf 'FW=%s\n' "${fw}"
    printf 'IFACE=%s\n' "${iface}"
    if [[ "${packages_installed}" -eq 1 ]]; then
      printf 'PACKAGES=yes\n'
    else
      printf 'PACKAGES=no\n'
    fi
  } >> "$(hm_ovpn_state_file)"
  if [[ -n "${first}" ]]; then
    if ! HM_OVPN_PKI="${pki}" hm_ovpn_client_add "${first}" --yes --no-export; then
      hm_err "Serwer jest zainstalowany, ale pierwszy klient nie powstał."
      return 1
    fi
  fi
  hm_ok "OpenVPN zainstalowany (${endpoint}:${port}/${proto})."
}
