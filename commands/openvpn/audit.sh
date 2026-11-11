#!/usr/bin/env bash
# openvpn audit, fail2ban i rotacja CA. Nie mylić z hm_ovpn_audit (wpis do applog).

hm_ovpn_audit_say() {
  local level="$1" msg="$2"
  if [[ "${HM_OVPN_AUDIT_JSON:-}" == "1" ]]; then
    printf '{"level":"%s","msg":"%s"}\n' "${level}" "${msg}"
  else
    printf '%s: %s\n' "${level}" "${msg}"
  fi
}

hm_ovpn_audit_mode() {
  local path="$1" kind="$2" mode=""
  [[ -e "${path}" ]] || return 0
  mode="$(hm_ovpn_mode "${path}" || true)"
  case "${kind}" in
    key)
      if [[ "${mode}" == "600" || "${mode}" == "400" ]]; then
        hm_ovpn_audit_say OK "uprawnienia ${path}: ${mode}"
      else
        hm_ovpn_audit_say "BŁĄD" "uprawnienia ${path}: ${mode:-brak} — chmod 0600"
      fi
      ;;
    dir)
      if [[ "${mode}" == "700" ]]; then
        hm_ovpn_audit_say OK "uprawnienia ${path}: ${mode}"
      else
        hm_ovpn_audit_say "BŁĄD" "uprawnienia ${path}: ${mode:-brak} — chmod 0700"
      fi
      ;;
    crl)
      if [[ "${mode}" == "644" ]]; then
        hm_ovpn_audit_say OK "uprawnienia ${path}: ${mode}"
      else
        hm_ovpn_audit_say "BŁĄD" "uprawnienia ${path}: ${mode:-brak} — chmod 0644"
      fi
      ;;
  esac
}

