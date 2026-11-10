#!/usr/bin/env bash
# Runtime PHP dla site new: wersje, repo (sury/ondrej/remi), FPM per serwis, Composer.

if [[ -n "${HMTOOLS_SITE_PHP_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_SITE_PHP_LOADED=1

hm_site_php_preset_exts() {
  case "${1:-minimal}" in
    laravel) printf '%s\n' bcmath ctype curl intl mbstring pdo_mysql pdo_pgsql redis xml zip gd ;;
    wordpress) printf '%s\n' gd mysqli zip intl exif ;;
    symfony) printf '%s\n' ctype curl iconv intl mbstring pdo_mysql xml zip tokenizer ;;
    minimal|"") return 0 ;;
    *) hm_err "Nieznany preset PHP: ${1}"; return 1 ;;
  esac
}

hm_site_php_support_of() {
  local ver="$1" v st until
  if [[ -n "${HM_PHP_SUPPORT_FILE:-}" && -f "${HM_PHP_SUPPORT_FILE}" ]]; then
    while read -r v st until _; do
      [[ "${v}" == "${ver}" ]] || continue
      printf '%s\t%s' "${st}" "${until:-}"
      return 0
    done < "${HM_PHP_SUPPORT_FILE}"
  fi
  case "${ver}" in
    8.5|8.4) printf 'active\t' ;;
    8.3) printf 'security\t2027-12-31' ;;
    8.2) printf 'security\t2026-12-31' ;;
    *) printf 'eol\t' ;;
  esac
}

hm_site_php_parse_apt_policy() {
  local file="$1" line ver="" inst="" cand=""
  [[ -f "${file}" ]] || return 1
  _hm_site_php_flush_policy() {
    [[ -n "${ver}" ]] || return 0
    if [[ -n "${inst}" && "${inst}" != "(none)" ]]; then
      printf '%s\tinstalled\n' "${ver}"
    elif [[ -n "${cand}" && "${cand}" != "(none)" ]]; then
      printf '%s\trepo\n' "${ver}"
    else
      printf '%s\tmissing\n' "${ver}"
    fi
  }
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" =~ ^php([0-9]+\.[0-9]+)-fpm: ]]; then
      _hm_site_php_flush_policy
      ver="${BASH_REMATCH[1]}"
      inst=""
      cand=""
    elif [[ "${line}" =~ ^[[:space:]]*Installed:[[:space:]]*(.*)$ ]]; then
      inst="${BASH_REMATCH[1]}"
      inst="${inst%"${inst##*[![:space:]]}"}"
    elif [[ "${line}" =~ ^[[:space:]]*Candidate:[[:space:]]*(.*)$ ]]; then
      cand="${BASH_REMATCH[1]}"
      cand="${cand%"${cand##*[![:space:]]}"}"
    fi
  done < "${file}"
  _hm_site_php_flush_policy
}

hm_site_php_parse_dnf_list() {
  local file="$1" line ver kind
  [[ -f "${file}" ]] || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" =~ ^php([0-9])([0-9])-php-fpm ]] || continue
    ver="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
    if [[ "${line}" == *"@"* ]]; then
      kind="installed"
    else
      kind="repo"
    fi
    printf '%s\t%s\n' "${ver}" "${kind}"
  done < "${file}"
}

# stdout: version \t installed|repo|extra
hm_site_php_versions() {
  local -a seen=()
  local line ver kind
  _hm_site_php_take() {
    local v="$1" k="$2" s
    [[ -n "${v}" && -n "${k}" ]] || return 0
    for s in "${seen[@]+"${seen[@]}"}"; do
      [[ "${s}" == "${v}" ]] && return 0
    done
    seen+=("${v}")
    printf '%s\t%s\n' "${v}" "${k}"
  }
  if [[ -n "${HM_PHP_POLICY_FILE:-}" ]]; then
    while IFS=$'\t' read -r ver kind; do
      [[ "${kind}" == "missing" ]] && continue
      _hm_site_php_take "${ver}" "${kind}"
    done < <(hm_site_php_parse_apt_policy "${HM_PHP_POLICY_FILE}")
  fi
  if [[ -n "${HM_PHP_DNF_FILE:-}" ]]; then
    while IFS=$'\t' read -r ver kind; do
      _hm_site_php_take "${ver}" "${kind}"
    done < <(hm_site_php_parse_dnf_list "${HM_PHP_DNF_FILE}")
  fi
  if [[ -n "${HM_PHP_EXTRA_FILE:-}" && -f "${HM_PHP_EXTRA_FILE}" ]]; then
    while read -r ver _; do
      [[ "${ver}" =~ ^[0-9]+\.[0-9]+$ ]] || continue
      _hm_site_php_take "${ver}" "extra"
    done < "${HM_PHP_EXTRA_FILE}"
  fi
}

hm_site_php_status_label() {
  case "${1:-}" in
    installed) printf 'zainstalowana' ;;
    repo) printf 'dostępna w repo' ;;
    *) printf 'wymaga dodania repo' ;;
  esac
}

