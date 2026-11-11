#!/usr/bin/env bash
# openvpn — unieważnianie, odnowienie, CRL i termin ważności.

_hm_cmd_help openvpn <<'EOF'
Użycie:
  openvpn                               status, albo podpowiedź install --dry-run
  openvpn install [--dry-run] [--yes]
  openvpn status
  openvpn doctor
  openvpn who
  openvpn kick <nazwa>
  openvpn log
  openvpn route
  openvpn config [show|set <klucz> <wartość>]
  openvpn backup [katalog]
  openvpn restore <katalog> --yes
  openvpn client add <nazwa> [--days N] [--pass] [--static-ip IP] [--no-export] [--yes]
  openvpn client export <nazwa> [--out ścieżka] [--print] | --all
  openvpn client list [--all|--revoked|--expiring N]
  openvpn client show <nazwa>
  openvpn client ip <nazwa>
  openvpn client revoke <nazwa> [--yes]
  openvpn client renew <nazwa> [--days N] [--yes]
  openvpn crl update [--quiet]
  openvpn crl status
  openvpn check [--notify]
  openvpn schedule install|status|disable
  openvpn server renew [--yes]
  openvpn uninstall [--yes] [--dry-run] [--keep-pki] [--keep-profiles] [--no-backup] [--purge-packages] [--force]
  openvpn audit [--fix] [--json]
  openvpn fail2ban on|off|status
  openvpn ca rotate [--days N] [--yes] | openvpn ca rotate finish [--yes]
  openvpn help
EOF

hm_ovpn_root() { printf '%s' "${HM_OVPN_ROOT:-/etc/openvpn}"; }
hm_ovpn_pki() {
  if [[ -n "${HM_OVPN_PKI:-}" ]]; then
    printf '%s' "${HM_OVPN_PKI}"
    return 0
  fi
  local state line
  state="$(hm_ovpn_state_file 2>/dev/null || true)"
  if [[ -n "${state}" && -f "${state}" ]]; then
    line="$(grep '^PKI=' "${state}" | head -1 || true)"
    if [[ -n "${line}" ]]; then
      printf '%s' "${line#PKI=}"
      return 0
    fi
  fi
  printf '%s' "$(hm_ovpn_root)/pki"
}
hm_ovpn_server_dir() { printf '%s' "${HM_OVPN_SERVER:-$(hm_ovpn_root)/server}"; }
hm_ovpn_export_dir() { printf '%s' "${HM_OVPN_EXPORT:-/root/hmtools-openvpn/clients}"; }
hm_ovpn_cron_file() { printf '%s' "${HM_OVPN_CRON:-/etc/cron.d/hmtools-openvpn}"; }
hm_ovpn_applog() { printf '%s' "${HM_OVPN_APPLOG:-/var/log/hmtools/openvpn.log}"; }
hm_ovpn_dedup_file() { printf '%s' "${HM_OVPN_DEDUP:-$(hm_ovpn_root)/dedup}"; }
hm_ovpn_instance() { printf '%s' "${HM_OVPN_INSTANCE:-hm}"; }
hm_ovpn_mgmt_sock() { printf '%s' "${HM_OVPN_MGMT:-/run/openvpn-server/hm.sock}"; }

hm_ovpn_name_ok() {
  [[ "${1:-}" =~ ^[A-Za-z0-9_.-]+$ ]]
}

hm_ovpn_audit() {
  local msg="$1" log
  log="$(hm_ovpn_applog)"
  mkdir -p "$(dirname "${log}")" 2>/dev/null || true
  printf '%s\n' "${msg}" >> "${log}" 2>/dev/null || true
  if declare -F hm_file_log >/dev/null 2>&1; then
    hm_file_log INFO "openvpn: ${msg}" || true
  fi
}

hm_ovpn_asn1_epoch() {
  local s="${1%Z}" yy mm dd hh mi ss year
  [[ "${s}" =~ ^[0-9]{12}$ ]] || return 1
  yy="${s:0:2}"
  mm="${s:2:2}"
  dd="${s:4:2}"
  hh="${s:6:2}"
  mi="${s:8:2}"
  ss="${s:10:2}"
  if [[ "${yy}" -ge 70 ]]; then
    year="19${yy}"
  else
    year="20${yy}"
  fi
  date -u -d "${year}-${mm}-${dd} ${hh}:${mi}:${ss}" +%s
}

hm_ovpn_parse_date() {
  local raw="${1:-}"
  raw="${raw//$'\r'/}"
  raw="${raw#nextUpdate=}"
  raw="${raw#notAfter=}"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  if [[ "${raw}" =~ ^[0-9]{12}Z$ ]]; then
    hm_ovpn_asn1_epoch "${raw}"
    return
  fi
  date -u -d "${raw}" +%s
}

hm_ovpn_days_left() {
  local epoch="$1" now
  now="$(date -u +%s)"
  printf '%s' $(( (epoch - now) / 86400 ))
}

hm_ovpn_easyrsa_bin() {
  local c
  if [[ -n "${HM_OVPN_EASYRSA:-}" && "${HM_OVPN_EASYRSA}" != "easyrsa" ]]; then
    printf '%s' "${HM_OVPN_EASYRSA}"
    return 0
  fi
  c="$(command -v easyrsa 2>/dev/null || true)"
  if [[ -n "${c}" ]]; then
    printf '%s' "${c}"
    return 0
  fi
  if [[ -x /usr/share/easy-rsa/easyrsa ]]; then
    printf '%s' /usr/share/easy-rsa/easyrsa
    return 0
  fi
  if [[ -x /usr/share/easy-rsa/3/easyrsa ]]; then
    printf '%s' /usr/share/easy-rsa/3/easyrsa
    return 0
  fi
  printf '%s' easyrsa
}