hm_ovpn_security_audit_read() {
  local conf="$1" line path bits ver
  if grep -qE '^cipher[[:space:]]+BF-CBC([[:space:]]|$)' "${conf}" \
    || { grep -qE '^cipher[[:space:]]+.*CBC' "${conf}" && ! grep -qE '^data-ciphers[[:space:]]' "${conf}"; }; then
    hm_ovpn_audit_say "BŁĄD" "słaby cipher — ustaw data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305"
  else
    hm_ovpn_audit_say OK "szyfry"
  fi
  if grep -qE '^(compress|comp-lzo)([[:space:]]|$)' "${conf}"; then
    hm_ovpn_audit_say "BŁĄD" "compress/comp-lzo — usuń (VORACLE)"
  else
    hm_ovpn_audit_say OK "brak compress"
  fi
  if grep -qE '^tls-version-min[[:space:]]+1\.2([[:space:]]|$)' "${conf}"; then
    hm_ovpn_audit_say OK "tls-version-min 1.2"
  else
    hm_ovpn_audit_say "BŁĄD" "brak tls-version-min 1.2 — dopisz tls-version-min 1.2"
  fi
  if grep -qE '^auth[[:space:]]+(SHA1|MD5)([[:space:]]|$)' "${conf}"; then
    hm_ovpn_audit_say "BŁĄD" "słaby auth — ustaw auth SHA256"
  else
    hm_ovpn_audit_say OK "auth"
  fi
  if grep -qE '^tls-crypt[[:space:]]+' "${conf}" || grep -qE '^tls-auth[[:space:]]+' "${conf}"; then
    hm_ovpn_audit_say OK "tls-crypt lub tls-auth"
  else
    hm_ovpn_audit_say "BŁĄD" "brak tls-crypt i tls-auth — dodaj tls-crypt"
  fi
  if grep -qE '^duplicate-cn([[:space:]]|$)' "${conf}"; then
    hm_ovpn_audit_say "UWAGA" "duplicate-cn — wyłącz, jeśli każdy klient ma własny certyfikat"
  fi
  if grep -qE '^client-to-client([[:space:]]|$)' "${conf}"; then
    hm_ovpn_audit_say "UWAGA" "client-to-client — zostaw tylko gdy klienci mają się widzieć"
  fi
  if grep -qE '^script-security[[:space:]]+[23]([[:space:]]|$)' "${conf}"; then
    hm_ovpn_audit_say "BŁĄD" "script-security 2/3 — obniż albo usuń"
  fi
  if grep -qE '^management[[:space:]]+.*0\.0\.0\.0' "${conf}"; then
    hm_ovpn_audit_say "BŁĄD" "management na 0.0.0.0 — użyj socketa unix"
  elif grep -qE '^management[[:space:]]+[0-9.]+:[0-9]+' "${conf}" && ! grep -qE '^management[[:space:]]+.*password' "${conf}"; then
    hm_ovpn_audit_say "BŁĄD" "management TCP bez hasła — socket unix albo hasło"
  else
    hm_ovpn_audit_say OK "management"
  fi
  if grep -qE '^user[[:space:]]+' "${conf}" && grep -qE '^group[[:space:]]+' "${conf}"; then
    hm_ovpn_audit_say OK "user i group"
  else
    hm_ovpn_audit_say "BŁĄD" "brak user/group — proces nie powinien zostać rootem"
  fi
  if grep -qE '^crl-verify[[:space:]]+' "${conf}"; then
    hm_ovpn_audit_say OK "crl-verify"
  else
    hm_ovpn_audit_say "BŁĄD" "brak crl-verify — wskaż crl.pem"
  fi
  while IFS= read -r line; do
    path="${line#* }"
    [[ -n "${path}" && "${path}" != "${line}" ]] && hm_ovpn_audit_mode "${path}" key
  done < <(grep -E '^(key|tls-crypt|tls-auth)[[:space:]]+' "${conf}" || true)
  if [[ -d "$(hm_ovpn_pki)/private" ]]; then
    hm_ovpn_audit_mode "$(hm_ovpn_pki)/private" dir
    for path in "$(hm_ovpn_pki)/private/"*.key; do
      [[ -f "${path}" ]] || continue
      hm_ovpn_audit_mode "${path}" key
    done
  fi
  path="$(grep -E '^crl-verify[[:space:]]+' "${conf}" | head -n 1 || true)"
  path="${path#* }"
  [[ -n "${path}" && -f "${path}" ]] && hm_ovpn_audit_mode "${path}" crl
  if [[ -d "$(hm_ovpn_export_dir)" ]]; then
    hm_ovpn_audit_mode "$(hm_ovpn_export_dir)" dir
    for path in "$(hm_ovpn_export_dir)/"*.ovpn; do
      [[ -f "${path}" ]] || continue
      hm_ovpn_audit_mode "${path}" key
    done
  fi
  bits="${HM_OVPN_RSA_BITS:-}"
  if [[ -z "${bits}" ]] && command -v openssl >/dev/null 2>&1; then
    path="$(grep -E '^key[[:space:]]+' "${conf}" | head -n 1 || true)"
    path="${path#* }"
    if [[ -n "${path}" && -f "${path}" ]]; then
      bits="$(openssl rsa -in "${path}" -text -noout 2>/dev/null | awk '/Private-Key/{print $2}' | tr -d '(),' || true)"
    fi
  fi
  if [[ "${bits}" =~ ^[0-9]+$ && "${bits}" -lt 2048 ]]; then
    hm_ovpn_audit_say "BŁĄD" "klucz RSA ${bits} bitów — minimum 2048, lepiej EC"
  fi
  ver="${HM_OVPN_VERSION:-}"
  if [[ -z "${ver}" ]] && command -v openvpn >/dev/null 2>&1; then
    ver="$(openvpn --version 2>/dev/null | head -n 1 || true)"
  fi
  case "${ver}" in
    *2.4.*|*OpenVPN\ 2.4*) hm_ovpn_audit_say "UWAGA" "OpenVPN 2.4 jest EOL — podnieś do 2.6" ;;
  esac
  if [[ -n "${HM_OVPN_CERT_DAYS:-}" && "${HM_OVPN_CERT_DAYS}" =~ ^-[0-9]+$ ]]; then
    hm_ovpn_audit_say "UWAGA" "certyfikat lub CRL po terminie — openvpn ca rotate albo crl update"
  fi
}