hm_site_php_print_catalog() {
  local ver kind st until label star def
  def="$(hm_site_php_default_version || true)"
  while IFS=$'\t' read -r ver kind; do
    [[ -n "${ver}" ]] || continue
    IFS=$'\t' read -r st until <<<"$(hm_site_php_support_of "${ver}")"
    label="$(hm_site_php_status_label "${kind}")"
    star=""
    [[ "${ver}" == "${def}" ]] && star="*"
    if [[ -n "${until}" && "${st}" == "security" ]]; then
      printf '%s\t%s\t%s (do %s)\t%s\n' "${ver}" "${label}" "${st}" "${until}" "${star}"
    else
      printf '%s\t%s\t%s\t%s\n' "${ver}" "${label}" "${st}" "${star}"
    fi
  done < <(hm_site_php_versions)
}

hm_site_php_default_version() {
  local ver kind st best=""
  while IFS=$'\t' read -r ver kind; do
    [[ -n "${ver}" ]] || continue
    IFS=$'\t' read -r st _ <<<"$(hm_site_php_support_of "${ver}")"
    [[ "${st}" == "active" ]] || continue
    if [[ -z "${best}" ]]; then
      best="${ver}"
    else
      best="$(printf '%s\n%s\n' "${best}" "${ver}" | sort -V | tail -1)"
    fi
  done < <(hm_site_php_versions)
  [[ -n "${best}" ]] || return 1
  printf '%s' "${best}"
}

hm_site_php_kind() {
  local want="$1" ver kind
  while IFS=$'\t' read -r ver kind; do
    if [[ "${ver}" == "${want}" ]]; then
      printf '%s' "${kind}"
      return 0
    fi
  done < <(hm_site_php_versions)
  return 1
}

hm_site_php_ensure_repo() {
  local ver="$1" yes="${2:-0}" label
  label="$(hm_pkg_php_repo_label)" || return 1
  local -a steps=("Dodanie repozytorium ${label} dla PHP ${ver}" "Klucz GPG w /etc/apt/keyrings albo marker Remi (bez apt-key)")
  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "Repozytorium PHP — ${label}" "Dopiero po zgodzie." --yes "${steps[@]}" || return 1
  else
    hm_confirm_plan "Repozytorium PHP — ${label}" "Dopiero po zgodzie." "${steps[@]}" || return 1
  fi
  hm_pkg_php_repo_add "${ver}" || return 1
  hm_pkg_refresh || true
}

hm_site_php_pkg_missing() {
  local pkg="$1"
  if [[ -n "${HM_PHP_INSTALLED_LIST:-}" && -f "${HM_PHP_INSTALLED_LIST}" ]]; then
    grep -qx "${pkg}" "${HM_PHP_INSTALLED_LIST}" && return 1
    return 0
  fi
  if hm_pkg_list_installed "${pkg}" 2>/dev/null | grep -qx "${pkg}"; then
    return 1
  fi
  return 0
}

hm_site_php_install_exts() {
  local ver="$1" sapi="$2"
  shift 2 || true
  local pkg
  local -a need=() names=()
  while IFS= read -r pkg; do
    [[ -n "${pkg}" ]] && names+=("${pkg}")
  done < <(hm_pkg_php_package_names "${ver}" "${sapi}" "$@")
  for pkg in "${names[@]+"${names[@]}"}"; do
    if hm_site_php_pkg_missing "${pkg}"; then
      need+=("${pkg}")
    fi
  done
  [[ "${#need[@]}" -eq 0 ]] && return 0
  hm_pkg_install "${need[@]}"
}

