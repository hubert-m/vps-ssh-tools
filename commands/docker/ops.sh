#!/usr/bin/env bash
# docker — down/logs/ps, update z rollbackiem, trivy, audyt, nowsze tagi.

hm_docker_redact() {
  # wycina wartości sekretów, nie całe linie
  sed -E \
    -e 's/(PASSWORD|SECRET[_A-Z0-9]*|API[_-]?KEY)=[^[:space:]]+/\1=[redacted]/gi' \
    -e 's/SECRET-[A-Za-z0-9_-]+/[redacted]/g'
}

# Ustawia: _hm_dc_wd, _hm_dc_project, _hm_dc_files (tablica ścieżek -f)
hm_docker_compose_resolve() {
  local stack="$1" id project="" wd="" files="" f
  _hm_dc_wd=""
  _hm_dc_project=""
  _hm_dc_files=()

  if [[ -n "${HM_DOCKER_STACK_DIR:-}" && -d "${HM_DOCKER_STACK_DIR}" ]]; then
    _hm_dc_wd="${HM_DOCKER_STACK_DIR}"
    _hm_dc_project="${HM_DOCKER_PROJECT:-${stack}}"
    if [[ -n "${HM_DOCKER_COMPOSE_FILES:-}" ]]; then
      IFS=',' read -r -a _hm_dc_files <<< "${HM_DOCKER_COMPOSE_FILES}"
    fi
    return 0
  fi

  hm_docker_require || return 1
  while IFS= read -r id; do
    [[ -n "${id}" ]] || continue
    project="$("${DOCKER_BIN}" inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "${id}" 2>/dev/null || true)"
    [[ "${project}" == "${stack}" ]] || continue
    wd="$("${DOCKER_BIN}" inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "${id}" 2>/dev/null || true)"
    files="$("${DOCKER_BIN}" inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "${id}" 2>/dev/null || true)"
    [[ "${wd}" == "<no value>" ]] && wd=""
    [[ "${files}" == "<no value>" ]] && files=""
    if [[ -n "${wd}" && -d "${wd}" ]]; then
      _hm_dc_wd="${wd}"
      _hm_dc_project="${project}"
      if [[ -n "${files}" ]]; then
        IFS=',' read -r -a _hm_dc_files <<< "${files}"
      fi
      return 0
    fi
  done < <("${DOCKER_BIN}" ps -aq --filter "label=com.docker.compose.project=${stack}" 2>/dev/null)

  # fallback: stary lookup workdir po liście
  wd="$(hm_docker_stack_workdir "${stack}" 2>/dev/null || true)"
  if [[ -n "${wd}" && -d "${wd}" ]]; then
    _hm_dc_wd="${wd}"
    _hm_dc_project="${stack}"
    return 0
  fi
  return 1
}

hm_docker_compose_exec() {
  # po resolve: docker compose -p PROJECT [-f …] …
  local -a args=(compose -p "${_hm_dc_project}")
  local f
  for f in "${_hm_dc_files[@]:-}"; do
    [[ -n "${f}" ]] || continue
    args+=(-f "${f}")
  done
  args+=("$@")
  if [[ ! -d "${_hm_dc_wd}" ]]; then
    hm_err "Katalog stacka nie istnieje: ${_hm_dc_wd}"
    return 1
  fi
  hm_docker_require || return 1
  if "${DOCKER_BIN}" compose version >/dev/null 2>&1 || [[ "${DOCKER_COMPOSE:-}" == "plugin" ]]; then
    (cd "${_hm_dc_wd}" && "${DOCKER_BIN}" "${args[@]}")
    return $?
  fi
  if hm_have_cmd docker-compose; then
    local -a dc=( -p "${_hm_dc_project}" )
    for f in "${_hm_dc_files[@]:-}"; do
      [[ -n "${f}" ]] || continue
      dc+=(-f "${f}")
    done
    (cd "${_hm_dc_wd}" && docker-compose "${dc[@]}" "$@")
    return $?
  fi
  hm_err "Brak docker compose / docker-compose."
  return 1
}

