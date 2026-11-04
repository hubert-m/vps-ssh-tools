#!/usr/bin/env bash
# Komenda: notify — setup / test / status powiadomień


_hm_cmd_help notify <<'EOF'
Użycie:
  notify status              Kanały (e-mail / webhook) + dedup
  notify test                Wyślij testowe powiadomienie
  notify setup               Interaktywna konfiguracja → hmtools.conf

Klucze conf: NOTIFY_EMAIL, NOTIFY_WEBHOOK_URL, NOTIFY_FROM, NOTIFY_DEDUP_HOURS.
Webhook URL nigdy nie trafia do applog.
EOF

hm_notify_conf_path() {
  printf '%s' "${HMTOOLS_CONF:-${HMTOOLS_ROOT}/config/hmtools.conf}"
}

hm_notify_conf_set_kv() {
  local key="$1" val="$2" conf
  conf="$(hm_notify_conf_path)"
  mkdir -p "$(dirname "${conf}")" 2>/dev/null || true
  touch "${conf}" 2>/dev/null || true
  local tmp
  tmp="$(hm_mktemp .conf)"
  if grep -qE "^[[:space:]]*${key}=" "${conf}" 2>/dev/null; then
    awk -v k="${key}" -v v="${val}" '
      BEGIN { done=0 }
      $0 ~ "^[[:space:]]*" k "=" {
        print k "=\"" v "\""
        done=1; next
      }
      { print }
      END { if (!done) print k "=\"" v "\"" }
    ' "${conf}" > "${tmp}"
  else
    cat "${conf}" > "${tmp}"
    printf '\n%s="%s"\n' "${key}" "${val}" >> "${tmp}"
  fi
  cat "${tmp}" > "${conf}"
  rm -f "${tmp}"
  chmod 600 "${conf}" 2>/dev/null || true
}

cmd_notify_setup() {
  hm_load_config
  local conf
  conf="$(hm_notify_conf_path)"
  echo "${C_BOLD}notify setup${C_RESET}"
  echo "  Plik: ${conf}"
  echo
  local email webhook
  printf 'E-mail (Enter = pomiń) [%s]: ' "${NOTIFY_EMAIL:-}"
  read -r email || true
  email="${email:-${NOTIFY_EMAIL:-}}"
  printf 'Webhook URL https://… (Enter = pomiń; nie będzie logowany): '
  read -r webhook || true
  webhook="${webhook:-}"

  if [[ -n "${email}" ]] && ! hm_notify_is_valid_email "${email}"; then
    hm_err "Nieprawidłowy e-mail: ${email}"
    return 1
  fi
  if [[ -n "${webhook}" ]] && ! hm_notify_is_valid_webhook "${webhook}"; then
    hm_err "Nieprawidłowy webhook URL (wymagany https://… lub http://localhost)."
    return 1
  fi

  local -a steps=("Zapis NOTIFY_* do ${conf} (chmod 600)")
  [[ -n "${email}" ]] && steps+=("NOTIFY_EMAIL=${email}")
  [[ -n "${webhook}" ]] && steps+=("NOTIFY_WEBHOOK_URL=(ukryty)")
  if ! hm_confirm_plan "notify setup" "" "${steps[@]}"; then
    return 0
  fi

  if [[ -n "${email}" ]]; then
    hm_notify_conf_set_kv "NOTIFY_EMAIL" "${email}"
  fi
  if [[ -n "${webhook}" ]]; then
    hm_notify_conf_set_kv "NOTIFY_WEBHOOK_URL" "${webhook}"
  fi
  hm_ok "Zapisano. Sprawdź: notify test"
  # przeładuj
  # shellcheck disable=SC1090
  source "${conf}" 2>/dev/null || true
  hm_notify_status
}

cmd_notify_test() {
  hm_load_config
  if ! hm_notify_configured; then
    hm_err "Brak NOTIFY_EMAIL / NOTIFY_WEBHOOK_URL — najpierw: notify setup"
    return 1
  fi
  # test omija dedup — użyj unikalnego type
  local key="notify.test.$(date +%s)"
  if hm_notify "info" "hmtools notify test" \
    "To jest test powiadomienia z $(hostname -f 2>/dev/null || hostname) o $(date -u +%Y-%m-%dT%H:%M:%SZ)." \
    "${key}"; then
    hm_ok "Wysłano test."
  else
    hm_err "Wysyłka nieudana."
    return 1
  fi
}

cmd_notify() {
  local sub="${1:-status}"
  shift || true
  case "${sub}" in
    status|stat|"")
      hm_notify_status
      ;;
    test)
      cmd_notify_test
      ;;
    setup|config)
      cmd_notify_setup
      ;;
    help|-h|--help)
      hm_help_topic notify
      ;;
    *)
      hm_err "Nieznane: notify ${sub}. notify help"
      return 1
      ;;
  esac
}

_hm_cmd_register notify cmd_notify 0
