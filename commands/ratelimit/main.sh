#!/usr/bin/env bash
# ratelimit / protect / geoip / bots — limity per ścieżka, ochrona WP, GeoIP, boty wyszukiwarek

_hm_cmd_help ratelimit <<'EOF'
Użycie:
  ratelimit status [<domena>]
  ratelimit set <domena> --rps N [--burst M] [--path /wp-login.php] [--yes]

Limity dynamiczne (OLS perClientConnLimit w kontekście ścieżki).
IP sesji SSH i wpisy firewall whitelist (hmtools) są zawsze wyłączone z limitów (T w accessControl).
Za Cloudflare: włącz cf realip apply — klient = prawdziwy IP (nie brzeg).
Stan: /var/lib/hmtools/ratelimit (HM_RL_STATE_DIR).
EOF

_hm_cmd_help protect <<'EOF'
Użycie:
  protect wp <domena> [--rps N] [--xmlrpc block|limit] [--yes]

Preset: limit wp-login.php, blokada/limit xmlrpc.php, stub jail Fail2Ban (log OLS).
EOF

_hm_cmd_help geoip <<'EOF'
Użycie:
  geoip block|allow <kod> [--domain d] [--yes]
  geoip status [--domain d]
  geoip off|clear [--domain d] [--yes]

