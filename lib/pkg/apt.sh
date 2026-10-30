#!/usr/bin/env bash
# Adapter pakietów: apt (Debian/Ubuntu). Funkcje _hm_pkg_do_* — kontrakt lib/pkg.sh.

_hm_pkg_do_refresh() {
  hm_info "Odświeżanie list pakietów (apt-get update)…"
  hm_run apt-get update
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
