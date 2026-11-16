#!/usr/bin/env bash
# system — czas (NTP), strefa, hostname/FQDN/rDNS, locale UTF-8

_hm_cmd_help system <<'EOF'
Użycie:
  system | system status        Czas, NTP, strefa, hostname, FQDN, rDNS, locale
  system time sync on           Włączenie synchronizacji czasu (chrony / timesyncd)
  system timezone set <TZ>      np. Europe/Warsaw
  system hostname set <fqdn>      hostnamectl (+ CyberPanel hostNameSSL)
  system locale fix               C.UTF-8, pl_PL.UTF-8, en_US.UTF-8

Status ostrzega przy |offset|>1s bez NTP oraz gdy rDNS ≠ hostname (kontekst poczty).
Zmiany: plan + potwierdzenie (hm_confirm_plan); idempotentne gdy już OK.
Testy: HM_SYSTEM_* (mock timedatectl, hostname, dig, locale-gen).
EOF

hm_system_timedatectl() {
  if [[ -n "${HM_SYSTEM_TIMEDATECTL:-}" ]]; then
    bash "${HM_SYSTEM_TIMEDATECTL}" "$@"
    return $?
  fi
  if [[ "${HMTOOLS_TEST:-}" == "1" ]]; then
    hm_warn "system: brak HM_SYSTEM_TIMEDATECTL w teście"
    return 1
  fi
  command timedatectl "$@"
}

hm_system_hostname_cmd() {
  if [[ -n "${HM_SYSTEM_HOSTNAME:-}" ]]; then
    bash "${HM_SYSTEM_HOSTNAME}" "$@"
    return $?
  fi
  command hostname "$@"
}

hm_system_dig() {
  if [[ -n "${HM_SYSTEM_DIG:-}" ]]; then
    bash "${HM_SYSTEM_DIG}" "$@"
    return $?
  fi
  if hm_have_cmd dig; then
    dig "$@"
    return $?
  fi
  return 1
}

hm_system_hostnamectl() {
  local a
  if [[ -n "${HM_SYSTEM_HOSTNAMECTL_LOG:-}" ]]; then
    printf '%s\n' "$*" >> "${HM_SYSTEM_HOSTNAMECTL_LOG}"
    return 0
  fi
  if [[ "${HMTOOLS_TEST:-}" == "1" ]]; then
    hm_warn "system: brak HM_SYSTEM_HOSTNAMECTL_LOG w teście"
    return 1
  fi
  hostnamectl "$@"
}

hm_system_locale_list() {
  if [[ -n "${HM_SYSTEM_LOCALE_A:-}" && -f "${HM_SYSTEM_LOCALE_A}" ]]; then
    cat "${HM_SYSTEM_LOCALE_A}"
    return 0
  fi
  locale -a 2>/dev/null
}

hm_system_locale_env() {
  if [[ -n "${HM_SYSTEM_LOCALE_ENV:-}" && -f "${HM_SYSTEM_LOCALE_ENV}" ]]; then
    # shellcheck disable=SC1090
    source "${HM_SYSTEM_LOCALE_ENV}"
    return 0
  fi
  command locale 2>/dev/null || true
}

hm_system_etc_hostname() {
  printf '%s' "${HM_SYSTEM_ETC_HOSTNAME:-/etc/hostname}"
}

hm_system_locale_gen_file() {
  printf '%s' "${HM_SYSTEM_LOCALE_GEN:-/etc/locale.gen}"
}