hm_docker_save_digests() {
  # Format linii: tag imageID [repoDigest]
  # imageID = .Image kontenera (lokalny sha256) — do docker tag przy rollbacku
  # repoDigest = index .RepoDigests 0 (manifest) — do docker pull gdy obraz usunięty
  local project="$1" out="$2" id img iid repo
  : > "${out}"
  chmod 0600 "${out}" || true
  while IFS= read -r id; do
    [[ -n "${id}" ]] || continue
    img="$("${DOCKER_BIN}" inspect -f '{{.Config.Image}}' "${id}" 2>/dev/null || true)"
    iid="$("${DOCKER_BIN}" inspect -f '{{.Image}}' "${id}" 2>/dev/null || true)"
    [[ -n "${img}" && -n "${iid}" && "${iid}" != "<no value>" ]] || continue
    repo=""
    if [[ -n "${iid}" ]]; then
      repo="$("${DOCKER_BIN}" image inspect -f '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "${iid}" 2>/dev/null || true)"
      [[ "${repo}" == "<no value>" ]] && repo=""
    fi
    # Zachowaj lokalny tag-prev żeby prune nie usunął obrazu przed rollbackiem
    "${DOCKER_BIN}" tag "${iid}" "${img}-hmtools-prev" 2>/dev/null || true
    printf '%s %s %s\n' "${img}" "${iid}" "${repo}" >> "${out}"
  done < <("${DOCKER_BIN}" ps -aq --filter "label=com.docker.compose.project=${project}" 2>/dev/null)
  # test fixture: jeśli brak kontenerów, a jest images.txt — tylko gdy HMTOOLS_TEST
  if [[ ! -s "${out}" && "${HMTOOLS_TEST:-}" == "1" && -f "${_hm_dc_wd}/images.txt" ]]; then
    cp -f "${_hm_dc_wd}/images.txt" "${out}"
    chmod 0600 "${out}" || true
  fi
  [[ -s "${out}" ]] || return 1
  return 0
}

# Czeka aż kontenery projektu będą healthy (albo stabilne running bez healthchecka).
# starting ≠ fail; unhealthy / restarting / timeout → błąd.
# Oneshot (exited 0 + restart no|on-failure) — OK (migrate/init).
hm_docker_health_ok() {
  local project="$1"
  local id st health rest rstcnt url code exitc pol
  local timeout interval stable_need end all_ok
  local -A nohc_since=() nohc_restarts=()

  # flaga testowa ma pierwszeństwo (bez pętli)
  if [[ -n "${HM_DOCKER_HEALTH:-}" ]]; then
    [[ "${HM_DOCKER_HEALTH}" == "ok" ]]
    return $?
  fi

  timeout="${HM_DOCKER_HEALTH_TIMEOUT:-60}"
  interval="${HM_DOCKER_HEALTH_INTERVAL:-2}"
  stable_need="${HM_DOCKER_NOHEALTH_STABLE:-10}"
  [[ "${timeout}" =~ ^[0-9]+$ ]] || timeout=60
  [[ "${interval}" =~ ^[0-9]+$ ]] || interval=2
  [[ "${stable_need}" =~ ^[0-9]+$ ]] || stable_need=10
  (( interval < 1 )) && interval=1
  end=$((SECONDS + timeout))

  while (( SECONDS <= end )); do
    all_ok=1
    while IFS= read -r id; do
      [[ -n "${id}" ]] || continue
      st="$("${DOCKER_BIN}" inspect -f '{{.State.Status}}' "${id}" 2>/dev/null || true)"
      rest="$("${DOCKER_BIN}" inspect -f '{{.State.Restarting}}' "${id}" 2>/dev/null || true)"
      rstcnt="$("${DOCKER_BIN}" inspect -f '{{.RestartCount}}' "${id}" 2>/dev/null || true)"
      [[ "${rstcnt}" =~ ^[0-9]+$ ]] || rstcnt=0
      health="$("${DOCKER_BIN}" inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "${id}" 2>/dev/null || true)"

      if [[ "${rest}" == "true" || "${st}" == "restarting" ]]; then
        return 1
      fi
      case "${st}" in
        running) ;;
        exited|dead)
          # Jednorazowy serwis (migrate/init): ExitCode=0 + restart no|on-failure → pomiń
          exitc="$("${DOCKER_BIN}" inspect -f '{{.State.ExitCode}}' "${id}" 2>/dev/null || true)"
          pol="$("${DOCKER_BIN}" inspect -f '{{.HostConfig.RestartPolicy.Name}}' "${id}" 2>/dev/null || true)"
          [[ "${exitc}" =~ ^[0-9]+$ ]] || exitc=1
          if [[ "${exitc}" -eq 0 && ( "${pol}" == "no" || "${pol}" == "" || "${pol}" == "on-failure" ) ]]; then
            continue
          fi
          return 1
          ;;
        created|removing)
          all_ok=0
          continue
          ;;
        *) return 1 ;;
      esac

      if [[ -n "${health}" ]]; then
        case "${health}" in
          healthy) ;;
          unhealthy) return 1 ;;
          *) all_ok=0 ;; # starting / inne — czekaj
        esac
      else
        # bez healthchecka: krótkie okno stabilnego running bez wzrostu RestartCount
        if [[ -z "${nohc_since[${id}]+x}" ]]; then
          nohc_since["${id}"]="${SECONDS}"
          nohc_restarts["${id}"]="${rstcnt}"
          all_ok=0
        elif [[ "${nohc_restarts[${id}]}" != "${rstcnt}" ]]; then
          return 1
        elif (( SECONDS - nohc_since["${id}"] < stable_need )); then
          all_ok=0
        fi
      fi
    done < <("${DOCKER_BIN}" ps -aq --filter "label=com.docker.compose.project=${project}" 2>/dev/null)

    if [[ "${all_ok}" -eq 1 ]]; then
      url="${HM_DOCKER_HEALTH_URL:-}"
      if [[ -n "${url}" ]]; then
        code="$("${HM_CF_CURL:-curl}" -fsS -o /dev/null -w '%{http_code}' --max-time 5 -- "${url}" 2>/dev/null || true)"
        [[ "${code}" =~ ^2[0-9][0-9]$ ]] || return 1
      fi
      return 0
    fi
    (( SECONDS + interval > end )) && break
    sleep "${interval}"
  done
  return 1
}

