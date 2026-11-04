#!/usr/bin/env bash
# Powiadomienia: e-mail (sendmail) / webhook — z deduplikacją 24h + recovery


if [[ -n "${HMTOOLS_NOTIFY_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_NOTIFY_LOADED=1

hm_notify_state_dir() {
  printf '%s' "${NOTIFY_STATE_DIR:-/var/lib/hmtools/notify}"
}

hm_notify_ensure_state() {
  local d
  d="$(hm_notify_state_dir)"
  mkdir -m 0700 -p "${d}" 2>/dev/null || mkdir -p "${d}" 2>/dev/null || true
  chmod 0700 "${d}" 2>/dev/null || true
}

hm_notify_configured() {
  hm_load_config 2>/dev/null || true
  [[ -n "${NOTIFY_EMAIL:-}" || -n "${NOTIFY_WEBHOOK_URL:-}" ]]
}

hm_notify_is_valid_email() {
  local e="${1:-}"
  [[ "${e}" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

hm_notify_is_valid_webhook() {
  local u="${1:-}"
  # https://… lub http://127.0.0.1|localhost — bez spacji / shell meta
  [[ -n "${u}" ]] || return 1
  case "${u}" in
    *[[:space:]]*|*'`'*|*'$('*|*';'*|*'|'*) return 1 ;;
  esac
  case "${u}" in
    https://*)
      # prosta walidacja: brak białych znaków, min. host
      [[ "${u}" == https://*.* || "${u}" == https://*/* ]] || [[ "${#u}" -gt 10 ]]
      return $?
      ;;
    http://127.0.0.1/*|http://127.0.0.1:*|http://localhost/*|http://localhost:*|http://127.0.0.1|http://localhost)
      return 0
      ;;
  esac
  return 1
}

hm_notify_key_hash() {
  local key="${1:-}"
  printf '%s' "${key}" | md5sum 2>/dev/null | awk '{print $1}' \
    || printf '%s' "${key}" | cksum | awk '{print $1}'
}

# Czy wolno wysłać alert (dedup 24h per typ). Recovery zawsze gdy poprzedni alert aktywny.
# hm_notify_gate <type_key> <level>  → 0=send, 1=skip
# Ustawia HM_NOTIFY_IS_RECOVERY=1 gdy level=ok/recovery i był pending alert.
hm_notify_gate() {
  local type_key="${1:-general}" level="${2:-error}"
  local ttl="${NOTIFY_DEDUP_HOURS:-24}"
  local d h f now age
  HM_NOTIFY_IS_RECOVERY=0
  hm_notify_ensure_state
  d="$(hm_notify_state_dir)"
  h="$(hm_notify_key_hash "${type_key}")"
  f="${d}/${h}.state"
  now="$(date +%s)"

  case "${level}" in
    ok|recovery|info-ok)
      if [[ -f "${f}" ]]; then
        # był alert — wyślij recovery i usuń stan
        HM_NOTIFY_IS_RECOVERY=1
        return 0
      fi
      return 1
      ;;
  esac

  if [[ -f "${f}" ]]; then
    local ts
    ts="$(awk 'NR==1{print $1; exit}' "${f}" 2>/dev/null || echo 0)"
    [[ "${ts}" =~ ^[0-9]+$ ]] || ts=0
    age=$((now - ts))
    local max=$((ttl * 3600))
    if [[ "${age}" -ge 0 && "${age}" -lt "${max}" ]]; then
      return 1
    fi
  fi
  return 0
}

hm_notify_mark() {
  local type_key="${1:-general}" level="${2:-error}"
  local d h f
  hm_notify_ensure_state
  d="$(hm_notify_state_dir)"
  h="$(hm_notify_key_hash "${type_key}")"
  f="${d}/${h}.state"
  case "${level}" in
    ok|recovery|info-ok)
      rm -f "${f}" 2>/dev/null || true
      ;;
    *)
      printf '%s %s %s\n' "$(date +%s)" "${level}" "${type_key}" > "${f}"
      chmod 600 "${f}" 2>/dev/null || true
      ;;
  esac
}

hm_notify_send_email() {
  local title="$1" body="$2" level="$3"
  local to="${NOTIFY_EMAIL:-}"
  [[ -n "${to}" ]] || return 1
  hm_notify_is_valid_email "${to}" || {
    hm_warn "NOTIFY_EMAIL nieprawidłowy — pomijam e-mail."
    return 1
  }
  local from="${NOTIFY_FROM:-hmtools@$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo localhost)}"
  local subject="[hmtools/${level}] ${title}"
  if hm_have_cmd sendmail; then
    {
      printf 'To: %s\n' "${to}"
      printf 'From: %s\n' "${from}"
      printf 'Subject: %s\n' "${subject}"
      printf 'Content-Type: text/plain; charset=UTF-8\n'
      printf '\n'
      printf '%s\n' "${body}"
    } | sendmail -t
    return $?
  fi
  if hm_have_cmd msmtp; then
    {
      printf 'To: %s\n' "${to}"
      printf 'From: %s\n' "${from}"
      printf 'Subject: %s\n' "${subject}"
      printf '\n'
      printf '%s\n' "${body}"
    } | msmtp --read-recipients
    return $?
  fi
  hm_warn "Brak sendmail/msmtp — e-mail nie wysłany."
  return 1
}

hm_notify_send_webhook() {
  local title="$1" body="$2" level="$3"
  local url="${NOTIFY_WEBHOOK_URL:-}"
  [[ -n "${url}" ]] || return 1
  hm_notify_is_valid_webhook "${url}" || {
    hm_warn "NOTIFY_WEBHOOK_URL nieprawidłowy — pomijam webhook."
    return 1
  }
  hm_have_cmd curl || {
    hm_warn "Brak curl — webhook nie wysłany."
    return 1
  }
  local te tb jl payload
  te="$(hm_json_escape_str "${title}")"
  tb="$(hm_json_escape_str "${body}")"
  jl="$(hm_json_escape_str "${level}")"
  # Uniwersalny JSON (Slack/Discord/ntfy-friendly text)
  payload="$(printf '{"text":"[hmtools/%s] %s\\n%s","level":"%s","title":"%s","body":"%s"}' \
    "${jl}" "${te}" "${tb}" "${jl}" "${te}" "${tb}")"
  # URL NIGDY do logu — curl bez -v; hm_file_log bez URL
  hm_file_log INFO "NOTIFY_WEBHOOK: sending (url redacted)" 2>/dev/null || true
  curl --max-time 10 -sS -o /dev/null -w '' \
    -H 'Content-Type: application/json' \
    -d "${payload}" \
    "${url}" >/dev/null 2>&1
  return $?
}

# hm_notify <level> <title> <body> [type_key]
hm_notify() {
  local level="${1:-info}" title="${2:-hmtools}" body="${3:-}" type_key="${4:-general}"
  hm_load_config 2>/dev/null || true

  if ! hm_notify_configured; then
    hm_file_log INFO "NOTIFY_SKIP: not configured type=${type_key}" 2>/dev/null || true
    return 0
  fi

  if ! hm_notify_gate "${type_key}" "${level}"; then
    hm_file_log INFO "NOTIFY_DEDUP: skip type=${type_key} level=${level}" 2>/dev/null || true
    return 0
  fi

  if [[ "${HM_NOTIFY_IS_RECOVERY:-0}" -eq 1 ]]; then
    title="OK: ${title}"
    level="ok"
  fi

  local ok=0
  if [[ -n "${NOTIFY_EMAIL:-}" ]]; then
    hm_notify_send_email "${title}" "${body}" "${level}" && ok=1
  fi
  if [[ -n "${NOTIFY_WEBHOOK_URL:-}" ]]; then
    hm_notify_send_webhook "${title}" "${body}" "${level}" && ok=1
  fi

  if [[ "${ok}" -eq 1 ]]; then
    hm_notify_mark "${type_key}" "${level}"
    hm_file_log INFO "NOTIFY_SENT: type=${type_key} level=${level} title=${title}" 2>/dev/null || true
    return 0
  fi
  hm_file_log WARN "NOTIFY_FAIL: type=${type_key} (channels failed)" 2>/dev/null || true
  return 1
}

hm_notify_status() {
  hm_load_config
  echo "${C_BOLD}notify — status${C_RESET}"
  if [[ -n "${NOTIFY_EMAIL:-}" ]]; then
    if hm_notify_is_valid_email "${NOTIFY_EMAIL}"; then
      echo "  email:   ${NOTIFY_EMAIL}"
    else
      hm_warn "email: nieprawidłowy (${NOTIFY_EMAIL})"
    fi
  else
    echo "  email:   (wyłączony)"
  fi
  if [[ -n "${NOTIFY_WEBHOOK_URL:-}" ]]; then
    if hm_notify_is_valid_webhook "${NOTIFY_WEBHOOK_URL}"; then
      echo "  webhook: (ustawiony, URL ukryty)"
    else
      hm_warn "webhook: nieprawidłowy URL"
    fi
  else
    echo "  webhook: (wyłączony)"
  fi
  echo "  dedup:   ${NOTIFY_DEDUP_HOURS:-24}h"
  echo "  state:   $(hm_notify_state_dir)"
  local n
  n="$(find "$(hm_notify_state_dir)" -maxdepth 1 -name '*.state' 2>/dev/null | wc -l | tr -d ' ')"
  echo "  active alerts: ${n:-0}"
}
