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
  cand="$(printf '%s\n' "${chk}" | awk -v p="^${name}" '$1 ~ p { print $2; exit }')"
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
  chk="$(LC_ALL=C "${cli}" -q -C check-update "${main}*" 2>/dev/null || true)"
  cand="$(printf '%s\n' "${chk}" | awk -v p="^${main}" '$1 ~ p { print $2; exit }')"
  upg_count="$(printf '%s\n' "${chk}" | awk -v p="^${main}" '$1 ~ p { c++ } END { print c+0 }')"
  if [[ -z "${cand}" ]]; then
    cand="${inst}"
  fi
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
    printf '%s dni temu' "$((age_s / 86400))"
  fi
}
