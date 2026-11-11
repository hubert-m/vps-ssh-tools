#!/usr/bin/env bash
# Składanie JSON bez jq. Wartości liczbowe tylko z cyfr (inaczej 0).

if [[ -n "${HM_JSON_LIB_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HM_JSON_LIB_LOADED=1

hm_json_q() {
  local s="${1:-}"
  if ! declare -F hm_json_escape_str >/dev/null 2>&1; then
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '"%s"' "${s}"
    return 0
  fi
  printf '"%s"' "$(hm_json_escape_str "${s}")"
}

hm_json_num() {
  local v="${1:-0}"
  if [[ "${v}" =~ ^-?[0-9]+$ ]]; then
    printf '%s' "${v}"
  else
    printf '0'
  fi
}

hm_json_bool() {
  case "${1:-}" in
    1|true|TRUE|yes|ok) printf 'true' ;;
    *) printf 'false' ;;
  esac
}

# hm_json_obj key type value ...
# type: s (string) | n (number) | b (bool) | r (surowy JSON)
hm_json_obj() {
  local out="{" sep="" k t v
  while [[ $# -ge 3 ]]; do
    k="${1}"
    t="${2}"
    v="${3}"
    shift 3
    out+="${sep}$(hm_json_q "${k}"):"
    sep=","
    case "${t}" in
      s) out+="$(hm_json_q "${v}")" ;;
      n) out+="$(hm_json_num "${v}")" ;;
      b) out+="$(hm_json_bool "${v}")" ;;
      r) out+="${v}" ;;
      *) out+="null" ;;
    esac
  done
  printf '%s}' "${out}"
}

hm_has_json_flag() {
  local a
  for a in "$@"; do
    [[ "${a}" == "--json" ]] && return 0
  done
  return 1
}

hm_prom_label() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/}"
  s="${s//$'\r'/}"
  printf '%s' "${s}"
}
