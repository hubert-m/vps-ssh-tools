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

# Fail2Ban wymaga grupy <HOST>/<ADDR> — inaczej „No failure-id group”.
hm_ovpn_f2b_failregex() {
  printf '%s\n' \
    '^.*(?:[\w.@-]+/)?<ADDR>:\d+ (?:TLS Error: TLS handshake failed|tls-crypt unwrap error|VERIFY ERROR|AUTH_FAILED)'
}

hm_ovpn_fail2ban() {
  local action="${1:-status}" jail filter ip sample n phrase f2b_port f2b_proto
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
      f2b_port="$(hm_ovpn_state_get PORT 2>/dev/null || true)"
      f2b_proto="$(hm_ovpn_state_get PROTO 2>/dev/null || true)"
      [[ "${f2b_port}" =~ ^[0-9]+$ ]] || f2b_port="1194"
      [[ "${f2b_proto}" == "tcp" || "${f2b_proto}" == "udp" ]] || f2b_proto="udp"
      mkdir -p "$(dirname "${jail}")" "$(dirname "${filter}")"
      {
        printf '%s\n' '[Definition]'
        printf 'failregex = %s\n' "$(hm_ovpn_f2b_failregex)"
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
port = ${f2b_port}
protocol = ${f2b_proto}
ignoreip = 127.0.0.1/8 ::1 ${ip}
EOF
      if [[ "${HMTOOLS_TEST:-}" != "1" ]] && declare -F hm_firewall_fail2ban_ignore >/dev/null 2>&1; then
        hm_firewall_fail2ban_ignore "${ip}" || true
      fi
      if [[ "${HMTOOLS_TEST:-}" != "1" ]] && hm_have_cmd fail2ban-regex; then
        fail2ban-regex /dev/null "${filter}" >/dev/null 2>&1 \
          || hm_warn "fail2ban-regex: filtr hmtools-openvpn może być niepoprawny."
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

hm_ovpn_ca_cn_skip() {
  # nie buduj ponownie certu serwera / CA jako „klienta”
  case "${1:-}" in
    server|ca|CA|Easy-RSA\ CA) return 0 ;;
  esac
  return 1
}

hm_ovpn_ca_state_set_pki() {
  local pki="$1" state tmp
  state="$(hm_ovpn_state_file)"
  [[ -f "${state}" ]] || return 0
  tmp="$(mktemp)"
  if grep -q '^PKI=' "${state}"; then
    awk -v p="${pki}" 'BEGIN{done=0} /^PKI=/ { print "PKI=" p; done=1; next } { print } END { if (!done) print "PKI=" p }' "${state}" > "${tmp}"
  else
    cat "${state}" > "${tmp}"
    printf 'PKI=%s\n' "${pki}" >> "${tmp}"
  fi
  mv -f "${tmp}" "${state}"
}

hm_ovpn_ca_abort() {
  local pending conf bak new old
  pending="$(hm_ovpn_ca_pending)"
  [[ -f "${pending}" ]] || { hm_err "Brak rotacji w toku."; return 1; }
  conf="$(hm_ovpn_conf_file)"
  bak="${conf}.hmtools-ca-rotate.bak"
  new="$(grep '^NEW=' "${pending}" | head -n 1 || true)"; new="${new#NEW=}"
  old="$(grep '^OLD=' "${pending}" | head -n 1 || true)"; old="${old#OLD=}"
  if [[ -f "${bak}" ]]; then
    mv -f "${bak}" "${conf}"
  fi
  [[ -n "${new}" ]] && rm -rf "${new}"
  # pki.old zostawiamy jako archiwum; aktywne PKI bez zmian
  rm -f "${pending}"
  hm_ok "Rotacja CA przerwana (--abort). Przywrócono hm.conf."
}

hm_ovpn_ca_rotate() {
  local finish=0 abort=0 days="3650" yes=0 pki old new bundle conf index line cn
  local conf_bak pending
  while [[ $# -gt 0 ]]; do
    case "$1" in
      finish|--finish) finish=1; shift ;;
      abort|--abort) abort=1; shift ;;
      --days) days="${2:-3650}"; shift 2 || true ;;
      --days=*) days="${1#*=}"; shift ;;
      --yes|-y) yes=1; shift ;;
      *) hm_err "Nieznana flaga: $1"; return 1 ;;
    esac
  done
  [[ "${days}" =~ ^[0-9]+$ ]] || { hm_err "Złe --days."; return 1; }
  if [[ "${abort}" -eq 1 ]]; then
    hm_ovpn_ca_abort
    return
  fi
  if [[ "${finish}" -eq 1 ]]; then
    hm_ovpn_ca_finish "${yes}"
    return
  fi
  pending="$(hm_ovpn_ca_pending)"
  if [[ -f "${pending}" ]]; then
    hm_err "Rotacja CA już trwa (${pending}). Użyj: openvpn ca rotate finish | openvpn ca rotate --abort"
    return 1
  fi
  pki="$(hm_ovpn_pki)"
  [[ -d "${pki}" ]] || { hm_err "Brak PKI."; return 1; }
  conf="$(hm_ovpn_conf_file)"
  [[ -f "${conf}" ]] || { hm_err "Brak konfiguracji OpenVPN."; return 1; }
  local -a steps=("kopia PKI" "nowa CA obok starej" "bundle obu CA" "CRL obu CA" "nowe certyfikaty klientów" "ca=bundle (cert serwera bez zmian do finish)")
  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "openvpn ca rotate" "Okres przejściowy: stara i nowa CA." --yes "${steps[@]}" || return 1
  else
    hm_confirm_plan "openvpn ca rotate" "Okres przejściowy: stara i nowa CA." "${steps[@]}" || return 1
  fi
  hm_ovpn_backup "${HM_OVPN_BACKUP_DIR:-$(hm_ovpn_root)/backups}/ca-$(date -u +%Y%m%d%H%M%S)" || return 1
  old="${pki}.old"
  new="${pki}.new"
  # nie kasuj pki.new/old gdy pending — już zablokowane wyżej
  rm -rf "${old}" "${new}"
  mkdir -p "${old}" "${new}"
  cp -a "${pki}/." "${old}/" 2>/dev/null || cp -R "${pki}/." "${old}/"
  (
    umask 077
    export EASYRSA_PKI="${new}" EASYRSA_BATCH=1
    hm_ovpn_easyrsa init-pki \
      && hm_ovpn_easyrsa build-ca nopass \
      && hm_ovpn_easyrsa build-server-full server nopass \
      && hm_ovpn_easyrsa gen-crl
  ) || {
    rm -rf "${new}"
    hm_err "Nie udało się zbudować nowej CA/serwera. hm.conf bez zmian."
    return 1
  }
  # klienci V z indeksu starego PKI — bez CN=server
  index="${old}/index.txt"
  if [[ -f "${index}" ]]; then
    while IFS= read -r line; do
      [[ "${line}" == V* ]] || continue
      cn="${line#*/CN=}"
      cn="${cn%%/*}"
      cn="${cn%%$'\t'*}"
      [[ -n "${cn}" ]] || continue
      hm_ovpn_ca_cn_skip "${cn}" && continue
      if ! EASYRSA_PKI="${new}" EASYRSA_BATCH=1 hm_ovpn_easyrsa build-client-full "${cn}" nopass; then
        rm -rf "${new}"
        hm_err "build-client-full ${cn} nieudany. hm.conf bez zmian."
        return 1
      fi
    done < "${index}"
  fi
  if [[ "${HM_OVPN_MOCK:-}" == "1" ]]; then
    mkdir -p "${new}/issued" "${new}/private"
    [[ -f "${new}/ca.crt" ]] || printf 'NEW-CA\n' > "${new}/ca.crt"
    [[ -f "${new}/issued/server.crt" ]] || printf 'NEW-SERVER\n' > "${new}/issued/server.crt"
    [[ -f "${new}/private/server.key" ]] || printf 'NEW-KEY\n' > "${new}/private/server.key"
    [[ -f "${new}/crl.pem" ]] || printf 'NEW-CRL\n' > "${new}/crl.pem"
  fi
  # CRL starego CA: z pki.old albo z hm/crl.pem
  if [[ ! -f "${old}/crl.pem" && -f "$(hm_ovpn_etc)/hm/crl.pem" ]]; then
    cp -f "$(hm_ovpn_etc)/hm/crl.pem" "${old}/crl.pem"
  fi
  if [[ "${HM_OVPN_MOCK:-}" == "1" && ! -f "${old}/crl.pem" ]]; then
    printf 'OLD-CRL\n' > "${old}/crl.pem"
  fi
  # CRL przejściowe = stare + nowe (crl-verify wymaga CRL dla każdej CA w bundlu)
  if ! hm_ovpn_ca_crl_merge "$(hm_ovpn_etc)/hm/crl.pem" "${old}/crl.pem" "${new}/crl.pem"; then
    rm -rf "${new}"
    hm_err "Nie udało się złożyć CRL. hm.conf bez zmian."
    return 1
  fi
  # dopiero po sukcesie PKI — kopia hm.conf; ca=bundle, cert/key serwera ZOSTAJĄ stare do finish
  conf_bak="${conf}.hmtools-ca-rotate.bak"
  cp -a "${conf}" "${conf_bak}" || return 1
  bundle="$(hm_ovpn_etc)/ca-bundle.crt"
  hm_ovpn_ca_bundle_write "${bundle}" "${new}/ca.crt" "${old}/ca.crt"
  hm_ovpn_ca_set_line "${conf}" ca "${bundle}"
  cat > "${pending}" <<EOF
