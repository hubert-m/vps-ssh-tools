#!/usr/bin/env bash
# redis — detekcja, CLI wrapper, parse conf

REDIS_BIN=""
REDIS_HOST="127.0.0.1"
REDIS_PORT="6379"
REDIS_SOCK=""
REDIS_PASS=""
REDIS_SERVICE=""
REDIS_CONF=""

# Wyciągnięcie wartości dyrektywy z redis.conf (ignoruj komentarze; ostatnia wygrywa)
hm_redis_conf_get() {
  local conf="$1" key="$2"
  [[ -n "${conf}" && -f "${conf}" && -n "${key}" ]] || return 1
  awk -v k="${key}" '
    $0 ~ /^[[:space:]]*#/ { next }
    $1 == k {
      val = $2
      for (i = 3; i <= NF; i++) {
        if ($i ~ /^#/) break
        val = val " " $i
      }
      gsub(/^"/, "", val); gsub(/"$/, "", val)
      out = val
    }
    END { if (out != "") print out; else exit 1 }
  ' "${conf}"
}

hm_redis_find_conf() {
  local c
  for c in \
    /etc/redis/redis.conf \
    /etc/redis.conf \
    /etc/redis/redis-server.conf \
    /usr/local/etc/redis.conf \
    /etc/redis/redis/redis.conf; do
    if [[ -f "${c}" ]]; then
      printf '%s' "${c}"
      return 0
    fi
  done
  return 1
}

hm_redis_detect_service() {
  local u
  if ! hm_have_cmd systemctl; then
    return 1
  fi
  for u in redis-server redis redis-server.service redis.service; do
    if systemctl list-unit-files "${u}" >/dev/null 2>&1 \
      || systemctl status "${u}" >/dev/null 2>&1; then
      printf '%s' "${u%.service}"
      return 0
    fi
  done
  # template / alias
  if systemctl list-units --type=service --all 2>/dev/null | grep -qE 'redis(-server)?\.service'; then
    printf 'redis-server'
    return 0
  fi
  return 1
}

hm_redis_detect() {
  REDIS_BIN=""
  REDIS_HOST="127.0.0.1"
  REDIS_PORT="6379"
  REDIS_SOCK=""
  REDIS_PASS=""
  REDIS_SERVICE=""
  REDIS_CONF=""

  if hm_have_cmd redis-cli; then
    REDIS_BIN="$(command -v redis-cli)"
  fi

  REDIS_CONF="$(hm_redis_find_conf 2>/dev/null || true)"
  if [[ -n "${REDIS_CONF}" ]]; then
    local v
    v="$(hm_redis_conf_get "${REDIS_CONF}" port 2>/dev/null || true)"
    [[ -n "${v}" && "${v}" =~ ^[0-9]+$ ]] && REDIS_PORT="${v}"
    v="$(hm_redis_conf_get "${REDIS_CONF}" bind 2>/dev/null || true)"
    # bind może być listą — do połączenia lokalnego preferuj 127.0.0.1
    # (nie ustawiaj REDIS_HOST=* — wygląda jak *:port w statusie)
    if [[ -n "${v}" ]]; then
      if printf '%s' "${v}" | grep -qE '(^|[[:space:]])(127\.0\.0\.1|::1)([[:space:]]|$)'; then
        REDIS_HOST="127.0.0.1"
      else
        local first
        first="$(printf '%s' "${v}" | awk '{print $1}')"
        case "${first}" in
          0.0.0.0|\*|::|localhost)
            REDIS_HOST="127.0.0.1"
            ;;
          ::1)
            REDIS_HOST="127.0.0.1"
            ;;
          *)
            # inne IPv6 (np. fe80::1) / konkretny interfejs — zostaw jako host CLI
            if [[ "${first}" == *:* ]]; then
              REDIS_HOST="127.0.0.1"
            else
              REDIS_HOST="${first}"
            fi
            ;;
        esac
      fi
    fi
    v="$(hm_redis_conf_get "${REDIS_CONF}" unixsocket 2>/dev/null || true)"
    [[ -n "${v}" && -S "${v}" ]] && REDIS_SOCK="${v}"
    # sock z conf nawet jeśli jeszcze nie istnieje (daemon down)
    if [[ -z "${REDIS_SOCK}" ]]; then
      v="$(hm_redis_conf_get "${REDIS_CONF}" unixsocket 2>/dev/null || true)"
      [[ -n "${v}" ]] && REDIS_SOCK="${v}"
    fi
    v="$(hm_redis_conf_get "${REDIS_CONF}" requirepass 2>/dev/null || true)"
    [[ -n "${v}" ]] && REDIS_PASS="${v}"
  fi

  REDIS_SERVICE="$(hm_redis_detect_service 2>/dev/null || true)"
  return 0
}

# Czy bind wygląda na publiczny (ostrzeżenie)
hm_redis_bind_is_public() {
  local conf="${REDIS_CONF:-}"
  [[ -n "${conf}" && -f "${conf}" ]] || return 1
  local bind
  bind="$(hm_redis_conf_get "${conf}" bind 2>/dev/null || true)"
  [[ -n "${bind}" ]] || return 1
  printf '%s' "${bind}" | grep -qE '(^|[[:space:]])(0\.0\.0\.0|\*|::)([[:space:]]|$)'
}