hm_site_php_children() {
  local ram="${HM_SITE_PHP_RAM_MB:-}"
  if [[ -z "${ram}" && -r /proc/meminfo ]]; then
    ram="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null || true)"
  fi
  [[ "${ram}" =~ ^[0-9]+$ ]] || ram=1024
  local n=$((ram / 128))
  [[ "${n}" -lt 2 ]] && n=2
  [[ "${n}" -gt 20 ]] && n=20
  printf '%s' "${n}"
}

hm_site_php_write_pool() {
  local domain="$1" ver="$2" user="$3" home="$4" sapi="${5:-fpm}"
  local dir pool bak group kids sock
  if [[ "${sapi}" == "lsphp" ]]; then
    mkdir -p "${home}/.hmtools" "${home}/logs"
    sock="${home}/.hmtools/${user}.sock"
    cat > "${home}/.hmtools/extprocessor.conf" <<EOF
extprocessor ${user} {
  type                    lsapi
  address                 ${sock}
  maxConns                10
  env                     LSAPI_CHILDREN=$(hm_site_php_children)
  autoStart               1
  path                    ${home}/lsphp/bin/lsphp
  user                    ${user}
  group                   ${user}
}
EOF
    printf '%s' "${home}/.hmtools/extprocessor.conf"
    return 0
  fi
  dir="$(hm_pkg_php_pool_dir "${ver}")" || return 1
  mkdir -p "${dir}" "${home}/logs"
  pool="${dir}/${domain}.conf"
  bak="${pool}.hmbak"
  rm -f "${bak}"
  if [[ -f "${pool}" ]]; then
    cp "${pool}" "${bak}"
  fi
  group="${HM_SITE_PHP_WEB_GROUP:-}"
  if [[ -z "${group}" ]] && declare -F hm_os_web_group >/dev/null 2>&1; then
    group="$(hm_os_web_group 2>/dev/null || true)"
  fi
  [[ -n "${group}" ]] || group="www-data"
  kids="$(hm_site_php_children)"
  sock="/run/php/${domain}.sock"
  cat > "${pool}" <<EOF
[${domain}]
user = ${user}
group = ${user}
listen = ${sock}
listen.owner = ${group}
listen.group = ${group}
listen.mode = 0660
pm = ondemand
pm.max_children = ${kids}
pm.process_idle_timeout = 10s
php_admin_value[open_basedir] = ${home}:/tmp
php_admin_value[upload_max_filesize] = 64M
php_admin_value[memory_limit] = 256M
php_admin_value[error_log] = ${home}/logs/php-error.log
slowlog = ${home}/logs/php-slow.log
EOF
  if [[ "${HM_SITE_PHP_HARDEN:-}" == "1" ]]; then
    printf '%s\n' 'php_admin_value[disable_functions] = exec,passthru,shell_exec,system,proc_open,popen' >> "${pool}"
  fi
  if ! hm_pkg_php_fpm_check "${ver}" "${pool}"; then
    if [[ -f "${bak}" ]]; then
      mv -f "${bak}" "${pool}"
    else
      rm -f "${pool}"
    fi
    hm_err "php-fpm${ver} -t nieudany — przywrócono poprzednią pulę."
    return 1
  fi
  rm -f "${bak}"
  chmod 0750 "${home}" 2>/dev/null || true
  printf '%s' "${pool}"
}