hm_ovpn_easyrsa() {
  local bin pki
  bin="$(hm_ovpn_easyrsa_bin)"
  export EASYRSA_BATCH=1
  if [[ -z "${EASYRSA_PKI:-}" ]]; then
    pki="$(hm_ovpn_pki 2>/dev/null || true)"
    [[ -n "${pki}" ]] && export EASYRSA_PKI="${pki}"
  fi
  [[ -n "${HM_OVPN_CALL_LOG:-}" ]] && printf 'easyrsa %s\n' "$*" >> "${HM_OVPN_CALL_LOG}"
  if [[ "${HM_OVPN_MOCK:-}" == "1" ]]; then
    printf 'easyrsa %s\n' "$*" >> "${HM_OVPN_MOCK_LOG:?}"
    return 0
  fi
  "${bin}" "$@"
}

hm_ovpn_easyrsa_version() {
  local bin="${HM_OVPN_EASYRSA:-easyrsa}" out
  if [[ -n "${HM_OVPN_EASYRSA_VERSION:-}" ]]; then
    printf '%s' "${HM_OVPN_EASYRSA_VERSION}"
    return 0
  fi
  out="$("${bin}" --version 2>&1 || true)"
  printf '%s\n' "${out}" | grep -oE '3\.[0-9]+(\.[0-9]+)?' | head -1
}

hm_ovpn_copy_crl() {
  local src dest
  src="$(hm_ovpn_pki)/crl.pem"
  dest="$(hm_ovpn_server_dir)/crl.pem"
  [[ -f "${src}" ]] || { hm_err "Brak ${src}"; return 1; }
  mkdir -p "$(hm_ovpn_server_dir)"
  cp -f "${src}" "${dest}"
  chmod 0644 "${dest}" || true
}

hm_ovpn_mgmt_kill() {
  local cn="$1" sock
  sock="$(hm_ovpn_mgmt_sock)"
  [[ -n "${HM_OVPN_MGMT_LOG:-}" ]] && printf 'kill %s\n' "${cn}" >> "${HM_OVPN_MGMT_LOG}"
  if [[ -S "${sock}" ]] && hm_have_cmd nc; then
    printf 'kill %s\n' "${cn}" | nc -U "${sock}" || hm_warn "sesja nie została rozłączona"
    return 0
  fi
  hm_warn "sesja nie została rozłączona"
}

hm_ovpn_client_revoke() {
  local name="" yes=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y) yes=1; shift ;;
      *) name="$1"; shift ;;
    esac
  done
  hm_ovpn_name_ok "${name}" || { hm_err "Zła nazwa klienta."; return 1; }
  local -a steps=("easyrsa revoke ${name}" "easyrsa gen-crl" "kopia crl.pem 0644" "rozłączenie ${name}" "usunięcie ccd i profilu")
  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "openvpn revoke ${name}" "Stary profil przestanie działać." --yes "${steps[@]}" || return 1
  else
    hm_confirm_plan "openvpn revoke ${name}" "Stary profil przestanie działać." "${steps[@]}" || return 1
  fi
  hm_ovpn_easyrsa revoke "${name}" || return 1
  hm_ovpn_easyrsa gen-crl || return 1
  if [[ "${HM_OVPN_MOCK:-}" == "1" ]]; then
    mkdir -p "$(hm_ovpn_pki)" "$(hm_ovpn_server_dir)"
    printf 'CRL\n' > "$(hm_ovpn_pki)/crl.pem"
  fi
  hm_ovpn_copy_crl || return 1
  hm_ovpn_mgmt_kill "${name}"
  rm -f "$(hm_ovpn_server_dir)/ccd/${name}" "$(hm_ovpn_export_dir)/${name}.ovpn"
  hm_ovpn_audit "revoke ${name}"
  hm_ok "Unieważniono ${name}. Pozostali klienci zostają bez restartu."
}

hm_ovpn_client_renew() {
  local name="" days="365" yes=0 ver
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --days) days="${2:-365}"; shift 2 || true ;;
      --days=*) days="${1#*=}"; shift ;;
      --yes|-y) yes=1; shift ;;
      *) name="$1"; shift ;;
    esac
  done
  hm_ovpn_name_ok "${name}" || { hm_err "Zła nazwa klienta."; return 1; }
  [[ "${days}" =~ ^[0-9]+$ ]] || { hm_err "Zła liczba dni."; return 1; }
  ver="$(hm_ovpn_easyrsa_version)"
  local -a steps=("odnowienie ${name} na ${days} dni" "ponowny eksport profilu")
  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "openvpn renew ${name}" "Stary profil przestanie działać." --yes "${steps[@]}" || return 1
  else
    hm_confirm_plan "openvpn renew ${name}" "Stary profil przestanie działać." "${steps[@]}" || return 1
  fi
  case "${ver}" in
    3.0*)
      hm_ovpn_easyrsa revoke "${name}" || return 1
      hm_ovpn_easyrsa build-client-full "${name}" nopass || return 1
      ;;
    *)
      hm_ovpn_easyrsa renew "${name}" || return 1
      ;;
  esac
  if [[ "${HM_OVPN_MOCK:-}" == "1" ]]; then
    hm_ovpn_mock_pems "${name}"
  fi
  hm_ovpn_export_one "${name}" "$(hm_ovpn_export_dir)/${name}.ovpn" >/dev/null
  hm_ovpn_audit "renew ${name} days=${days}"
  hm_warn "Stary profil ${name}.ovpn przestanie działać. Rozdaj nowy plik."
}

hm_ovpn_crl_update() {
  local quiet=0
  [[ "${1:-}" == "--quiet" ]] && quiet=1
  hm_ovpn_easyrsa gen-crl || return 1
  if [[ "${HM_OVPN_MOCK:-}" == "1" && ! -f "$(hm_ovpn_pki)/crl.pem" ]]; then
    mkdir -p "$(hm_ovpn_pki)"
    printf 'CRL\n' > "$(hm_ovpn_pki)/crl.pem"
  fi
  hm_ovpn_copy_crl || return 1
  [[ "${quiet}" -eq 1 ]] || hm_ok "CRL skopiowane, bez restartu OpenVPN."
}

