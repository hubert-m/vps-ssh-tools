#!/usr/bin/env bash
# Adapter pakietów: apt (Debian/Ubuntu). Funkcje _hm_pkg_do_* — kontrakt lib/pkg.sh.

_hm_pkg_do_refresh() {
  hm_info "Odświeżanie list pakietów (apt-get update)…"
  local rc=0
  hm_run apt-get update || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    hm_warn "apt-get update zakończyło się kodem ${rc} — indeks może być niekompletny."
    return "${rc}"
  fi
  return 0
}

_hm_pkg_do_install() {
  DEBIAN_FRONTEND=noninteractive hm_run apt-get install -y "$@"
}

_hm_pkg_do_upgrade() {
  # Lista konkretnych pakietów (bez globów shell — apt --only-upgrade)
  DEBIAN_FRONTEND=noninteractive hm_run apt-get install --only-upgrade -y "$@"
}

_hm_pkg_do_list_installed() {
  local pattern="${1:-}"
  [[ -n "${pattern}" ]] || return 0
  if hm_have_cmd dpkg-query; then
    dpkg-query -W -f='${Package}\n' "${pattern}" 2>/dev/null || true
  fi
}

_hm_pkg_do_candidate() {
  local name="${1:-}"
  [[ -n "${name}" ]] || { printf '-'; return 0; }
  local cand
  cand="$(LC_ALL=C apt-cache policy "${name}" 2>/dev/null | awk '/^[[:space:]]+Candidate:/{print $2; exit}')"
  [[ -n "${cand}" && "${cand}" != "(none)" ]] || cand="-"
  printf '%s' "${cand}"
}

# prefix → linie: rest_suffix<TAB>candidate (tylko dokładne nazwy prefix+cyfry, np. lsphp84)
_hm_pkg_do_list_available_bases() {
  local prefix="${1:-}"
  [[ -n "${prefix}" ]] || return 0
  local name ver sfx
  while IFS= read -r name; do
    [[ "${name}" =~ ^${prefix}([0-9]+)$ ]] || continue
    sfx="${BASH_REMATCH[1]}"
    ver="$(LC_ALL=C apt-cache policy "${name}" 2>/dev/null | awk '/^[[:space:]]+Candidate:/{print $2; exit}')"
    [[ -n "${ver}" && "${ver}" != "(none)" ]] || continue
    printf '%s\t%s\n' "${sfx}" "${ver}"
  done < <(apt-cache pkgnames "${prefix}" 2>/dev/null | grep -E "^${prefix}[0-9]+$" | sort -V || true)
}

