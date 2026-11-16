#!/usr/bin/env bash
# Deploy w trybie releases/<stamp> i atomowe current.

hm_deploy_home() {
  printf '%s' "${HM_DEPLOY_HOME:-${HM_SITE_ROOT:-/var/www/${HM_SITE_DOMAIN:-site}}}"
}

hm_deploy_hook_cmd_ok() {
  case "${1:-}" in
    migrate|collectstatic|php-lint|npm-build|none) return 0 ;;
    *) return 1 ;;
  esac
}

# releases musi być prawdziwym katalogiem pod $home (nie symlinkiem).
hm_deploy_releases_dir_ok() {
  local home="$1" rels rp home_rp
  rels="${home}/releases"
  if [[ -L "${rels}" ]]; then
    hm_err "Odmowa: ${rels} jest symlinkiem."
    return 1
  fi
  [[ -d "${rels}" ]] || return 0
  if command -v realpath >/dev/null 2>&1; then
    rp="$(realpath "${rels}" 2>/dev/null || true)"
    home_rp="$(realpath "${home}" 2>/dev/null || true)"
    if [[ -n "${rp}" && -n "${home_rp}" && "${rp}" != "${home_rp}/releases" && "${rp}" != "${home_rp}"/releases ]]; then
      # dopuszczamy tylko gdy realpath kończy się na /releases pod home
      case "${rp}" in
        "${home_rp}/releases"|"${home_rp}/releases/"*) ;;
        *)
          hm_err "Odmowa: releases poza home (${rp})."
          return 1
          ;;
      esac
    fi
  fi
  return 0
}

hm_deploy_release_path_ok() {
  local home="$1" stamp="$2" path rp home_rp
  hm_deploy_releases_dir_ok "${home}" || return 1
  [[ "${stamp}" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  path="${home}/releases/${stamp}"
  if [[ -L "${path}" ]]; then
    hm_err "Odmowa: release ${stamp} jest symlinkiem."
    return 1
  fi
  if [[ -e "${path}" ]] && command -v realpath >/dev/null 2>&1; then
    rp="$(realpath "${path}" 2>/dev/null || true)"
    home_rp="$(realpath "${home}/releases" 2>/dev/null || true)"
    if [[ -n "${rp}" && -n "${home_rp}" ]]; then
      case "${rp}" in
        "${home_rp}"|"${home_rp}/"*) ;;
        *)
          hm_err "Odmowa: ścieżka release poza ${home}/releases."
          return 1
          ;;
      esac
    fi
  fi
  return 0
}

hm_deploy_status_write() {
  local path="$1" val="$2"
  if declare -F hm_site_write_nofollow >/dev/null 2>&1; then
    printf '%s\n' "${val}" | hm_site_write_nofollow "${path}" || return 1
  else
    if [[ -L "${path}" ]] || [[ -L "$(dirname "${path}")" ]]; then
      hm_err "Odmowa zapisu statusu przez symlink: ${path}"
      return 1
    fi
    printf '%s\n' "${val}" > "${path}"
  fi
}

hm_deploy_rm_release() {
  local path="$1"
  if declare -F hm_site_rm_nofollow >/dev/null 2>&1; then
    hm_site_rm_nofollow "${path}" || return 1
    return 0
  fi
  if [[ -L "${path}" ]]; then
    hm_err "Odmowa kasowania symlinku release: ${path}"
    return 1
  fi
  # rodzic releases nie może być symlinkiem (już sprawdzone w path_ok)
  rm -rf --one-file-system -- "${path}" 2>/dev/null || rm -rf -- "${path}"
}

hm_deploy_switch_current() {
  local home="$1" stamp="$2" cur tmp
  hm_deploy_release_path_ok "${home}" "${stamp}" || return 1
  [[ -d "${home}/releases/${stamp}" ]] || return 1
  cur="${home}/current"
  tmp="${home}/.current-next"
  ln -sfn "releases/${stamp}" "${tmp}"
  if mv -Tf "${tmp}" "${cur}" 2>/dev/null; then
    return 0
  fi
  mv -T "${tmp}" "${cur}"
}