hm_ovpn_crl_next_raw() {
  local pem="$(hm_ovpn_server_dir)/crl.pem" out
  [[ -f "${pem}" ]] || pem="$(hm_ovpn_pki)/crl.pem"
  if [[ -f "${pem}.next" ]]; then
    cat "${pem}.next"
    return 0
  fi
  out="$(openssl crl -in "${pem}" -noout -nextupdate 2>/dev/null || true)"
  printf '%s' "${out}"
}

hm_ovpn_crl_status() {
  local raw epoch days
  raw="$(hm_ovpn_crl_next_raw)"
  epoch="$(hm_ovpn_parse_date "${raw}")" || { hm_err "Nie czytam daty CRL."; return 1; }
  days="$(hm_ovpn_days_left "${epoch}")"
  printf 'nextUpdate=%s\ndays=%s\n' "${raw}" "${days}"
}

hm_ovpn_index_expiring() {
  local within="$1" file line status rest exp cn epoch days
  file="$(hm_ovpn_pki)/index.txt"
  [[ -f "${file}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    status="${line%%$'\t'*}"
    [[ "${status}" == "V" ]] || continue
    rest="${line#*$'\t'}"
    exp="${rest%%$'\t'*}"
    cn="${line##*$'\t'}"
    cn="${cn##*CN=}"
    [[ -n "${cn}" && -n "${exp}" ]] || continue
    epoch="$(hm_ovpn_parse_date "${exp}")" || continue
    days="$(hm_ovpn_days_left "${epoch}")"
    if [[ "${days}" -lt "${within}" ]]; then
      printf '%s\t%s\n' "${cn}" "${days}"
    fi
  done < "${file}"
}

hm_ovpn_notify_once() {
  local key="$1" title="$2" body="$3" file now last=0 window=604800
  file="$(hm_ovpn_dedup_file)"
  mkdir -p "$(dirname "${file}")" 2>/dev/null || true
  now="$(date -u +%s)"
  if [[ -f "${file}" ]]; then
    last="$(awk -v k="${key}" '$1==k {print $2}' "${file}" | tail -1)"
    last="${last:-0}"
    if [[ $((now - last)) -lt "${window}" ]]; then
      return 0
    fi
    grep -v "^${key} " "${file}" > "${file}.tmp" || true
    mv -f "${file}.tmp" "${file}"
  fi
  hm_notify warning "${title}" "${body}" "openvpn.${key}"
  printf '%s %s\n' "${key}" "${now}" >> "${file}"
}

hm_ovpn_check() {
  local notify=0 rc=0 raw epoch days limit line
  [[ "${1:-}" == "--notify" ]] && notify=1
  raw="$(hm_ovpn_crl_next_raw || true)"
  if [[ -n "${raw}" ]]; then
    epoch="$(hm_ovpn_parse_date "${raw}" || true)"
    if [[ -n "${epoch}" ]]; then
      days="$(hm_ovpn_days_left "${epoch}")"
      if [[ "${days}" -lt 30 ]]; then
        rc=1
        hm_warn "CRL wygasa za ${days} dni."
        [[ "${notify}" -eq 1 ]] && hm_ovpn_notify_once "crl" "CRL OpenVPN" "wygasa za ${days} dni"
      fi
    fi
  fi
  local kind path warn_at
  for kind in ca server; do
    path="$(hm_ovpn_pki)/${kind}.notafter"
    [[ "${kind}" == "server" ]] && path="$(hm_ovpn_pki)/issued/server.notafter"
    [[ -f "${path}" ]] || continue
    epoch="$(hm_ovpn_parse_date "$(cat "${path}")" || true)"
    [[ -n "${epoch}" ]] || continue
    days="$(hm_ovpn_days_left "${epoch}")"
    warn_at=60
    if [[ "${days}" -lt "${warn_at}" ]]; then
      rc=1
      hm_warn "${kind} wygasa za ${days} dni."
      [[ "${notify}" -eq 1 ]] && hm_ovpn_notify_once "${kind}" "Certyfikat ${kind}" "wygasa za ${days} dni"
    fi
  done
  limit="${OVPN_CLIENT_WARN_DAYS:-14}"
  while IFS=$'\t' read -r line days || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    rc=1
    hm_warn "Klient ${line} wygasa za ${days} dni."
    [[ "${notify}" -eq 1 ]] && hm_ovpn_notify_once "client.${line}" "Klient ${line}" "wygasa za ${days} dni"
  done < <(hm_ovpn_index_expiring "${limit}")
  return "${rc}"
}

hm_ovpn_schedule() {
  local action="${1:-status}" file body
  file="$(hm_ovpn_cron_file)"
  body=$'# hmtools-openvpn\n15 4 * * 1 root hmtools openvpn crl update --quiet\n20 4 * * 1 root hmtools openvpn check --notify\n'
  case "${action}" in
    install)
      mkdir -p "$(dirname "${file}")"
      printf '%s' "${body}" > "${file}"
      hm_ok "Cron: ${file}"
      ;;
    status)
      if [[ -f "${file}" ]]; then
        hm_ok "Cron zainstalowany: ${file}"
      else
        hm_warn "Brak crona OpenVPN."
        return 1
      fi
      ;;
    disable)
      if [[ -f "${file}" ]] && grep -q 'hmtools-openvpn' "${file}"; then
        rm -f "${file}"
        hm_ok "Usunięto ${file}"
      else
        hm_warn "To nie jest plik hmtools-openvpn."
        return 1
      fi
      ;;
    *)
      hm_err "Użycie: openvpn schedule install|status|disable"
      return 1
      ;;
  esac
}

