#!/usr/bin/env bash
# Komenda: redis — detekcja, diagnostyka, powiązania ze stronami, mutacje


_hm_cmd_help redis <<'EOF'
Użycie:
  redis | redis status          PING, wersja, RAM, klienci, bind
  redis detect                  Wykryte ścieżki (conf/sock/service)
  redis info [section]          INFO (server|memory|clients|keyspace|…)
  redis memory                  used/peak/rss + MEMORY STATS
  redis dbs | keyspace          Bazy: keys / expires / avg_ttl
  redis clients                 CLIENT LIST (skrót)
  redis slowlog [N]             SLOWLOG GET (domyślnie 10)
  redis monitor [sek]           MONITOR przez N sekund (domyślnie 5)
  redis sites | who             Strony wskazujące na Redis (.env / WP / Laravel)
  redis config get <pattern>
  redis config set <key> <val>  Z potwierdzeniem (bez CONFIG REWRITE)
  redis flushdb [N] | flushall  Z potwierdzeniem
  redis restart                 systemctl/service (confirm)
  redis client kill <id|addr>   CLIENT KILL (confirm)

Wymaga redis-cli i działającej lokalnej instancji. Hasło z requirepass w conf
(nie logowane). W kontekście use: redis sites filtruje do bieżącej domeny.
EOF

_HM_REDIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cli.sh
source "${_HM_REDIS_DIR}/cli.sh"

hm_redis_cmd_detect() {
  hm_redis_detect
  echo "${C_BOLD}Redis — detekcja${C_RESET}"
  echo "  redis-cli : ${REDIS_BIN:--}"
  echo "  conf      : ${REDIS_CONF:--}"
  echo "  host:port : ${REDIS_HOST}:${REDIS_PORT}"
  echo "  sock      : ${REDIS_SOCK:--}"
  echo "  requirepass: $([[ -n "${REDIS_PASS}" ]] && echo 'tak (ukryte)' || echo 'nie')"
  echo "  service   : ${REDIS_SERVICE:--}"
  if [[ -n "${REDIS_BIN}" ]]; then
    local pong
    pong="$(hm_redis_cli PING 2>/dev/null | tr -d '\r' || true)"
    echo "  PING      : ${pong:-FAIL}"
  fi
}

hm_redis_cmd_status() {
  hm_redis_require || return 1
  local ver used clients role mode
  ver="$(hm_redis_info_field server redis_version)"
  used="$(hm_redis_info_field memory used_memory_human)"
  clients="$(hm_redis_info_field clients connected_clients)"
  role="$(hm_redis_info_field replication role)"
  mode="$(hm_redis_info_field server redis_mode)"

  echo "${C_BOLD}Redis — status${C_RESET}"
  echo "  Endpoint  : ${REDIS_SOCK:-${REDIS_HOST}:${REDIS_PORT}}"
  echo "  Version   : ${ver:--}"
  echo "  Mode/role : ${mode:--} / ${role:--}"
  echo "  Memory    : ${used:--}"
  echo "  Clients   : ${clients:--}"
  echo "  Conf      : ${REDIS_CONF:--}"
  echo "  Service   : ${REDIS_SERVICE:--}"
  if hm_redis_bind_is_public; then
    hm_warn "bind w conf wygląda na publiczny (0.0.0.0 / ::) — sprawdź: security ports"
  fi
}

hm_redis_cmd_info() {
  local section="${1:-}"
  hm_redis_require || return 1
  if [[ -n "${section}" ]]; then
    hm_redis_cli INFO "${section}"
  else
    hm_redis_cli INFO
  fi
}

hm_redis_cmd_memory() {
  hm_redis_require || return 1
  echo "${C_BOLD}Redis — memory${C_RESET}"
  local k v
  for k in used_memory_human used_memory_peak_human used_memory_rss_human \
           mem_fragmentation_ratio maxmemory_human maxmemory_policy; do
    v="$(hm_redis_info_field memory "${k}")"
    printf '  %-28s %s\n' "${k}" "${v:--}"
  done
  echo
  if hm_redis_cli MEMORY STATS >/dev/null 2>&1; then
    echo "${C_DIM}MEMORY STATS (fragment):${C_RESET}"
    hm_redis_cli MEMORY STATS 2>/dev/null | head -40
  else
    hm_info "MEMORY STATS niedostępne (stary Redis?)."
  fi
}

