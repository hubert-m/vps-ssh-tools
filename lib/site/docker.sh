#!/usr/bin/env bash
# Runtime Docker dla site new: compose za reverse proxy, port tylko 127.0.0.1.

if [[ -n "${HMTOOLS_SITE_DOCKER_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_SITE_DOCKER_LOADED=1

hm_site_docker_home() {
  if declare -F hm_site_home >/dev/null 2>&1; then
    hm_site_home "$1"
    return
  fi
  printf '%s/%s' "${HM_SITE_HOME_BASE:-/home}" "$1"
}

hm_site_docker_project() {
  local d="${1:-}"
  d="$(printf '%s' "${d}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//')"
  printf 'hm-%s' "${d:-site}"
}

hm_site_docker_bin() {
  if [[ -n "${DOCKER_BIN:-}" && -x "${DOCKER_BIN}" ]]; then
    printf '%s' "${DOCKER_BIN}"
    return 0
  fi
  command -v docker 2>/dev/null || return 1
}

hm_site_docker_preflight() {
  local bin
  if [[ "${FORCE_DOCKER:-}" == "yes" || "${DOCKER:-}" == "yes" ]]; then
    return 0
  fi
  bin="$(hm_site_docker_bin)" || {
    hm_err "Brak Dockera — zainstaluj docker + plugin compose albo FORCE_DOCKER=yes."
    return 1
  }
  if [[ "${HMTOOLS_TEST:-}" == "1" ]]; then
    return 0
  fi
  if ! "${bin}" info >/dev/null 2>&1; then
    hm_err "Docker CLI jest, ale daemon nie odpowiada (docker info)."
    return 1
  fi
  if ! "${bin}" compose version >/dev/null 2>&1; then
    hm_err "Brak docker compose (plugin)."
    return 1
  fi
  return 0
}

hm_site_docker_validate_compose() {
  local file="$1"
  [[ -f "${file}" ]] || {
    hm_err "Brak compose: ${file}"
    return 1
  }
  # Odrzuć publikację na 0.0.0.0 (Docker omija UFW).
  if grep -Eqi '0\.0\.0\.0:' "${file}"; then
    hm_err "Odmowa: compose publikuje port na 0.0.0.0 (wymagane 127.0.0.1)."
    return 1
  fi
  if ! grep -Eq '127\.0\.0\.1:[0-9]+:[0-9]+' "${file}"; then
    hm_err "Compose musi mapować port jako 127.0.0.1:<host>:<container>."
    return 1
  fi
  return 0
}

hm_site_docker_write_compose() {
  local dest="$1" image="$2" host_port="$3" cport="$4" env_file="${5:-}"
  local dir
  dir="$(dirname "${dest}")"
  mkdir -p "${dir}"
  {
    printf '%s\n' 'services:'
    printf '%s\n' '  app:'
    printf '    image: %s\n' "${image}"
    printf '%s\n' '    restart: unless-stopped'
    printf '%s\n' '    ports:'
    printf '      - "127.0.0.1:%s:%s"\n' "${host_port}" "${cport}"
    if [[ -n "${env_file}" ]]; then
      printf '%s\n' '    env_file:'
      printf '      - %s\n' "${env_file}"
    fi
    printf '%s\n' '    mem_limit: 512m'
    printf '%s\n' '    cpus: 1.0'
    printf '%s\n' '    healthcheck:'
    printf '%s\n' '      test: ["CMD-SHELL", "true"]'
    printf '%s\n' '      interval: 30s'
    printf '%s\n' '      timeout: 5s'
    printf '%s\n' '      retries: 3'
  } > "${dest}"
  chmod 0640 "${dest}" 2>/dev/null || true
  hm_site_docker_validate_compose "${dest}"
}

hm_site_docker_up() {
  local wd="$1" project="$2" file="$3"
  local bin
  bin="$(hm_site_docker_bin)" || return 1
  if [[ -n "${HM_SITE_DOCKER_LOG:-}" ]]; then
    printf 'compose -p %s -f %s up -d\n' "${project}" "${file}" >> "${HM_SITE_DOCKER_LOG}"
  fi
  if [[ "${HMTOOLS_TEST:-}" == "1" && -z "${HM_SITE_DOCKER_REAL:-}" ]]; then
    return 0
  fi
  (cd "${wd}" && "${bin}" compose -p "${project}" -f "${file}" up -d)
}

hm_site_docker_down() {
  local wd="$1" project="$2" file="${3:-}"
  local bin
  bin="$(hm_site_docker_bin)" || return 1
  if [[ -n "${HM_SITE_DOCKER_LOG:-}" ]]; then
    printf 'compose -p %s down\n' "${project}" >> "${HM_SITE_DOCKER_LOG}"
  fi
  if [[ "${HMTOOLS_TEST:-}" == "1" && -z "${HM_SITE_DOCKER_REAL:-}" ]]; then
    return 0
  fi
  if [[ -n "${file}" && -f "${file}" ]]; then
    (cd "${wd}" && "${bin}" compose -p "${project}" -f "${file}" down) || true
  else
    (cd "${wd}" && "${bin}" compose -p "${project}" down) || true
  fi
}

hm_site_docker_provision() {
  local domain="$1" image="${2:-}" cport="${3:-80}" host_port="${4:-auto}" yes="${5:-0}"
  local home project compose envf host
  [[ -n "${domain}" ]] || {
    hm_err "Brak domeny."
    return 1
  }
  [[ -n "${image}" ]] || {
    hm_err "Użycie: --runtime docker --image OBRAZ[:tag] [--container-port N]"
    return 1
  }
  [[ "${cport}" =~ ^[0-9]+$ ]] || {
    hm_err "Nieprawidłowy --container-port: ${cport}"
    return 1
  }
  hm_site_docker_preflight || return 1
  home="$(hm_site_docker_home "${domain}")"
  project="$(hm_site_docker_project "${domain}")"
  compose="${home}/compose.yaml"
  envf="${home}/shared/.env"
  mkdir -p "${home}/shared" "${home}/logs"
  [[ -f "${envf}" ]] || ( umask 077; : > "${envf}"; )

  if declare -F hm_site_web_reserve_port >/dev/null 2>&1; then
    host="$(hm_site_web_reserve_port "${domain}" "${host_port}")" || return 1
  else
    host="${host_port}"
    [[ "${host}" == "auto" ]] && host="3001"
  fi

  hm_site_docker_write_compose "${compose}" "${image}" "${host}" "${cport}" "shared/.env" || return 1

  if [[ "${yes}" -ne 1 && "${HMTOOLS_TEST:-}" != "1" ]] && declare -F hm_confirm_plan >/dev/null 2>&1; then
    hm_confirm_plan "site docker — ${domain}" \
      "compose ${project}: ${image} → 127.0.0.1:${host}:${cport}" \
      "" "docker compose -p ${project} up -d" || return 1
  fi

  hm_site_docker_up "${home}" "${project}" "${compose}" || return 1

  if declare -F hm_site_resource_add >/dev/null 2>&1; then
    hm_site_resource_add "${domain}" compose "${compose}" 0 || true
    hm_site_resource_add "${domain}" port "${host}" 0 || true
  fi
  if declare -F hm_tx_note_undo >/dev/null 2>&1; then
    hm_tx_note_undo "$(printf 'compose-down\t%s\t%s\t%s' "${project}" "${home}" "${compose}")"
  fi

  # Eksport dla kroku vhost proxy
  HM_SITE_DOCKER_PORT="${host}"
  HM_SITE_DOCKER_PROJECT="${project}"
  HM_SITE_DOCKER_COMPOSE="${compose}"
  printf '%s\n' "${host}"
  return 0
}