# Kopiuje kod do release: git archive / rsync ze źródła / mock w teście.
hm_deploy_release_populate() {
  local rel="$1" home src branch
  home="$(hm_deploy_home)"
  src="${HM_DEPLOY_SOURCE:-${home}/repo}"
  branch="${HM_DEPLOY_BRANCH:-main}"
  mkdir -p "${rel}"
  if [[ "${HMTOOLS_TEST:-}" == "1" && -z "${HM_DEPLOY_FORCE_POPULATE:-}" ]]; then
    # w teście zachowaj istniejące pliki fixture; nic nie kasuj
    return 0
  fi
  if [[ -d "${src}/.git" ]] && command -v git >/dev/null 2>&1; then
    git -C "${src}" archive --format=tar "${branch}" 2>/dev/null | tar -xf - -C "${rel}" || {
      # fallback: checkout HEAD
      git -C "${src}" archive --format=tar HEAD | tar -xf - -C "${rel}" || return 1
    }
  elif [[ -d "${src}" ]]; then
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --delete --exclude '.git' "${src}/" "${rel}/" || return 1
    else
      cp -a "${src}/." "${rel}/" || return 1
    fi
  else
    hm_err "Brak źródła kodu (${src}) do release."
    return 1
  fi
  # shared → linki
  if [[ -d "${home}/shared" ]]; then
    local name
    for name in .env storage media uploads; do
      if [[ -e "${home}/shared/${name}" && ! -e "${rel}/${name}" ]]; then
        ln -sfn "../../shared/${name}" "${rel}/${name}"
      fi
    done
  fi
  return 0
}

hm_deploy_release_build() {
  local rel="${1:-}"
  [[ "${HM_DEPLOY_BUILD_FAIL:-}" == "1" ]] && return 1
  if [[ "${HMTOOLS_TEST:-}" == "1" && -z "${HM_DEPLOY_BUILD_CMD:-}" ]]; then
    return 0
  fi
  local cmd="${HM_DEPLOY_BUILD_CMD:-}"
  [[ -z "${cmd}" ]] && return 0
  if declare -F hm_deploy_build_line_ok >/dev/null 2>&1; then
    hm_deploy_build_line_ok "${cmd}" || {
      hm_err "Build spoza whitelist: ${cmd}"
      return 1
    }
  fi
  (
    cd "${rel}" || exit 1
    # shellcheck disable=SC2086
    eval "${cmd}"
  )
}

hm_deploy_release_health() {
  local rel="${1:-}" url port path
  case "${HM_DEPLOY_HEALTH_MOCK:-}" in
    ok) return 0 ;;
    bad|fail) return 1 ;;
  esac
  if [[ "${HMTOOLS_TEST:-}" == "1" && -z "${HM_DEPLOY_HEALTH_URL:-}" ]]; then
    return 0
  fi
  url="${HM_DEPLOY_HEALTH_URL:-}"
  [[ -n "${url}" ]] || return 0
  port="${HM_DEPLOY_HEALTH_PORT:-}"
  path="${url}"
  if [[ -n "${port}" ]]; then
    if command -v curl >/dev/null 2>&1; then
      curl -fsS --max-time 5 -H "Host: ${HM_SITE_DOMAIN:-localhost}" \
        "http://127.0.0.1:${port}${path}" >/dev/null 2>&1 || return 1
      return 0
    fi
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 5 "${url}" >/dev/null 2>&1 || return 1
  fi
  # opcjonalnie php -l na index
  if [[ -f "${rel}/index.php" ]] && command -v php >/dev/null 2>&1; then
    php -l "${rel}/index.php" >/dev/null 2>&1 || return 1
  fi
  return 0
}

hm_deploy_release_prune() {
  local home="$1" keep="${2:-5}" stamp cur="" n=0 path
  [[ "${keep}" =~ ^[0-9]+$ ]] || keep=5
  hm_deploy_releases_dir_ok "${home}" || return 1
  if [[ -L "${home}/current" ]]; then
    cur="$(readlink "${home}/current" 2>/dev/null || true)"
    cur="${cur##*/}"
  fi
  while IFS= read -r stamp; do
    [[ -n "${stamp}" ]] || continue
    n=$((n + 1))
    [[ "${n}" -le "${keep}" ]] && continue
    [[ "${stamp}" == "${cur}" ]] && continue
    path="${home}/releases/${stamp}"
    hm_deploy_release_path_ok "${home}" "${stamp}" || continue
    hm_deploy_rm_release "${path}" || true
  done < <(ls -1 "${home}/releases" 2>/dev/null | sort -r)
}