hm_redis_cmd_dbs() {
  hm_redis_require || return 1
  echo "${C_BOLD}Redis — keyspace${C_RESET}"
  local line db keys expires avg
  local any=0
  while IFS= read -r line; do
    [[ "${line}" =~ ^db([0-9]+):keys=([0-9]+),expires=([0-9]+),avg_ttl=([0-9]+) ]] || continue
    any=1
    db="${BASH_REMATCH[1]}"
    keys="${BASH_REMATCH[2]}"
    expires="${BASH_REMATCH[3]}"
    avg="${BASH_REMATCH[4]}"
    printf '  db%-3s  keys=%-10s expires=%-10s avg_ttl=%s\n' "${db}" "${keys}" "${expires}" "${avg}"
  done < <(hm_redis_cli INFO keyspace 2>/dev/null)
  if [[ "${any}" -eq 0 ]]; then
    echo "  (pusto — brak kluczy we wszystkich DB)"
  fi
}

hm_redis_cmd_clients() {
  hm_redis_require || return 1
  echo "${C_BOLD}Redis — clients${C_RESET}"
  printf '  %-8s %-22s %-16s %-12s %s\n' "id" "addr" "name" "cmd" "age"
  hm_redis_cli CLIENT LIST 2>/dev/null | while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    local id addr name cmd age
    id="$(printf '%s' "${line}" | sed -n 's/.*\bid=\([0-9]*\).*/\1/p')"
    addr="$(printf '%s' "${line}" | sed -n 's/.*\baddr=\([^ ]*\).*/\1/p')"
    name="$(printf '%s' "${line}" | sed -n 's/.*\bname=\([^ ]*\).*/\1/p')"
    cmd="$(printf '%s' "${line}" | sed -n 's/.*\bcmd=\([^ ]*\).*/\1/p')"
    age="$(printf '%s' "${line}" | sed -n 's/.*\bage=\([0-9]*\).*/\1/p')"
    printf '  %-8s %-22s %-16s %-12s %s\n' "${id:--}" "${addr:--}" "${name:--}" "${cmd:--}" "${age:--}"
  done
}

hm_redis_cmd_slowlog() {
  local n="${1:-10}"
  [[ "${n}" =~ ^[0-9]+$ ]] || n=10
  hm_redis_require || return 1
  echo "${C_BOLD}Redis — slowlog (ostatnie ${n})${C_RESET}"
  hm_redis_cli SLOWLOG GET "${n}"
}

hm_redis_cmd_monitor() {
  local sek="${1:-5}"
  [[ "${sek}" =~ ^[0-9]+$ && "${sek}" -ge 1 ]] || sek=5
  hm_redis_require || return 1
  hm_info "MONITOR przez ${sek}s (timeout)…"
  local -a rargs=()
  if [[ -n "${REDIS_SOCK}" && -S "${REDIS_SOCK}" ]]; then
    rargs+=(-s "${REDIS_SOCK}")
  else
    rargs+=(-h "${REDIS_HOST:-127.0.0.1}" -p "${REDIS_PORT:-6379}")
  fi
  rargs+=(--no-auth-warning MONITOR)
  [[ -n "${REDIS_PASS}" ]] && export REDISCLI_AUTH="${REDIS_PASS}"
  local mrc=0
  hm_run_timeout "${sek}" "${REDIS_BIN}" "${rargs[@]}" || mrc=$?
  # 124 = timeout = oczekiwane zakończenie
  if [[ "${mrc}" -eq 124 || "${mrc}" -eq 0 ]]; then
    hm_ok "MONITOR zakończony."
    return 0
  fi
  hm_warn "MONITOR zakończony z rc=${mrc}."
  return "${mrc}"
}

# --- sites ---