hm_ovpn_server_renew() {
  local yes=0 ver
  [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && yes=1
  ver="$(hm_ovpn_easyrsa_version)"
  local -a steps=("odnowienie certyfikatu serwera" "restart OpenVPN")
  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "openvpn server renew" "Klienci zostają na tym samym CA." --yes "${steps[@]}" || return 1
  else
    hm_confirm_plan "openvpn server renew" "Klienci zostają na tym samym CA." "${steps[@]}" || return 1
  fi
  case "${ver}" in
    3.0*) hm_ovpn_easyrsa build-server-full server nopass || return 1 ;;
    *) hm_ovpn_easyrsa renew server || return 1 ;;
  esac
  local unit
  unit="openvpn-server@$(hm_ovpn_instance)"
  if [[ -n "${HM_OVPN_RESTART_LOG:-}" ]]; then
    printf 'systemctl restart %s\n' "${unit}" >> "${HM_OVPN_RESTART_LOG}"
  else
    systemctl restart "${unit}" || hm_warn "Nie zrestartowano OpenVPN."
  fi
  hm_ovpn_audit "server renew"
  hm_ok "Certyfikat serwera odnowiony. Profile klientów bez zmian."
}

hm_ovpn_name_client() {
  local name="${1:-}"
  [[ "${name}" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || return 1
  [[ "${name}" == "server" || "${name}" == "ca" ]] && return 1
  return 0
}

hm_ovpn_client_exists() {
  local name="$1" index
  [[ -f "$(hm_ovpn_pki)/issued/${name}.crt" ]] && return 0
  index="$(hm_ovpn_pki)/index.txt"
  [[ -f "${index}" ]] && grep -q "/CN=${name}\$" "${index}" && return 0
  return 1
}

hm_ovpn_read_passfile() {
  local p1="" p2="" dir file
  printf 'Hasło klucza: ' >&2
  IFS= read -r -s p1 || return 1
  printf '\nHasło ponownie: ' >&2
  IFS= read -r -s p2 || return 1
  printf '\n' >&2
  [[ -n "${p1}" && "${p1}" == "${p2}" ]] || { hm_err "Hasła nie są zgodne."; return 1; }
  dir="${HM_OVPN_TMP:-/var/lib/hmtools/tmp}"
  mkdir -p "${dir}"
  file="$(mktemp "${dir}/ovpn-pass.XXXXXX")"
  chmod 0600 "${file}" || true
  printf '%s\n' "${p1}" > "${file}"
  printf '%s' "${file}"
}

hm_ovpn_mock_pems() {
  local name="$1" pki
  pki="$(hm_ovpn_pki)"
  mkdir -p "${pki}/issued" "${pki}/private"
  if [[ ! -f "${pki}/ca.crt" ]]; then
    printf '%s\n' '-----BEGIN CERTIFICATE-----' 'CA' '-----END CERTIFICATE-----' > "${pki}/ca.crt"
  fi
  if [[ ! -f "${pki}/issued/${name}.crt" ]]; then
    printf '%s\n' '-----BEGIN CERTIFICATE-----' "CN=${name}" '-----END CERTIFICATE-----' > "${pki}/issued/${name}.crt"
  fi
  if [[ ! -f "${pki}/private/${name}.key" ]]; then
    printf '%s\n' '-----BEGIN PRIVATE KEY-----' 'key' '-----END PRIVATE KEY-----' > "${pki}/private/${name}.key"
  fi
  local tls
  tls="$(hm_ovpn_tls_key_path)"
  if [[ ! -f "${tls}" ]]; then
    mkdir -p "$(dirname "${tls}")"
    printf '%s\n' '-----BEGIN OpenVPN Static key V1-----' 'ta' '-----END OpenVPN Static key V1-----' > "${tls}"
  fi
}

hm_ovpn_tls_key_path() {
  if [[ -n "${HM_OVPN_TLS_KEY:-}" ]]; then
    printf '%s' "${HM_OVPN_TLS_KEY}"
    return 0
  fi
  printf '%s/tls-crypt.key' "$(hm_ovpn_etc)"
}

hm_ovpn_state_value() {
  local key="$1" file line
  file="$(hm_ovpn_state_file 2>/dev/null || true)"
  [[ -n "${file}" && -f "${file}" ]] || return 1
  line="$(grep -E "^${key}=" "${file}" 2>/dev/null | head -n 1 || true)"
  [[ -n "${line}" ]] || return 1
  printf '%s' "${line#*=}"
}

hm_ovpn_client_endpoint() {
  local remote port proto
  remote="${HM_OVPN_REMOTE:-}"
  port="${HM_OVPN_PORT:-}"
  proto="${HM_OVPN_PROTO:-}"
  [[ -n "${remote}" ]] || remote="$(hm_ovpn_state_value ENDPOINT || true)"
  [[ -n "${port}" ]] || port="$(hm_ovpn_state_value PORT || true)"
  [[ -n "${proto}" ]] || proto="$(hm_ovpn_state_value PROTO || true)"
  [[ -n "${port}" ]] || port="1194"
  [[ -n "${proto}" ]] || proto="udp"
  if [[ -z "${remote}" || "${remote}" == "vpn.example" ]]; then
    hm_err "Brak endpointu serwera (pusty albo vpn.example). Podaj go przy openvpn install."
    return 1
  fi
  printf '%s %s %s\n' "${remote}" "${port}" "${proto}"
}

hm_ovpn_pem_body() {
  local file="$1" line on=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" == "-----BEGIN "* ]] && on=1
    [[ "${on}" -eq 1 ]] && printf '%s\n' "${line}"
    [[ "${line}" == "-----END "* ]] && on=0
  done < "${file}"
}

hm_ovpn_profile_body() {
  local name="$1" remote port proto cn ca cert key ta tls ep
  ep="$(hm_ovpn_client_endpoint)" || return 1
  # shellcheck disable=SC2086
  read -r remote port proto <<< "${ep}"
  cn="${HM_OVPN_SERVER_CN:-server}"
  tls="$(hm_ovpn_tls_key_path)"
  if [[ ! -s "${tls}" ]]; then
    hm_err "Brak klucza tls-crypt: ${tls}"
    return 1
  fi
  ca="$(hm_ovpn_pem_body "$(hm_ovpn_pki)/ca.crt")"
  cert="$(hm_ovpn_pem_body "$(hm_ovpn_pki)/issued/${name}.crt")"
  key="$(hm_ovpn_pem_body "$(hm_ovpn_pki)/private/${name}.key")"
  ta="$(hm_ovpn_pem_body "${tls}")"
  if [[ -z "${ta}" ]]; then
    hm_err "Pusty klucz tls-crypt."
    return 1
  fi
  cat <<EOF
client
dev tun
proto ${proto}
remote ${remote} ${port}
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
verify-x509-name ${cn} name
data-ciphers AES-256-GCM:AES-128-GCM
tls-version-min 1.2
auth SHA256
ignore-unknown-option block-outside-dns
block-outside-dns
verb 3
<ca>
${ca}
</ca>
<cert>
${cert}
</cert>
<key>
${key}
</key>
<tls-crypt>
${ta}
</tls-crypt>
EOF
}

hm_ovpn_write_secret_file() {
  local dest="$1" body="$2" saved dir
  saved="$(umask)"
  dir="$(dirname "${dest}")"
  (
    umask 077
    mkdir -p "${dir}"
    chmod 0700 "${dir}" || true
    printf '%s\n' "${body}" > "${dest}"
    chmod 0600 "${dest}" || true
  )
  umask "${saved}"
}

hm_ovpn_export_one() {
  local name="$1" dest="${2:-}" print=0
  hm_ovpn_name_client "${name}" || { hm_err "Zła nazwa klienta."; return 1; }
  [[ -f "$(hm_ovpn_pki)/issued/${name}.crt" ]] || { hm_err "Brak certyfikatu ${name}."; return 1; }
  [[ -n "${dest}" ]] || dest="$(hm_ovpn_export_dir)/${name}.ovpn"
  local body
  body="$(hm_ovpn_profile_body "${name}")" || return 1
  [[ -n "${body}" ]] || return 1
  hm_ovpn_write_secret_file "${dest}" "${body}"
  hm_ovpn_audit "export ${name}"
  if [[ "${HM_OVPN_EXPORT_PRINT:-}" == "1" ]]; then
    hm_print_secret "${body}"
  else
    local size sum host
    size="$(wc -c < "${dest}" | tr -d '[:space:]')"
    if hm_have_cmd sha256sum; then
      sum="$(sha256sum "${dest}" | awk '{print $1}')"
    else
      sum="$(openssl dgst -sha256 "${dest}" | awk '{print $NF}')"
    fi
    host="$(hostname 2>/dev/null || echo vps)"
    printf 'plik: %s\nrozmiar: %s\nsha256: %s\nscp root@%s:%s .\n' "${dest}" "${size}" "${sum}" "${host}" "${dest}"
  fi
}

hm_ovpn_client_add() {
  local name="" days="${OVPN_CLIENT_DAYS:-825}" yes=0 pass=0 static="" no_export=0 passfile=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --days) days="${2:-825}"; shift 2 || true ;;
      --days=*) days="${1#*=}"; shift ;;
      --pass) pass=1; shift ;;
      --static-ip) static="${2:-}"; shift 2 || true ;;
      --static-ip=*) static="${1#*=}"; shift ;;
      --no-export) no_export=1; shift ;;
      --yes|-y) yes=1; shift ;;
      *) name="$1"; shift ;;
    esac
  done
  hm_ovpn_name_client "${name}" || { hm_err "Zła nazwa klienta."; return 1; }
  [[ "${days}" =~ ^[0-9]+$ ]] || { hm_err "Zła liczba dni."; return 1; }
  if hm_ovpn_client_exists "${name}"; then
    hm_err "Klient już istnieje: ${name}"
    return 1
  fi
  local -a steps=("certyfikat ${name} na ${days} dni" "profil ovpn")
  [[ -n "${static}" ]] && steps+=("ccd ${static}")
  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "openvpn client add ${name}" "Profil zawiera klucz." --yes "${steps[@]}" || return 1
  else
    hm_confirm_plan "openvpn client add ${name}" "Profil zawiera klucz." "${steps[@]}" || return 1
  fi
  if [[ "${pass}" -eq 1 ]]; then
    passfile="$(hm_ovpn_read_passfile)" || return 1
    export EASYRSA_PASSIN="file:${passfile}"
    export EASYRSA_PASSOUT="file:${passfile}"
  fi
  export EASYRSA_CERT_EXPIRE="${days}"
  if [[ "${pass}" -eq 1 ]]; then
    hm_ovpn_easyrsa build-client-full "${name}" || { rm -f "${passfile}"; unset EASYRSA_PASSIN EASYRSA_PASSOUT; return 1; }
  else
    hm_ovpn_easyrsa build-client-full "${name}" nopass || return 1
  fi
  if [[ -n "${passfile}" ]]; then
    rm -f "${passfile}"
    unset EASYRSA_PASSIN EASYRSA_PASSOUT
  fi
  if [[ ! -f "$(hm_ovpn_pki)/issued/${name}.crt" ]]; then
    mkdir -p "$(hm_ovpn_pki)/issued" "$(hm_ovpn_pki)/private"
    printf '%s\n' '-----BEGIN CERTIFICATE-----' 'Q0VSVAo=' '-----END CERTIFICATE-----' > "$(hm_ovpn_pki)/issued/${name}.crt"
    printf '%s\n' '-----BEGIN PRIVATE KEY-----' 'S0VZ' '-----END PRIVATE KEY-----' > "$(hm_ovpn_pki)/private/${name}.key"
  fi
  local exp index
  exp="$(date -u -d "+${days} days" '+%y%m%d%H%M%SZ')"
  index="$(hm_ovpn_pki)/index.txt"
  mkdir -p "$(hm_ovpn_pki)"
  if [[ ! -f "${index}" ]] || ! grep -q "/CN=${name}\$" "${index}"; then
    printf 'V\t%s\t\t01\t/CN=%s\n' "${exp}" "${name}" >> "${index}"
  fi
  if [[ -n "${static}" ]]; then
    mkdir -p "$(hm_ovpn_server_dir)/ccd"
    printf 'ifconfig-push %s 255.255.255.0\n' "${static}" > "$(hm_ovpn_server_dir)/ccd/${name}"
  fi
  hm_ovpn_audit "client add ${name}"
  if [[ "${no_export}" -eq 0 ]]; then
    hm_ovpn_export_one "${name}" || return 1
  fi
}