# main_pkg → installed<TAB>candidate<TAB>upgradable_count
# Opcjonalnie dalsze args = lista pakietów do policy; puste → main + zainstalowane main*
_hm_pkg_do_status_for() {
  local main="${1:-}"
  shift || true
  [[ -n "${main}" ]] || { printf -- '-\t-\t0\n'; return 0; }

  local -a pkgs=()
  local p
  if [[ $# -gt 0 ]]; then
    pkgs=("$@")
  else
    while IFS= read -r p; do
      [[ -n "${p}" ]] && pkgs+=("${p}")
    done < <(_hm_pkg_do_list_installed "${main}*")
    [[ "${#pkgs[@]}" -eq 0 ]] && pkgs=("${main}")
  fi

  local policy_out inst cand upg_count=0
  policy_out="$(LC_ALL=C apt-cache policy "${pkgs[@]}" 2>/dev/null || true)"
  IFS=$'\t' read -r inst cand upg_count < <(
    awk -v main="${main}:" '
      /^[^ ]/ { pkg=$1; inst=""; cand="" }
      /^[[:space:]]+Installed:/ { inst=$2 }
      /^[[:space:]]+Candidate:/ {
        cand=$2
        if (pkg == main || main_inst == "") {
          main_inst=inst; main_cand=cand
        }
        if (inst != "" && inst != "(none)" && cand != "" && cand != "(none)" && inst != cand) {
          upg++
        }
      }
      END {
        printf "%s\t%s\t%d\n", (main_inst ? main_inst : "-"), (main_cand ? main_cand : "-"), upg+0
      }
    ' <<<"${policy_out}"
  )
  [[ -n "${inst}" ]] || inst="-"
  [[ -n "${cand}" ]] || cand="-"
  [[ -n "${upg_count}" ]] || upg_count=0

  if [[ "${inst}" != "-" && "${inst}" != "(none)" && "${cand}" != "-" && "${cand}" != "(none)" ]]; then
    if _hm_pkg_do_version_gt "${cand}" "${inst}"; then
      [[ "${upg_count}" -eq 0 ]] && upg_count=1
    fi
  fi
  printf '%s\t%s\t%s\n' "${inst}" "${cand}" "${upg_count}"
}

_hm_pkg_do_version_gt() {
  # 0 = $1 nowsze niż $2
  local a="${1:-}" b="${2:-}"
  [[ -n "${a}" && -n "${b}" && "${a}" != "(none)" && "${b}" != "(none)" ]] || return 1
  hm_have_cmd dpkg || return 1
  dpkg --compare-versions "${a}" gt "${b}" 2>/dev/null
}

_hm_pkg_do_cache_age_info() {
  local f="" mtime now age_s
  now="$(date +%s)"
  if [[ -f /var/cache/apt/pkgcache.bin ]]; then
    f="/var/cache/apt/pkgcache.bin"
  elif [[ -d /var/lib/apt/lists ]]; then
    f="$(find /var/lib/apt/lists -type f 2>/dev/null | head -1 || true)"
  fi
  [[ -n "${f}" && -e "${f}" ]] || { printf 'wiek indeksu: nieznany'; return 0; }
  mtime="$(stat -c %Y "${f}" 2>/dev/null || echo 0)"
  age_s=$((now - mtime))
  [[ "${age_s}" -lt 0 ]] && age_s=0
  if [[ "${age_s}" -lt 120 ]]; then
    printf 'przed chwilą'
  elif [[ "${age_s}" -lt 3600 ]]; then
    printf '%s min temu' "$((age_s / 60))"
  elif [[ "${age_s}" -lt 86400 ]]; then
    printf '%s godz. temu' "$((age_s / 3600))"
  else
    local d=$((age_s / 86400))
    if [[ "${d}" -eq 1 ]]; then
      printf '1 dzień temu'
    else
      printf '%s dni temu' "${d}"
    fi
  fi
}

_hm_pkg_do_list_upgradable() {
  # name\tinstalled\tcandidate — portable (bez gawk match arr)
  LC_ALL=C apt list --upgradable 2>/dev/null | awk '
    NR == 1 { next }
    {
      line = $0
      # name/suite version arch [upgradable from: old]
      n = index(line, "/")
      if (n < 2) next
      name = substr(line, 1, n - 1)
      rest = substr(line, n + 1)
      split(rest, a, " ")
      cand = a[2]
      inst = ""
      if (match(line, /\[upgradable from: /)) {
        inst = substr(line, RSTART + RLENGTH)
        sub(/\].*/, "", inst)
      }
      printf "%s\t%s\t%s\n", name, inst, cand
    }'
}

_hm_pkg_do_list_security() {
  # pakiety z kandydatem z repo *-security* / UbuntuESM
  local name inst cand origin
  while IFS=$'\t' read -r name inst cand; do
    [[ -n "${name}" ]] || continue
    origin="$(LC_ALL=C apt-cache policy "${name}" 2>/dev/null | awk '
      /^[[:space:]]+[0-9]+/ {
        line=$0
        if (line ~ /security|Security|ESM/) { print "sec"; exit }
      }')"
    [[ "${origin}" == "sec" ]] && printf '%s\t%s\t%s\n' "${name}" "${inst}" "${cand}"
  done < <(_hm_pkg_do_list_upgradable)
}

_hm_pkg_do_upgrade_security() {
  if hm_have_cmd unattended-upgrade; then
    hm_run unattended-upgrade -v
    return $?
  fi
  local -a pkgs=()
  local name
  while IFS=$'\t' read -r name _ _; do
    [[ -n "${name}" ]] && pkgs+=("${name}")
  done < <(_hm_pkg_do_list_security)
  if [[ "${#pkgs[@]}" -eq 0 ]]; then
    hm_ok "Brak pakietów security do aktualizacji."
    return 0
  fi
  DEBIAN_FRONTEND=noninteractive hm_run apt-get install --only-upgrade -y "${pkgs[@]}"
}

_hm_pkg_do_upgrade_all() {
  # args: wzorce exclude (glob), np. mariadb*
  local -a excludes=("$@") hold=()
  local name skip ex rc
  if [[ "${#excludes[@]}" -gt 0 ]]; then
    while IFS=$'\t' read -r name _ _; do
      [[ -n "${name}" ]] || continue
      skip=0
      for ex in "${excludes[@]}"; do
        # shellcheck disable=SC2254
        case "${name}" in
          ${ex}) skip=1; break ;;
        esac
      done
      [[ "${skip}" -eq 1 ]] && hold+=("${name}")
    done < <(_hm_pkg_do_list_upgradable)
    if [[ "${#hold[@]}" -gt 0 ]]; then
      hm_info "Tymczasowy hold (exclude): ${hold[*]}"
      apt-mark hold "${hold[@]}" >/dev/null 2>&1 || true
    fi
  fi
  DEBIAN_FRONTEND=noninteractive hm_run apt-get upgrade -y
  rc=$?
  if [[ "${#hold[@]}" -gt 0 ]]; then
    apt-mark unhold "${hold[@]}" >/dev/null 2>&1 || true
  fi
  return "${rc}"
}

_hm_pkg_do_auto_security_status() {
  if [[ -d /etc/apt/apt.conf.d ]] && grep -RqsE 'Unattended-Upgrade::Allowed-Origins|"\$\{distro_id\}:\$\{distro_codename\}-security"' \
    /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null; then
    if systemctl is-enabled unattended-upgrades >/dev/null 2>&1 \
      || [[ -f /etc/apt/apt.conf.d/20auto-upgrades ]]; then
      printf 'on\n'
      return 0
    fi
  fi
  if [[ -f /etc/apt/apt.conf.d/20auto-upgrades ]] \
    && grep -qE 'APT::Periodic::Unattended-Upgrade[[:space:]]+"1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null; then
    printf 'on\n'
    return 0
  fi
  if hm_have_cmd unattended-upgrade || [[ -f /etc/apt/apt.conf.d/50unattended-upgrades ]]; then
    printf 'off\n'
    return 0
  fi
  printf 'unknown\n'
}

_hm_pkg_do_auto_security_set() {
  local mode="${1:-}"
  case "${mode}" in
    on)
      if ! hm_have_cmd unattended-upgrade && ! dpkg -l unattended-upgrades >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive hm_run apt-get install -y unattended-upgrades || return 1
      fi
      printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' \
        > /etc/apt/apt.conf.d/20auto-upgrades
      systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
      ;;
    off)
      printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "0";\n' \
        > /etc/apt/apt.conf.d/20auto-upgrades
      systemctl disable --now unattended-upgrades >/dev/null 2>&1 || true
      ;;
    *)
      hm_err "auto-security: oczekiwano on|off"
      return 1
      ;;
  esac
}

