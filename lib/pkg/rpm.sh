#!/usr/bin/env bash
# Adapter pakietów: dnf/yum (RHEL/Alma/Rocky/CentOS). Funkcje _hm_pkg_do_* — kontrakt lib/pkg.sh.

_hm_pkg_rpm_cli() {
  # aktualny CLI: dnf lub yum
  case "$(hm_pkg_id 2>/dev/null || echo dnf)" in
    yum) printf 'yum' ;;
    *) printf 'dnf' ;;
  esac
}

_hm_pkg_do_refresh() {
  local cli
  cli="$(_hm_pkg_rpm_cli)"
  hm_info "Odświeżanie cache (${cli} makecache)…"
  hm_run "${cli}" makecache -y || true
}

_hm_pkg_do_install() {
  local cli
  cli="$(_hm_pkg_rpm_cli)"
  hm_run "${cli}" install -y "$@"
}

_hm_pkg_do_upgrade() {
  local cli
  cli="$(_hm_pkg_rpm_cli)"
  hm_run "${cli}" update -y "$@"
}

_hm_pkg_do_list_installed() {
  local pattern="${1:-}"
  [[ -n "${pattern}" ]] || return 0
  if hm_have_cmd rpm; then
    rpm -qa --qf '%{NAME}\n' "${pattern}" 2>/dev/null || true
  fi
}

_hm_pkg_do_candidate() {
  local name="${1:-}"
  [[ -n "${name}" ]] || { printf '-'; return 0; }
  local cli cand inst chk
  cli="$(_hm_pkg_rpm_cli)"
  inst="-"
  if hm_have_cmd rpm; then
    inst="$(rpm -q --qf '%{VERSION}-%{RELEASE}' "${name}" 2>/dev/null || echo '-')"
    [[ "${inst}" == *"not installed"* ]] && inst="-"
  fi
  chk="$(LC_ALL=C "${cli}" -q -C check-update "${name}" 2>/dev/null || true)"
  # dnf: „lsphp81.x86_64  ver  repo” — zdejmij arch przed porównaniem; nie prefix subpakietów
  cand="$(printf '%s\n' "${chk}" | awk -v main="${name}" '
    {
      n=$1; sub(/\.[^.]+$/, "", n)
      if (n == main) { print $2; exit }
    }')"
  if [[ -z "${cand}" ]]; then
    cand="${inst}"
  fi
  [[ -n "${cand}" ]] || cand="-"
  printf '%s' "${cand}"
}

_hm_pkg_do_list_available_bases() {
  local prefix="${1:-}"
  [[ -n "${prefix}" ]] || return 0
  local cli name ver sfx
  cli="$(_hm_pkg_rpm_cli)"
  while IFS=$'\t' read -r name ver; do
    [[ -n "${name}" ]] || continue
    [[ "${name}" =~ ^${prefix}([0-9]+)$ ]] || continue
    sfx="${BASH_REMATCH[1]}"
    [[ -n "${ver}" && "${ver}" != "(none)" ]] || continue
    printf '%s\t%s\n' "${sfx}" "${ver}"
  done < <(
    LC_ALL=C "${cli}" -q -C repoquery --qf '%{name}\t%{version}-%{release}' "${prefix}[0-9][0-9]" 2>/dev/null \
      || true
  )
}