hm_docker_rollback_digests() {
  # Linie: tag imageID [repoDigest]  (stary format: tag imageID — nadal OK)
  local digests="$1" name iid repo
  local rc=0 tagged
  while read -r name iid repo; do
    [[ -n "${name}" && -n "${iid}" ]] || continue
    tagged=0
    # 1) lokalny image ID (nadal na dysku po pull nowego) — nie pull-uj ID
    if "${DOCKER_BIN}" tag "${iid}" "${name}" 2>/dev/null; then
      tagged=1
    elif [[ -n "${repo}" ]] && "${DOCKER_BIN}" pull "${repo}" 2>/dev/null; then
      "${DOCKER_BIN}" tag "${repo}" "${name}" 2>/dev/null && tagged=1
    elif "${DOCKER_BIN}" tag "${name}-hmtools-prev" "${name}" 2>/dev/null; then
      tagged=1
    else
      # ostatnia szansa: pull name@digest gdy iid wygląda na sha256:… a repo pusty (stary format)
      if [[ "${iid}" == sha256:* ]]; then
        if "${DOCKER_BIN}" pull "${name%@*}@${iid}" 2>/dev/null \
            || "${DOCKER_BIN}" pull "${name}@${iid}" 2>/dev/null; then
          "${DOCKER_BIN}" tag "${iid}" "${name}" 2>/dev/null && tagged=1
        fi
      fi
    fi
    [[ "${tagged}" -eq 1 ]] || rc=1
  done < "${digests}"
  hm_docker_compose_exec up -d --force-recreate || rc=1
  return "${rc}"
}

hm_docker_compose_down() {
  local stack="$1"
  hm_docker_compose_resolve "${stack}" || { hm_err "Nie znaleziono stacka ${stack}."; return 1; }
  hm_confirm_plan "docker compose down — ${stack}" \
    "Zatrzymanie projektu ${_hm_dc_project} (bez usuwania wolumenów)." \
    "" "docker compose -p ${_hm_dc_project} down" || return 1
  hm_docker_compose_exec down
}

hm_docker_compose_logs() {
  local stack="$1" n="${2:-100}"
  hm_docker_compose_resolve "${stack}" || { hm_err "Nie znaleziono stacka ${stack}."; return 1; }
  hm_docker_compose_exec logs --tail "${n}" | hm_docker_redact
}

hm_docker_compose_ps() {
  local stack="$1"
  hm_docker_compose_resolve "${stack}" || { hm_err "Nie znaleziono stacka ${stack}."; return 1; }
  hm_docker_compose_exec ps
}