Kod kraju ISO-3166 (PL, US, …). Blokada/allowlista w vhconf (# hmtools:geoip).
Wymaga bazy GeoIP (MaxMind) — `allow` odmawia bez bazy; `block` ostrzega.
geoip off/clear usuwa blok vhconf i stan.
EOF

_hm_cmd_help bots <<'EOF'
Użycie:
  bots allow [verify <IP>|status|on|off] [--yes]

on: reguły bypass limitów dla zweryfikowanych IP Googlebot/Bingbot (reverse+forward DNS).
verify <IP>: sprawdź i dopisz do allowlisty.
EOF

# --- stan / ścieżki ----------------------------------------------------------

hm_rl_state_root() {
  printf '%s' "${HM_RL_STATE_DIR:-/var/lib/hmtools/ratelimit}"
}

hm_rl_domain_safe() {
  printf '%s' "${1:-}" | tr './:' '___' | tr -cd 'A-Za-z0-9_-'
}

hm_rl_domain_dir() {
  local domain="$1" key
  key="$(hm_rl_domain_safe "${domain}")"
  [[ -n "${key}" ]] || return 1
  printf '%s/%s' "$(hm_rl_state_root)" "${key}"
}

hm_rl_ensure_state() {
  local root
  root="$(hm_rl_state_root)"
  mkdir -p "${root}" 2>/dev/null || true
  chmod 0750 "${root}" 2>/dev/null || true
}

hm_rl_limits_file() {
  local domain="$1"
  printf '%s/limits.tsv' "$(hm_rl_domain_dir "${domain}")"
}

hm_rl_geoip_file() {
  local domain="$1"
  printf '%s/geoip.list' "$(hm_rl_domain_dir "${domain}")"
}

hm_rl_bots_ips_file() {
  printf '%s/bots-verified.list' "$(hm_rl_state_root)"
}

hm_rl_protect_flag() {
  local domain="$1"
  printf '%s/protect-wp' "$(hm_rl_domain_dir "${domain}")"
}

hm_rl_f2b_jail() {
  printf '%s' "${HM_RL_F2B_JAIL:-${HM_RL_F2B_DIR:-/etc/fail2ban/jail.d}/hmtools-wp-login.conf}"
}

hm_rl_f2b_filter() {
  printf '%s' "${HM_RL_F2B_FILTER:-/etc/fail2ban/filter.d/hmtools-wp-login.conf}"
}

# --- IP sesji / whitelist / Cloudflare ---------------------------------------

hm_rl_session_ssh_ip() {
  if declare -F hm_session_ssh_ip >/dev/null 2>&1; then
    hm_session_ssh_ip 2>/dev/null && return 0
  fi
  local tip=""
  if [[ -n "${SSH_CLIENT:-}" ]]; then
    tip="${SSH_CLIENT%% *}"
  elif [[ -n "${SSH_CONNECTION:-}" ]]; then
    tip="${SSH_CONNECTION%% *}"
  fi
  [[ -n "${tip}" ]] || return 1
  printf '%s' "${tip}"
}

hm_rl_firewall_whitelist_ips() {
  local -a ips=() line ip cmt rest
  local csf_file="${HM_RL_CSF_ALLOW:-/etc/csf/csf.allow}"
  if [[ -f "${csf_file}" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      # Najpierw komentarz (hmtools), potem ucięcie — inaczej „IP # hmtools” znika.
      [[ "${line}" == *hmtools* ]] || continue
      line="${line%%#*}"
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ -n "${line}" ]] || continue
      ip="${line%%[[:space:]]*}"
      ip="${ip%%/*}"
      [[ -n "${ip}" ]] && ips+=("${ip}")
    done < "${csf_file}"
  fi
  local ufw_src=""
  if [[ -n "${HM_RL_UFW_STATUS:-}" && -f "${HM_RL_UFW_STATUS}" ]]; then
    ufw_src="${HM_RL_UFW_STATUS}"
  elif hm_have_cmd ufw; then
    ufw_src="ufw"
  fi
  if [[ -n "${ufw_src}" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ "${line}" == *ALLOW* ]] || continue
      [[ "${line}" == *"#"* ]] || continue
      cmt="${line#*#}"
      [[ "${cmt}" == *hmtools* ]] || continue
      rest="${line%%#*}"
      # Kolumna From = ostatni token (nie słowo „from ” — ufw status go nie ma).
      ip="$(printf '%s' "${rest}" | awk '{print $NF}')"
      [[ "${ip}" =~ ^[0-9a-fA-F:.]+$ || "${ip}" == */* ]] || continue
      ip="${ip%%/*}"
      ips+=("${ip}")
    done < <(if [[ "${ufw_src}" == "ufw" ]]; then ufw status numbered 2>/dev/null || true; else cat "${ufw_src}"; fi)
  fi
  # user.rules (ALLOW + komentarz hmtools) — gdy ufw status niedostępny
  local urules="${HM_RL_UFW_USER_RULES:-/etc/ufw/user.rules}"
  if [[ -f "${urules}" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ "${line}" == *hmtools* ]] || continue
      if [[ "${line}" =~ -s[[:space:]]+([^[:space:]]+) ]]; then
        ips+=("${BASH_REMATCH[1]}")
      fi
    done < "${urules}"
  fi
  local x
  for x in "${ips[@]}"; do
    printf '%s\n' "${x}"
  done
}

hm_rl_trusted_ips() {
  local ip
  ip="$(hm_rl_session_ssh_ip 2>/dev/null || true)"
  [[ -n "${ip}" ]] && printf '%s\n' "${ip}"
  hm_rl_firewall_whitelist_ips 2>/dev/null || true
}

hm_rl_country_ok() {
  local cc="${1^^}"
  [[ "${#cc}" -eq 2 && "${cc}" =~ ^[A-Z]{2}$ ]]
}

hm_rl_path_ok() {
  local p="${1:-}"
  [[ "${p}" == /* ]] || return 1
  [[ "${p}" != *".."* ]] || return 1
  [[ "${p}" != *$'\n'* ]] || return 1
  return 0
}

hm_rl_pos_int() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && ((10#${1} > 0))
}

# --- boty (reverse + forward DNS) --------------------------------------------

hm_rl_bot_host_ok() {
  local host="${1,,}"
  [[ "${host}" == *.googlebot.com || "${host}" == googlebot.com ]] && return 0
  [[ "${host}" == *.search.msn.com || "${host}" == search.msn.com ]] && return 0
  [[ "${host}" == *.bingbot.com || "${host}" == bingbot.com ]] && return 0
  return 1
}

hm_rl_bot_verify_ip() {
  local ip="$1" ptr fwd host
  [[ -n "${ip}" ]] || return 1
  if [[ -n "${HM_RL_MOCK_PTR:-}" ]]; then
    ptr="${HM_RL_MOCK_PTR}"
  elif command -v host >/dev/null 2>&1; then
    ptr="$(host -W 3 "${ip}" 2>/dev/null | awk '/pointer/{print $NF; exit}' | sed 's/\.$//' || true)"
  elif command -v dig >/dev/null 2>&1; then
    ptr="$(dig +short -x "${ip}" 2>/dev/null | head -1 | sed 's/\.$//' || true)"
  fi
  [[ -n "${ptr}" ]] || return 1
  hm_rl_bot_host_ok "${ptr}" || return 1
  if [[ -n "${HM_RL_MOCK_FWD:-}" ]]; then
    fwd="${HM_RL_MOCK_FWD}"
  elif command -v host >/dev/null 2>&1; then
    fwd="$(host -W 3 "${ptr}" 2>/dev/null | awk '/has address|has IPv6/{print $NF; exit}' || true)"
  elif command -v dig >/dev/null 2>&1; then
    fwd="$(dig +short A "${ptr}" 2>/dev/null | head -1 || true)"
    [[ -n "${fwd}" ]] || fwd="$(dig +short AAAA "${ptr}" 2>/dev/null | head -1 || true)"
  fi
  [[ -n "${fwd}" && "${fwd}" == "${ip}" ]]
}

# --- GeoIP DB (opcjonalnie) --------------------------------------------------

hm_rl_geoip_mmdb() {
  local f
  for f in \
    "${HM_RL_GEOIP_MMDB:-}" \
    /usr/share/GeoIP/GeoLite2-Country.mmdb \
    /var/lib/GeoIP/GeoLite2-Country.mmdb \
    /usr/share/GeoIP/GeoIP.dat
  do
    [[ -n "${f}" && -f "${f}" ]] && { printf '%s' "${f}"; return 0; }
  done
  return 1
}

hm_rl_geoip_install_hint() {
  hm_info "Brak bazy GeoIP. Zainstaluj pakiet GeoLite (np. geoip-database) lub ustaw HM_RL_GEOIP_MMDB."
  if declare -F hm_pkg_install >/dev/null 2>&1; then
    hm_pkg_install geoip-database 2>/dev/null || hm_pkg_install geoip 2>/dev/null || true
  fi
}

# --- generatory bloków vhconf ------------------------------------------------

hm_rl_trusted_access_body() {
  local ip
  while IFS= read -r ip || [[ -n "${ip}" ]]; do
    [[ -n "${ip}" ]] || continue
    printf '  allow                   %sT\n' "${ip}"
  done < <(hm_rl_trusted_ips | sort -u)
}

hm_rl_block_ratelimit_body() {
  local path="$1" rps="$2" burst="$3"
  local ctx_name
  ctx_name="$(printf '%s' "${path}" | tr '/.' '_' | tr -cd 'A-Za-z0-9_' | head -c 32)"
  [[ -n "${ctx_name}" ]] || ctx_name="path"
  cat <<EOF
# path=${path} rps=${rps} burst=${burst}
# realip: useIpInProxyHeader / cf realip — REMOTE_ADDR = klient za CF
accessControl  {
$(hm_rl_trusted_access_body)
}
context ${path} {
  perClientConnLimit  {
    dynReqPerSec            ${rps}
    staticReqPerSec         ${rps}
    softLimit               ${burst}
    hardLimit               $((burst + burst / 2 + 1))
    gracePeriod             5
    banPeriod               60
  }
}
EOF
}

hm_rl_block_protect_wp_body() {
  local rps="$1" xmlrpc_mode="$2"
  cat <<EOF
# protect wp-login rps=${rps} xmlrpc=${xmlrpc_mode}
accessControl  {
$(hm_rl_trusted_access_body)
}
context /wp-login.php {
  perClientConnLimit  {
    dynReqPerSec            ${rps}
    staticReqPerSec         ${rps}
    softLimit               $((rps * 3))
    hardLimit               $((rps * 4))
    gracePeriod             5
    banPeriod               120
  }
}
EOF
  case "${xmlrpc_mode}" in
    block)
      cat <<'EOF'
context /xmlrpc.php {
  allowBrowse             0
  accessible              0
}
EOF
      ;;
    limit)
      cat <<EOF
context /xmlrpc.php {
  perClientConnLimit  {
    dynReqPerSec            2
    staticReqPerSec         2
    softLimit               6
    hardLimit               10
    gracePeriod             5
    banPeriod               300
  }
}
EOF
      ;;
  esac
}

hm_rl_block_geoip_body() {
  local mode="$1"
  shift
  local -a codes=("$@")
  local cc line
  printf '# geoip %s: %s\n' "${mode}" "${codes[*]}"
  printf 'accessControl  {\n'
  hm_rl_trusted_access_body
  printf '}\n'
  printf 'rewrite  {\n  enable                  1\n  rules                   <<<END_hmtools_geoip\n'
  printf '# GeoIP: wymaga modułu/geo — reguły oparte o %%{ENV:GEOIP_COUNTRY_CODE}\n'
  if [[ "${mode}" == "block" ]]; then
    printf 'RewriteCond %%{ENV:GEOIP_COUNTRY_CODE} !^$\n'
    printf 'RewriteCond %%{ENV:GEOIP_COUNTRY_CODE} ^(%s)$ [NC]\n' "$(IFS='|'; printf '%s' "${codes[*]}")"
    printf 'RewriteRule .* - [F,L]\n'
  else
    # Pusty GEOIP_COUNTRY_CODE ≠ „nie-PL” — inaczej allow blokuje cały ruch bez bazy.
    printf 'RewriteCond %%{ENV:GEOIP_COUNTRY_CODE} !^$\n'
    printf 'RewriteCond %%{ENV:GEOIP_COUNTRY_CODE} !^(%s)$ [NC]\n' "$(IFS='|'; printf '%s' "${codes[*]}")"
    printf 'RewriteRule .* - [F,L]\n'
  fi
  printf 'END_hmtools_geoip\n}\n'
}

hm_rl_block_bots_body() {
  cat <<'EOF'
# bots: bypass limitów dla zweryfikowanych crawlerów (IP z bots-verified.list)
rewrite  {
  enable                  1
  rules                   <<<END_hmtools_bots
RewriteCond %{HTTP_USER_AGENT} (Googlebot|bingbot|Bingbot) [NC]
RewriteRule .* - [E=HMTOOLS_BOT_UA:1]
END_hmtools_bots
}
EOF
}

# --- zapis vhconf ------------------------------------------------------------

hm_rl_vhost_conf() {
  local domain="$1" conf=""
  if declare -F hm_ols_vhost_conf_for >/dev/null 2>&1; then
    conf="$(hm_ols_vhost_conf_for "${domain}" 2>/dev/null || true)"
  fi
  if [[ -z "${conf}" || ! -f "${conf}" ]]; then
    conf="$(hm_vhost_conf_path "${domain}" 2>/dev/null || true)"
  fi
  [[ -n "${conf}" && -f "${conf}" ]] || return 1
  printf '%s' "${conf}"
}

hm_rl_apply_block() {
  local domain="$1" block_name="$2" body="$3" yes="${4:-0}"
  local conf tmp
  conf="$(hm_rl_vhost_conf "${domain}")" || { hm_err "Brak vhconf dla ${domain}."; return 1; }
  if ! declare -F hm_ols_vhost_strip_block >/dev/null 2>&1; then
    hm_err "Brak helperów OLS vhost (hm_ols_vhost_strip_block)."
    return 1
  fi
  tmp="$(hm_mktemp .vhconf-rl)"
  hm_ols_vhost_strip_block "${conf}" "${block_name}" "${tmp}"
  {
    cat "${tmp}"
    echo "# hmtools:${block_name} BEGIN"
    printf '%s\n' "${body}"
    echo "# hmtools:${block_name} END"
  } > "${tmp}.new"

  if [[ "${HMTOOLS_TEST:-}" == "1" || "${yes}" == "1" ]]; then
    export HM_OLS_VHOST_YES=1
  fi
  if declare -F hm_ols_vhost_apply_tmp >/dev/null 2>&1 \
    && [[ "${HM_RL_DIRECT_WRITE:-}" != "1" ]]; then
    hm_ols_vhost_apply_tmp "${domain}" "${conf}" "${tmp}.new" \
      "ratelimit — ${block_name} (${domain})" \
      "Blok # hmtools:${block_name}" \
      "ols reload" || {
      rm -f "${tmp}" "${tmp}.new"
      unset HM_OLS_VHOST_YES
      return 1
    }
  else
    hm_ols_vhost_write "${conf}" "${tmp}.new" 2>/dev/null \
      || cat "${tmp}.new" > "${conf}" \
      || { rm -f "${tmp}" "${tmp}.new"; return 1; }
    if declare -F hm_ols_reload_soft >/dev/null 2>&1; then
      hm_ols_reload_soft 2>/dev/null || true
    fi
  fi
  unset HM_OLS_VHOST_YES
  rm -f "${tmp}" "${tmp}.new"
  return 0
}

# --- fail2ban stub (wp-login) ------------------------------------------------

hm_rl_f2b_wp_login_enable() {
  local domain="$1" logf jail filter ip
  jail="$(hm_rl_f2b_jail)"
  filter="$(hm_rl_f2b_filter)"
  ip="$(hm_rl_session_ssh_ip 2>/dev/null || true)"
  [[ "${ip}" =~ ^[0-9a-fA-F:.]+$ ]] || ip="127.0.0.1"
  logf="${HM_RL_OLS_ACCESS:-${OLS_ROOT:-/usr/local/lsws}/logs/access.log}"
  if declare -F hm_vhost_conf_path >/dev/null 2>&1; then
    local vhroot
    vhroot="$(hm_ols_vhroot_for_domain "${domain}" 2>/dev/null || true)"
    if [[ -n "${vhroot}" ]]; then
      logf="${vhroot}/logs/access.log"
      [[ -f "${logf}" ]] || logf="${vhroot}/../logs/access.log"
    fi
  fi
  mkdir -p "$(dirname "${jail}")" "$(dirname "${filter}")"
  cat > "${filter}" <<'EOF'
[Definition]
failregex = ^<HOST> .* "(GET|POST) /wp-login\.php
ignoreregex =
EOF
  cat > "${jail}" <<EOF
[hmtools-wp-login]
enabled = true
filter = hmtools-wp-login
port = http,https
logpath = ${logf}
maxretry = 10
findtime = 600
bantime = 3600
backend = auto
ignoreip = 127.0.0.1/8 ::1 ${ip}
EOF
  if [[ "${HMTOOLS_TEST:-}" != "1" ]] && declare -F hm_firewall_fail2ban_ignore >/dev/null 2>&1; then
    hm_firewall_fail2ban_ignore "${ip}" || true
  fi
  if [[ "${HMTOOLS_TEST:-}" != "1" ]] && hm_have_cmd fail2ban-client; then
    fail2ban-client reload 2>/dev/null || true
  fi
}

# --- ratelimit set / status ----------------------------------------------------

hm_rl_save_limit_line() {
  local domain="$1" path="$2" rps="$3" burst="$4"
  local dir f tmp
  dir="$(hm_rl_domain_dir "${domain}")"
  mkdir -p "${dir}" 2>/dev/null || true
  f="$(hm_rl_limits_file "${domain}")"
  touch "${f}" 2>/dev/null || true
  tmp="$(hm_mktemp .rl-tsv)"
  if [[ -f "${f}" ]]; then
    grep -vF "	${path}	" "${f}" 2>/dev/null > "${tmp}" || : > "${tmp}"
  else
    : > "${tmp}"
  fi
  printf '%s\t%s\t%s\t%s\n' "${domain}" "${path}" "${rps}" "${burst}" >> "${tmp}"
  cat "${tmp}" > "${f}"
  rm -f "${tmp}"
  chmod 0640 "${f}" 2>/dev/null || true
}

hm_rl_status_domain() {
  local domain="$1" conf f
  echo "${C_BOLD}ratelimit — ${domain}${C_RESET}"
  conf="$(hm_rl_vhost_conf "${domain}" 2>/dev/null || true)"
  if [[ -n "${conf}" && -f "${conf}" ]]; then
    if grep -qF '# hmtools:ratelimit BEGIN' "${conf}" 2>/dev/null; then
      hm_ok "vhconf: blok ratelimit aktywny"
    else
      hm_info "vhconf: brak bloku ratelimit"
    fi
  fi
  f="$(hm_rl_limits_file "${domain}")"
  if [[ -f "${f}" ]]; then
    echo "  limity (path → rps/burst):"
    while IFS=$'\t' read -r _dom path rps burst; do
      [[ -n "${path}" ]] || continue
      printf '    %s  rps=%s burst=%s\n' "${path}" "${rps}" "${burst}"
    done < "${f}"
  fi
  if [[ -f "$(hm_rl_protect_flag "${domain}")" ]]; then
    hm_info "protect wp: włączone"
  fi
  if [[ -f "$(hm_rl_geoip_file "${domain}")" ]]; then
    echo "  geoip:"
    cat "$(hm_rl_geoip_file "${domain}")" 2>/dev/null | sed 's/^/    /'
  fi
  local tip
  tip="$(hm_rl_session_ssh_ip 2>/dev/null || true)"
  [[ -n "${tip}" ]] && hm_info "IP sesji (wyłączone z limitów): ${tip}"
}

hm_rl_cmd_set() {
  local domain="" path="/wp-login.php" rps="" burst="10" yes=0
  [[ -n "${1:-}" ]] || { hm_err "Użycie: ratelimit set <domena> --rps N"; return 1; }
  domain="$1"
  shift
  hm_is_valid_domain "${domain}" || { hm_err "Nieprawidłowa domena: ${domain}"; return 1; }
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --rps) rps="${2:-}"; shift 2 ;;
      --rps=*) rps="${1#*=}"; shift ;;
      --burst) burst="${2:-}"; shift 2 ;;
      --burst=*) burst="${1#*=}"; shift ;;
      --path) path="${2:-}"; shift 2 ;;
      --path=*) path="${1#*=}"; shift ;;
      --yes) yes=1; shift ;;
      help|-h|--help) hm_help_topic ratelimit; return 0 ;;
      *) hm_err "Nieznany argument: $1"; return 1 ;;
    esac
  done
  hm_rl_pos_int "${rps}" || { hm_err "--rps: liczba > 0"; return 1; }
  hm_rl_pos_int "${burst}" || { hm_err "--burst: liczba > 0"; return 1; }
  hm_rl_path_ok "${path}" || { hm_err "Nieprawidłowa --path (musi zaczynać się od /)"; return 1; }

  hm_rl_ensure_state
  local body
  body="$(hm_rl_block_ratelimit_body "${path}" "${rps}" "${burst}")"
  hm_rl_apply_block "${domain}" "ratelimit" "${body}" "${yes}" || return 1
  hm_rl_save_limit_line "${domain}" "${path}" "${rps}" "${burst}"
  hm_ok "Limit ${path}: ${rps} rps, burst ${burst} (${domain})"
}

hm_rl_cmd_status() {
  local domain="${1:-}"
  if [[ -n "${domain}" ]]; then
    hm_is_valid_domain "${domain}" || { hm_err "Nieprawidłowa domena"; return 1; }
    hm_rl_status_domain "${domain}"
    return 0
  fi
  hm_rl_ensure_state
  local d dir
  if [[ ! -d "$(hm_rl_state_root)" ]]; then
    hm_info "Brak skonfigurowanych limitów."
    return 0
  fi
  for dir in "$(hm_rl_state_root)"/*/; do
    [[ -d "${dir}" ]] || continue
    d="$(basename "${dir}")"
    d="${d//___/.}"
    hm_rl_status_domain "${d}"
    echo
  done
}

# --- protect wp ----------------------------------------------------------------

hm_rl_cmd_protect_wp() {
  local domain="" rps="5" xmlrpc="block" yes=0
  [[ -n "${1:-}" ]] || { hm_err "Użycie: protect wp <domena>"; return 1; }
  domain="$1"
  shift
  hm_is_valid_domain "${domain}" || { hm_err "Nieprawidłowa domena: ${domain}"; return 1; }
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --rps) rps="${2:-}"; shift 2 ;;
      --rps=*) rps="${1#*=}"; shift ;;
      --xmlrpc) xmlrpc="${2:-}"; shift 2 ;;
      --xmlrpc=*) xmlrpc="${1#*=}"; shift ;;
      --yes) yes=1; shift ;;
      *) hm_err "Nieznany argument: $1"; return 1 ;;
    esac
  done
  case "${xmlrpc}" in
    block|limit) ;;
    *) hm_err "--xmlrpc: block|limit"; return 1 ;;
  esac
  hm_rl_pos_int "${rps}" || { hm_err "--rps: liczba > 0"; return 1; }

  hm_rl_ensure_state
  mkdir -p "$(hm_rl_domain_dir "${domain}")" 2>/dev/null || true
  date -Is > "$(hm_rl_protect_flag "${domain}")" 2>/dev/null || true

  local body
  body="$(hm_rl_block_protect_wp_body "${rps}" "${xmlrpc}")"
  hm_rl_apply_block "${domain}" "protect-wp" "${body}" "${yes}" || return 1
  hm_rl_f2b_wp_login_enable "${domain}"
  hm_rl_save_limit_line "${domain}" "/wp-login.php" "${rps}" "$((rps * 3))"
  hm_ok "Ochrona WordPress: wp-login ${rps} rps, xmlrpc=${xmlrpc}, fail2ban stub."
}