hm_ovpn_client_export() {
  local name="" out="" print=0 all=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out) out="${2:-}"; shift 2 || true ;;
      --out=*) out="${1#*=}"; shift ;;
      --print) print=1; shift ;;
      --all) all=1; shift ;;
      *) name="$1"; shift ;;
    esac
  done
  if [[ "${all}" -eq 1 ]]; then
    local line cn
    [[ -f "$(hm_ovpn_pki)/index.txt" ]] || return 0
    while IFS= read -r line; do
      [[ "${line}" == V$'\t'* ]] || continue
      cn="${line##*$'\t'}"
      cn="${cn##*CN=}"
      HM_OVPN_EXPORT_PRINT=0 hm_ovpn_export_one "${cn}" || return 1
    done < "$(hm_ovpn_pki)/index.txt"
    return 0
  fi
  if [[ "${print}" -eq 1 ]]; then
    HM_OVPN_EXPORT_PRINT=1 hm_ovpn_export_one "${name}" "${out}"
  else
    hm_ovpn_export_one "${name}" "${out}"
  fi
}

hm_ovpn_client_row() {
  local line="$1" within="${2:-}" status exp cn epoch days when ip="-" conn="nie" seen="-" label
  status="${line%%$'\t'*}"
  local rest="${line#*$'\t'}"
  exp="${rest%%$'\t'*}"
  cn="${line##*$'\t'}"
  cn="${cn##*CN=}"
  [[ -n "${cn}" ]] || return 0
  case "${status}" in
    V) label="ważny" ;;
    R) label="unieważniony" ;;
    E) label="wygasły" ;;
    *) return 0 ;;
  esac
  epoch="$(hm_ovpn_parse_date "${exp}" || true)"
  if [[ -n "${epoch}" ]]; then
    days="$(hm_ovpn_days_left "${epoch}")"
    when="$(date -u -d "@${epoch}" '+%Y-%m-%d' 2>/dev/null || printf '%s' "${exp}")"
    when="${when} (${days}d)"
    if [[ "${status}" == "V" && "${days}" -lt 0 ]]; then
      label="wygasły"
    fi
    if [[ -n "${within}" && "${days}" -ge "${within}" ]]; then
      return 0
    fi
  else
    when="${exp}"
  fi
  if [[ -f "$(hm_ovpn_server_dir)/ccd/${cn}" ]]; then
    ip="$(awk '{print $2; exit}' "$(hm_ovpn_server_dir)/ccd/${cn}")"
  fi
  if [[ -n "${HM_OVPN_STATUS:-}" && -f "${HM_OVPN_STATUS}" ]] && grep -q "CLIENT_LIST,${cn}," "${HM_OVPN_STATUS}"; then
    conn="tak"
    seen="$(awk -F, -v n="${cn}" '$1=="CLIENT_LIST" && $2==n {print $NF; exit}' "${HM_OVPN_STATUS}")"
    [[ -n "${seen}" ]] || seen="-"
  fi
  case "${HM_OVPN_LIST_MODE:-valid}" in
    revoked) [[ "${label}" == "unieważniony" ]] || return 0 ;;
    all) ;;
    *) [[ "${label}" == "unieważniony" ]] && return 0 ;;
  esac
  hm_table_row "${cn}" "${label}" "${when}" "${ip}" "${conn}" "${seen}"
}

