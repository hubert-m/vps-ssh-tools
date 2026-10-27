#!/usr/bin/env bash
# pm2 / node / apps — procesy Node/React/Next pod PM2 + porty + powiązanie ze stronami

hm_pm2_unix_home() {
  local user="$1"
  [[ -n "${user}" ]] || return 1
  getent passwd "${user}" 2>/dev/null | cut -d: -f6
}

hm_pm2_bin_in_home() {
  # najnowszy nvm/pm2 w danym $HOME (nie bierz pierwszego globa z innego serwisu)
  local home="$1"
  [[ -n "${home}" && -d "${home}" ]] || return 1
  local oldnull c best=""
  oldnull="$(shopt -p nullglob || true)"
  shopt -s nullglob
  local cands=(
    "${home}/.nvm/versions/node/"*/bin/pm2
    "${home}/node_modules/.bin/pm2"
    "${home}/.local/share/pnpm/pm2"
  )
  eval "${oldnull}" 2>/dev/null || shopt -u nullglob
  while IFS= read -r c; do
    [[ -x "${c}" ]] && best="${c}"
  done < <(printf '%s\n' "${cands[@]}" | sort -V)
  [[ -n "${best}" ]] || return 1
  printf '%s' "${best}"
}

hm_pm2_site_homes() {
  # katalogi-kandydaci na HOME strony (kolejność: root → /home/domena → home usera)
  local -a out=()
  local h
  if [[ -n "${HM_SITE_ROOT:-}" && -d "${HM_SITE_ROOT}" ]]; then
    out+=("${HM_SITE_ROOT}")
  fi
  if [[ -n "${HM_SITE_DOMAIN:-}" && -d "/home/${HM_SITE_DOMAIN}" ]]; then
    out+=("/home/${HM_SITE_DOMAIN}")
  fi
  if [[ -n "${HM_SITE_USER:-}" ]]; then
    h="$(hm_pm2_unix_home "${HM_SITE_USER}" || true)"
    [[ -n "${h}" && -d "${h}" ]] && out+=("${h}")
  fi
  # unikalne zachowując kolejność
  local seen="|" x
  for x in "${out[@]}"; do
    [[ "${seen}" == *"|${x}|"* ]] && continue
    seen="${seen}${x}|"
    printf '%s\n' "${x}"
  done
}

hm_pm2_bin_system() {
  # pm2 do odpytania jlist — bez losowego /home/*/nvm
  local c best="" oldnull
  if hm_have_cmd pm2; then
    command -v pm2
    return 0
  fi
  oldnull="$(shopt -p nullglob || true)"
  shopt -s nullglob
  local candidates=(
    /usr/bin/pm2
    /usr/local/bin/pm2
    /root/.nvm/versions/node/*/bin/pm2
  )
  eval "${oldnull}" 2>/dev/null || shopt -u nullglob
  while IFS= read -r c; do
    [[ -x "${c}" ]] && best="${c}"
  done < <(printf '%s\n' "${candidates[@]}" | sort -V)
  [[ -n "${best}" ]] && { printf '%s' "${best}"; return 0; }
  return 1
}

hm_pm2_bin() {
  local c h
  # 1) kontekst strony — preferuj nvm/pm2 z home tej strony
  if [[ -n "${HM_SITE_DOMAIN:-}" ]]; then
    while IFS= read -r h; do
      [[ -n "${h}" ]] || continue
      c="$(hm_pm2_bin_in_home "${h}" || true)"
      if [[ -n "${c}" ]]; then
        printf '%s' "${c}"
        return 0
      fi
    done < <(hm_pm2_site_homes)
    # brak lokalnego nvm — systemowy pm2 (PM2_HOME i tak ze strony)
    if c="$(hm_pm2_bin_system)"; then
      printf '%s' "${c}"
      return 0
    fi
    return 1
  fi
  # 2) globalnie
  if c="$(hm_pm2_bin_system)"; then
    printf '%s' "${c}"
    return 0
  fi
  # 3) ostatnia deska: nvm z /home (tylko poza use)
  local oldnull best=""
  oldnull="$(shopt -p nullglob || true)"
  shopt -s nullglob
  local candidates=(/home/*/.nvm/versions/node/*/bin/pm2)
  eval "${oldnull}" 2>/dev/null || shopt -u nullglob
  while IFS= read -r c; do
    [[ -x "${c}" ]] && best="${c}"
  done < <(printf '%s\n' "${candidates[@]}" | sort -V)
  [[ -n "${best}" ]] && { printf '%s' "${best}"; return 0; }
  return 1
}

hm_pm2_home_dirs() {
  # lista PM2_HOME do odpytania (w kontekście: tylko strona; globalnie: wszystkie)
  local h seen="|"
  if [[ -n "${HM_SITE_DOMAIN:-}" ]]; then
    while IFS= read -r h; do
      [[ -n "${h}" && -d "${h}/.pm2" ]] || continue
      [[ "${seen}" == *"|${h}/.pm2|"* ]] && continue
      seen="${seen}${h}/.pm2|"
      printf '%s\n' "${h}/.pm2"
    done < <(hm_pm2_site_homes)
    return 0
  fi
  local oldnull
  oldnull="$(shopt -p nullglob || true)"
  shopt -s nullglob
  local homes=(/root/.pm2 /home/*/.pm2)
  eval "${oldnull}" 2>/dev/null || shopt -u nullglob
  for h in "${homes[@]}"; do
    [[ -d "${h}" ]] || continue
    printf '%s\n' "${h}"
  done
}