cmd_protect() {
  local sub="${1:-}"
  shift || true
  case "${sub}" in
    wp) hm_rl_cmd_protect_wp "$@" ;;
    help|-h|--help|"") hm_help_topic protect ;;
    *) hm_err "Użycie: protect wp <domena>"; return 1 ;;
  esac
}

# --- geoip ---------------------------------------------------------------------

hm_rl_geoip_save() {
  local domain="$1" mode="$2" cc="$3"
  local f tmp
  f="$(hm_rl_geoip_file "${domain}")"
  mkdir -p "$(dirname "${f}")" 2>/dev/null || true
  tmp="$(hm_mktemp .geo)"
  if [[ -f "${f}" ]]; then
    grep -vF "${mode} ${cc}" "${f}" 2>/dev/null > "${tmp}" || : > "${tmp}"
  else
    : > "${tmp}"
  fi
  printf '%s %s\n' "${mode}" "${cc}" >> "${tmp}"
  cat "${tmp}" > "${f}"
  rm -f "${tmp}"
}

hm_rl_geoip_load_modes() {
  local domain="$1" mode="$2"
  local f
  f="$(hm_rl_geoip_file "${domain}")"
  [[ -f "${f}" ]] || return 0
  awk -v m="${mode}" '$1==m {print toupper($2)}' "${f}" 2>/dev/null
}