hm_ovpn_security_audit_fix() {
  local conf="$1" yes="$2" line path tmp
  local -a steps=("kopia ${conf}" "usunąć compress/comp-lzo" "dopisać tls-version-min 1.2" "chmod kluczy")
  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "openvpn audit --fix" "Tylko uprawnienia i compress. Szyfr zostaje." --yes "${steps[@]}" || return 1
  else
    hm_confirm_plan "openvpn audit --fix" "Tylko uprawnienia i compress. Szyfr zostaje." "${steps[@]}" || return 1
  fi
  cp -f "${conf}" "${conf}.bak-hmtools"
  tmp="$(mktemp)"
  awk '
    /^compress([[:space:]]|$)/ { next }
    /^comp-lzo([[:space:]]|$)/ { next }
    { print }
  ' "${conf}" > "${tmp}"
  if ! grep -qE '^tls-version-min[[:space:]]+' "${tmp}"; then
    printf 'tls-version-min 1.2\n' >> "${tmp}"
  fi
  mv -f "${tmp}" "${conf}"
  while IFS= read -r line; do
    path="${line#* }"
    [[ -f "${path}" ]] && chmod 0600 "${path}" 2>/dev/null || true
  done < <(grep -E '^(key|tls-crypt|tls-auth)[[:space:]]+' "${conf}" || true)
  if [[ -d "$(hm_ovpn_pki)/private" ]]; then
    chmod 0700 "$(hm_ovpn_pki)/private" 2>/dev/null || true
    for path in "$(hm_ovpn_pki)/private/"*.key; do
      [[ -f "${path}" ]] && chmod 0600 "${path}" 2>/dev/null || true
    done
  fi
  path="$(grep -E '^crl-verify[[:space:]]+' "${conf}" | head -n 1 || true)"
  path="${path#* }"
  [[ -n "${path}" && -f "${path}" ]] && chmod 0644 "${path}" 2>/dev/null || true
  if [[ -d "$(hm_ovpn_export_dir)" ]]; then
    chmod 0700 "$(hm_ovpn_export_dir)" 2>/dev/null || true
    for path in "$(hm_ovpn_export_dir)/"*.ovpn; do
      [[ -f "${path}" ]] && chmod 0600 "${path}" 2>/dev/null || true
    done
  fi
  if grep -qE '^cipher[[:space:]]+.*CBC' "${conf}"; then
    hm_ovpn_audit_say "UWAGA" "szyfr CBC zostaje — zmiana wymaga nowych profili klientów"
  fi
  hm_ok "Poprawiono uprawnienia i compress. Kopia: ${conf}.bak-hmtools"
}

hm_ovpn_security_audit() {
  local fix=0 json=0 yes=0 conf
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --fix) fix=1; shift ;;
      --json) json=1; shift ;;
      --yes|-y) yes=1; shift ;;
      *) hm_err "Nieznana flaga: $1"; return 1 ;;
    esac
  done
  conf="$(hm_ovpn_conf_file)"
  [[ -f "${conf}" ]] || { hm_err "Brak konfiguracji OpenVPN."; return 1; }
  if [[ "${fix}" -eq 1 ]]; then
    hm_ovpn_security_audit_fix "${conf}" "${yes}" || return 1
  fi
  if [[ "${json}" -eq 1 ]]; then
    HM_OVPN_AUDIT_JSON=1 hm_ovpn_security_audit_read "${conf}"
  else
    hm_ovpn_security_audit_read "${conf}"
  fi
}

hm_ovpn_f2b_jail() {
  printf '%s' "${HM_OVPN_F2B_JAIL:-${HM_OVPN_F2B_DIR:-/etc/fail2ban/jail.d}/hmtools-openvpn.conf}"
}

hm_ovpn_f2b_filter() {
  printf '%s' "${HM_OVPN_F2B_FILTER:-/etc/fail2ban/filter.d/hmtools-openvpn.conf}"
}

hm_ovpn_f2b_phrases() {
  printf '%s\n' \
    'TLS Error: TLS handshake failed' \
    'tls-crypt unwrap error' \
    'VERIFY ERROR' \
    'AUTH_FAILED'
}

hm_ovpn_fail2ban() {
  local action="${1:-status}" jail filter ip sample n phrase
  jail="$(hm_ovpn_f2b_jail)"
  filter="$(hm_ovpn_f2b_filter)"
  case "${action}" in
    on)
      ip="${HM_OVPN_SSH_IP:-}"
      if [[ -z "${ip}" && -n "${SSH_CLIENT:-}" ]]; then
        ip="${SSH_CLIENT%% *}"
      fi
      if [[ -z "${ip}" && -n "${SSH_CONNECTION:-}" ]]; then
        ip="${SSH_CONNECTION%% *}"
      fi
      [[ "${ip}" =~ ^[0-9a-fA-F:.]+$ ]] || ip="127.0.0.1"
      mkdir -p "$(dirname "${jail}")" "$(dirname "${filter}")"
      {
        printf '%s\n' '[Definition]'
        while IFS= read -r phrase; do
          printf 'failregex = %s\n' "${phrase}"
        done < <(hm_ovpn_f2b_phrases)
      } > "${filter}"
      cat > "${jail}" <<EOF