hm_deploy_release_apply() {
  local home stamp rel
  home="$(hm_deploy_home)"
  stamp="${1:-${HM_DEPLOY_STAMP:-}}"
  [[ -n "${stamp}" ]] || stamp="$(date -u +%Y%m%d%H%M%S)"
  [[ "${stamp}" =~ ^[A-Za-z0-9._-]+$ ]] || { hm_err "Zły stamp release."; return 1; }
  hm_deploy_releases_dir_ok "${home}" || return 1
  mkdir -p "${home}/releases" "${home}/shared"
  if [[ -L "${home}/releases" ]]; then
    hm_err "Odmowa: releases jest symlinkiem."
    return 1
  fi
  rel="${home}/releases/${stamp}"
  if [[ -L "${rel}" ]]; then
    hm_err "Odmowa: ${rel} jest symlinkiem."
    return 1
  fi
  mkdir -p "${rel}"
  hm_deploy_release_path_ok "${home}" "${stamp}" || return 1
  if ! hm_deploy_release_populate "${rel}"; then
    hm_deploy_status_write "${rel}/.hm-release-status" "failed" || true
    hm_err "Populate release ${stamp} nieudany. current bez zmian."
    return 1
  fi
  if ! hm_deploy_release_build "${rel}"; then
    hm_deploy_status_write "${rel}/.hm-release-status" "failed" || true
    hm_err "Build release ${stamp} nieudany. current bez zmian."
    return 1
  fi
  if ! hm_deploy_release_health "${rel}"; then
    hm_deploy_status_write "${rel}/.hm-release-status" "failed" || true
    hm_err "Healthcheck release ${stamp} nieudany. current bez zmian."
    return 1
  fi
  hm_deploy_switch_current "${home}" "${stamp}" || return 1
  hm_deploy_status_write "${rel}/.hm-release-status" "ok" || return 1
  hm_deploy_release_prune "${home}" "${HM_DEPLOY_KEEP:-5}"
  hm_ok "current → releases/${stamp}"
}

hm_deploy_release_rollback() {
  local home cur prev="" stamp st
  home="$(hm_deploy_home)"
  if [[ -n "${1:-}" ]]; then
    hm_deploy_switch_current "${home}" "$1"
    return $?
  fi
  if [[ -L "${home}/current" ]]; then
    cur="$(readlink "${home}/current" 2>/dev/null || true)"
    cur="${cur##*/}"
  fi
  while IFS= read -r stamp; do
    [[ -n "${stamp}" && "${stamp}" != "${cur}" && -d "${home}/releases/${stamp}" ]] || continue
    [[ -L "${home}/releases/${stamp}" ]] && continue
    st=""
    if [[ -f "${home}/releases/${stamp}/.hm-release-status" && ! -L "${home}/releases/${stamp}/.hm-release-status" ]]; then
      st="$(tr -d '[:space:]' < "${home}/releases/${stamp}/.hm-release-status")"
    fi
    [[ "${st}" == "ok" ]] || continue
    prev="${stamp}"
    break
  done < <(ls -1 "${home}/releases" 2>/dev/null | sort -r)
  [[ -n "${prev}" ]] || { hm_err "Brak poprzedniego release ze statusem ok."; return 1; }
  hm_deploy_switch_current "${home}" "${prev}"
}

hm_deploy_webhook_verify() {
  local body="$1" sig="$2" secret="$3" expect
  command -v openssl >/dev/null 2>&1 || return 1
  expect="$(printf '%s' "${body}" | openssl dgst -sha256 -hmac "${secret}" 2>/dev/null | awk '{print $NF}')"
  [[ -n "${expect}" && "${sig}" == "sha256=${expect}" ]]
}

hm_deploy_webhook_handle() {
  local body="$1" sig="$2" secret="$3" log="${4:-}"
  if ! hm_deploy_webhook_verify "${body}" "${sig}" "${secret}"; then
    [[ -n "${log}" ]] && printf 'webhook 403\n' >> "${log}"
    printf '403\n'
    return 1
  fi
  [[ -n "${log}" ]] && printf 'webhook 202\n' >> "${log}"
  printf '202\n'
}
