#!/usr/bin/env bash
# Moduł: docker — kontenery / compose + mapowanie na proxy OLS


_hm_cmd_help docker <<'EOF'
Użycie:
  docker | status              Lista kontenerów (nazwa, obraz, status, porty, stack, domena OLS)
  docker all                   Wszystkie (ignoruj filtr kontekstu use)
  docker logs <nazwa> [N] [--follow]
  docker restart|stop|start <nazwa>
  docker compose ls
  docker compose pull <stack>
  docker compose up <stack>
  docker prune [--images] [--volumes] [--dry-run]
                               Domyślnie dry-run; --volumes wymaga critical confirm

W kontekście use <domena>: tylko kontenery powiązane z portami proxy OLS tej strony.
Wymaga CLI docker. Brak Dockera → czytelny komunikat (detect / FORCE_DOCKER).
EOF

hm_docker_require() {
  hm_detect_docker 2>/dev/null || true
  if [[ -n "${FORCE_DOCKER:-}" ]]; then
    case "${FORCE_DOCKER}" in
      yes) DOCKER="yes"; DOCKER_SOURCE="override:FORCE_DOCKER" ;;
      no)
        DOCKER="no"
        hm_err "Docker wyłączony (FORCE_DOCKER=no)."
        return 1
        ;;
    esac
  fi
  if [[ "${DOCKER:-no}" != "yes" || -z "${DOCKER_BIN:-}" || ! -x "${DOCKER_BIN}" ]]; then
    hm_err "Brak Dockera (CLI docker nie wykryte)."
    hm_info "Sprawdź: detect   | nadpisanie: FORCE_DOCKER=yes|no w hmtools.conf"
    return 1
  fi
  if ! "${DOCKER_BIN}" info >/dev/null 2>&1; then
    hm_err "Docker CLI jest, ale daemon nie odpowiada (docker info)."
    return 1
  fi
  return 0
}

hm_docker_run_compose() {
  # $1=workdir, dalsze = args compose (pull/up -d/…)
  local workdir="$1"
  shift
  hm_docker_require || return 1
  if [[ ! -d "${workdir}" ]]; then
    hm_err "Katalog stacka nie istnieje: ${workdir}"
    return 1
  fi
  if "${DOCKER_BIN}" compose version >/dev/null 2>&1 || [[ "${DOCKER_COMPOSE}" == "plugin" ]]; then
    (cd "${workdir}" && "${DOCKER_BIN}" compose "$@")
    return $?
  fi
  if hm_have_cmd docker-compose; then
    (cd "${workdir}" && docker-compose "$@")
    return $?
  fi
  hm_err "Brak docker compose / docker-compose."
  return 1
}

# Mapa port→domena z OLS (cache per wywołanie listy).
hm_docker_ols_port_map() {
  declare -gA HM_DOCKER_PORT_DOMAIN=()
  local domain port
  if declare -F hm_ols_proxy_ports_global >/dev/null 2>&1; then
    while IFS=$'\t' read -r domain port; do
      [[ -n "${domain}" && -n "${port}" ]] || continue
      if [[ -n "${HM_DOCKER_PORT_DOMAIN[${port}]:-}" ]]; then
        HM_DOCKER_PORT_DOMAIN["${port}"]="${HM_DOCKER_PORT_DOMAIN[${port}]},${domain}"
      else
        HM_DOCKER_PORT_DOMAIN["${port}"]="${domain}"
      fi
    done < <(hm_ols_proxy_ports_global 2>/dev/null || true)
  fi
}

hm_docker_domains_for_ports() {
  # stdin/args: lista portów → unikalne domeny
  local p d out="" seen="|"
  for p in "$@"; do
    [[ -n "${p}" ]] || continue
    d="${HM_DOCKER_PORT_DOMAIN[${p}]:-}"
    [[ -n "${d}" ]] || continue
    local part
    IFS=',' read -r -a _parts <<< "${d}"
    for part in "${_parts[@]}"; do
      [[ -n "${part}" ]] || continue
      [[ "${seen}" == *"|${part}|"* ]] && continue
      seen+="${part}|"
      out+="${out:+,}${part}"
    done
  done
  printf '%s' "${out:--}"
}