[hmtools-openvpn]
enabled = true
filter = hmtools-openvpn
backend = systemd
journalmatch = _SYSTEMD_UNIT=openvpn-server@$(hm_ovpn_instance).service
maxretry = 5
findtime = 600
bantime = 3600
port = 1194
protocol = udp
ignoreip = 127.0.0.1/8 ::1 ${ip}
EOF
      if [[ "${HMTOOLS_TEST:-}" != "1" ]] && declare -F hm_firewall_fail2ban_ignore >/dev/null 2>&1; then
        hm_firewall_fail2ban_ignore "${ip}" || true
      fi
      hm_ok "Fail2Ban: jail hmtools-openvpn, ignoreip ${ip}"
      ;;
    off)
      if [[ -f "${jail}" ]]; then
        awk '
          /^enabled[[:space:]]*=/ { print "enabled = false"; next }
          { print }
        ' "${jail}" > "${jail}.tmp" && mv "${jail}.tmp" "${jail}"
      fi
      hm_ok "Fail2Ban: off"
      ;;
    status)
      if [[ -f "${jail}" ]] && grep -qE '^enabled[[:space:]]*=[[:space:]]*true' "${jail}"; then
        printf 'fail2ban: on\n'
      else
        printf 'fail2ban: off\n'
      fi
      sample="${HM_OVPN_F2B_SAMPLE:-}"
      if [[ -n "${sample}" && -f "${sample}" ]]; then
        n=0
        while IFS= read -r phrase; do
          if grep -F -q -- "${phrase}" "${sample}"; then
            n=$((n + 1))
          fi
        done < <(hm_ovpn_f2b_phrases)
        printf 'dopasowania: %s\n' "${n}"
      fi
      ;;
    *)
      hm_err "Użycie: openvpn fail2ban on|off|status"
      return 1
      ;;
  esac
}

hm_ovpn_ca_pending() {
  printf '%s' "${HM_OVPN_CA_PENDING:-$(hm_ovpn_etc)/ca-rotate.pending}"
}

hm_ovpn_ca_set_line() {
  local file="$1" key="$2" value="$3" tmp
  tmp="$(mktemp)"
  if grep -qE "^${key}[[:space:]]+" "${file}"; then
    awk -v k="${key}" -v v="${value}" '
      $1 == k { print k " " v; next }
      { print }
    ' "${file}" > "${tmp}"
  else
    cat "${file}" > "${tmp}"
    printf '%s %s\n' "${key}" "${value}" >> "${tmp}"
  fi
  mv -f "${tmp}" "${file}"
}

hm_ovpn_ca_bundle_write() {
  local bundle="$1" newcrt="$2" oldcrt="$3"
  {
    printf '%s\n' '# BEGIN hmtools-openvpn-ca-new'
    if [[ -f "${newcrt}" ]]; then
      cat "${newcrt}"
    else
      printf '%s\n' 'NEW-CA'
    fi
    printf '%s\n' '# END hmtools-openvpn-ca-new'
    printf '%s\n' '# BEGIN hmtools-openvpn-ca-old'
    if [[ -f "${oldcrt}" ]]; then
      cat "${oldcrt}"
    else
      printf '%s\n' 'OLD-CA'
    fi
    printf '%s\n' '# END hmtools-openvpn-ca-old'
  } > "${bundle}"
}

hm_ovpn_ca_strip_old() {
  local bundle="$1" tmp
  tmp="$(mktemp)"
  awk '
    /BEGIN hmtools-openvpn-ca-old/ { skip=1; next }
    /END hmtools-openvpn-ca-old/ { skip=0; next }
    skip==0 { print }
  ' "${bundle}" > "${tmp}" && mv -f "${tmp}" "${bundle}"
}

