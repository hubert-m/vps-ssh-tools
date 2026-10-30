#!/usr/bin/env bash
# Ładuje shared + wszystkie moduły commands/<narzędzie>/main.sh
# Opcjonalnie meta.sh przed main (rejestr aliasów / restricted).

if [[ -n "${HMTOOLS_COMMANDS_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_COMMANDS_LOADED=1

: "${HMTOOLS_ROOT:?HMTOOLS_ROOT wymagane}"

declare -gA HM_CMD_ALIAS_MAP=()
declare -gA HM_CMD_ENTRY=()
declare -gA HM_CMD_RESTRICTED=()
declare -gA HM_CMD_SITE_ENTRY=()
declare -gA HM_CMD_HELP=()

# _hm_cmd_help <topic>  + heredoc na stdin
_hm_cmd_help() {
  local topic="$1"
  HM_CMD_HELP["${topic}"]="$(cat)"
}

# _hm_cmd_register <canonical> <entry_fn> [restricted_ok] [alias...]
_hm_cmd_register() {
  local name="$1" entry="$2" restr="${3:-0}"
  shift 3 || true
  HM_CMD_ENTRY["${name}"]="${entry}"
  HM_CMD_RESTRICTED["${name}"]="${restr}"
  HM_CMD_ALIAS_MAP["${name}"]="${name}"
  local a
  for a in "$@"; do
    [[ -n "${a}" ]] || continue
    HM_CMD_ALIAS_MAP["${a}"]="${name}"
  done
}

_hm_cmd_register_site() {
  local name="$1" entry="$2"
  HM_CMD_SITE_ENTRY["${name}"]="${entry}"
}

# Współdzielone helpery (vhost/discover/…) — przed narzędziami
if [[ -f "${HMTOOLS_ROOT}/commands/_shared/sites/init.sh" ]]; then
  # shellcheck disable=SC1091
  source "${HMTOOLS_ROOT}/commands/_shared/sites/init.sh"
fi

for _hm_cmd_dir in "${HMTOOLS_ROOT}/commands"/*/; do
  [[ -d "${_hm_cmd_dir}" ]] || continue
  _hm_base="$(basename "${_hm_cmd_dir}")"
  case "${_hm_base}" in
    _shared|.*) continue ;;
  esac
  if [[ -f "${_hm_cmd_dir}meta.sh" ]]; then
    # shellcheck disable=SC1090
    source "${_hm_cmd_dir}meta.sh"
  fi
  if [[ -f "${_hm_cmd_dir}main.sh" ]]; then
    # shellcheck disable=SC1090
    source "${_hm_cmd_dir}main.sh"
  fi
done
unset _hm_cmd_dir _hm_base

# shellcheck disable=SC1091
source "${HMTOOLS_ROOT}/commands/_dispatch.sh"