# Linie: name|image|status|ports|stack|workdir|cpu|mem
hm_docker_list_raw() {
  hm_docker_require || return 1
  local id name image status ports stack workdir stats cpu mem
  while IFS= read -r id; do
    [[ -n "${id}" ]] || continue
    name="$("${DOCKER_BIN}" inspect -f '{{.Name}}' "${id}" 2>/dev/null | sed 's#^/##')"
    image="$("${DOCKER_BIN}" inspect -f '{{.Config.Image}}' "${id}" 2>/dev/null)"
    status="$("${DOCKER_BIN}" inspect -f '{{.State.Status}}' "${id}" 2>/dev/null)"
    ports="$("${DOCKER_BIN}" port "${id}" 2>/dev/null | awk -F'[: ]' '
      {
        # 80/tcp -> 0.0.0.0:8080
        for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/ && $(i-1) !~ /\//) host=$i
        if (host != "") { print host; host="" }
      }' | sort -nu | tr '\n' ',' | sed 's/,$//')"
    # prostszy parser portów hosta
    if [[ -z "${ports}" ]]; then
      ports="$("${DOCKER_BIN}" port "${id}" 2>/dev/null | grep -oE ':[0-9]+$' | tr -d ':' | sort -nu | tr '\n' ',' | sed 's/,$//')"
    fi
    stack="$("${DOCKER_BIN}" inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "${id}" 2>/dev/null)"
    workdir="$("${DOCKER_BIN}" inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "${id}" 2>/dev/null)"
    [[ "${stack}" == "<no value>" ]] && stack=""
    [[ "${workdir}" == "<no value>" ]] && workdir=""
    cpu="-"; mem="-"
    stats="$("${DOCKER_BIN}" stats --no-stream --format '{{.CPUPerc}}|{{.MemUsage}}' "${id}" 2>/dev/null | head -1 || true)"
    if [[ -n "${stats}" ]]; then
      cpu="${stats%%|*}"
      mem="${stats#*|}"
      mem="${mem%%/*}"
    fi
    printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "${name:--}" "${image:--}" "${status:--}" "${ports:--}" \
      "${stack:--}" "${workdir:--}" "${cpu:--}" "${mem:--}"
  done < <("${DOCKER_BIN}" ps -aq 2>/dev/null)
}

hm_docker_filter_for_site() {
  # filtruj linie list_raw do domeny HM_SITE_DOMAIN (po portach)
  local domain="${1:-}"
  local line name image status ports stack workdir cpu mem p match
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    IFS='|' read -r name image status ports stack workdir cpu mem <<<"${line}"
    match=0
    if [[ -z "${domain}" ]]; then
      match=1
    else
      IFS=',' read -r -a _ps <<< "${ports}"
      for p in "${_ps[@]}"; do
        [[ -n "${p}" && "${p}" != "-" ]] || continue
        case ",${HM_DOCKER_PORT_DOMAIN[${p}]:-}," in
          *",${domain},"*) match=1; break ;;
        esac
      done
      # fallback: nazwa kontenera / stack zawiera domenę
      if [[ "${match}" -eq 0 ]]; then
        case "${name}${stack}" in
          *"${domain}"*) match=1 ;;
        esac
      fi
    fi
    [[ "${match}" -eq 1 ]] && printf '%s\n' "${line}"
  done
  return 0
}

cmd_docker_list() {
  local force_all="${1:-0}"
  hm_docker_require || return 1
  hm_docker_ols_port_map

  local filter_domain=""
  if [[ "${force_all}" -eq 0 && -n "${HM_SITE_DOMAIN:-}" ]]; then
    filter_domain="${HM_SITE_DOMAIN}"
    echo "${C_BOLD}Docker — kontekst ${filter_domain}${C_RESET} ${C_DIM}(powiązanie przez porty OLS proxy)${C_RESET}"
  else
    echo "${C_BOLD}Docker — kontenery${C_RESET}"
  fi
  echo
  printf '  %s%-22s %-18s %-10s %-14s %-18s %s%s\n' \
    "${C_DIM}" "NAME" "STATUS" "CPU" "MEM" "PORTS" "OLS / STACK" "${C_RESET}"
  printf '  %s%s%s\n' "${C_DIM}" "$(printf '%.0s─' {1..100})" "${C_RESET}"

  local line name image status ports stack workdir cpu mem domains label n=0
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    IFS='|' read -r name image status ports stack workdir cpu mem <<<"${line}"
    n=$((n + 1))
    local -a parr=()
    IFS=',' read -r -a parr <<< "${ports}"
    domains="$(hm_docker_domains_for_ports "${parr[@]:-}")"
    label="${domains}"
    if [[ -n "${stack}" && "${stack}" != "-" ]]; then
      label="${label} [${stack}]"
    fi
    printf '  %-22s %-18s %-10s %-14s %-18s %s\n' \
      "${name:0:22}" "${status:0:18}" "${cpu:0:10}" "${mem:0:14}" "${ports:0:18}" "${label}"
  done < <(hm_docker_list_raw | hm_docker_filter_for_site "${filter_domain}")

  if [[ "${n}" -eq 0 ]]; then
    if [[ -n "${filter_domain}" ]]; then
      hm_warn "Brak kontenerów powiązanych z ${filter_domain} (porty proxy / nazwa)."
      hm_info "Pełna lista: docker all"
    else
      hm_warn "Brak kontenerów."
    fi
  fi
}