hm_ovpn_ca_rotate() {
  local finish=0 days="3650" yes=0 pki old new bundle conf index line cn
  while [[ $# -gt 0 ]]; do
    case "$1" in
      finish) finish=1; shift ;;
      --days) days="${2:-3650}"; shift 2 || true ;;
      --days=*) days="${1#*=}"; shift ;;
      --yes|-y) yes=1; shift ;;
      *) hm_err "Nieznana flaga: $1"; return 1 ;;
    esac
  done
  [[ "${days}" =~ ^[0-9]+$ ]] || { hm_err "Złe --days."; return 1; }
  if [[ "${finish}" -eq 1 ]]; then
    hm_ovpn_ca_finish "${yes}"
    return
  fi
  pki="$(hm_ovpn_pki)"
  [[ -d "${pki}" ]] || { hm_err "Brak PKI."; return 1; }
  conf="$(hm_ovpn_conf_file)"
  [[ -f "${conf}" ]] || { hm_err "Brak konfiguracji OpenVPN."; return 1; }
  local -a steps=("kopia PKI" "nowa CA obok starej" "bundle obu CA" "nowe certyfikaty klientów")
  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "openvpn ca rotate" "Okres przejściowy: stara i nowa CA." --yes "${steps[@]}" || return 1
  else
    hm_confirm_plan "openvpn ca rotate" "Okres przejściowy: stara i nowa CA." "${steps[@]}" || return 1
  fi
  hm_ovpn_backup "${HM_OVPN_BACKUP_DIR:-$(hm_ovpn_root)/backups}/ca-$(date -u +%Y%m%d%H%M%S)" || return 1
  old="${pki}.old"
  new="${pki}.new"
  rm -rf "${old}" "${new}"
  mkdir -p "${old}" "${new}"
  cp -a "${pki}/." "${old}/" 2>/dev/null || cp -R "${pki}/." "${old}/"
  (
    umask 077
    export EASYRSA_PKI="${new}" EASYRSA_BATCH=1
    hm_ovpn_easyrsa init-pki
    hm_ovpn_easyrsa build-ca nopass
    hm_ovpn_easyrsa build-server-full server nopass
  ) || return 1
  bundle="$(hm_ovpn_etc)/ca-bundle.crt"
  hm_ovpn_ca_bundle_write "${bundle}" "${new}/ca.crt" "${old}/ca.crt"
  hm_ovpn_ca_set_line "${conf}" ca "${bundle}"
  if [[ -f "${new}/issued/server.crt" ]]; then
    hm_ovpn_ca_set_line "${conf}" cert "${new}/issued/server.crt"
  fi
  if [[ -f "${new}/private/server.key" ]]; then
    hm_ovpn_ca_set_line "${conf}" key "${new}/private/server.key"
  fi
  index="${old}/index.txt"
  if [[ -f "${index}" ]]; then
    while IFS= read -r line; do
      [[ "${line}" == V* ]] || continue
      cn="${line#*/CN=}"
      cn="${cn%%/*}"
      [[ -n "${cn}" ]] || continue
      EASYRSA_PKI="${new}" EASYRSA_BATCH=1 hm_ovpn_easyrsa build-client-full "${cn}" nopass || return 1
    done < "${index}"
  fi
  cat > "$(hm_ovpn_ca_pending)" <<EOF
DAYS=${days}
BUNDLE=${bundle}
NEW=${new}
OLD=${old}
EOF
  hm_ok "Rotacja CA: okres przejściowy. Bundle: ${bundle}"
}

hm_ovpn_ca_finish() {
  local yes="$1" pending bundle new old conf
  pending="$(hm_ovpn_ca_pending)"
  [[ -f "${pending}" ]] || { hm_err "Brak rotacji w toku."; return 1; }
  local -a steps=("zostawić tylko nową CA" "zarchiwizować starą PKI")
  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "openvpn ca rotate finish" "Starzy klienci przestaną się łączyć." --yes "${steps[@]}" || return 1
  else
    hm_confirm_plan "openvpn ca rotate finish" "Starzy klienci przestaną się łączyć." "${steps[@]}" || return 1
  fi
  bundle="$(grep '^BUNDLE=' "${pending}" | head -n 1 || true)"
  bundle="${bundle#BUNDLE=}"
  new="$(grep '^NEW=' "${pending}" | head -n 1 || true)"
  new="${new#NEW=}"
  old="$(grep '^OLD=' "${pending}" | head -n 1 || true)"
  old="${old#OLD=}"
  conf="$(hm_ovpn_conf_file)"
  if [[ -n "${old}" && -d "${old}" ]]; then
    HM_OVPN_PKI="${old}" hm_ovpn_backup "${HM_OVPN_BACKUP_DIR:-$(hm_ovpn_root)/backups}/ca-old-$(date -u +%Y%m%d%H%M%S)" || return 1
  fi
  if [[ -n "${bundle}" && -f "${bundle}" ]]; then
    hm_ovpn_ca_strip_old "${bundle}"
  fi
  if [[ -n "${new}" && -f "${new}/ca.crt" && -f "${conf}" ]]; then
    hm_ovpn_ca_set_line "${conf}" ca "${new}/ca.crt"
  fi
  rm -rf "${old}"
  rm -f "${pending}"
  hm_ok "Rotacja CA zakończona. Zostaje nowa CA."
}

hm_ovpn_ca() {
  case "${1:-}" in
    rotate)
      shift || true
      hm_ovpn_ca_rotate "$@"
      ;;
    *)
      hm_err "Użycie: openvpn ca rotate [--days N] [--yes] | openvpn ca rotate finish [--yes]"
      return 1
      ;;
  esac
}