hm_site_php_composer() {
  local domain="$1" home bin dir sum sig
  home="$(hm_site_home "${domain}")"
  dir="${home}/.local/bin"
  mkdir -p "${dir}"
  bin="${dir}/composer"
  if [[ -n "${HM_COMPOSER_PHAR:-}" && -f "${HM_COMPOSER_PHAR}" ]]; then
    cp "${HM_COMPOSER_PHAR}" "${bin}"
  else
    hm_have_cmd curl || { hm_err "Brak curl — nie pobieram Composera."; return 1; }
    curl -fsSL --max-time 60 -o "${bin}" "https://getcomposer.org/download/latest-stable/composer.phar" || return 1
  fi
  if [[ -n "${HM_COMPOSER_SIG:-}" && -f "${HM_COMPOSER_SIG}" ]]; then
    sig="$(tr -d '[:space:]' < "${HM_COMPOSER_SIG}")"
  else
    hm_have_cmd curl || { rm -f "${bin}"; return 1; }
    sig="$(curl -fsSL --max-time 30 "https://getcomposer.org/download/latest-stable/composer.phar.sha384" | tr -d '[:space:]')"
  fi
  if hm_have_cmd sha384sum; then
    sum="$(sha384sum "${bin}" | awk '{print $1}')"
  elif hm_have_cmd openssl; then
    sum="$(openssl dgst -sha384 "${bin}" | awk '{print $NF}')"
  else
    rm -f "${bin}"
    hm_err "Brak sha384sum — nie weryfikuję Composera."
    return 1
  fi
  if [[ -z "${sig}" || "${sum}" != "${sig}" ]]; then
    rm -f "${bin}"
    hm_err "Suma SHA-384 Composera nie zgadza się."
    return 1
  fi
  chmod 755 "${bin}"
  HM_SITE_PHP_COMPOSER_VER="$("${bin}" --version 2>/dev/null | head -1 || true)"
  printf '%s' "${bin}"
}

hm_site_php_skeleton() {
  local domain="$1" kind="$2" home
  home="$(hm_site_home "${domain}")"
  mkdir -p "${home}/app"
  case "${kind}" in
    ""|none) return 0 ;;
    laravel)
      [[ -n "${HM_SITE_PHP_LOG:-}" ]] && printf 'composer create-project laravel/laravel %s/app\n' "${home}" >> "${HM_SITE_PHP_LOG}"
      hm_site_env_app_secrets "${domain}" laravel || true
      ;;
    symfony)
      [[ -n "${HM_SITE_PHP_LOG:-}" ]] && printf 'composer create-project symfony/skeleton %s/app\n' "${home}" >> "${HM_SITE_PHP_LOG}"
      ;;
    wordpress)
      [[ -n "${HM_SITE_PHP_LOG:-}" ]] && printf 'wp install %s\n' "${domain}" >> "${HM_SITE_PHP_LOG}"
      ;;
    *) hm_err "Nieznany szkielet: ${kind}"; return 1 ;;
  esac
}

hm_site_php_provision() {
  local domain="$1" ver="$2" preset="${3:-minimal}" ext_csv="${4:-}" skel="${5:-}" yes="${6:-0}" sapi="${7:-fpm}" with_composer="${8:-1}"
  local user home kind
  [[ "${ver}" =~ ^[0-9]+\.[0-9]+$ ]] || ver="$(hm_site_php_default_version)" || {
    hm_err "Brak wersji PHP."
    return 1
  }
  user="$(hm_site_unix_user "${domain}")"
  home="$(hm_site_home "${domain}")"
  mkdir -p "${home}"
  hm_site_php_print_catalog >&2 || true
  kind="$(hm_site_php_kind "${ver}" || true)"
  if [[ "${kind}" == "extra" || -z "${kind}" ]]; then
    hm_site_php_ensure_repo "${ver}" "${yes}" || return 1
  fi
  local -a exts=()
  if [[ -z "${ext_csv}" ]]; then
    hm_site_php_preset_exts "${preset}" >/dev/null || return 1
  fi
  if [[ -n "${ext_csv}" ]]; then
    local part
    while IFS= read -r part; do
      [[ -n "${part}" ]] && exts+=("${part}")
    done < <(printf '%s\n' "${ext_csv}" | tr ',' '\n')
  else
    while IFS= read -r part; do
      [[ -n "${part}" ]] && exts+=("${part}")
    done < <(hm_site_php_preset_exts "${preset}")
  fi
  hm_site_php_install_exts "${ver}" "${sapi}" "${exts[@]+"${exts[@]}"}" || return 1
  [[ "${HM_SITE_PHP_HARDEN:-}" == "1" || "${preset}" == "harden" ]] || true
  hm_site_php_write_pool "${domain}" "${ver}" "${user}" "${home}" "${sapi}" || return 1
  if [[ "${with_composer}" == "1" ]]; then
    hm_site_php_composer "${domain}" >/dev/null || return 1
  fi
  hm_site_php_skeleton "${domain}" "${skel}" || return 1
  hm_ok "PHP ${ver} dla ${domain} (${sapi}). Composer: ${HM_SITE_PHP_COMPOSER_VER:-pominięty}."
}