hm_redis_scan_file_hints() {
  # stdout: hint lines for one file; stdin unused; args: file
  local f="$1"
  [[ -f "${f}" ]] || return 1
  local hits=""
  if grep -qiE 'REDIS_(HOST|URL|PASSWORD|PORT)|CACHE_DRIVER[[:space:]]*=[[:space:]]*redis|SESSION_DRIVER[[:space:]]*=[[:space:]]*redis|QUEUE_CONNECTION[[:space:]]*=[[:space:]]*redis' "${f}" 2>/dev/null; then
    hits="${hits}env "
  fi
  if grep -qiE 'WP_REDIS_|define\s*\(\s*['\''\"]REDIS|object-cache|RedisObjectCache' "${f}" 2>/dev/null; then
    hits="${hits}wp "
  fi
  if grep -qiE "['\"]redis['\"]|RedisManager|phpredis|driver[[:space:]]*=>[[:space:]]*['\"]redis['\"]" "${f}" 2>/dev/null; then
    hits="${hits}laravel "
  fi
  # prostszy fallback: słowo redis w kontekście cache/session
  if [[ -z "${hits}" ]] && grep -qiE 'redis' "${f}" 2>/dev/null; then
    if grep -qiE 'cache|session|queue|REDIS' "${f}" 2>/dev/null; then
      hits="redis "
    fi
  fi
  [[ -n "${hits}" ]] || return 1
  printf '%s' "${hits}"
}

hm_redis_cmd_sites() {
  hm_redis_detect
  hm_discover_sites 2>/dev/null || true

  local -a domains=()
  local d
  if [[ -n "${HM_SITE_DOMAIN:-}" ]]; then
    domains=("${HM_SITE_DOMAIN}")
  else
    for d in "${HM_SITES_LIST[@]:-}"; do
      [[ -n "${d}" ]] && domains+=("${d}")
    done
  fi

  echo "${C_BOLD}Redis — powiązania ze stronami${C_RESET}"
  if [[ "${#domains[@]}" -eq 0 ]]; then
    hm_warn "Brak stron na liście (webs / use)."
    return 0
  fi

  local any=0 domain root doc f hint
  for domain in "${domains[@]}"; do
    hm_set_site_context "${domain}" 2>/dev/null || true
    root="${HM_SITE_ROOT:-}"
    doc="${HM_SITE_DOCROOT:-}"
    local -a files=()
    local base
    for base in "${root}" "${doc}"; do
      [[ -n "${base}" && -d "${base}" ]] || continue
      while IFS= read -r f; do
        [[ -n "${f}" ]] && files+=("${f}")
      done < <(
        find "${base}" -maxdepth 4 \( \
          -name '.env' -o -name '.env.*' -o -name 'wp-config.php' \
          -o -name 'object-cache.php' -o -path '*/config/cache.php' \
          -o -path '*/config/database.php' -o -path '*/config/queue.php' \
        \) -type f 2>/dev/null | head -40
      )
    done
    for f in "${files[@]}"; do
      hint="$(hm_redis_scan_file_hints "${f}" 2>/dev/null || true)"
      [[ -n "${hint}" ]] || continue
      any=1
      printf '  %-28s %s  %s\n' "${domain}" "${hint}" "${f}"
    done
  done
  if [[ "${any}" -eq 0 ]]; then
    echo "  (brak heurystycznych trafień .env / WP / Laravel)"
  fi
}

# --- mutations ---

hm_redis_cmd_config() {
  local op="${1:-}"
  shift || true
  hm_redis_require || return 1
  case "${op}" in
    get)
      local pat="${1:-*}"
      hm_redis_cli CONFIG GET "${pat}"
      ;;
    set)
      local key="${1:-}" val="${2:-}"
      [[ -n "${key}" && -n "${val}" ]] || {
        hm_err "Użycie: redis config set <key> <value>"
        return 1
      }
      local cur
      cur="$(hm_redis_cli CONFIG GET "${key}" 2>/dev/null | tail -n 1 || true)"
      if ! hm_confirm_plan "redis config set — ${key}" \
        "Zmiana runtime (bez CONFIG REWRITE — po restarcie wróci wartość z conf)." \
        "CONFIG SET ${key} ${val} (obecnie: ${cur:--})"; then
        return 1
      fi
      if hm_redis_cli CONFIG SET "${key}" "${val}"; then
        hm_ok "CONFIG SET ${key} OK."
        hm_info "Aby utrwalić: edytuj ${REDIS_CONF:-(conf)} lub redis-cli CONFIG REWRITE (ręcznie)."
      else
        hm_err "CONFIG SET nieudany."
        return 1
      fi
      ;;
    *)
      hm_err "Użycie: redis config get|set …"
      return 1
      ;;
  esac
}