hm_pm2_jlist() {
  local bin json home
  local -a parts=()
  bin="$(hm_pm2_bin)" || return 1

  while IFS= read -r home; do
    [[ -n "${home}" && -d "${home}" ]] || continue
    json="$(PM2_HOME="${home}" "${bin}" jlist 2>/dev/null || true)"
    if [[ -n "${json}" && "${json}" != "[]" ]]; then
      parts+=("${json}")
    fi
  done < <(hm_pm2_home_dirs)

  # poza kontekstem / gdy pusto: spróbuj jeszcze domyślnego env binarki
  if [[ "${#parts[@]}" -eq 0 && -z "${HM_SITE_DOMAIN:-}" ]]; then
    json="$("${bin}" jlist 2>/dev/null || true)"
    if [[ -n "${json}" && "${json}" != "[]" ]]; then
      parts+=("${json}")
    fi
  fi

  # w kontekście strony: jeśli lokalny PM2_HOME pusty — fallback globalny + filtr match_site
  if [[ "${#parts[@]}" -eq 0 && -n "${HM_SITE_DOMAIN:-}" ]]; then
    local oldnull
    oldnull="$(shopt -p nullglob || true)"
    shopt -s nullglob
    local homes=(/root/.pm2 /home/*/.pm2)
    eval "${oldnull}" 2>/dev/null || shopt -u nullglob
    for home in "${homes[@]}"; do
      [[ -d "${home}" ]] || continue
      json="$(PM2_HOME="${home}" "${bin}" jlist 2>/dev/null || true)"
      if [[ -n "${json}" && "${json}" != "[]" ]]; then
        parts+=("${json}")
      fi
    done
  fi

  if [[ "${#parts[@]}" -eq 0 ]]; then
    echo "[]"
    return 0
  fi
  if hm_have_cmd jq && [[ "${#parts[@]}" -gt 1 ]]; then
    printf '%s\n' "${parts[@]}" | jq -s 'add | unique_by([.name, .pid])' 2>/dev/null \
      || printf '%s\n' "${parts[0]}"
  elif hm_have_cmd jq; then
    printf '%s\n' "${parts[0]}"
  else
    printf '%s\n' "${parts[0]}"
  fi
}

hm_pm2_describe_context() {
  # krótki opis bin + PM2_HOME dla UI
  local bin homes
  bin="$(hm_pm2_bin 2>/dev/null || true)"
  homes="$(hm_pm2_home_dirs 2>/dev/null | paste -sd ',' - || true)"
  printf 'bin=%s' "${bin:-?}"
  [[ -n "${homes}" ]] && printf '  PM2_HOME=%s' "${homes}"
  printf '\n'
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
      # regex w zmiennych — unika błędów parsowania [= ] / [[:space:]] w =~
      local re_num='^[0-9]+$'
      local re_port_eq='PORT(=|:)([0-9]+)'
      local re_port_flag='(^|[[:space:]])(-p|--port)(=|[[:space:]])([0-9]+)'
      if [[ "${porthint}" =~ $re_num ]]; then
        port="${porthint}"
      elif [[ "${porthint}" =~ $re_port_eq ]]; then
        port="${BASH_REMATCH[2]}"
      elif [[ "${porthint}" =~ $re_port_flag ]]; then
        port="${BASH_REMATCH[4]}"
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

hm_pm2_status_color() {
  local s
  s="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "${s}" in
    online|launching) printf '%s' "${C_GREEN}" ;;
    stopped|errored|stopping) printf '%s' "${C_RED}" ;;
    *) printf '%s' "${C_YELLOW}" ;;
  esac
}

hm_pm2_print_table() {
  # stdin: name|pid|status|cwd|script|port|mem|restarts — sortuj po porcie
  local -a rows=()
  local name pid status cwd script port mem restarts line sortkey
  while IFS='|' read -r name pid status cwd script port mem restarts; do
    [[ -n "${name}" ]] || continue
    if [[ "${port}" =~ ^[0-9]+$ ]]; then
      sortkey=$(printf '%05d' "${port}")
    else
      sortkey="99999"
    fi
    rows+=("${sortkey}|${name}|${pid}|${status}|${cwd}|${script}|${port}|${mem}|${restarts}")
  done

  printf '  %s%-24s %-8s %-10s %6s %8s %5s  %s%s\n' \
    "${C_DIM}" "NAME" "PID" "STATUS" "PORT" "MEM(MB)" "RST" "CWD" "${C_RESET}"
  printf '  %s%s%s\n' "${C_DIM}" "$(printf '%.0s─' {1..78})" "${C_RESET}"

  if [[ "${#rows[@]}" -eq 0 ]]; then
    echo "  (brak procesów PM2 — sprawdź PM2_HOME użytkownika strony)"
    return 0
  fi

  local stc
  while IFS='|' read -r sortkey name pid status cwd script port mem restarts; do
    [[ -n "${name}" ]] || continue
    stc="$(hm_pm2_status_color "${status}")"
    printf '  %-24s %-8s %s%-10s%s %6s %8s %5s  %s\n' \
      "${name:0:24}" \
      "${pid}" \
      "${stc}" "${status:0:10}" "${C_RESET}" \
      "${port:--}" \
      "${mem:--}" \
      "${restarts:--}" \
      "${cwd:--}"
  done < <(printf '%s\n' "${rows[@]}" | sort -t'|' -k1,1)
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
  echo "${C_BOLD}Proxy OLS → porty backend${C_RESET} ${C_DIM}(sort: port ↑)${C_RESET}"
  printf '  %s%6s%s  %s%s%s\n' "${C_DIM}" "PORT" "${C_RESET}" "${C_DIM}" "DOMAIN" "${C_RESET}"
  printf '  %s%s%s\n' "${C_DIM}" "$(printf '%.0s─' {1..56})" "${C_RESET}"

  local domain port any=0
  local -a rows=()
  while IFS=$'\t' read -r domain port; do
    [[ -n "${domain}" && -n "${port}" ]] || continue
    any=1
    rows+=("${port}"$'\t'"${domain}")
  done < <(hm_ols_proxy_ports_global)

  if [[ "${any}" -eq 0 ]]; then
    echo "  (brak extprocessor type proxy w vhostach)"
    echo
    return 0
  fi

  while IFS=$'\t' read -r port domain; do
    [[ -n "${port}" ]] || continue
    printf '  %s%6s%s  %s\n' "${C_CYAN}" "${port}" "${C_RESET}" "${domain}"
  done < <(printf '%s\n' "${rows[@]}" | sort -t$'\t' -k1,1n -k2,2)

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
      echo
      echo "${C_BOLD}PM2 procesy${C_RESET}"
      echo "  ${C_DIM}$(hm_pm2_describe_context | tr -d '\n')${C_RESET}"
      if [[ -n "${HM_SITE_DOMAIN}" ]]; then
        echo "  ${C_DIM}filtr: ${HM_SITE_DOMAIN}  user=${HM_SITE_USER:--}  root=${HM_SITE_ROOT:--}${C_RESET}"
        echo
        hm_pm2_parse_apps | hm_pm2_match_site "${HM_SITE_DOMAIN}" "${HM_SITE_ROOT}" | hm_pm2_print_table
        echo
        local stack
        stack="$(hm_detect_node_stack "${HM_SITE_DOCROOT}")"
        [[ -z "${stack}" && -n "${HM_SITE_ROOT}" ]] && stack="$(hm_detect_node_stack "${HM_SITE_ROOT}")"
        [[ -z "${stack}" && -n "${HM_SITE_ROOT}" ]] && stack="$(hm_detect_node_stack "${HM_SITE_ROOT}/app")"
        echo "  Stack: ${stack:-nie wykryto next/react/…}"
        local p
        p="$(hm_ols_proxy_ports_for_domain "${HM_SITE_DOMAIN}" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
        echo "  Proxy OLS: ${C_CYAN}${p:-—}${C_RESET}"
        echo
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
      echo
      echo "${C_BOLD}PM2 procesy${C_RESET} ${C_DIM}(wszystkie)${C_RESET}"
      echo "  ${C_DIM}$(hm_pm2_describe_context | tr -d '\n')${C_RESET}"
      echo
      # all = bez kontekstu strony
      local _sd="${HM_SITE_DOMAIN:-}"
      HM_SITE_DOMAIN=""
      hm_pm2_parse_apps | hm_pm2_print_table
      HM_SITE_DOMAIN="${_sd}"
      echo
      hm_print_proxy_map
      ;;
    proxy)
      echo
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
      echo
      echo "${C_BOLD}Nasłuchujące porty (node/pm2/next)${C_RESET} ${C_DIM}(sort: port ↑)${C_RESET}"
      printf '  %s%6s  %s%s\n' "${C_DIM}" "PORT" "ADRES / PROCES" "${C_RESET}"
      printf '  %s%s%s\n' "${C_DIM}" "$(printf '%.0s─' {1..56})" "${C_RESET}"
      if hm_have_cmd ss; then
        ss -lntp 2>/dev/null | awk '
          NR==1 { next }
          /node|pm2|next/ {
            n = split($4, a, ":");
            port = a[n];
            if (port ~ /^[0-9]+$/) printf "%s\t%s\n", port, $0;
          }
        ' | sort -n -k1,1 | while IFS=$'\t' read -r port rest; do
          printf '  %s%6s%s  %s\n' "${C_CYAN}" "${port}" "${C_RESET}" "${rest}"
        done
      else
        hm_warn "Brak ss — zainstaluj iproute."
      fi
      echo
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