hm_rl_geoip_clear() {
  local domain="$1" yes="${2:-0}"
  local conf tmp f
  f="$(hm_rl_geoip_file "${domain}")"
  conf="$(hm_rl_vhost_conf "${domain}")" || return 1
  if [[ "${yes}" -ne 1 ]]; then
    hm_confirm_plan "geoip off ${domain}" "" "Usuń blok # hmtools:geoip" "Wyczyść stan geoip.list" || return 0
  fi
  if declare -F hm_ols_vhost_strip_block >/dev/null 2>&1; then
    tmp="$(hm_mktemp .geooff)"
    hm_ols_vhost_strip_block "${conf}" "geoip" "${tmp}"
    hm_ols_vhost_write "${conf}" "${tmp}"
    rm -f "${tmp}"
  fi
  rm -f "${f}"
  if [[ "${HMTOOLS_TEST:-}" != "1" ]]; then
    hm_ols_reload_soft 2>/dev/null || true
  fi
  hm_ok "GeoIP wyłączone (${domain})"
}

hm_rl_cmd_geoip() {
  local sub="${1:-status}"
  shift || true
  local domain="${HM_SITE_DOMAIN:-}" cc="" yes=0 mode=""
  case "${sub}" in
    block|allow)
      mode="${sub}"
      [[ -n "${1:-}" ]] || { hm_err "Użycie: geoip ${sub} <kod> [--domain d]"; return 1; }
      cc="${1^^}"
      shift
      ;;
    off|clear)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --domain) domain="${2:-}"; shift 2 ;;
          --domain=*) domain="${1#*=}"; shift ;;
          --yes) yes=1; shift ;;
          *) shift ;;
        esac
      done
      [[ -n "${domain}" ]] || { hm_err "Podaj --domain lub use <domena>"; return 1; }
      hm_is_valid_domain "${domain}" || return 1
      hm_rl_geoip_clear "${domain}" "${yes}"
      return $?
      ;;
    status|stat)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --domain) domain="${2:-}"; shift 2 ;;
          --domain=*) domain="${1#*=}"; shift ;;
          *) shift ;;
        esac
      done
      [[ -n "${domain}" ]] || { hm_err "Podaj --domain lub use <domena>"; return 1; }
      hm_rl_status_domain "${domain}"
      hm_rl_geoip_mmdb >/dev/null && hm_ok "GeoIP DB: $(hm_rl_geoip_mmdb)" \
        || hm_warn "Brak bazy GeoIP na serwerze."
      return 0
      ;;
    install)
      hm_rl_geoip_install_hint
      return 0
      ;;
    help|-h|--help)
      hm_help_topic geoip
      return 0
      ;;
    *)
      hm_err "Użycie: geoip block|allow <kod> | off|clear [--domain d]"
      return 1
      ;;
  esac

  hm_rl_country_ok "${cc}" || { hm_err "Kod kraju: 2 litery ISO (np. PL)"; return 1; }
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain) domain="${2:-}"; shift 2 ;;
      --domain=*) domain="${1#*=}"; shift ;;
      --yes) yes=1; shift ;;
      *) hm_err "Nieznany argument: $1"; return 1 ;;
    esac
  done
  [[ -n "${domain}" ]] || { hm_err "Podaj --domain lub use <domena>"; return 1; }
  hm_is_valid_domain "${domain}" || return 1

  if [[ "${mode}" == "allow" ]] && ! hm_rl_geoip_mmdb >/dev/null; then
    hm_err "geoip allow wymaga bazy GeoIP (GEOIP_COUNTRY_CODE puste = blokada całego ruchu). Zainstaluj bazę lub: geoip install."
    return 1
  fi
  if [[ "${mode}" == "block" ]] && ! hm_rl_geoip_mmdb >/dev/null; then
    hm_warn "GeoIP DB nie znaleziona — reguła block zapisana, ale bez bazy nie zadziała (warunek !^$)."
  fi

  hm_rl_ensure_state
  hm_rl_geoip_save "${domain}" "${mode}" "${cc}"

  local -a block=() allow=()
  while IFS= read -r line; do
    [[ -n "${line}" ]] && block+=("${line}")
  done < <(hm_rl_geoip_load_modes "${domain}" block)
  while IFS= read -r line; do
    [[ -n "${line}" ]] && allow+=("${line}")
  done < <(hm_rl_geoip_load_modes "${domain}" allow)

  local body=""
  if [[ "${#block[@]}" -gt 0 ]]; then
    if [[ "${#allow[@]}" -gt 0 ]]; then
      hm_warn "Jednocześnie block i allow — stosuję tylko block; allow ignorowane."
    fi
    body="$(hm_rl_block_geoip_body block "${block[@]}")"
  elif [[ "${#allow[@]}" -gt 0 ]]; then
    body="$(hm_rl_block_geoip_body allow "${allow[@]}")"
  else
    body="# geoip empty"
  fi
  hm_rl_apply_block "${domain}" "geoip" "${body}" "${yes}" || return 1
  hm_ok "GeoIP ${mode} ${cc} (${domain})"
}

