#!/usr/bin/env bash
# Regresja: docker helpers — mapowanie port→domena, prune flags, require (mock)
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
# shellcheck disable=SC1091
source lib/common/ui.sh
hm_file_log_ui() { :; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }
hm_run() { "$@"; }
_hm_cmd_help() { cat >/dev/null; }
_hm_cmd_register() { :; }
_hm_cmd_register_site() { :; }
hm_confirm_plan() { return 1; }
hm_confirm_plan_critical() { return 1; }

fail=0

# stub detect
DOCKER=yes
DOCKER_BIN=/bin/true
DOCKER_COMPOSE=plugin
hm_detect_docker() { DOCKER=yes; DOCKER_BIN=/bin/true; }

# shellcheck disable=SC1091
source commands/docker/main.sh

# --- port map ---
declare -gA HM_DOCKER_PORT_DOMAIN=()
HM_DOCKER_PORT_DOMAIN[5678]="n8n.example.pl"
HM_DOCKER_PORT_DOMAIN[3001]="uptime.example.pl,other.example.pl"
got="$(hm_docker_domains_for_ports 5678)"
[[ "${got}" == "n8n.example.pl" ]] && echo "OK   map-single" || { echo "FAIL map-single: ${got}"; fail=1; }
got="$(hm_docker_domains_for_ports 3001)"
case "${got}" in
  *uptime.example.pl*) echo "OK   map-multi" ;;
  *) echo "FAIL map-multi: ${got}"; fail=1 ;;
esac
got="$(hm_docker_domains_for_ports 9999)"
[[ "${got}" == "-" ]] && echo "OK   map-miss" || { echo "FAIL map-miss: ${got}"; fail=1; }

# --- require when FORCE_DOCKER=no ---
FORCE_DOCKER=no
DOCKER=yes
if hm_docker_require 2>/dev/null; then
  echo "FAIL require-force-no"
  fail=1
else
  echo "OK   require-force-no"
fi
unset FORCE_DOCKER

# --- prune dry-run default (confirm nie wołany — dry wraca 0) ---
DOCKER=yes
DOCKER_BIN=/bin/true
# mock docker binary via function? hm_run calls DOCKER_BIN — use true which ignores args
# system df will "succeed"
if cmd_docker_prune --dry-run >/dev/null 2>&1; then
  echo "OK   prune-dry-run"
else
  echo "FAIL prune-dry-run"
  fail=1
fi

# execute without volumes — confirm cancels
if cmd_docker_prune --execute >/dev/null 2>&1; then
  echo "FAIL prune-execute-should-cancel"
  fail=1
else
  echo "OK   prune-execute-confirm-cancel"
fi

# volumes path hits critical first
if cmd_docker_prune --volumes --execute >/dev/null 2>&1; then
  echo "FAIL prune-volumes-should-critical-cancel"
  fail=1
else
  echo "OK   prune-volumes-critical"
fi

# filter for site
line="n8n|img|running|5678|stack|/tmp|-|- "
out="$(printf '%s\n' "${line}" | hm_docker_filter_for_site "n8n.example.pl")"
[[ -n "${out}" ]] && echo "OK   filter-match" || { echo "FAIL filter-match"; fail=1; }
out="$(printf '%s\n' "${line}" | hm_docker_filter_for_site "other.test")"
# name doesn't contain other.test, port maps to n8n only
[[ -z "${out}" ]] && echo "OK   filter-miss" || { echo "FAIL filter-miss: ${out}"; fail=1; }

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL OK"
exit 0