cmd_docker_logs() {
  hm_docker_require || return 1
  local name="" lines=100 follow=0
  local -a raw=("$@")
  local i=0 a
  while [[ "${i}" -lt "${#raw[@]}" ]]; do
    a="${raw[i]}"
    case "${a}" in
      --follow|-f) follow=1 ;;
      -n)
        i=$((i + 1))
        lines="${raw[i]:-}"
        [[ "${lines}" =~ ^[0-9]+$ ]] || { hm_err "Użycie: -n <liczba>"; return 1; }
        ;;
      -n*)
        lines="${a#-n}"
        [[ "${lines}" =~ ^[0-9]+$ ]] || { hm_err "Użycie: -n<liczba>"; return 1; }
        ;;
      -*)
        hm_err "Nieznana flaga: ${a}"
        return 1
        ;;
      *)
        if [[ -z "${name}" ]]; then
          name="${a}"
        elif [[ "${a}" =~ ^[0-9]+$ ]]; then
          lines="${a}"
        else
          hm_err "Nieznany argument: ${a}"
          return 1
        fi
        ;;
    esac
    i=$((i + 1))
  done
  [[ -n "${name}" ]] || {
    hm_err "Użycie: docker logs <nazwa> [N] [--follow]"
    return 1
  }
  if [[ "${follow}" -eq 1 ]]; then
    hm_run "${DOCKER_BIN}" logs -f --tail "${lines}" "${name}"
  else
    hm_run "${DOCKER_BIN}" logs --tail "${lines}" "${name}"
  fi
}

cmd_docker_action() {
  local action="$1"
  shift || true
  local name="${1:-}"
  [[ -n "${name}" ]] || {
    hm_err "Użycie: docker ${action} <nazwa>"
    return 1
  }
  hm_docker_require || return 1
  if ! hm_confirm_plan "docker ${action} — ${name}" \
    "Zmiana stanu kontenera ${name}." \
    "docker ${action} ${name}"; then
    return 1
  fi
  hm_run "${DOCKER_BIN}" "${action}" "${name}" || return 1
  hm_ok "docker ${action} ${name} OK."
}

hm_docker_stack_workdir() {
  local stack="$1"
  local line name _i _s _p st wd
  while IFS= read -r line; do
    IFS='|' read -r name _i _s _p st wd _ <<<"${line}"
    if [[ "${st}" == "${stack}" && -n "${wd}" && "${wd}" != "-" && -d "${wd}" ]]; then
      printf '%s' "${wd}"
      return 0
    fi
  done < <(hm_docker_list_raw)
  return 1
}

cmd_docker_compose() {
  hm_docker_require || return 1
  local sub="${1:-ls}"
  shift || true
  case "${sub}" in
    ls|list)
      if "${DOCKER_BIN}" compose ls >/dev/null 2>&1; then
        hm_run "${DOCKER_BIN}" compose ls
      elif hm_have_cmd docker-compose; then
        hm_warn "docker compose ls niedostępne — lista stacków z labeli kontenerów:"
        hm_docker_list_raw | awk -F'|' '$5!="-" && $5!=""{print $5"\t"$6}' | sort -u | sed 's/^/  /'
      else
        hm_err "Brak docker compose."
        return 1
      fi
      ;;
    pull|up)
      local stack="${1:-}"
      [[ -n "${stack}" ]] || {
        hm_err "Użycie: docker compose ${sub} <stack>"
        return 1
      }
      local wd
      wd="$(hm_docker_stack_workdir "${stack}")" || {
        hm_err "Nie znaleziono working_dir dla stacka „${stack}” (label compose)."
        return 1
      }
      local -a plan=(
        "Katalog stacka: ${wd}"
        "docker compose ${sub} (tylko ten projekt)"
      )
      if [[ "${sub}" == "pull" ]]; then
        plan+=("Pobranie nowszych obrazów z rejestru")
      else
        plan+=("Odświeżenie kontenerów (up -d)")
      fi
      if ! hm_confirm_plan "docker compose ${sub} — ${stack}" \
        "Operacja na stacku compose w ${wd}." \
        "${plan[@]}"; then
        return 1
      fi
      if [[ "${sub}" == "pull" ]]; then
        hm_docker_run_compose "${wd}" pull || return 1
      else
        hm_docker_run_compose "${wd}" up -d || return 1
      fi
      hm_ok "compose ${sub} ${stack} OK."
      ;;
    *)
      hm_err "Użycie: docker compose ls|pull <stack>|up <stack>"
      return 1
      ;;
  esac
}

