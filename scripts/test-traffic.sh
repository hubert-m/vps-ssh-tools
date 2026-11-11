#!/usr/bin/env bash
# traffic — liczniki, log strumieniowo, adres cf=, skok.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_help_topic() { :; }
_hm_cmd_help() { cat >/dev/null; }
_hm_cmd_register() { :; }

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
mkdir -p "${root}/logs"
export HM_TRAFFIC_COUNTERS="${root}/counters"
export HM_TRAFFIC_LOGS="${root}/logs"
export HM_TRAFFIC_NOW="${root}/now"

printf '%s\n' 'rx_day=10' 'tx_day=4' 'rx_month=100' 'tx_month=40' > "${root}/counters"
{
  i=0
  while [[ "${i}" -lt 12 ]]; do
    printf '172.16.0.1 example.com 100 cf=203.0.113.50\n'
    i=$((i + 1))
  done
  printf '%s\n' '198.51.100.2 shop.example 50' '198.51.100.3 shop.example 50' '198.51.100.4 other.example 50'
} > "${root}/logs/access.log"
printf '198.51.100.8 shop.example 25\n' | gzip > "${root}/logs/extra.log.gz"
printf '%s\n' '203.0.113.50' '203.0.113.50' '198.51.100.2' > "${root}/now"

# shellcheck disable=SC1091
source commands/traffic/main.sh
# shellcheck disable=SC1091
source commands/report/main.sh

day="$(cmd_traffic day)"
printf '%s\n' "${day}" | grep -qx 'rx: 10' && ok day-rx || bad day-rx
month="$(cmd_traffic month)"
printf '%s\n' "${month}" | grep -qx 'tx: 40' && ok month-tx || bad month-tx

sites="$(cmd_traffic sites --since 24h)"
printf '%s\n' "${sites}" | grep -q $'example.com\t12\t1200' && ok sites-example || bad sites-example
printf '%s\n' "${sites}" | grep -q $'shop.example\t3\t125' && ok sites-gz || bad sites-gz
printf '%s\n' "${sites}" | grep -q '172.16.0.1' && bad sites-cf || ok sites-cf

now="$(cmd_traffic now)"
printf '%s\n' "${now}" | grep -qx 'polaczenia: 3' && ok now-n || bad now-n
printf '%s\n' "${now}" | grep -q $'top: 203.0.113.50\t2' && ok now-top || bad now-top

spikes="$(cmd_traffic spikes)"
printf '%s\n' "${spikes}" | grep -q $'spike\t203.0.113.50\t12' && ok spike || bad spike
printf '%s\n' "${spikes}" | grep -q 'security ban 203.0.113.50' && ok spike-hint || bad spike-hint
printf '%s\n' "${spikes}" | grep -q '172.16.0.1' && bad spike-edge || ok spike-edge

text="$(cmd_report weekly)"
printf '%s\n' "${text}" | grep -q '## Ruch' && ok report || bad report
printf '%s\n' "${text}" | grep -q 'rx: 100' && ok report-rx || bad report-rx

[[ "${fail}" -eq 0 ]] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
