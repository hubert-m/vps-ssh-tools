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
  printf '  %-8s %-18s %-16s %-12s %s\n' "id" "addr" "name" "cmd" "age"
  hm_redis_cli CLIENT LIST 2>/dev/null | while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    local id addr name cmd age
    id="$(printf '%s' "${line}" | sed -n 's/.*\bid=\([0-9]*\).*/\1/p')"
    addr="$(printf '%s' "${line}" | sed -n 's/.*\baddr=\([^ ]*\).*/\1/p')"
    name="$(printf '%s' "${line}" | sed -n 's/.*\bname=\([^ ]*\).*/\1/p')"
    cmd="$(printf '%s' "${line}" | sed -n 's/.*\bcmd=\([^ ]*\).*/\1/p')"
    age="$(printf '%s' "${line}" | sed -n 's/.*\bage=\([0-9]*\).*/\1/p')"
    # unix socket — skróć do basename
    if [[ "${addr}" == /* ]]; then
      addr="unix:$(basename "${addr}")"
    fi
    printf '  %-8s %-18s %-16s %-12s %s\n' "${id:--}" "${addr:--}" "${name:--}" "${cmd:--}" "${age:--}"
  done
}

hm_redis_cmd_slowlog() {
  local n="${1:-10}"
  if [[ -n "${1:-}" && ! "${1}" =~ ^[0-9]+$ ]]; then
    hm_err "Użycie: redis slowlog [N] — N musi być liczbą całkowitą ≥0."
    return 1
  fi
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
  # stdout: hint tags; args: file
  local f="$1"
  local base
  base="$(basename "${f}")"
  [[ -f "${f}" ]] || return 1
  local hits=""
  # WP najpierw — WP_REDIS_HOST nie oznaczaj jako „env”
  if [[ "${base}" == wp-config.php || "${base}" == object-cache.php ]] \
    || grep -qiE 'WP_REDIS_|object-cache|RedisObjectCache' "${f}" 2>/dev/null; then
    if grep -qiE 'WP_REDIS_|object-cache|RedisObjectCache|define\s*\(\s*['\''\"]REDIS' "${f}" 2>/dev/null; then
      hits="${hits}wp "
    fi
  fi
  if [[ "${base}" == .env || "${base}" == .env.* || "${base}" =~ ^\.env ]]; then
    if grep -qiE '(^|[[:space:]])REDIS_(HOST|URL|PASSWORD|PORT)=|CACHE_DRIVER[[:space:]]*=[[:space:]]*redis|SESSION_DRIVER[[:space:]]*=[[:space:]]*redis|QUEUE_CONNECTION[[:space:]]*=[[:space:]]*redis' "${f}" 2>/dev/null; then
      hits="${hits}env "
    fi
  elif [[ -z "${hits}" ]] && grep -qiE '(^|[[:space:]])REDIS_(HOST|URL|PASSWORD|PORT)=|CACHE_DRIVER[[:space:]]*=[[:space:]]*redis' "${f}" 2>/dev/null; then
    hits="${hits}env "
  fi
  if [[ "${f}" == */config/cache.php || "${f}" == */config/database.php || "${f}" == */config/queue.php ]] \
    || grep -qiE "driver[[:space:]]*=>[[:space:]]*['\"]redis['\"]|RedisManager|phpredis" "${f}" 2>/dev/null; then
    if grep -qiE "['\"]redis['\"]|RedisManager|phpredis|driver[[:space:]]*=>[[:space:]]*['\"]redis['\"]" "${f}" 2>/dev/null; then
      [[ "${hits}" == *laravel* ]] || hits="${hits}laravel "
    fi
  fi
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

  local any=0 domain root doc f hint rp
  local seen="|"
  for domain in "${domains[@]}"; do
    hm_set_site_context "${domain}" 2>/dev/null || true
    root="${HM_SITE_ROOT:-}"
    doc="${HM_SITE_DOCROOT:-}"
    local -a files=()
    local base
    for base in "${root}" "${doc}"; do
      [[ -n "${base}" && -d "${base}" ]] || continue
      while IFS= read -r f; do
        [[ -n "${f}" ]] || continue
        rp="$(realpath -m "${f}" 2>/dev/null || echo "${f}")"
        [[ "${seen}" == *"|${rp}|"* ]] && continue
        seen="${seen}${rp}|"
        files+=("${rp}")
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
      local key="${1:-}"
      shift || true
      # reszta args = jedna wartość (np. save "3600 1")
      local val="$*"
      # zdejmij otaczające cudzysłowy z CLI użytkownika
      if [[ "${val}" =~ ^\".*\"$ ]]; then
        val="${val:1:${#val}-2}"
      elif [[ "${val}" =~ ^\'.*\'$ ]]; then
        val="${val:1:${#val}-2}"
      fi
      [[ -n "${key}" && -n "${val}" ]] || {
        hm_err "Użycie: redis config set <key> <value>"
        hm_info "Wartość ze spacjami: redis config set save \"3600 1\""
        return 1
      }
      local cur
      cur="$(hm_redis_cli CONFIG GET "${key}" 2>/dev/null | tail -n 1 || true)"
      if ! hm_confirm_plan "redis config set — ${key}" \
        "Zmiana runtime (bez CONFIG REWRITE — po restarcie wróci wartość z conf)." \
        "CONFIG SET ${key} ${val} (obecnie: ${cur:--})"; then
        return 1
      fi
      local out
      if ! out="$(hm_redis_cli_checked CONFIG SET "${key}" "${val}")"; then
        hm_err "CONFIG SET nieudany: ${out:-?(brak odpowiedzi)}"
        return 1
      fi
      hm_ok "CONFIG SET ${key} OK."
      hm_info "Aby utrwalić: edytuj ${REDIS_CONF:-(conf)} lub redis-cli CONFIG REWRITE (ręcznie)."
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
  # WAŻNE: redis-cli -n N przy N≥databases robi „SELECT failed” i i tak FLUSHDB na db0.
  # Walidacja ZAKRESU przed confirm — inaczej „nieudany” + utrata danych w db0.
  hm_redis_db_index_ok "${n}" || return 1
  if ! hm_confirm_plan "redis flushdb ${n}" \
    "Usunie WSZYSTKIE klucze w bazie db${n}." \
    "redis-cli -n ${n} FLUSHDB (jedno połączenie; N sprawdzone vs CONFIG databases)"; then
    return 1
  fi
  # Ponowna walidacja po confirm (config mógł się zmienić) + -n w tym samym procesie
  hm_redis_db_index_ok "${n}" || return 1
  local out
  REDIS_CLI_DB="${n}"
  if ! out="$(hm_redis_cli_checked FLUSHDB)"; then
    unset REDIS_CLI_DB
    hm_err "FLUSHDB db${n} nieudany: ${out:-}"
    return 1
  fi
  # obrona: jeśli CLI mimo wszystko zgłosiło SELECT failed — nie raportuj OK
  if printf '%s' "${out}" | grep -qiE 'SELECT .*failed|out of range'; then
    unset REDIS_CLI_DB
    hm_err "FLUSHDB db${n} przerwany (SELECT nieudany) — sprawdź db0 ręcznie."
    return 1
  fi
  local left
  left="$(REDIS_CLI_DB="${n}" hm_redis_cli DBSIZE 2>/dev/null | tr -d '\r' || true)"
  unset REDIS_CLI_DB
  if [[ "${left}" =~ ^[0-9]+$ && "${left}" -ne 0 ]]; then
    hm_warn "FLUSHDB db${n}: DBSIZE nadal ${left} (oczekiwano 0)."
  fi
  hm_ok "FLUSHDB db${n} OK."
}

hm_redis_cmd_flushall() {
  hm_redis_require || return 1
  if ! hm_confirm_plan "redis flushall" \
    "Usunie WSZYSTKIE klucze we WSZYSTKICH bazach Redis na tej instancji." \
    "FLUSHALL"; then
    return 1
  fi
  local out
  if ! out="$(hm_redis_cli_checked FLUSHALL)"; then
    hm_err "FLUSHALL nieudany: ${out:-}"
    return 1
  fi
  hm_ok "FLUSHALL OK."
}

hm_redis_cmd_restart() {
  hm_redis_detect
  local svc="${REDIS_SERVICE:-redis-server}"
  if ! hm_confirm_plan "redis restart — ${svc}" \
    "Chwilowa niedostępność cache/sesji/kolejek zależnych od Redis." \
    "systemctl restart ${svc} (lub service)"; then
    return 1
  fi
  local used=""
  if hm_have_cmd systemctl; then
    if systemctl restart "${svc}" 2>/dev/null; then
      used="systemctl:${svc}"
    elif systemctl restart redis 2>/dev/null; then
      used="systemctl:redis"
    elif systemctl restart redis-server 2>/dev/null; then
      used="systemctl:redis-server"
    fi
  fi
  if [[ -z "${used}" ]]; then
    if service redis-server restart 2>/dev/null; then
      used="service:redis-server"
    elif service redis restart 2>/dev/null; then
      used="service:redis"
    fi
  fi
  if [[ -n "${used}" ]]; then
    hm_ok "Redis restart OK (${used})."
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
  if [[ "${target}" == *.* || "${target}" == *:* || "${target}" == /* ]]; then
    mode="ADDR"
  fi
  if ! hm_confirm_plan "redis client kill — ${mode} ${target}" \
    "Rozłączy klienta Redis." \
    "CLIENT KILL ${mode} ${target}"; then
    return 1
  fi
  local out
  out="$(hm_redis_cli CLIENT KILL "${mode}" "${target}" 2>&1)" || true
  if hm_redis_reply_is_error "${out}"; then
    hm_err "CLIENT KILL nieudany: ${out}"
    return 1
  fi
  # odpowiedź: OK albo (integer) N — N=0 oznacza brak klientów
  local n=""
  if [[ "${out}" =~ \(integer\)[[:space:]]*([0-9]+) ]]; then
    n="${BASH_REMATCH[1]}"
  elif [[ "${out}" =~ ^[0-9]+$ ]]; then
    n="${out}"
  elif [[ "${out}" =~ ^OK ]]; then
    n=1
  fi
  if [[ -z "${n}" ]]; then
    hm_err "CLIENT KILL: nieoczekiwana odpowiedź: ${out:-pusto}"
    return 1
  fi
  if [[ "${n}" -lt 1 ]]; then
    hm_err "CLIENT KILL: nie zabito żadnego klienta (odpowiedź ${out})."
    return 1
  fi
  hm_ok "CLIENT KILL OK (zabito: ${n})."
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
