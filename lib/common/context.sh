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

# Stos migawek REPL — tymczasowy use <domena> bez zmiany promptu po komendzie.
# hm_site_context_push [domena]  — zapisuje bieżący kontekst; opcjonalnie ustawia nowy (pusty = clear)
# hm_site_context_pop            — przywraca poprzedni (pusty stos = no-op)
declare -a _HM_SC_D=() _HM_SC_R=() _HM_SC_DR=() _HM_SC_L=() _HM_SC_V=() _HM_SC_P=() _HM_SC_U=() _HM_SC_S=()

hm_site_context_push() {
  _HM_SC_D+=("${HM_SITE_DOMAIN}")
  _HM_SC_R+=("${HM_SITE_ROOT}")
  _HM_SC_DR+=("${HM_SITE_DOCROOT}")
  _HM_SC_L+=("${HM_SITE_LOGS}")
  _HM_SC_V+=("${HM_SITE_VHOST}")
  _HM_SC_P+=("${HM_SITE_PHP}")
  _HM_SC_U+=("${HM_SITE_USER}")
  _HM_SC_S+=("${HM_SITE_STATUS}")
  if [[ $# -gt 0 ]]; then
    if [[ -n "${1}" ]]; then
      if ! hm_set_site_context "${1}"; then
        hm_site_context_pop
        return 1
      fi
    else
      hm_clear_site_context
    fi
  fi
  return 0
}

hm_site_context_pop() {
  local n="${#_HM_SC_D[@]}"
  [[ "${n}" -gt 0 ]] || return 0
  local i=$((n - 1))
  HM_SITE_DOMAIN="${_HM_SC_D[i]}"
  HM_SITE_ROOT="${_HM_SC_R[i]}"
  HM_SITE_DOCROOT="${_HM_SC_DR[i]}"
  HM_SITE_LOGS="${_HM_SC_L[i]}"
  HM_SITE_VHOST="${_HM_SC_V[i]}"
  HM_SITE_PHP="${_HM_SC_P[i]}"
  HM_SITE_USER="${_HM_SC_U[i]}"
  HM_SITE_STATUS="${_HM_SC_S[i]}"
  _HM_SC_D=("${_HM_SC_D[@]:0:i}")
  _HM_SC_R=("${_HM_SC_R[@]:0:i}")
  _HM_SC_DR=("${_HM_SC_DR[@]:0:i}")
  _HM_SC_L=("${_HM_SC_L[@]:0:i}")
  _HM_SC_V=("${_HM_SC_V[@]:0:i}")
  _HM_SC_P=("${_HM_SC_P[@]:0:i}")
  _HM_SC_U=("${_HM_SC_U[@]:0:i}")
  _HM_SC_S=("${_HM_SC_S[@]:0:i}")
  return 0
}

# Uruchom komendę w tymczasowym kontekście domeny; zawsze przywraca poprzedni.
hm_with_site_context() {
  local __hm_sc_domain="${1:-}"
  shift || true
  hm_site_context_push "${__hm_sc_domain}" || return 1
  local __hm_sc_rc=0
  "$@" || __hm_sc_rc=$?
  hm_site_context_pop
  return "${__hm_sc_rc}"
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