_hm_pkg_do_status_for() {
  local main="${1:-}"
  [[ -n "${main}" ]] || { printf -- '-\t-\t0\n'; return 0; }
  local cli inst="-" cand="" upg_count=0 chk
  cli="$(_hm_pkg_rpm_cli)"
  if hm_have_cmd rpm; then
    inst="$(rpm -q --qf '%{VERSION}-%{RELEASE}' "${main}" 2>/dev/null || echo '-')"
    [[ "${inst}" == *"not installed"* ]] && inst="-"
  fi
  # tylko dokładny pakiet main (nazwa.arch z check-update → strip arch)
  chk="$(LC_ALL=C "${cli}" -q -C check-update "${main}" 2>/dev/null || true)"
  cand="$(printf '%s\n' "${chk}" | awk -v main="${main}" '
    {
      n=$1; sub(/\.[^.]+$/, "", n)
      if (n == main) { print $2; exit }
    }')"
  upg_count="$(printf '%s\n' "${chk}" | awk -v main="${main}" '
    {
      n=$1; sub(/\.[^.]+$/, "", n)
      if (n == main) c++
    }
    END { print c+0 }')"
  if [[ -z "${cand}" ]]; then
    cand="${inst}"
  fi
  # subpakiety: osobne check-update main-* (nie myli wersji głównego; name.arch OK przez ^main-)
  local sub_chk
  sub_chk="$(LC_ALL=C "${cli}" -q -C check-update "${main}-*" 2>/dev/null || true)"
  local sub_n
  sub_n="$(printf '%s\n' "${sub_chk}" | awk -v p="^${main}-" '
    {
      n=$1; sub(/\.[^.]+$/, "", n)
      if (n ~ p) c++
    }
    END { print c+0 }')"
  upg_count=$((upg_count + sub_n))
  [[ -n "${cand}" ]] || cand="-"
  printf '%s\t%s\t%s\n' "${inst}" "${cand}" "${upg_count:-0}"
}

_hm_pkg_do_version_gt() {
  # 0 = $1 nowsze niż $2 (sort -V)
  local a="${1:-}" b="${2:-}" top
  [[ -n "${a}" && -n "${b}" && "${a}" != "-" && "${b}" != "-" ]] || return 1
  [[ "${a}" == "${b}" ]] && return 1
  top="$(printf '%s\n%s\n' "${a}" "${b}" | sort -V | tail -1)"
  [[ "${top}" == "${a}" ]]
}

_hm_pkg_do_cache_age_info() {
  local f="" mtime now age_s
  now="$(date +%s)"
  if [[ -d /var/cache/dnf ]]; then
    f="$(find /var/cache/dnf -type f 2>/dev/null | head -1 || true)"
  elif [[ -d /var/cache/yum ]]; then
    f="$(find /var/cache/yum -type f 2>/dev/null | head -1 || true)"
  fi
  [[ -n "${f}" && -e "${f}" ]] || { printf 'nieznany'; return 0; }
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
  local cli
  cli="$(_hm_pkg_rpm_cli)"
  # name\tinstalled\tcandidate — check-update: name.arch ver repo
  LC_ALL=C "${cli}" -q check-update 2>/dev/null | awk '
    NF >= 2 && $1 !~ /^Obsoleting/ && $1 !~ /^Security/ {
      n = $1
      sub(/\.[^.]+$/, "", n)
      printf "%s\t-\t%s\n", n, $2
    }' || true
}

_hm_pkg_do_list_security() {
  local cli
  cli="$(_hm_pkg_rpm_cli)"
  if LC_ALL=C "${cli}" updateinfo list security 2>/dev/null | grep -q .; then
    LC_ALL=C "${cli}" -q updateinfo list security 2>/dev/null | awk '
      NF >= 3 {
        # typ ID pkg
        n = $NF
        sub(/\.[^.]+$/, "", n)
        printf "%s\t-\t-\n", n
      }' || true
    return 0
  fi
  # yum --security check-update
  LC_ALL=C "${cli}" -q --security check-update 2>/dev/null | awk '
    NF >= 2 && $1 !~ /^Obsoleting/ {
      n = $1
      sub(/\.[^.]+$/, "", n)
      printf "%s\t-\t%s\n", n, $2
    }' || true
}

_hm_pkg_do_upgrade_security() {
  local cli
  cli="$(_hm_pkg_rpm_cli)"
  hm_run "${cli}" update -y --security
}

_hm_pkg_do_upgrade_all() {
  local cli
  cli="$(_hm_pkg_rpm_cli)"
  local -a args=(-y) excludes=("$@") ex
  for ex in "${excludes[@]}"; do
    [[ -n "${ex}" ]] && args+=(--exclude="${ex}")
  done
  hm_run "${cli}" update "${args[@]}"
}