# Uruchom redis-cli z wykrytymi parametrami; args = komenda Redis
# Opcjonalnie: REDIS_CLI_DB=N → dodaje -n N (ta sama sesja/połączenie)
hm_redis_cli() {
  [[ -n "${REDIS_BIN}" && -x "${REDIS_BIN}" ]] || {
    hm_err "Brak redis-cli w PATH."
    return 1
  }
  local -a args=()
  if [[ -n "${REDIS_SOCK}" && -S "${REDIS_SOCK}" ]]; then
    args+=(-s "${REDIS_SOCK}")
  else
    args+=(-h "${REDIS_HOST:-127.0.0.1}" -p "${REDIS_PORT:-6379}")
  fi
  if [[ -n "${REDIS_CLI_DB:-}" && "${REDIS_CLI_DB}" =~ ^[0-9]+$ ]]; then
    args+=(-n "${REDIS_CLI_DB}")
  fi
  # AUTH bez hasła w argv innych procesów — REDISCLI_AUTH (redis-cli ≥6)
  if [[ -n "${REDIS_PASS}" ]]; then
    export REDISCLI_AUTH="${REDIS_PASS}"
  else
    unset REDISCLI_AUTH 2>/dev/null || true
  fi
  "${REDIS_BIN}" "${args[@]}" --no-auth-warning "$@"
}

# Czy odpowiedź redis-cli to błąd protokołu (rc CLI bywa 0)
hm_redis_reply_is_error() {
  local out="${1:-}"
  printf '%s' "${out}" | grep -qiE '(^|[[:space:]])(\(error\)|ERR |WRONGTYPE|NOAUTH|WRONGPASS|NOPERM|BUSY|NOSCRIPT)' 
}

# Uruchom komendę; stdout = odpowiedź; return ≠0 przy rc≠0 lub ERR w treści
hm_redis_cli_checked() {
  local out rc=0
  out="$(hm_redis_cli "$@" 2>&1)" || rc=$?
  printf '%s\n' "${out}"
  if [[ "${rc}" -ne 0 ]] || hm_redis_reply_is_error "${out}"; then
    return 1
  fi
  return 0
}

# Liczba baz z CONFIG GET databases (domyślnie 16). Potrzebne przed flushdb -n N —
# redis-cli przy złym SELECT i tak wykonuje komendę na db0.
hm_redis_databases_count() {
  local out n
  out="$(hm_redis_cli CONFIG GET databases 2>/dev/null || true)"
  n="$(printf '%s\n' "${out}" | awk '
    BEGIN { v = "" }
    tolower($0) ~ /^databases$/ { getline; gsub(/[^0-9]/, "", $0); if ($0 != "") { print $0; exit } }
    /^[0-9]+$/ { v = $0 }
    END { if (v != "") print v }
  ')"
  if [[ "${n}" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "${n}"
    return 0
  fi
  printf '%s' "16"
  return 0
}

# Czy indeks DB jest bezpieczny do -n / FLUSHDB (przed confirm).
hm_redis_db_index_ok() {
  local n="${1:-}"
  local max
  [[ "${n}" =~ ^[0-9]+$ ]] || return 1
  # zbyt długa liczba → overflow w redis-cli (np. SELECT -1) i ryzyko FLUSHDB na db0
  if [[ "${#n}" -gt 6 ]]; then
    hm_err "Numer bazy zbyt duży (${#n} cyfr) — odmowa (ryzyko czyszczenia db0)."
    return 1
  fi
  max="$(hm_redis_databases_count)"
  if [[ "${n}" -ge "${max}" ]]; then
    hm_err "db${n} poza zakresem (databases=${max}, dozwolone 0…$((max - 1)))."
    return 1
  fi
  return 0
}

hm_redis_require() {
  hm_redis_detect
  if [[ -z "${REDIS_BIN}" ]]; then
    hm_err "Brak redis-cli — zainstaluj redis-tools / redis."
    hm_info "Na Debian/Ubuntu: apt install redis-tools. Na RHEL: dnf install redis."
    return 1
  fi
  local pong
  pong="$(hm_redis_cli PING 2>&1 | tr -d '\r' || true)"
  if [[ "${pong}" == "PONG" ]]; then
    return 0
  fi
  if printf '%s' "${pong}" | grep -qiE 'NOAUTH|WRONGPASS|invalid password|Authentication required'; then
    hm_err "Redis wymaga hasła (NOAUTH/WRONGPASS) — sprawdź requirepass w ${REDIS_CONF:-(conf)}."
    return 1
  fi
  if hm_redis_reply_is_error "${pong}"; then
    hm_err "Redis PING błąd: ${pong}"
    return 1
  fi
  hm_err "Redis nie odpowiada na PING (${REDIS_SOCK:-${REDIS_HOST}:${REDIS_PORT}})."
  [[ -n "${REDIS_SERVICE}" ]] && hm_info "Sprawdź: systemctl status ${REDIS_SERVICE}"
  return 1
}

# INFO field → wartość (pierwsza linia key:value)
hm_redis_info_field() {
  local section="$1" field="$2"
  hm_redis_cli INFO "${section}" 2>/dev/null | awk -F: -v f="${field}" '
    $0 ~ /^#/ { next }
    $1 == f { gsub(/\r/, "", $2); print $2; exit }
  '
}