cmd_geoip() {
  hm_rl_cmd_geoip "$@"
}

# --- bots ----------------------------------------------------------------------

hm_rl_bots_add_ip() {
  local ip="$1" f
  f="$(hm_rl_bots_ips_file)"
  hm_rl_ensure_state
  grep -qxF "${ip}" "${f}" 2>/dev/null && return 0
  printf '%s\n' "${ip}" >> "${f}"
  chmod 0640 "${f}" 2>/dev/null || true
}

hm_rl_cmd_bots() {
  local sub="${1:-status}"
  shift || true
  local domain="${HM_SITE_DOMAIN:-}" yes=0 ip=""
  case "${sub}" in
    allow)
      if [[ "${1:-}" == "verify" ]]; then
        shift || true
        ip="${1:-}"
        [[ -n "${ip}" ]] || { hm_err "Użycie: bots allow verify <IP>"; return 1; }
        if declare -F hm_is_valid_ip >/dev/null 2>&1; then
          hm_is_valid_ip "${ip}" || { hm_err "Nieprawidłowe IP"; return 1; }
        fi
        if hm_rl_bot_verify_ip "${ip}"; then
          hm_rl_bots_add_ip "${ip}"
          hm_ok "Bot zweryfikowany: ${ip}"
        else
          hm_err "Weryfikacja DNS nieudana dla ${ip} (nie Googlebot/Bingbot)."
          return 1
        fi
        return 0
      fi
      if [[ -z "${1:-}" || "${1}" == "on" ]]; then
        [[ -n "${domain}" ]] || domain="${HM_RL_BOTS_DOMAIN:-}"
        [[ -n "${domain}" ]] || { hm_err "Podaj domenę: use <d> lub HM_RL_BOTS_DOMAIN"; return 1; }
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --yes) yes=1; shift ;;
            *) shift ;;
          esac
        done
        local body
        body="$(hm_rl_block_bots_body)"
        hm_rl_apply_block "${domain}" "bots" "${body}" "${yes}" || return 1
        hm_ok "Bypass botów włączony (${domain}). Użyj: bots allow verify <IP>"
        return 0
      fi
      if [[ "${1:-}" == "off" ]]; then
        [[ -n "${domain}" ]] || domain="${HM_RL_BOTS_DOMAIN:-}"
        local conf tmp
        conf="$(hm_rl_vhost_conf "${domain}")" || return 1
        tmp="$(hm_mktemp .vh)"
        hm_ols_vhost_strip_block "${conf}" "bots" "${tmp}"
        hm_ols_vhost_write "${conf}" "${tmp}" || cat "${tmp}" > "${conf}"
        rm -f "${tmp}"
        hm_ok "Bypass botów wyłączony."
        return 0
      fi
      hm_help_topic bots
      return 0
      ;;
    status|stat)
      local f n
      f="$(hm_rl_bots_ips_file)"
      if [[ -f "${f}" ]]; then
        n="$(grep -c . "${f}" 2>/dev/null || echo 0)"
        hm_info "Zweryfikowane IP botów: ${n}"
        sed 's/^/  /' "${f}" 2>/dev/null
      else
        hm_info "Brak zweryfikowanych IP."
      fi
      return 0
      ;;
    help|-h|--help)
      hm_help_topic bots
      return 0
      ;;
    *)
      hm_err "Użycie: bots allow|status"
      return 1
      ;;
  esac
}

cmd_bots() {
  hm_rl_cmd_bots "$@"
}

# --- główny dispatch -----------------------------------------------------------

cmd_ratelimit() {
  local sub="${1:-status}"
  shift || true
  case "${sub}" in
    status|stat) hm_rl_cmd_status "$@" ;;
    set) hm_rl_cmd_set "$@" ;;
    help|-h|--help) hm_help_topic ratelimit ;;
    *)
      hm_err "Użycie: ratelimit status|set <domena> --rps N"
      return 1
      ;;
  esac
}

_hm_cmd_register ratelimit cmd_ratelimit 0 rl rate-limit
_hm_cmd_register protect cmd_protect 0
_hm_cmd_register geoip cmd_geoip 0
_hm_cmd_register bots cmd_bots 0