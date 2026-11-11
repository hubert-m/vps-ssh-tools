#!/usr/bin/env bash
# docker — down/logs/ps, update z rollbackiem, trivy, audyt, nowsze tagi.

hm_docker_stack_dir() {
  local stack="$1" wd="${HM_DOCKER_STACK_DIR:-}"
  if [[ -n "${wd}" && -d "${wd}" ]]; then
    printf '%s\n' "${wd}"
    return 0
  fi
  wd="$(hm_docker_stack_workdir "${stack}")" || return 1
  printf '%s\n' "${wd}"
}

hm_docker_redact() {
  grep -v -E 'PASSWORD=|SECRET-|API_KEY=' || true
}

hm_docker_compose_down() {
  local stack="$1" wd
  wd="$(hm_docker_stack_dir "${stack}")" || { hm_err "Nie znaleziono stacka ${stack}."; return 1; }
  hm_confirm_plan "docker compose down — ${stack}" "Zatrzymanie stacka." "" "docker compose down ${stack}" || return 1
  hm_docker_run_compose "${wd}" down
}

hm_docker_compose_logs() {
  local stack="$1" n="${2:-100}" wd
  wd="$(hm_docker_stack_dir "${stack}")" || { hm_err "Nie znaleziono stacka ${stack}."; return 1; }
  hm_docker_run_compose "${wd}" logs --tail "${n}" | hm_docker_redact
}

hm_docker_compose_ps() {
  local stack="$1" wd
  wd="$(hm_docker_stack_dir "${stack}")" || { hm_err "Nie znaleziono stacka ${stack}."; return 1; }
  hm_docker_run_compose "${wd}" ps
}

hm_docker_compose_update() {
  local stack="$1" wd digests name digest rc=0
  wd="$(hm_docker_stack_dir "${stack}")" || { hm_err "Nie znaleziono stacka ${stack}."; return 1; }
  [[ -f "${wd}/images.txt" ]] || { hm_err "Brak images.txt z digestami."; return 1; }
  hm_confirm_plan "docker compose update — ${stack}" "Zapis digestów, pull, up. Przy błędzie health wraca do zapisanych digestów." "" "docker compose update ${stack}" || return 1
  digests="${wd}/.hmtools-digests"
  cp -f "${wd}/images.txt" "${digests}"
  chmod 0600 "${digests}" || true
  hm_docker_run_compose "${wd}" pull || return 1
  hm_docker_run_compose "${wd}" up -d || return 1
  if [[ "${HM_DOCKER_HEALTH:-ok}" == "fail" ]]; then
    hm_warn "Health nie przeszedł. Przywracam zapisane digesty."
    while read -r name digest; do
      [[ -n "${name}" && -n "${digest}" ]] || continue
      "${DOCKER_BIN}" pull "${name}@${digest}" || rc=$?
    done < "${digests}"
    hm_docker_run_compose "${wd}" up -d || rc=$?
    return 1
  fi
  hm_ok "compose update ${stack} OK."
}

hm_docker_scan() {
  local bin="${HM_TRIVY_BIN:-}" image="${1:-}"
  if [[ -z "${bin}" ]] && command -v trivy >/dev/null 2>&1; then
    bin="$(command -v trivy)"
  fi
  if [[ -z "${bin}" || ! -x "${bin}" ]]; then
    hm_warn "Brak trivy. Do instalacji jest pakiet trivy."
    return 1
  fi
  [[ -n "${image}" ]] || { hm_err "Użycie: docker scan <obraz|--all>"; return 1; }
  "${bin}" image "${image}" | hm_docker_redact
}

hm_docker_audit() {
  local file="${HM_DOCKER_AUDIT:-}" line name restart health priv port image
  [[ -n "${file}" && -f "${file}" ]] || { hm_err "Brak danych audytu kontenerów."; return 1; }
  while read -r name restart health priv port image; do
    [[ -n "${name}" ]] || continue
    if [[ "${restart}" == "no" || -z "${restart}" ]]; then
      printf 'restart\t%s\n' "${name}"
    fi
    if [[ "${health}" == "no" ]]; then
      printf 'health\t%s\n' "${name}"
    fi
    if [[ "${priv}" == "yes" ]]; then
      printf 'privileged\t%s\n' "${name}"
    fi
    if [[ "${port}" == 0.0.0.0:* ]]; then
      printf 'public-port\t%s\t%s\n' "${name}" "${port}"
    fi
    if [[ "${image}" == *:latest ]]; then
      printf 'latest\t%s\t%s\n' "${name}" "${image}"
    fi
  done < "${file}"
}

hm_docker_updates() {
  local file="${HM_DOCKER_UPDATES:-}"
  if [[ -z "${file}" || ! -f "${file}" ]]; then
    hm_info "Brak nowszych tagów."
    return 0
  fi
  awk 'NF >= 2 { printf "%s -> %s\n", $1, $2 }' "${file}"
}
