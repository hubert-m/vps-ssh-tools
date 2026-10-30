#!/usr/bin/env bash
# Pomoc: help  /  help <polecenie>
# Treści tematów: HM_CMD_HELP (rejestrowane w commands/*/main.sh przez _hm_cmd_help)

if [[ -n "${HMTOOLS_HELP_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_HELP_LOADED=1

hm_help_topic() {
  local topic="${1:-}"
  topic="$(printf '%s' "${topic}" | tr '[:upper:]' '[:lower:]')"

  if [[ -z "${topic}" ]]; then
    hm_help_global
    return 0
  fi

  local canon="${topic}"
  if [[ -n "${HM_CMD_ALIAS_MAP[${topic}]:-}" ]]; then
    canon="${HM_CMD_ALIAS_MAP[${topic}]}"
  fi

  local text="${HM_CMD_HELP[${canon}]:-}"
  if [[ -z "${text}" && "${canon}" != "${topic}" ]]; then
    text="${HM_CMD_HELP[${topic}]:-}"
  fi
  if [[ -z "${text}" ]]; then
    text="${HM_CMD_HELP[${topic}]:-}"
  fi

  if [[ -z "${text}" ]]; then
    hm_err "Brak podpowiedzi dla tego polecenia"
    return 1
  fi
  printf '%s\n' "${text}"
}

hm_cmd_help() {
  if [[ -z "${1:-}" ]]; then
    if [[ -n "${HM_SITE_DOMAIN:-}" ]]; then
      cmd_site_help
    else
      hm_help_global
    fi
    echo
    echo "Szczegóły: help <polecenie>   np. help use"
    return 0
  fi
  hm_help_topic "$1"
}
