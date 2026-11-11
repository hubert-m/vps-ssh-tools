#!/usr/bin/env bash
# Publiczne API menedżera pakietów (apt | dnf | yum).
# Feature’y wołają tylko hm_pkg_* — nigdy bezpośrednio apt-get/dnf/yum.
# Adaptery: lib/pkg/apt.sh | lib/pkg/rpm.sh; opcjonalnie lib/pkg/overrides/${OS_ID}.sh

if [[ -n "${HMTOOLS_PKG_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_PKG_LOADED=1

HMTOOLS_PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pkg"
HM_PKG_BACKEND_KEY=""

# --- Detekcja ID -------------------------------------------------------------

hm_pkg_id() {
  # stdout: apt | dnf | yum ; rc≠0 gdy brak
  local forced="${FORCE_PKG_MANAGER:-}"
  if [[ -n "${forced}" ]]; then
    case "${forced}" in
      apt|dnf|yum)
        printf '%s' "${forced}"
        return 0
        ;;
      *)
        # ostrzeżenie raz na proces (detect też waliduje)
        if [[ "${_HM_FORCE_PKG_WARNED:-0}" != "1" ]]; then
          _HM_FORCE_PKG_WARNED=1
          hm_warn "FORCE_PKG_MANAGER='${forced}' spoza listy (apt|dnf|yum) — używam auto-detekcji." 2>/dev/null || true
        fi
        ;;
    esac
  fi
  if [[ -n "${PKG_MANAGER:-}" && "${PKG_MANAGER}" != "unknown" ]]; then
    case "${PKG_MANAGER}" in
      apt|dnf|yum)
        printf '%s' "${PKG_MANAGER}"
        return 0
        ;;
    esac
  fi
  # Rodzina OS przed samym PATH — unikaj apt-get na RPM (fałszywy „apt”)
  case "${OS_FAMILY:-}" in
    rhel)
      if hm_have_cmd dnf; then
        printf 'dnf'
        return 0
      fi
      if hm_have_cmd yum; then
        printf 'yum'
        return 0
      fi
      ;;
    debian)
      if hm_have_cmd apt-get; then
        printf 'apt'
        return 0
      fi
      ;;
  esac
  if hm_have_cmd apt-get; then
    printf 'apt'
    return 0
  fi
  if hm_have_cmd dnf; then
    printf 'dnf'
    return 0
  fi
  if hm_have_cmd yum; then
    printf 'yum'
    return 0
  fi
  return 1
}

# Alias wstecznie kompatybilny
hm_pkg_manager() {
  hm_pkg_id "$@"
}

hm_pkg_backend_family() {
  case "$(hm_pkg_id 2>/dev/null || true)" in
    apt) printf 'apt' ;;
    dnf|yum) printf 'rpm' ;;
    *) return 1 ;;
  esac
}

# --- Bind adaptera (+ override OS_ID) ----------------------------------------

hm_pkg_bind() {
  local fam pm key override
  fam="$(hm_pkg_backend_family)" || {
    hm_err "Brak wspieranego menedżera pakietów (apt/dnf/yum)."
    return 1
  }
  pm="$(hm_pkg_id)" || return 1
  key="${fam}:${pm}:${OS_ID:-}"
  if [[ "${HM_PKG_BACKEND_KEY}" == "${key}" ]]; then
    return 0
  fi
  case "${fam}" in
    apt)
      # shellcheck source=pkg/apt.sh
      source "${HMTOOLS_PKG_DIR}/apt.sh"
      ;;
    rpm)
      # shellcheck source=pkg/rpm.sh
      source "${HMTOOLS_PKG_DIR}/rpm.sh"
      ;;
    *)
      return 1
      ;;
  esac
  if [[ -n "${OS_ID:-}" && -f "${HMTOOLS_PKG_DIR}/overrides/${OS_ID}.sh" ]]; then
    # shellcheck disable=SC1090
    source "${HMTOOLS_PKG_DIR}/overrides/${OS_ID}.sh"
  fi
  HM_PKG_BACKEND_KEY="${key}"
  return 0
}

# Domyślne stuby (nadpisywane przez adapter)
_hm_pkg_do_refresh() { hm_err "pkg: brak załadowanego adaptera (refresh)"; return 1; }
_hm_pkg_do_install() { hm_err "pkg: brak załadowanego adaptera (install)"; return 1; }
_hm_pkg_do_upgrade() { hm_err "pkg: brak załadowanego adaptera (upgrade)"; return 1; }
_hm_pkg_do_list_installed() { return 0; }
_hm_pkg_do_candidate() { printf '-'; }
_hm_pkg_do_list_available_bases() { return 0; }
_hm_pkg_do_status_for() { printf -- '-\t-\t0\n'; }
_hm_pkg_do_version_gt() { return 1; }
_hm_pkg_do_cache_age_info() { printf 'nieznany'; }
_hm_pkg_do_list_upgradable() { return 0; }
_hm_pkg_do_list_security() { return 0; }
_hm_pkg_do_upgrade_security() { hm_err "pkg: brak adaptera (upgrade_security)"; return 1; }
_hm_pkg_do_upgrade_all() { hm_err "pkg: brak adaptera (upgrade_all)"; return 1; }
_hm_pkg_do_auto_security_status() { printf 'unknown\n'; }
_hm_pkg_do_auto_security_set() { hm_err "pkg: brak adaptera (auto_security)"; return 1; }
_hm_pkg_do_php_repo_label() { printf 'php'; }
_hm_pkg_do_php_repo_add() { hm_err "pkg: brak adaptera (php repo)"; return 1; }
_hm_pkg_do_php_package_names() { hm_err "pkg: brak adaptera (php packages)"; return 1; }
_hm_pkg_do_php_pool_dir() { printf '%s/etc/php/%s/fpm/pool.d' "${HM_PKG_ROOT:-}" "${1:-}"; }
_hm_pkg_do_php_fpm_check() { return 0; }