hm_redis_cmd_flushdb() {
  local n="${1:-0}"
  [[ "${n}" =~ ^[0-9]+$ ]] || {
    hm_err "Użycie: redis flushdb [N]"
    return 1
  }
  hm_redis_require || return 1
  if ! hm_confirm_plan "redis flushdb ${n}" \
    "Usunie WSZYSTKIE klucze w bazie db${n}." \
    "SELECT ${n}" \
    "FLUSHDB"; then
    return 1
  fi
  hm_redis_cli SELECT "${n}" >/dev/null || return 1
  if hm_redis_cli FLUSHDB; then
    hm_ok "FLUSHDB db${n} OK."
  else
    hm_err "FLUSHDB nieudany."
    return 1
  fi
}

hm_redis_cmd_flushall() {
  hm_redis_require || return 1
  if ! hm_confirm_plan "redis flushall" \
    "Usunie WSZYSTKIE klucze we WSZYSTKICH bazach Redis na tej instancji." \
    "FLUSHALL"; then
    return 1
  fi
  if hm_redis_cli FLUSHALL; then
    hm_ok "FLUSHALL OK."
  else
    hm_err "FLUSHALL nieudany."
    return 1
  fi
}

hm_redis_cmd_restart() {
  hm_redis_detect
  local svc="${REDIS_SERVICE:-redis-server}"
  if ! hm_confirm_plan "redis restart — ${svc}" \
    "Chwilowa niedostępność cache/sesji/kolejek zależnych od Redis." \
    "systemctl restart ${svc} (lub service)"; then
    return 1
  fi
  if hm_have_cmd systemctl; then
    if systemctl restart "${svc}" 2>/dev/null || systemctl restart redis 2>/dev/null \
      || systemctl restart redis-server 2>/dev/null; then
      hm_ok "Redis restart OK (${svc})."
      return 0
    fi
  fi
  if service redis-server restart 2>/dev/null || service redis restart 2>/dev/null; then
    hm_ok "Redis restart OK (service)."
    return 0
  fi
  hm_err "Nie udało się zrestartować Redis (brak unit/service?)."
  return 1
}

hm_redis_cmd_client_kill() {
  local target="${1:-}"
  [[ -n "${target}" ]] || {
    hm_err "Użycie: redis client kill <id|addr>"
    return 1
  }
  hm_redis_require || return 1
  local mode="ID"
  if [[ "${target}" == *.* || "${target}" == *:* ]]; then
    mode="ADDR"
  fi
  if ! hm_confirm_plan "redis client kill — ${mode} ${target}" \
    "Rozłączy klienta Redis." \
    "CLIENT KILL ${mode} ${target}"; then
    return 1
  fi
  if hm_redis_cli CLIENT KILL "${mode}" "${target}"; then
    hm_ok "CLIENT KILL OK."
  else
    hm_err "CLIENT KILL nieudany."
    return 1
  fi
}

cmd_redis() {
  local sub="${1:-status}"
  shift || true
  hm_detect_all 2>/dev/null || true

  case "${sub}" in
    status|stat|"")
      hm_redis_cmd_status
      ;;
    detect|env)
      hm_redis_cmd_detect
      ;;
    info)
      hm_redis_cmd_info "$@"
      ;;
    memory|mem)
      hm_redis_cmd_memory
      ;;
    dbs|db|keyspace|ks)
      hm_redis_cmd_dbs
      ;;
    clients|client)
      if [[ "${1:-}" == "kill" ]]; then
        shift || true
        hm_redis_cmd_client_kill "$@"
      else
        hm_redis_cmd_clients
      fi
      ;;
    slowlog|slow)
      hm_redis_cmd_slowlog "$@"
      ;;
    monitor|mon)
      hm_redis_cmd_monitor "$@"
      ;;
    sites|who|site)
      hm_redis_cmd_sites
      ;;
    config|cfg)
      hm_redis_cmd_config "$@"
      ;;
    flushdb)
      hm_redis_cmd_flushdb "$@"
      ;;
    flushall)
      hm_redis_cmd_flushall
      ;;
    restart)
      hm_redis_cmd_restart
      ;;
    help|-h|--help)
      hm_help_topic redis
      ;;
    *)
      hm_err "Nieznane: ${sub}. redis help"
      return 1
      ;;
  esac
}

_hm_cmd_register redis cmd_redis 0