hm_ovpn_client_list() {
  local mode="valid" days=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all) mode="all"; shift ;;
      --revoked) mode="revoked"; shift ;;
      --expiring) days="${2:-14}"; shift 2 || true ;;
      --expiring=*) days="${1#*=}"; shift ;;
      *) shift ;;
    esac
  done
  HM_OVPN_LIST_MODE="${mode}"
  if declare -F hm_table_begin >/dev/null 2>&1; then
    hm_table_begin LLLLLL
    hm_table_row "Nazwa" "Status" "Wygasa" "IP" "Połączony" "Ostatnio"
  fi
  local line file
  file="$(hm_ovpn_pki)/index.txt"
  [[ -f "${file}" ]] || { hm_table_print 2>/dev/null || true; return 0; }
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    hm_ovpn_client_row "${line}" "${days}"
  done < "${file}"
  if declare -F hm_table_print >/dev/null 2>&1; then
    hm_table_print
  fi
}

hm_ovpn_client_show() {
  local name="${1:-}" cert
  hm_ovpn_name_client "${name}" || { hm_err "Zła nazwa klienta."; return 1; }
  cert="$(hm_ovpn_pki)/issued/${name}.crt"
  [[ -f "${cert}" ]] || { hm_err "Brak certyfikatu ${name}."; return 1; }
  openssl x509 -in "${cert}" -noout -serial -fingerprint -sha256 -dates -subject 2>/dev/null || true
  printf 'profil: %s\n' "$(hm_ovpn_export_dir)/${name}.ovpn"
  if [[ -f "$(hm_ovpn_server_dir)/ccd/${name}" ]]; then
    printf 'ip: %s\n' "$(awk '{print $2; exit}' "$(hm_ovpn_server_dir)/ccd/${name}")"
  fi
  if [[ -n "${HM_OVPN_STATUS:-}" && -f "${HM_OVPN_STATUS}" ]] && grep -q "CLIENT_LIST,${name}," "${HM_OVPN_STATUS}"; then
    printf 'sesja: połączony\n'
  else
    printf 'sesja: brak\n'
  fi
}