hm_docker_compose_update() {
  local stack="$1" digests rc=0
  hm_docker_compose_resolve "${stack}" || { hm_err "Nie znaleziono stacka ${stack}."; return 1; }
  hm_confirm_plan "docker compose update — ${stack}" \
    "Zapis digestów z działających kontenerów, pull, up. Przy złym health — rollback (tag + force-recreate)." \
    "" "docker compose update ${stack}" || return 1
  digests="${_hm_dc_wd}/.hmtools-digests"
  hm_docker_save_digests "${_hm_dc_project}" "${digests}" || {
    hm_err "Nie udało się zapisać digestów z kontenerów projektu ${_hm_dc_project}."
    return 1
  }
  hm_docker_compose_exec pull || return 1
  if ! hm_docker_compose_exec up -d; then
    hm_warn "compose up -d nieudany. Przywracam zapisane digesty (tag + force-recreate)."
    hm_docker_rollback_digests "${digests}" || true
    return 1
  fi
  if ! hm_docker_health_ok "${_hm_dc_project}"; then
    hm_warn "Health nie przeszedł. Przywracam zapisane digesty (tag + force-recreate)."
    hm_docker_rollback_digests "${digests}" || rc=1
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

hm_docker_audit_live() {
  local id name restart health priv ports image hc
  while IFS= read -r id; do
    [[ -n "${id}" ]] || continue
    name="$("${DOCKER_BIN}" inspect -f '{{.Name}}' "${id}" 2>/dev/null | sed 's#^/##')"
    restart="$("${DOCKER_BIN}" inspect -f '{{.HostConfig.RestartPolicy.Name}}' "${id}" 2>/dev/null || true)"
    hc="$("${DOCKER_BIN}" inspect -f '{{if .Config.Healthcheck}}yes{{else}}no{{end}}' "${id}" 2>/dev/null || true)"
    priv="$("${DOCKER_BIN}" inspect -f '{{.HostConfig.Privileged}}' "${id}" 2>/dev/null || true)"
    ports="$("${DOCKER_BIN}" inspect -f '{{range $p,$c := .NetworkSettings.Ports}}{{range $c}}{{.HostIp}}:{{.HostPort}} {{end}}{{end}}' "${id}" 2>/dev/null || true)"
    image="$("${DOCKER_BIN}" inspect -f '{{.Config.Image}}' "${id}" 2>/dev/null || true)"
    if [[ -z "${restart}" || "${restart}" == "no" ]]; then
      printf 'restart\t%s\n' "${name}"
    fi
    if [[ "${hc}" != "yes" ]]; then
      printf 'health\t%s\n' "${name}"
    fi
    if [[ "${priv}" == "true" || "${priv}" == "yes" ]]; then
      printf 'privileged\t%s\n' "${name}"
    fi
    if printf '%s' "${ports}" | grep -qE '(^|[[:space:]])0\.0\.0\.0:'; then
      printf 'public-port\t%s\t%s\n' "${name}" "$(printf '%s' "${ports}" | grep -oE '0\.0\.0\.0:[0-9]+' | head -1)"
    fi
    if [[ "${image}" == *:latest ]]; then
      printf 'latest\t%s\t%s\n' "${name}" "${image}"
    fi
  done < <("${DOCKER_BIN}" ps -aq 2>/dev/null)
}

hm_docker_audit() {
  local file="${HM_DOCKER_AUDIT:-}" line name restart health priv port image
  if [[ -n "${file}" && -f "${file}" ]]; then
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
    return 0
  fi
  hm_docker_require || return 1
  hm_docker_audit_live
}

hm_docker_updates_live() {
  local id img repo tag newer
  declare -A seen=()
  while IFS= read -r id; do
    [[ -n "${id}" ]] || continue
    img="$("${DOCKER_BIN}" inspect -f '{{.Config.Image}}' "${id}" 2>/dev/null || true)"
    [[ -n "${img}" && "${img}" != *":"* ]] && continue
    [[ -n "${seen[${img}]:-}" ]] && continue
    seen["${img}"]=1
    # bez pull: zapytanie o digest w rejestrze (mockowalny podkomendą)
    newer="$("${DOCKER_BIN}" image inspect --format '{{index .RepoDigests 0}}' "${img}" 2>/dev/null || true)"
    # jeśli mock/env poda mapowanie nowszego tagu
    if [[ -n "${HM_DOCKER_NEWER:-}" ]]; then
      # format: old=new;old2=new2
      local pair
      IFS=';' read -r -a _pairs <<< "${HM_DOCKER_NEWER}"
      for pair in "${_pairs[@]}"; do
        if [[ "${pair%%=*}" == "${img}" ]]; then
          printf '%s -> %s\n' "${img}" "${pair#*=}"
        fi
      done
      continue
    fi
    # produkcja: spróbuj registry bez pobierania (manifest)
    if "${DOCKER_BIN}" manifest inspect "${img}" >/dev/null 2>&1; then
      # brak prostego „nowszy tag” bez API — zgłoś floating :latest
      if [[ "${img}" == *:latest ]]; then
        printf '%s -> (floating latest)\n' "${img}"
      fi
    fi
  done < <("${DOCKER_BIN}" ps -aq 2>/dev/null)
}

hm_docker_updates() {
  local file="${HM_DOCKER_UPDATES:-}"
  if [[ -n "${file}" && -f "${file}" ]]; then
    awk 'NF >= 2 { printf "%s -> %s\n", $1, $2 }' "${file}"
    return 0
  fi
  hm_docker_require || return 1
  hm_docker_updates_live
}