_hm_pkg_do_php_repo_label() {
  if [[ "${OS_ID:-}" == "ubuntu" ]]; then
    printf 'ondrej'
  else
    printf 'sury'
  fi
}

_hm_pkg_do_php_repo_add() {
  local label root keydir keyfile
  label="$(_hm_pkg_do_php_repo_label)"
  root="${HM_PKG_ROOT:-}"
  keydir="${root}/etc/apt/keyrings"
  mkdir -p "${keydir}" "${root}/etc/apt/sources.list.d"
  keyfile="${keydir}/hmtools-${label}.gpg"
  if [[ -n "${HM_PKG_PHP_KEY_FILE:-}" ]]; then
    cp "${HM_PKG_PHP_KEY_FILE}" "${keyfile}"
  else
    local keyurl
    case "${label}" in
      ondrej) keyurl="https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x4f4ea0aae5267a6c" ;;
      *) keyurl="https://packages.sury.org/php/apt.gpg" ;;
    esac
    hm_have_cmd curl || { hm_err "Brak curl — nie pobieram klucza PHP."; return 1; }
    hm_have_cmd gpg || { hm_err "Brak gpg — nie składam klucza PHP."; return 1; }
    curl -fsSL --max-time 60 "${keyurl}" | gpg --dearmor -o "${keyfile}"
  fi
  case "${label}" in
    ondrej)
      printf 'deb [signed-by=%s] https://ppa.launchpadcontent.net/ondrej/php/ubuntu %s main\n' \
        "${keyfile}" "${HM_OS_CODENAME:-noble}" \
        > "${root}/etc/apt/sources.list.d/hmtools-php.list"
      ;;
    *)
      printf 'deb [signed-by=%s] https://packages.sury.org/php/ %s main\n' \
        "${keyfile}" "${HM_OS_CODENAME:-bookworm}" \
        > "${root}/etc/apt/sources.list.d/hmtools-php.list"
      ;;
  esac
  if [[ -n "${HM_PKG_PHP_LOG:-}" ]]; then
    printf 'repo-add %s\n' "${label}" >> "${HM_PKG_PHP_LOG}"
  fi
}

_hm_pkg_do_php_package_names() {
  local ver="$1" sapi="$2" ext sfx
  shift 2 || return 1
  if [[ "${sapi}" == "lsphp" ]]; then
    sfx="${ver//./}"
    printf 'lsphp%s\n' "${sfx}"
    for ext in "$@"; do
      [[ -n "${ext}" ]] || continue
      printf 'lsphp%s-%s\n' "${sfx}" "${ext}"
    done
    return 0
  fi
  printf 'php%s-fpm\n' "${ver}"
  printf 'php%s-cli\n' "${ver}"
  for ext in "$@"; do
    [[ -n "${ext}" ]] || continue
    case "${ext}" in
      ctype|iconv|tokenizer|mbstring) continue ;;
      pdo_mysql) printf 'php%s-mysql\n' "${ver}" ;;
      pdo_pgsql) printf 'php%s-pgsql\n' "${ver}" ;;
      *) printf 'php%s-%s\n' "${ver}" "${ext}" ;;
    esac
  done
}

_hm_pkg_do_php_pool_dir() {
  printf '%s/etc/php/%s/fpm/pool.d' "${HM_PKG_ROOT:-}" "${1:-}"
}

_hm_pkg_do_php_fpm_check() {
  local ver="$1"
  if [[ "${HM_SITE_PHP_FPM_TEST:-}" == "fail" ]]; then
    return 1
  fi
  if [[ "${HM_SITE_PHP_FPM_TEST:-}" == "ok" || -n "${HM_PKG_ROOT:-}" ]]; then
    return 0
  fi
  local bin="php-fpm${ver}"
  if ! hm_have_cmd "${bin}"; then
    bin="php-fpm"
  fi
  hm_have_cmd "${bin}" || { hm_err "Brak ${bin}."; return 1; }
  "${bin}" -t
}
