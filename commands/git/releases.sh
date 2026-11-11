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

hm_deploy_switch_current() {
  local home="$1" stamp="$2" cur tmp
  [[ -d "${home}/releases/${stamp}" ]] || return 1
  cur="${home}/current"
  tmp="${home}/.current-next"
  ln -sfn "releases/${stamp}" "${tmp}"
  if mv -Tf "${tmp}" "${cur}" 2>/dev/null; then
    return 0
  fi
  mv -T "${tmp}" "${cur}"
}

hm_deploy_release_build() {
  [[ "${HM_DEPLOY_BUILD_FAIL:-}" == "1" ]] && return 1
  return 0
}

hm_deploy_release_health() {
  case "${HM_DEPLOY_HEALTH_MOCK:-ok}" in
    ok) return 0 ;;
    *) return 1 ;;
  esac
}

hm_deploy_release_prune() {
  local home="$1" keep="${2:-5}" stamp cur="" n=0
  [[ "${keep}" =~ ^[0-9]+$ ]] || keep=5
  if [[ -L "${home}/current" ]]; then
    cur="$(readlink "${home}/current" 2>/dev/null || true)"
    cur="${cur##*/}"
  fi
  while IFS= read -r stamp; do
    [[ -n "${stamp}" ]] || continue
    n=$((n + 1))
    [[ "${n}" -le "${keep}" ]] && continue
    [[ "${stamp}" == "${cur}" ]] && continue
    rm -rf "${home}/releases/${stamp}"
  done < <(ls -1 "${home}/releases" 2>/dev/null | sort -r)
}

hm_deploy_release_apply() {
  local home stamp rel
  home="$(hm_deploy_home)"
  stamp="${1:-${HM_DEPLOY_STAMP:-}}"
  [[ -n "${stamp}" ]] || stamp="$(date -u +%Y%m%d%H%M%S)"
  [[ "${stamp}" =~ ^[A-Za-z0-9._-]+$ ]] || { hm_err "Zły stamp release."; return 1; }
  rel="${home}/releases/${stamp}"
  mkdir -p "${rel}" "${home}/shared"
  if ! hm_deploy_release_build "${rel}"; then
    printf 'failed\n' > "${rel}/.hm-release-status"
    hm_err "Build release ${stamp} nieudany. current bez zmian."
    return 1
  fi
  if ! hm_deploy_release_health "${rel}"; then
    printf 'failed\n' > "${rel}/.hm-release-status"
    hm_err "Healthcheck release ${stamp} nieudany. current bez zmian."
    return 1
  fi
  hm_deploy_switch_current "${home}" "${stamp}" || return 1
  printf 'ok\n' > "${rel}/.hm-release-status"
  hm_deploy_release_prune "${home}" "${HM_DEPLOY_KEEP:-5}"
  hm_ok "current → releases/${stamp}"
}

hm_deploy_release_rollback() {
  local home cur prev="" stamp
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
    prev="${stamp}"
    break
  done < <(ls -1 "${home}/releases" 2>/dev/null | sort -r)
  [[ -n "${prev}" ]] || { hm_err "Brak poprzedniego release."; return 1; }
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