hm_ovpn_client() {
  local sub="${1:-}"
  shift || true
  case "${sub}" in
    add) hm_ovpn_client_add "$@" ;;
    export) hm_ovpn_client_export "$@" ;;
    list) hm_ovpn_client_list "$@" ;;
    show) hm_ovpn_client_show "$@" ;;
    ip) hm_ovpn_client_ip "$@" ;;
    revoke) hm_ovpn_client_revoke "$@" ;;
    renew) hm_ovpn_client_renew "$@" ;;
    *)
      hm_err "Użycie: openvpn client add|export|list|show|ip|revoke|renew"
      return 1
      ;;
  esac
}

hm_ovpn_installed() {
  [[ -f "$(hm_ovpn_conf_file)" || -f "$(hm_ovpn_state_file)" ]]
}

hm_ovpn_mode() {
  local path="$1" mode=""
  [[ -e "${path}" ]] || return 1
  mode="$(stat -c '%a' -- "${path}" 2>/dev/null || stat -f '%OLp' "${path}" 2>/dev/null || true)"
  printf '%s' "${mode}"
}

hm_ovpn_redact_line() {
  local line="$1"
  case "${line}" in
    *BEGIN*PRIVATE*|*BEGIN\ CERTIFICATE*|*SECRET*|*PASSWORD*|*password*) return 1 ;;
  esac
  printf '%s\n' "${line}"
}

hm_ovpn_status() {
  local n="0" ep port proto
  if ! hm_ovpn_installed; then
    hm_info "OpenVPN nie jest zainstalowany. Podgląd: openvpn install --dry-run"
    return 0
  fi
  ep="$(hm_ovpn_state_value ENDPOINT 2>/dev/null || true)"
  port="$(hm_ovpn_state_value PORT 2>/dev/null || true)"
  proto="$(hm_ovpn_state_value PROTO 2>/dev/null || true)"
  if [[ -f "$(hm_ovpn_pki)/index.txt" ]]; then
    n="$(grep -c '^V' "$(hm_ovpn_pki)/index.txt" 2>/dev/null || true)"
    [[ "${n}" =~ ^[0-9]+$ ]] || n="0"
  fi
  printf 'instancja: %s\n' "$(hm_ovpn_instance)"
  printf 'endpoint: %s\n' "${ep:-brak}"
  printf 'port: %s/%s\n' "${port:-1194}" "${proto:-udp}"
  printf 'klienci: %s\n' "${n}"
  if [[ -f "$(hm_ovpn_etc)/crl.pem" ]]; then
    printf 'crl: jest\n'
  else
    printf 'crl: brak\n'
  fi
}

hm_ovpn_doctor() {
  local rc=0 mode unit key ca bin
  if command -v openvpn >/dev/null 2>&1; then
    printf 'pakiet openvpn: jest\n'
  else
    printf 'pakiet openvpn: brak\n'
    rc=1
  fi
  if command -v easyrsa >/dev/null 2>&1; then
    printf 'pakiet easy-rsa: jest\n'
  else
    printf 'pakiet easy-rsa: brak\n'
    rc=1
  fi
  unit="${HM_OVPN_UNIT:-/lib/systemd/system/openvpn-server@$(hm_ovpn_instance).service}"
  if [[ -f "${unit}" ]]; then
    printf 'unit: jest\n'
  else
    printf 'unit: brak\n'
    rc=1
  fi
  key="$(hm_ovpn_tls_key_path)"
  ca="$(hm_ovpn_pki)/private/ca.key"
  for bin in "${key}" "${ca}"; do
    if [[ ! -e "${bin}" ]]; then
      printf 'uprawnienia %s: brak\n' "${bin}"
      continue
    fi
    mode="$(hm_ovpn_mode "${bin}" || true)"
    printf 'uprawnienia %s: %s\n' "${bin}" "${mode:-nieznany}"
    if [[ "${mode}" != "600" && "${mode}" != "400" ]]; then
      hm_warn "Klucz ${bin} nie jest 0600."
      rc=1
    fi
  done
  return "${rc}"
}

hm_ovpn_who() {
  local file line name
  file="${HM_OVPN_STATUS:-$(hm_ovpn_etc)/status-hm.log}"
  [[ -f "${file}" ]] || { hm_info "Brak pliku statusu."; return 0; }
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" == CLIENT_LIST,* ]] || continue
    name="${line#CLIENT_LIST,}"
    name="${name%%,*}"
    [[ -n "${name}" ]] && printf '%s\n' "${name}"
  done < "${file}"
}

hm_ovpn_kick() {
  local name="${1:-}"
  hm_ovpn_name_ok "${name}" || { hm_err "Zła nazwa klienta."; return 1; }
  hm_ovpn_mgmt_kill "${name}"
  hm_ovpn_audit "kick ${name}"
}

hm_ovpn_log() {
  local file line
  file="$(hm_ovpn_applog)"
  [[ -f "${file}" ]] || { hm_info "Brak applog."; return 0; }
  while IFS= read -r line || [[ -n "${line}" ]]; do
    hm_ovpn_redact_line "${line}" || true
  done < "${file}"
}

