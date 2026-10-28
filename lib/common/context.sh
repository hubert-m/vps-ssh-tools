#!/usr/bin/env bash
# Common: kontekst strony i prompt REPL

# Globalny stan kontekstu strony
HM_SITE_DOMAIN=""
HM_SITE_ROOT=""
HM_SITE_DOCROOT=""
HM_SITE_LOGS=""
HM_SITE_VHOST=""
HM_SITE_PHP=""
HM_SITE_USER=""
HM_SITE_STATUS=""

hm_clear_site_context() {
  HM_SITE_DOMAIN=""
  HM_SITE_ROOT=""
  HM_SITE_DOCROOT=""
  HM_SITE_LOGS=""
  HM_SITE_VHOST=""
  HM_SITE_PHP=""
  HM_SITE_USER=""
  HM_SITE_STATUS=""
}

hm_prompt_string() {
  # zwykły wypis (bez znaczników readline)
  if [[ -n "${HM_SITE_DOMAIN}" ]]; then
    printf '%s[%s]%s> ' "${C_BOLD}${C_BLUE}" "${HM_SITE_DOMAIN}" "${C_RESET}"
  else
    printf '%shmtools%s> ' "${C_BOLD}${C_CYAN}" "${C_RESET}"
  fi
}

hm_prompt_for_read() {
  # Prompt dla `read -e -p` — kolory w \001...\002, żeby readline
  # poprawnie przerysował linię po Tab (bind -x).
  local si=$'\001' ei=$'\002'
  if [[ -n "${HM_SITE_DOMAIN}" ]]; then
    printf '%s%s%s[%s]%s%s%s> ' \
      "${si}" "${C_BOLD}${C_BLUE}" "${ei}" \
      "${HM_SITE_DOMAIN}" \
      "${si}" "${C_RESET}" "${ei}"
  else
    printf '%s%s%shmtools%s%s%s> ' \
      "${si}" "${C_BOLD}${C_CYAN}" "${ei}" \
      "${si}" "${C_RESET}" "${ei}"
  fi
}