hm_system_main_ipv4() {
  if [[ -n "${HM_SYSTEM_MAIN_IP:-}" ]]; then
    printf '%s' "${HM_SYSTEM_MAIN_IP}"
    return 0
  fi
  local ip
  while IFS= read -r ip; do
    [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    printf '%s' "${ip}"
    return 0
  done < <(hm_system_hostname_cmd -I 2>/dev/null | tr ' ' '\n')
  return 1
}

hm_system_valid_fqdn() {
  local h="${1:-}"
  [[ -n "${h}" && "${h}" == *.* ]] || return 1
  [[ "${h}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]
}

hm_system_normalize_dns() {
  local s="${1:-}"
  s="${s%.}"
  printf '%s' "${s,,}"
}

hm_system_ntp_synchronized() {
  if [[ -n "${HM_SYSTEM_NTP_SYNC:-}" ]]; then
    [[ "${HM_SYSTEM_NTP_SYNC}" == "yes" || "${HM_SYSTEM_NTP_SYNC}" == "1" ]]
    return $?
  fi
  local v
  v="$(hm_system_timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
  [[ "${v}" == "yes" ]]
}

hm_system_timezone_current() {
  if [[ -n "${HM_SYSTEM_TIMEZONE:-}" ]]; then
    printf '%s' "${HM_SYSTEM_TIMEZONE}"
    return 0
  fi
  hm_system_timedatectl show -p Timezone --value 2>/dev/null \
    || hm_system_timedatectl 2>/dev/null | awk -F': ' '/Time zone:/{print $2; exit}' | awk '{print $1}'
}

hm_system_sync_daemon() {
  if [[ -n "${HM_SYSTEM_SYNC_DAEMON:-}" ]]; then
    printf '%s' "${HM_SYSTEM_SYNC_DAEMON}"
    return 0
  fi
  if [[ -n "${HM_SYSTEM_CHRONY_ACTIVE:-}" ]]; then
    [[ "${HM_SYSTEM_CHRONY_ACTIVE}" == "1" ]] && printf 'chrony' || printf 'none'
    return 0
  fi
  if systemctl is-active --quiet chronyd 2>/dev/null || systemctl is-active --quiet chrony 2>/dev/null; then
    printf 'chrony'
    return 0
  fi
  if systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
    printf 'systemd-timesyncd'
    return 0
  fi
  if hm_system_ntp_synchronized; then
    printf 'ntp'
    return 0
  fi
  printf 'none'
}

hm_system_offset_seconds() {
  local daemon off="" line
  daemon="$(hm_system_sync_daemon)"
  if [[ "${daemon}" == "chrony" ]]; then
    if [[ -n "${HM_SYSTEM_CHRONY_OFFSET:-}" ]]; then
      printf '%s' "${HM_SYSTEM_CHRONY_OFFSET}"
      return 0
    fi
    if [[ -f "${HM_SYSTEM_CHRONY_TRACKING:-}" ]]; then
      off="$(awk '/^Last offset/{print $4; exit}' "${HM_SYSTEM_CHRONY_TRACKING}")"
    elif hm_have_cmd chronyc; then
      off="$(chronyc -n tracking 2>/dev/null | awk '/Last offset/{print $4; exit}')"
    fi
    [[ -n "${off}" ]] && printf '%s' "${off}"
    return 0
  fi
  if [[ -f "${HM_SYSTEM_TIMESYNC_STATUS:-}" ]]; then
    off="$(awk -F': ' '/^Offset:/{gsub(/ s$/,"",$2); print $2; exit}' "${HM_SYSTEM_TIMESYNC_STATUS}")"
  else
    off="$(hm_system_timedatectl timesync-status 2>/dev/null | awk -F': ' '/^Offset:/{gsub(/ s$/,"",$2); print $2; exit}')"
  fi
  [[ -n "${off}" ]] && printf '%s' "${off}"
}

hm_system_offset_abs_gt() {
  local limit="${1:-1}" off abs
  off="$(hm_system_offset_seconds 2>/dev/null || true)"
  [[ -n "${off}" ]] || return 1
  if [[ "${off}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
    abs="${off#-}"
    awk -v a="${abs}" -v l="${limit}" 'BEGIN{exit (a+0>l+0)?0:1}'
    return $?
  fi
  return 1
}

hm_system_short_hostname() {
  local f
  f="$(hm_system_etc_hostname)"
  if [[ -f "${f}" ]]; then
    tr -d '[:space:]' < "${f}"
    return 0
  fi
  hm_system_hostname_cmd -s 2>/dev/null || true
}

hm_system_fqdn() {
  local short fq
  short="$(hm_system_short_hostname)"
  fq="$(hm_system_hostname_cmd -f 2>/dev/null || true)"
  [[ -n "${fq}" ]] && printf '%s' "${fq}" || printf '%s' "${short}"
}

hm_system_ptr_for_ip() {
  local ip="$1" ptr
  [[ -n "${ip}" ]] || return 1
  ptr="$(hm_system_dig +short -x "${ip}" 2>/dev/null | head -1 || true)"
  printf '%s' "${ptr}"
}

hm_system_rdns_matches_hostname() {
  local ip ptr h fq nptr nh nf
  ip="$(hm_system_main_ipv4)" || return 2
  ptr="$(hm_system_ptr_for_ip "${ip}")"
  [[ -n "${ptr}" ]] || return 2
  h="$(hm_system_short_hostname)"
  fq="$(hm_system_fqdn)"
  nptr="$(hm_system_normalize_dns "${ptr}")"
  nh="$(hm_system_normalize_dns "${h}")"
  nf="$(hm_system_normalize_dns "${fq}")"
  [[ "${nptr}" == "${nh}" || "${nptr}" == "${nf}" ]] && return 0
  return 1
}

hm_system_locales_required() {
  printf '%s\n' 'C.UTF-8' 'pl_PL.UTF-8' 'en_US.UTF-8'
}

hm_system_locale_missing() {
  local -a have=() loc
  while IFS= read -r loc; do
    [[ -n "${loc}" ]] || continue
    have+=("${loc,,}")
  done < <(hm_system_locale_list 2>/dev/null | tr -d '\r')
  while IFS= read -r loc; do
    [[ -n "${loc}" ]] || continue
    local found=0 x
    for x in "${have[@]:-}"; do
      [[ "${x}" == "${loc,,}" ]] && found=1 && break
    done
    [[ "${found}" -eq 0 ]] && printf '%s\n' "${loc}"
  done < <(hm_system_locales_required)
}

hm_system_status() {
  local rc=0 daemon synced tz offset ip ptr fq short lang
  echo "${C_BOLD}system${C_RESET}"
  daemon="$(hm_system_sync_daemon)"
  synced=0
  hm_system_ntp_synchronized && synced=1
  tz="$(hm_system_timezone_current)"
  offset="$(hm_system_offset_seconds 2>/dev/null || true)"
  short="$(hm_system_short_hostname)"
  fq="$(hm_system_fqdn)"
  ip="$(hm_system_main_ipv4)"

  printf '  NTP sync   : %s\n' "$( [[ "${synced}" -eq 1 ]] && printf 'tak' || printf 'nie' )"
  printf '  daemon     : %s\n' "${daemon}"
  [[ -n "${offset}" ]] && printf '  offset     : %s s\n' "${offset}" || printf '  offset     : (nieznany)\n'
  printf '  timezone   : %s\n' "${tz:-?}"
  printf '  hostname   : %s\n' "${short:-?}"
  printf '  FQDN       : %s\n' "${fq:-?}"
  if [[ -n "${ip}" ]]; then
    ptr="$(hm_system_ptr_for_ip "${ip}")"
    printf '  główne IP  : %s\n' "${ip}"
    printf '  rDNS       : %s\n' "${ptr:-(brak)}"
  else
    printf '  główne IP  : (nie ustalono)\n'
    hm_warn "system: nie ustalono głównego IPv4."
    rc=1
  fi

  if [[ -n "${HM_SYSTEM_LOCALE_ENV:-}" && -f "${HM_SYSTEM_LOCALE_ENV}" ]]; then
    # shellcheck disable=SC1090
    source "${HM_SYSTEM_LOCALE_ENV}"
  fi
  lang="${LANG:-}"
  printf '  LANG       : %s\n' "${lang:-(puste)}"
  [[ -n "${LC_ALL:-}" ]] && printf '  LC_ALL     : %s\n' "${LC_ALL}"
  [[ -n "${LC_CTYPE:-}" ]] && printf '  LC_CTYPE   : %s\n' "${LC_CTYPE}"
  [[ -n "${LC_MESSAGES:-}" ]] && printf '  LC_MESSAGES: %s\n' "${LC_MESSAGES}"

  printf '  locale UTF-8:\n'
  while IFS= read -r loc; do
    local found=0 x
    while IFS= read -r x; do
      [[ "${x,,}" == "${loc,,}" ]] && found=1 && break
    done < <(hm_system_locale_list 2>/dev/null)
    if [[ "${found}" -eq 1 ]]; then
      printf '    %s OK\n' "${loc}"
    else
      printf '    %s brak\n' "${loc}"
    fi
  done < <(hm_system_locales_required)

  if [[ "${synced}" -ne 1 ]] && hm_system_offset_abs_gt 1; then
    hm_warn "system: |offset|>1 s przy wyłączonym NTP — ustaw: system time sync on"
    rc=1
  elif [[ "${synced}" -eq 1 && -n "${offset}" ]] && hm_system_offset_abs_gt 1; then
    hm_warn "system: |offset|>1 s mimo NTP — sprawdź chrony/timesyncd."
    rc=1
  fi

  case "${lang}" in
    C|POSIX|'') hm_warn "system: LANG=${lang:-puste} — rozważ: system locale fix" ;;
  esac

  if [[ -n "${ip}" && -n "${ptr:-}" ]]; then
    if ! hm_system_rdns_matches_hostname; then
      hm_warn "system: rDNS (${ptr}) ≠ hostname (${short}/${fq}) — problemy z dostarczalnością poczty (SPF/DKIM/rDNS)."
      rc=1
    fi
  elif [[ -n "${ip}" && -z "${ptr:-}" ]]; then
    hm_warn "system: brak PTR dla ${ip} — reverse DNS wymagany dla serwera poczty."
    rc=1
  fi

  local miss
  miss="$(hm_system_locale_missing | tr '\n' ' ')"
  if [[ -n "${miss// /}" ]]; then
    hm_warn "system: brakuje locale UTF-8: ${miss} — system locale fix"
    rc=1
  fi

  if [[ "${rc}" -eq 0 ]]; then
    hm_ok "system: status OK."
  fi
  return "${rc}"
}

hm_system_time_sync_on() {
  local synced=0
  hm_system_ntp_synchronized && synced=1
  if [[ "${synced}" -eq 1 ]]; then
    hm_ok "NTP już włączone (synchronizacja aktywna)."
    return 0
  fi
  local -a plan=(
    "timedatectl set-ntp true"
    "Włączenie usługi: chronyd lub systemd-timesyncd (wg dystrybucji)"
  )
  hm_confirm_plan "system time sync on" "Synchronizacja czasu z NTP." "${plan[@]}" || return 0
  if [[ -n "${HM_SYSTEM_TIMEDATECTL_LOG:-}" ]]; then
    printf 'set-ntp true\n' >> "${HM_SYSTEM_TIMEDATECTL_LOG}"
  elif [[ "${HMTOOLS_TEST:-}" == "1" ]]; then
    hm_err "Ustaw HM_SYSTEM_TIMEDATECTL_LOG w teście."
    return 1
  else
    hm_system_timedatectl set-ntp true || return 1
  fi
  if [[ -z "${HM_SYSTEM_TIMEDATECTL_LOG:-}" && "${HMTOOLS_TEST:-}" != "1" ]]; then
    systemctl enable --now chronyd 2>/dev/null \
      || systemctl enable --now chrony 2>/dev/null \
      || systemctl enable --now systemd-timesyncd 2>/dev/null \
      || true
  fi
  hm_ok "Włączono synchronizację NTP."
  return 0
}

hm_system_timezone_set() {
  local tz="${1:-}"
  [[ -n "${tz}" ]] || {
    hm_err "Użycie: system timezone set <strefa> (np. Europe/Warsaw)"
    return 1
  }
  local cur
  cur="$(hm_system_timezone_current)"
  if [[ "${cur}" == "${tz}" ]]; then
    hm_ok "Strefa już ustawiona: ${tz}"
    return 0
  fi
  hm_confirm_plan "system timezone set" "" \
    "timedatectl set-timezone ${tz}" \
    "Bieżąca: ${cur:-?} → ${tz}" || return 0
  if [[ -n "${HM_SYSTEM_TIMEDATECTL_LOG:-}" ]]; then
    printf 'set-timezone %s\n' "${tz}" >> "${HM_SYSTEM_TIMEDATECTL_LOG}"
  elif [[ "${HMTOOLS_TEST:-}" == "1" ]]; then
    hm_err "Ustaw HM_SYSTEM_TIMEDATECTL_LOG w teście."
    return 1
  else
    hm_system_timedatectl set-timezone "${tz}" || return 1
  fi
  hm_ok "Ustawiono strefę: ${tz}"
}

hm_system_hostname_set() {
  local fqdn="${1:-}"
  [[ -n "${fqdn}" ]] || {
    hm_err "Użycie: system hostname set <fqdn>"
    return 1
  }
  hm_system_valid_fqdn "${fqdn}" || {
    hm_err "Nieprawidłowy FQDN: ${fqdn}"
    return 1
  }
  local cur
  cur="$(hm_system_fqdn)"
  if [[ "$(hm_system_normalize_dns "${cur}")" == "$(hm_system_normalize_dns "${fqdn}")" ]]; then
    hm_ok "Hostname już: ${fqdn}"
    return 0
  fi
  local warn="CyberPanel: po zmianie uruchom «ssl hostname» (certyfikat hostNameSSL panelu)."
  hm_confirm_plan "system hostname set" "${warn}" \
    "hostnamectl set-hostname ${fqdn}" \
    "Zaktualizuj rekordy DNS / rDNS u dostawcy" || return 0
  hm_system_hostnamectl set-hostname "${fqdn}" || return 1
  hm_warn "${warn}"
  hm_ok "Ustawiono hostname: ${fqdn}"
}

hm_system_locale_gen_run() {
  if [[ -n "${HM_SYSTEM_LOCALE_GEN_LOG:-}" ]]; then
    printf 'locale-gen\n' >> "${HM_SYSTEM_LOCALE_GEN_LOG}"
    return 0
  fi
  if [[ "${HMTOOLS_TEST:-}" == "1" ]]; then
    hm_err "Ustaw HM_SYSTEM_LOCALE_GEN_LOG w teście."
    return 1
  fi
  if command -v locale-gen >/dev/null 2>&1; then
    locale-gen
    return $?
  fi
  if command -v localectl >/dev/null 2>&1; then
    local loc
    while IFS= read -r loc; do
      [[ -n "${loc}" ]] || continue
      localedef -i "${loc%%.*}" -f UTF-8 "${loc}" 2>/dev/null || localectl set-locale "LANG=${loc}"
    done < <(hm_system_locales_required)
    return 0
  fi
  hm_err "Brak locale-gen / localectl."
  return 1
}

hm_system_locale_ensure_lines() {
  local genfile="$1" loc line esc
  [[ -f "${genfile}" ]] || touch "${genfile}"
  while IFS= read -r loc; do
    [[ -n "${loc}" ]] || continue
    esc="${loc//./\\.}"
    if grep -qE "^[[:space:]]*#?[[:space:]]*${esc}[[:space:]]" "${genfile}" 2>/dev/null; then
      if grep -qE "^[[:space:]]*#.*${esc}" "${genfile}" 2>/dev/null; then
        sed -i "s/^[[:space:]]*#\\(.*${esc}.*\\)$/\\1/" "${genfile}" 2>/dev/null || true
      fi
    else
      printf '%s UTF-8\n' "${loc}" >> "${genfile}"
    fi
  done < <(hm_system_locales_required)
}

hm_system_locale_fix() {
  local miss
  miss="$(hm_system_locale_missing)"
  if [[ -z "${miss}" ]]; then
    hm_ok "Wymagane locale UTF-8 już wygenerowane."
    return 0
  fi
  local -a steps=()
  local loc
  while IFS= read -r loc; do
    [[ -n "${loc}" ]] || continue
    steps+=("Wygeneruj locale: ${loc}")
  done <<<"${miss}"
  steps+=("Uruchom locale-gen (lub localedef na RHEL)")
  hm_confirm_plan "system locale fix" "LANG=C utrudnia narzędzia UTF-8." "${steps[@]}" || return 0

  if [[ "${OS_FAMILY:-}" == "debian" || -f "$(hm_system_locale_gen_file)" ]]; then
    hm_system_locale_ensure_lines "$(hm_system_locale_gen_file)"
  fi
  hm_system_locale_gen_run || return 1
  if [[ -n "${HM_SYSTEM_LOCALE_A:-}" ]]; then
    while IFS= read -r loc; do
      grep -qxi "${loc}" "${HM_SYSTEM_LOCALE_A}" 2>/dev/null || echo "${loc}" >> "${HM_SYSTEM_LOCALE_A}"
    done < <(hm_system_locales_required)
  fi
  hm_ok "Wygenerowano locale UTF-8 (C, pl_PL, en_US)."
}

cmd_system() {
  local sub="${1:-status}"
  shift || true
  case "${sub}" in
    status|"") hm_system_status ;;
    time)
      case "${1:-}" in
        sync)
          shift || true
          case "${1:-}" in
            on) hm_system_time_sync_on ;;
            *)
              hm_err "Użycie: system time sync on"
              return 1
              ;;
          esac
          ;;
        *)
          hm_err "Użycie: system time sync on"
          return 1
          ;;
      esac
      ;;
    timezone)
      case "${1:-}" in
        set)
          shift || true
          hm_system_timezone_set "${1:-}"
          ;;
        *)
          hm_err "Użycie: system timezone set <strefa>"
          return 1
          ;;
      esac
      ;;
    hostname)
      case "${1:-}" in
        set)
          shift || true
          hm_system_hostname_set "${1:-}"
          ;;
        *)
          hm_err "Użycie: system hostname set <fqdn>"
          return 1
          ;;
      esac
      ;;
    locale)
      case "${1:-}" in
        fix) hm_system_locale_fix ;;
        *)
          hm_err "Użycie: system locale fix"
          return 1
          ;;
      esac
      ;;
    help|-h|--help) hm_help_topic system 2>/dev/null || true ;;
    *)
      hm_err "Nieznana podkomenda: ${sub} (help: system help)"
      return 1
      ;;
  esac
}

_hm_cmd_register system cmd_system 0