hm_ovpn_route() {
  local conf line
  conf="$(hm_ovpn_conf_file)"
  [[ -f "${conf}" ]] || { hm_info "Brak hm.conf."; return 0; }
  while IFS= read -r line || [[ -n "${line}" ]]; do
    case "${line}" in
      server\ *|route\ *|push\ \"route\ *) printf '%s\n' "${line}" ;;
    esac
  done < "${conf}"
}

hm_ovpn_config_key_ok() {
  case "${1:-}" in
    ENDPOINT|PORT|PROTO|DNS|SUBNET) return 0 ;;
    *) return 1 ;;
  esac
}

hm_ovpn_config() {
  local sub="${1:-show}" key val file tmp line
  case "${sub}" in
    show|"")
      file="$(hm_ovpn_state_file)"
      [[ -f "${file}" ]] || { hm_info "Brak pliku stanu."; return 0; }
      while IFS= read -r line || [[ -n "${line}" ]]; do
        key="${line%%=*}"
        hm_ovpn_config_key_ok "${key}" || continue
        printf '%s\n' "${line}"
      done < "${file}"
      ;;
    set)
      key="${2:-}"
      val="${3:-}"
      hm_ovpn_config_key_ok "${key}" || { hm_err "Niedozwolony klucz konfiguracji."; return 1; }
      [[ "${val}" =~ ^[A-Za-z0-9.:/_-]+$ ]] || { hm_err "Niedozwolona wartość."; return 1; }
      file="$(hm_ovpn_state_file)"
      [[ -f "${file}" ]] || { hm_err "Brak pliku stanu."; return 1; }
      tmp="$(mktemp "${file}.XXXXXX")"
      grep -v -E "^${key}=" "${file}" > "${tmp}" || true
      printf '%s=%s\n' "${key}" "${val}" >> "${tmp}"
      mv -f "${tmp}" "${file}"
      hm_ok "config ${key}"
      ;;
    *)
      hm_err "Użycie: openvpn config show|set <klucz> <wartość>"
      return 1
      ;;
  esac
}

hm_ovpn_client_ip() {
  local name="${1:-}" ccd
  hm_ovpn_name_ok "${name}" || { hm_err "Zła nazwa klienta."; return 1; }
  ccd="$(hm_ovpn_server_dir)/ccd/${name}"
  [[ -f "${ccd}" ]] || { hm_err "Brak stałego IP dla ${name}."; return 1; }
  awk '{print $2; exit}' "${ccd}"
}

hm_ovpn_backup() {
  local dest="${1:-}" src stamp
  src="$(hm_ovpn_pki)"
  [[ -d "${src}" ]] || { hm_err "Brak PKI."; return 1; }
  stamp="$(date -u +%Y%m%d%H%M%S)"
  [[ -n "${dest}" ]] || dest="${HM_OVPN_BACKUP_DIR:-$(hm_ovpn_root)/backups}/pki-${stamp}"
  case "${dest}" in
    *..*) hm_err "Zła ścieżka kopii."; return 1 ;;
  esac
  mkdir -p "${dest}"
  chmod 0700 "${dest}" 2>/dev/null || true
  cp -a "${src}/." "${dest}/" 2>/dev/null || cp -R "${src}/." "${dest}/"
  hm_ok "Kopia PKI: ${dest}"
}

hm_ovpn_restore() {
  local dest="" yes=0 src
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y) yes=1; shift ;;
      *) dest="$1"; shift ;;
    esac
  done
  [[ "${yes}" -eq 1 ]] || { hm_err "restore wymaga --yes."; return 1; }
  [[ -n "${dest}" && -d "${dest}" ]] || { hm_err "Brak katalogu kopii."; return 1; }
  case "${dest}" in
    *..*) hm_err "Zła ścieżka kopii."; return 1 ;;
  esac
  src="$(hm_ovpn_pki)"
  mkdir -p "${src}"
  cp -a "${dest}/." "${src}/" 2>/dev/null || cp -R "${dest}/." "${src}/"
  hm_ok "Przywrócono PKI z ${dest}"
}

cmd_openvpn() {
  local sub="${1:-}"
  shift || true
  case "${sub}" in
    "")
      hm_ovpn_status
      ;;
    install) hm_ovpn_install "$@" ;;
    status) hm_ovpn_status ;;
    doctor) hm_ovpn_doctor ;;
    who) hm_ovpn_who ;;
    kick) hm_ovpn_kick "$@" ;;
    log) hm_ovpn_log ;;
    route) hm_ovpn_route ;;
    config) hm_ovpn_config "$@" ;;
    backup) hm_ovpn_backup "$@" ;;
    restore) hm_ovpn_restore "$@" ;;
    uninstall) hm_ovpn_uninstall "$@" ;;
    audit) hm_ovpn_security_audit "$@" ;;
    fail2ban) hm_ovpn_fail2ban "$@" ;;
    ca) hm_ovpn_ca "$@" ;;
    client) hm_ovpn_client "$@" ;;
    crl)
      case "${1:-}" in
        update) shift || true; hm_ovpn_crl_update "$@" ;;
        status) hm_ovpn_crl_status ;;
        *) hm_err "Użycie: openvpn crl update|status"; return 1 ;;
      esac
      ;;
    check) hm_ovpn_check "$@" ;;
    schedule) hm_ovpn_schedule "$@" ;;
    server)
      case "${1:-}" in
        renew) shift || true; hm_ovpn_server_renew "$@" ;;
        *) hm_err "Użycie: openvpn server renew"; return 1 ;;
      esac
      ;;
    help|-h|--help|"") hm_help_topic openvpn ;;
    *)
      hm_err "Użycie: openvpn client|crl|check|schedule|server"
      return 1
      ;;
  esac
}

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/install.sh"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/audit.sh"

_hm_cmd_register openvpn cmd_openvpn 0 ovpn vpn