cmd_docker_prune() {
  hm_docker_require || return 1
  local images=0 volumes=0 dry=1 a
  for a in "$@"; do
    case "${a}" in
      --images) images=1 ;;
      --volumes) volumes=1 ;;
      --dry-run) dry=1 ;;
      --execute|--apply|-y|--yes) dry=0 ;;
      -h|--help)
        hm_info "Użycie: docker prune [--images] [--volumes] [--dry-run|--execute]"
        hm_info "Domyślnie dry-run. --volumes wymaga wpisania „volumes”."
        return 0
        ;;
      *)
        hm_err "Nieznana flaga: ${a}"
        return 1
        ;;
    esac
  done

  echo "${C_BOLD}docker system df${C_RESET}"
  hm_run "${DOCKER_BIN}" system df || true
  echo

  if [[ "${dry}" -eq 1 ]]; then
    hm_info "Tryb dry-run — nic nie usuwam. Aby wykonać: docker prune [--images] [--execute]"
    if [[ "${volumes}" -eq 1 ]]; then
      hm_warn "--volumes w dry-run: pokażę tylko ostrzeżenie (volume prune jest destrukcyjne)."
    fi
    hm_run "${DOCKER_BIN}" system prune -f --filter "until=0s" --dry-run 2>/dev/null \
      || hm_info "(docker nie wspiera --dry-run na system prune — df powyżej = szacunek)"
    return 0
  fi

  local -a plan=(
    "docker system prune -f (dangling containers/networks/images build cache)"
  )
  [[ "${images}" -eq 1 ]] && plan+=("Dodatkowo: nieużywane obrazy (-a)")
  if [[ "${volumes}" -eq 1 ]]; then
    if ! hm_confirm_plan_critical "volumes" \
      "docker prune --volumes — NIEODWRACALNE" \
      "Usunięcie nieużywanych wolumenów Docker (UTRATY DANYCH DB!)." \
      "docker volume prune -f"; then
      return 1
    fi
  fi
  if ! hm_confirm_plan "docker prune" \
    "Usunięcie nieużywanych obiektów Dockera." \
    "${plan[@]}"; then
    return 1
  fi

  local -a args=(-f)
  [[ "${images}" -eq 1 ]] && args+=(-a)
  hm_run "${DOCKER_BIN}" system prune "${args[@]}" || return 1
  if [[ "${volumes}" -eq 1 ]]; then
    hm_run "${DOCKER_BIN}" volume prune -f || return 1
  fi
  hm_ok "prune zakończone."
  hm_run "${DOCKER_BIN}" system df || true
}

cmd_docker() {
  case "${1:-}" in
    ""|status|list|ls)
      shift || true
      cmd_docker_list 0
      ;;
    all)
      shift || true
      cmd_docker_list 1
      ;;
    logs|log)
      shift || true
      cmd_docker_logs "$@"
      ;;
    restart|stop|start)
      cmd_docker_action "$@"
      ;;
    compose|c)
      shift || true
      cmd_docker_compose "$@"
      ;;
    prune|clean)
      shift || true
      cmd_docker_prune "$@"
      ;;
    help|-h|--help)
      hm_help_topic docker
      ;;
    *)
      # docker <name> → traktuj jako status filtrowany? nie — błąd
      hm_err "Nieznana podkomenda: ${1}"
      hm_help_topic docker
      return 1
      ;;
  esac
}

_hm_cmd_register docker cmd_docker 0
_hm_cmd_register_site docker cmd_docker