# --- Publiczne API -----------------------------------------------------------

hm_pkg_refresh() {
  hm_pkg_bind || return 1
  _hm_pkg_do_refresh "$@"
}

hm_pkg_install() {
  hm_pkg_bind || return 1
  _hm_pkg_do_install "$@"
}

hm_pkg_upgrade() {
  hm_pkg_bind || return 1
  _hm_pkg_do_upgrade "$@"
}

hm_pkg_list_installed() {
  hm_pkg_bind || return 1
  _hm_pkg_do_list_installed "$@"
}

hm_pkg_candidate() {
  hm_pkg_bind || { printf '-'; return 1; }
  _hm_pkg_do_candidate "$@"
}

hm_pkg_list_available_bases() {
  hm_pkg_bind || return 1
  _hm_pkg_do_list_available_bases "$@"
}

# stdout: installed<TAB>candidate<TAB>upgradable_count
hm_pkg_status_for() {
  hm_pkg_bind || { printf -- '-\t-\t0\n'; return 1; }
  _hm_pkg_do_status_for "$@"
}

# 0 = $1 nowsze niż $2
hm_pkg_version_gt() {
  hm_pkg_bind || return 1
  _hm_pkg_do_version_gt "$@"
}

hm_pkg_cache_age_info() {
  if ! hm_pkg_bind 2>/dev/null; then
    printf 'nieznany'
    return 0
  fi
  _hm_pkg_do_cache_age_info "$@"
}

hm_pkg_label() {
  case "$(hm_pkg_id 2>/dev/null || true)" in
    apt) printf 'apt-cache' ;;
    dnf) printf 'dnf' ;;
    yum) printf 'yum' ;;
    *) printf 'pakiety' ;;
  esac
}

# stdout: nazwa_pakietu[TAB]zainstalowana[TAB]kandydat (jedna linia / pakiet)
hm_pkg_list_upgradable() {
  hm_pkg_bind || return 1
  _hm_pkg_do_list_upgradable "$@"
}

# stdout: jak list_upgradable, tylko security
hm_pkg_list_security() {
  hm_pkg_bind || return 1
  _hm_pkg_do_list_security "$@"
}

hm_pkg_upgrade_security() {
  hm_pkg_bind || return 1
  _hm_pkg_do_upgrade_security "$@"
}

# upgrade wszystkich (lub z --exclude wzorcami przekazanymi jako args)
hm_pkg_upgrade_all() {
  hm_pkg_bind || return 1
  _hm_pkg_do_upgrade_all "$@"
}

# stdout: on|off|unknown
hm_pkg_auto_security_status() {
  hm_pkg_bind || { printf 'unknown\n'; return 1; }
  _hm_pkg_do_auto_security_status "$@"
}

# $1 = on|off
hm_pkg_auto_security_set() {
  hm_pkg_bind || return 1
  _hm_pkg_do_auto_security_set "$@"
}

hm_pkg_php_repo_label() {
  hm_pkg_bind || return 1
  _hm_pkg_do_php_repo_label "$@"
}

# $1 = gałąź X.Y (dla Remi). Zapis klucza do keyrings, bez apt-key.
hm_pkg_php_repo_add() {
  hm_pkg_bind || return 1
  _hm_pkg_do_php_repo_add "$@"
}

# Lista php*-fpm z repozytorium OS (apt-cache policy albo dnf list). Stdout do parsera.
hm_pkg_php_fpm_query() {
  hm_pkg_bind || return 1
  _hm_pkg_do_php_fpm_query "$@"
}

# $1=X.Y $2=fpm|lsphp  reszta: nazwy rozszerzeń. Stdout: paczki, jedna na linię.
hm_pkg_php_package_names() {
  hm_pkg_bind || return 1
  _hm_pkg_do_php_package_names "$@"
}

hm_pkg_php_pool_dir() {
  hm_pkg_bind || return 1
  _hm_pkg_do_php_pool_dir "$@"
}

# $1=X.Y $2=plik puli. 0 gdy php-fpm -t przechodzi.
hm_pkg_php_fpm_check() {
  hm_pkg_bind || return 1
  _hm_pkg_do_php_fpm_check "$@"
}