_hm_pkg_do_auto_security_status() {
  if systemctl is-enabled dnf-automatic.timer >/dev/null 2>&1 \
    || systemctl is-enabled dnf-automatic-install.timer >/dev/null 2>&1; then
    printf 'on\n'
    return 0
  fi
  if [[ -f /etc/dnf/automatic.conf ]] || hm_have_cmd dnf-automatic; then
    printf 'off\n'
    return 0
  fi
  printf 'unknown\n'
}

_hm_pkg_do_auto_security_set() {
  local mode="${1:-}" cli
  cli="$(_hm_pkg_rpm_cli)"
  case "${mode}" in
    on)
      if ! rpm -q dnf-automatic >/dev/null 2>&1; then
        hm_run "${cli}" install -y dnf-automatic || return 1
      fi
      if [[ -f /etc/dnf/automatic.conf ]]; then
        sed -i -E 's/^[[:space:]]*apply_updates[[:space:]]*=.*/apply_updates = yes/' /etc/dnf/automatic.conf 2>/dev/null || true
        sed -i -E 's/^[[:space:]]*upgrade_type[[:space:]]*=.*/upgrade_type = security/' /etc/dnf/automatic.conf 2>/dev/null || true
      fi
      systemctl enable --now dnf-automatic.timer >/dev/null 2>&1 \
        || systemctl enable --now dnf-automatic-install.timer >/dev/null 2>&1 \
        || true
      ;;
    off)
      systemctl disable --now dnf-automatic.timer >/dev/null 2>&1 || true
      systemctl disable --now dnf-automatic-install.timer >/dev/null 2>&1 || true
      ;;
    *)
      hm_err "auto-security: oczekiwano on|off"
      return 1
      ;;
  esac
}

_hm_pkg_do_php_repo_label() {
  printf 'remi'
}

_hm_pkg_do_php_repo_add() {
  local ver="${1:-}" root cli rel
  [[ "${ver}" =~ ^[0-9]+\.[0-9]+$ ]] || { hm_err "Zła gałąź Remi: ${ver}"; return 1; }
  root="${HM_PKG_ROOT:-}"
  if [[ -n "${root}" ]]; then
    mkdir -p "${root}/etc/yum.repos.d"
    printf 'php:remi-%s\n' "${ver}" > "${root}/etc/yum.repos.d/hmtools-remi.repo"
  else
    cli="$(_hm_pkg_rpm_cli)"
    rel="$(rpm -E %rhel 2>/dev/null || echo 9)"
    hm_run "${cli}" install -y "https://rpms.remirepo.net/enterprise/remi-release-${rel}.rpm" || return 1
    hm_run "${cli}" module enable -y "php:remi-${ver}" || return 1
  fi
  if [[ -n "${HM_PKG_PHP_LOG:-}" ]]; then
    printf 'dnf module enable php:remi-%s\n' "${ver}" >> "${HM_PKG_PHP_LOG}"
  fi
}

_hm_pkg_do_php_package_names() {
  local ver="$1" _sapi="$2" ext scl
  shift 2 || return 1
  scl="php${ver//./}"
  printf '%s-php-fpm\n' "${scl}"
  printf '%s-php-cli\n' "${scl}"
  for ext in "$@"; do
    [[ -n "${ext}" ]] || continue
    case "${ext}" in
      ctype|iconv|tokenizer|mbstring) continue ;;
      *) printf '%s-php-%s\n' "${scl}" "${ext}" ;;
    esac
  done
}

_hm_pkg_do_php_pool_dir() {
  local ver="${1:-}"
  printf '%s/etc/opt/remi/php%s/php-fpm.d' "${HM_PKG_ROOT:-}" "${ver//./}"
}

_hm_pkg_do_php_fpm_query() {
  if hm_have_cmd dnf; then
    dnf list --available --installed 'php*-php-fpm' 2>/dev/null || true
    return 0
  fi
  if hm_have_cmd yum; then
    yum list 'php*-php-fpm' 2>/dev/null || true
    return 0
  fi
  return 1
}

_hm_pkg_do_php_fpm_check() {
  if [[ "${HM_SITE_PHP_FPM_TEST:-}" == "fail" ]]; then
    return 1
  fi
  return 0
}