DAYS=${days}
BUNDLE=${bundle}
NEW=${new}
OLD=${old}
PKI=${pki}
CONF_BAK=${conf_bak}
EOF
  hm_ok "Rotacja CA: okres przejściowy. Bundle: ${bundle} (cert serwera bez zmian do finish)."
}

# Konkatenacja CRL (okres przejściowy: obie CA).
hm_ovpn_ca_crl_merge() {
  local dest="$1" a="${2:-}" b="${3:-}" tmp
  [[ -n "${dest}" ]] || return 1
  mkdir -p "$(dirname "${dest}")"
  tmp="$(mktemp)"
  : > "${tmp}"
  [[ -n "${a}" && -f "${a}" ]] && cat "${a}" >> "${tmp}"
  [[ -n "${b}" && -f "${b}" ]] && cat "${b}" >> "${tmp}"
  if [[ ! -s "${tmp}" ]]; then
    rm -f "${tmp}"
    return 1
  fi
  mv -f "${tmp}" "${dest}"
  chmod 0644 "${dest}" || true
}

hm_ovpn_ca_finish() {
  local yes="$1" pending bundle new old conf pki_active state_pki
  pending="$(hm_ovpn_ca_pending)"
  [[ -f "${pending}" ]] || { hm_err "Brak rotacji w toku."; return 1; }
  local -a steps=("zostawić tylko nową CA" "przepiąć PKI w stanie" "zarchiwizować starą PKI")
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
  pki_active="$(grep '^PKI=' "${pending}" | head -n 1 || true)"
  pki_active="${pki_active#PKI=}"
  [[ -n "${pki_active}" ]] || pki_active="$(hm_ovpn_pki)"
  conf="$(hm_ovpn_conf_file)"
  if [[ -n "${old}" && -d "${old}" ]]; then
    HM_OVPN_PKI="${old}" hm_ovpn_backup "${HM_OVPN_BACKUP_DIR:-$(hm_ovpn_root)/backups}/ca-old-$(date -u +%Y%m%d%H%M%S)" || return 1
  fi
  if [[ -n "${bundle}" && -f "${bundle}" ]]; then
    hm_ovpn_ca_strip_old "${bundle}"
  fi
  # przepnij aktywną PKI na zawartość pki.new
  if [[ -n "${new}" && -d "${new}" ]]; then
    if [[ -n "${pki_active}" && -d "${pki_active}" ]]; then
      rm -rf "${pki_active}.pre-finish" 2>/dev/null || true
      mv "${pki_active}" "${pki_active}.pre-finish" 2>/dev/null || true
      mkdir -p "${pki_active}"
      cp -a "${new}/." "${pki_active}/" 2>/dev/null || cp -R "${new}/." "${pki_active}/"
      rm -rf "${new}" "${pki_active}.pre-finish"
      state_pki="${pki_active}"
    else
      state_pki="${new}"
    fi
    hm_ovpn_ca_state_set_pki "${state_pki}"
    if [[ -f "${conf}" ]]; then
      hm_ovpn_ca_set_line "${conf}" ca "${state_pki}/ca.crt"
      # dopiero finish: cert/key serwera z nowego CA
      [[ -f "${state_pki}/issued/server.crt" ]] && hm_ovpn_ca_set_line "${conf}" cert "${state_pki}/issued/server.crt"
      [[ -f "${state_pki}/private/server.key" ]] && hm_ovpn_ca_set_line "${conf}" key "${state_pki}/private/server.key"
    fi
    # CRL tylko nowego CA
    EASYRSA_PKI="${state_pki}" EASYRSA_BATCH=1 hm_ovpn_easyrsa gen-crl >/dev/null 2>&1 || true
    if [[ "${HM_OVPN_MOCK:-}" == "1" && ! -f "${state_pki}/crl.pem" ]]; then
      printf 'NEW-CRL-FINISH\n' > "${state_pki}/crl.pem"
    fi
    if [[ -f "${state_pki}/crl.pem" ]]; then
      mkdir -p "$(hm_ovpn_etc)/hm"
      cp -f "${state_pki}/crl.pem" "$(hm_ovpn_etc)/hm/crl.pem"
      chmod 0644 "$(hm_ovpn_etc)/hm/crl.pem" || true
    fi
  elif [[ -n "${new}" && -f "${new}/ca.crt" && -f "${conf}" ]]; then
    hm_ovpn_ca_set_line "${conf}" ca "${new}/ca.crt"
    hm_ovpn_ca_state_set_pki "${new}"
  fi
  rm -rf "${old}"
  rm -f "${pending}" "${conf}.hmtools-ca-rotate.bak"
  hm_ok "Rotacja CA zakończona. PKI=${state_pki:-${new}}."
}

hm_ovpn_ca() {
  case "${1:-}" in
    rotate)
      shift || true
      hm_ovpn_ca_rotate "$@"
      ;;
    *)
      hm_err "Użycie: openvpn ca rotate [--days N] [--yes] | openvpn ca rotate finish [--yes] | openvpn ca rotate --abort"
      return 1
      ;;
  esac
}
