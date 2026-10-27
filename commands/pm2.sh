#!/usr/bin/env bash
# pm2 / node / apps — procesy Node/React/Next pod PM2 + porty + powiązanie ze stronami

hm_pm2_bin() {
  if hm_have_cmd pm2; then
    command -v pm2
    return 0
  fi
  # typowe lokalizacje npm/nvm
  local c oldnull
  oldnull="$(shopt -p nullglob || true)"
  shopt -s nullglob
  local candidates=(
    /usr/bin/pm2
    /usr/local/bin/pm2
    /root/.nvm/versions/node/*/bin/pm2
    /home/*/.nvm/versions/node/*/bin/pm2
  )
  eval "${oldnull}" 2>/dev/null || shopt -u nullglob
  for c in "${candidates[@]}"; do
    if [[ -x "${c}" ]]; then
      echo "${c}"
      return 0
    fi
  done
  return 1
}

hm_pm2_jlist() {
  local bin
  bin="$(hm_pm2_bin)" || return 1
  # PM2_HOME czasem pod root / konkretnym userem
  "${bin}" jlist 2>/dev/null || true
}

hm_pid_listen_ports() {
  local pid="$1"
  [[ -n "${pid}" && "${pid}" =~ ^[0-9]+$ ]] || return 0
  if hm_have_cmd ss; then
    ss -lntp 2>/dev/null | awk -v p="pid=${pid}," '
      index($0, p) {
        n = split($4, a, ":");
        if (n > 0 && a[n] ~ /^[0-9]+$/) print a[n];
      }' | sort -nu
    return 0
  fi
  if hm_have_cmd lsof; then
    lsof -nP -a -p "${pid}" -iTCP -sTCP:LISTEN 2>/dev/null \
      | awk 'NR>1 {
          n = split($9, a, ":");
          if (n > 0 && a[n] ~ /^[0-9]+$/) print a[n];
        }' | sort -nu
  fi
}

hm_ols_proxy_ports_for_domain() {
  # z vhosta: address ... :PORT  w extprocessor type proxy
  local domain="$1"
  local conf
  conf="$(hm_vhost_conf_path "${domain}" 2>/dev/null || true)"
  [[ -n "${conf}" && -f "${conf}" ]] || return 0
  awk '
    BEGIN { inext=0; isproxy=0 }
    tolower($1)=="extprocessor" { inext=1; isproxy=0; next }
    inext && tolower($1)=="type" && tolower($2)=="proxy" { isproxy=1 }
    inext && isproxy && tolower($1)=="address" {
      n = split($2, a, ":");
      if (n > 0 && a[n] ~ /^[0-9]+$/) print a[n];
    }
    inext && $0 ~ /^[[:space:]]*\}/ { inext=0; isproxy=0 }
  ' "${conf}" 2>/dev/null | sort -nu
}

hm_ols_proxy_ports_global() {
  # skan wszystkich vhostów → domain\tport
  hm_detect_all
  local domain conf p
  hm_discover_sites
  for domain in "${HM_SITES_LIST[@]}"; do
    while IFS= read -r p; do
      [[ -n "${p}" ]] && printf '%s\t%s\n' "${domain}" "${p}"
    done < <(hm_ols_proxy_ports_for_domain "${domain}")
  done
}

# Parsowanie pm2 jlist bez jq (fallback gdy brak jq)
hm_pm2_parse_apps() {
  # wypisz linie: name|pid|status|cwd|script|port_hint|mem_mb|restarts
  local json
  json="$(hm_pm2_jlist)"
  [[ -n "${json}" && "${json}" != "[]" ]] || return 0

  if hm_have_cmd jq; then
    echo "${json}" | jq -r '
      .[] |
      [
        (.name // "?"),
        (.pid // 0 | tostring),
        (.pm2_env.status // "?"),
        (.pm2_env.pm_cwd // .pm2_env.cwd // ""),
        (.pm2_env.pm_exec_path // .pm2_env.script // ""),
        (
          if ((.pm2_env.env.PORT // .pm2_env.PORT // null) != null) then
            (.pm2_env.env.PORT // .pm2_env.PORT | tostring)
          else
            ((.pm2_env.args // [])
              | if type=="array" then map(tostring)|join(" ") else tostring end)
          end
        ),
        (((.monit.memory // 0) / 1048576 * 10 | floor) / 10 | tostring),
        ((.pm2_env.restart_time // 0) | tostring)
      ] | @tsv
    ' 2>/dev/null | while IFS=$'\t' read -r name pid status cwd script porthint mem restarts; do
      local port=""
      # wyciągnij port: sama liczba, PORT=3000, -p/--port 3000
      if [[ "${porthint}" =~ ^[0-9]+$ ]]; then
        port="${porthint}"
      elif [[ "${porthint}" =~ PORT[=:]([0-9]+) ]]; then
        port="${BASH_REMATCH[1]}"
      elif [[ "${porthint}" =~ (^|[[:space:]])(-p|--port)[= ]([0-9]+) ]]; then
        port="${BASH_REMATCH[3]}"
      fi
      if [[ -z "${port}" && -n "${pid}" && "${pid}" != "0" ]]; then
        port="$(hm_pid_listen_ports "${pid}" | head -1)"
      fi
      printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "${name}" "${pid}" "${status}" "${cwd}" "${script}" "${port:-}" "${mem}" "${restarts}"
    done
    return 0
  fi

  # Uproszczony fallback bez jq — użyj pm2 pretty list + ss
  local bin
  bin="$(hm_pm2_bin)" || return 1
  "${bin}" prettylist 2>/dev/null | awk '
    /^[[:space:]]*name:/ { name=$2; gsub(/[",]/,"",name) }
    /^[[:space:]]*pid:/ { pid=$2; gsub(/[",]/,"",pid) }
    /^[[:space:]]*status:/ { status=$2; gsub(/[",]/,"",status) }
    /pm_cwd:/ { cwd=$2; gsub(/[",]/,"",cwd) }
    /pm_exec_path:/ { script=$2; gsub(/[",]/,"",script) }
    /restart_time:/ { restarts=$2; gsub(/[",]/,"",restarts) }
    /memory:/ { mem=$2; gsub(/[",]/,"",mem) }
    /^[[:space:]]*\}/ && name!="" {
      print name "|" pid "|" status "|" cwd "|" script "||" mem "|" restarts
      name=pid=status=cwd=script=mem=restarts=""
    }
  ' | while IFS='|' read -r name pid status cwd script _ mem restarts; do
      local port=""
      [[ -n "${pid}" && "${pid}" != "0" ]] && port="$(hm_pid_listen_ports "${pid}" | head -1)"
      printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "${name}" "${pid}" "${status}" "${cwd}" "${script}" "${port:-}" "${mem:-?}" "${restarts:-0}"
    done
}

hm_pm2_match_site() {
  # stdin: lines name|...|cwd|...|port|...
  # args: domain site_root → filter matching
  local domain="$1"
  local root="$2"
  local name pid status cwd script port mem restarts
  while IFS='|' read -r name pid status cwd script port mem restarts; do
    [[ -n "${name}" ]] || continue
    local hit=0
    if [[ -n "${root}" && -n "${cwd}" && "${cwd}" == "${root}"* ]]; then
      hit=1
    fi
    if [[ -n "${domain}" && "${name}" == *"${domain}"* ]]; then
      hit=1
    fi
    if [[ -n "${domain}" && -n "${port}" ]]; then
      local vp
      while IFS= read -r vp; do
        [[ "${vp}" == "${port}" ]] && hit=1
      done < <(hm_ols_proxy_ports_for_domain "${domain}")
    fi
    [[ "${hit}" -eq 1 ]] && printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "${name}" "${pid}" "${status}" "${cwd}" "${script}" "${port}" "${mem}" "${restarts}"
  done
}

hm_pm2_print_table() {
  # stdin: name|pid|status|cwd|script|port|mem|restarts
  local any=0
  printf '%-28s %-8s %-8s %-7s %-8s %-6s %s\n' \
    "NAME" "PID" "STATUS" "PORT" "MEM(MB)" "RST" "CWD"
  printf '%-28s %-8s %-8s %-7s %-8s %-6s %s\n' \
    "----" "---" "------" "----" "-------" "---" "---"
  local name pid status cwd script port mem restarts
  while IFS='|' read -r name pid status cwd script port mem restarts; do
    [[ -n "${name}" ]] || continue
    any=1
    printf '%-28s %-8s %-8s %-7s %-8s %-6s %s\n' \
      "${name:0:28}" \
      "${pid}" \
      "${status}" \
      "${port:--}" \
      "${mem:--}" \
      "${restarts:--}" \
      "${cwd:--}"
  done
  if [[ "${any}" -eq 0 ]]; then
    echo "(brak procesów)"
  fi
}

hm_detect_node_stack() {
  # w katalogu: next/react/nuxt/vite markers
  local dir="$1"
  [[ -d "${dir}" ]] || return 0
  local pkg="${dir}/package.json"
  [[ -f "${pkg}" ]] || return 0
  local deps
  deps="$(tr '\n' ' ' < "${pkg}" 2>/dev/null || true)"
  local tags=()
  echo "${deps}" | grep -q '"next"' && tags+=("next")
  echo "${deps}" | grep -q '"react"' && tags+=("react")
  echo "${deps}" | grep -q '"nuxt"' && tags+=("nuxt")
  echo "${deps}" | grep -q '"vite"' && tags+=("vite")
  echo "${deps}" | grep -q '"express"' && tags+=("express")
  echo "${deps}" | grep -q '"nestjs\|@nestjs' && tags+=("nestjs")
  ( IFS=','; echo "${tags[*]}" )
}

hm_print_proxy_map() {
  echo "${C_BOLD}Proxy OLS → porty backend${C_RESET}"
  printf '%-36s %s\n' "DOMAIN" "PORTS"
  printf '%-36s %s\n' "------" "-----"
  local any=0 domain ports
  local -A acc=()
  while IFS=$'\t' read -r domain ports; do
    [[ -n "${domain}" ]] || continue
    any=1
    if [[ -n "${acc[$domain]:-}" ]]; then
      acc[$domain]="${acc[$domain]},${ports}"
    else
      acc[$domain]="${ports}"
    fi
  done < <(hm_ols_proxy_ports_global)
  if [[ "${any}" -eq 0 ]]; then
    echo "(brak extprocessor type proxy w vhostach)"
  else
    local k
    while IFS= read -r k; do
      [[ -n "${k}" ]] || continue
      printf '%-36s %s\n' "${k}" "${acc[$k]}"
    done < <(printf '%s\n' "${!acc[@]}" | sort)
  fi
  echo
}

cmd_pm2() {
  local sub="${1:-list}"
  shift || true

  case "${sub}" in
    list|ls|status|"")
      if ! hm_pm2_bin >/dev/null; then
        hm_warn "PM2 nie jest zainstalowane (lub nie w PATH)."
        hm_info "Pokazuję tylko mapowanie proxy OLS (jeśli jest)."
        echo
        hm_print_proxy_map
        return 0
      fi
      echo "${C_BOLD}PM2 procesy${C_RESET} ($(hm_pm2_bin))"
      if [[ -n "${HM_SITE_DOMAIN}" ]]; then
        echo "Filtr kontekstu: ${HM_SITE_DOMAIN} (user=${HM_SITE_USER:--}, root=${HM_SITE_ROOT:--})"
        echo
        hm_pm2_parse_apps | hm_pm2_match_site "${HM_SITE_DOMAIN}" "${HM_SITE_ROOT}" | hm_pm2_print_table
        echo
        local stack
        stack="$(hm_detect_node_stack "${HM_SITE_DOCROOT}")"
        [[ -z "${stack}" && -n "${HM_SITE_ROOT}" ]] && stack="$(hm_detect_node_stack "${HM_SITE_ROOT}")"
        [[ -z "${stack}" && -n "${HM_SITE_ROOT}" ]] && stack="$(hm_detect_node_stack "${HM_SITE_ROOT}/app")"
        echo "Stack (package.json): ${stack:-nie wykryto next/react/…}"
        echo "Proxy OLS ports:"
        local p
        p="$(hm_ols_proxy_ports_for_domain "${HM_SITE_DOMAIN}" | tr '\n' ',' | sed 's/,$//')"
        echo "  ${p:-—}"
      else
        echo
        hm_pm2_parse_apps | hm_pm2_print_table
        echo
        hm_print_proxy_map
      fi
      ;;
    all)
      if ! hm_pm2_bin >/dev/null; then
        hm_err "Brak pm2 w PATH."
        return 1
      fi
      hm_pm2_parse_apps | hm_pm2_print_table
      echo
      hm_print_proxy_map
      ;;
    proxy)
      hm_print_proxy_map
      ;;
    site)
      local domain="${1:-${HM_SITE_DOMAIN}}"
      [[ -n "${domain}" ]] || { hm_err "Użycie: pm2 site <domena>"; return 1; }
      domain="$(hm_find_site_by_arg "${domain}")" || return 1
      # tymczasowy kontekst — nie zmienia aktywnego REPL use
      local _d="${HM_SITE_DOMAIN:-}" _r="${HM_SITE_ROOT:-}" _u="${HM_SITE_USER:-}" \
            _dr="${HM_SITE_DOCROOT:-}" _v="${HM_SITE_VHOST:-}" _p="${HM_SITE_PHP:-}" \
            _l="${HM_SITE_LOGS:-}" _s="${HM_SITE_STATUS:-}"
      hm_set_site_context "${domain}"
      cmd_pm2 list
      HM_SITE_DOMAIN="${_d}" HM_SITE_ROOT="${_r}" HM_SITE_USER="${_u}"
      HM_SITE_DOCROOT="${_dr}" HM_SITE_VHOST="${_v}" HM_SITE_PHP="${_p}"
      HM_SITE_LOGS="${_l}" HM_SITE_STATUS="${_s}"
      ;;
    ports)
      echo "${C_BOLD}Nasłuchujące porty (node/pm2)${C_RESET}"
      if hm_have_cmd ss; then
        ss -lntp 2>/dev/null | grep -E 'node|pm2|next' || ss -lntp 2>/dev/null | head -40
      else
        hm_warn "Brak ss — zainstaluj iproute."
      fi
      ;;
    raw)
      local bin
      bin="$(hm_pm2_bin)" || { hm_err "Brak pm2."; return 1; }
      "${bin}" list
      ;;
    help|-h|--help)
      hm_help_topic pm2
      ;;
    *)
      hm_err "Nieznane: pm2 ${sub}. Zobacz: help pm2"
      return 1
      ;;
  esac
}

cmd_node() { cmd_pm2 "$@"; }
cmd_apps() { cmd_pm2 "$@"; }
