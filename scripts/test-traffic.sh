#!/usr/bin/env bash
# traffic — liczniki, log strumieniowo, adres cf=, skok, combined, prod bez HM_TRAFFIC_*.
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
mkdir -p "${root}/logs" "${root}/tmp"
export TMP_DIR="${root}/tmp"
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
printf '%s\n' "${day}" | grep -Eqx 'rx: 10B?' && ok day-rx || bad day-rx
month="$(cmd_traffic month)"
printf '%s\n' "${month}" | grep -Eqx 'tx: 40B?' && ok month-tx || bad month-tx
# day ≠ month (osobne liczniki)
printf '%s\n' "${day}" | grep -q 'rx: 10' && printf '%s\n' "${month}" | grep -q 'rx: 100' && ok day-ne-month || bad day-ne-month

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

# Brak stałych plików w katalogu logów
if ls "${root}/logs"/.hm-traffic-* >/dev/null 2>&1; then
  bad tmp-in-logs
else
  ok tmp-in-logs
fi
# tmp w TMP_DIR sprzątnięty (brak osieroconych po wywołaniu)
leftover="$(find "${root}/tmp" -type f 2>/dev/null | wc -l | tr -d ' ')"
[[ "${leftover}" -eq 0 ]] && ok tmp-clean || bad tmp-clean

text="$(cmd_report weekly)"
printf '%s\n' "${text}" | grep -q '## Ruch' && ok report || bad report
printf '%s\n' "${text}" | grep -Eq 'rx: 100B?' && ok report-rx || bad report-rx

# Combined / OLS + domena ze ścieżki /home/<domena>/logs
unset HM_TRAFFIC_COUNTERS HM_TRAFFIC_LOGS HM_TRAFFIC_NOW
mkdir -p "${root}/home/app.example.pl/logs" "${root}/proc" "${root}/state"
export HM_TRAFFIC_DIR="${root}/state"
export HM_TRAFFIC_NET_FILE="${root}/proc/net.dev"
# shellcheck disable=SC2016
printf '%s\n' 'Inter-|   Receive                                                |  Transmit' \
  ' face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed' \
  '  eth0: 1000 1 0 0 0 0 0 0 400 1 0 0 0 0 0 0' \
  '    lo: 9 1 0 0 0 0 0 0 9 1 0 0 0 0 0 0' > "${root}/proc/net.dev"

# bez logów: proc delta (HM_TRAFFIC_LOGS pusty katalog / brak)
mkdir -p "${root}/empty-logs"
export HM_TRAFFIC_LOGS="${root}/empty-logs"
# pierwszy odczyt ustawia baseline → delta 0
d1="$(hm_traffic_day day)"
printf '%s\n' "${d1}" | grep -Eqx 'rx: 0B?' && ok proc-base || bad proc-base
# drugi odczyt po wzroście
printf '%s\n' 'Inter-|   Receive                                                |  Transmit' \
  ' face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed' \
  '  eth0: 1500 2 0 0 0 0 0 0 700 2 0 0 0 0 0 0' \
  '    lo: 9 1 0 0 0 0 0 0 9 1 0 0 0 0 0 0' > "${root}/proc/net.dev"
d2="$(hm_traffic_day day)"
printf '%s\n' "${d2}" | grep -Eqx 'rx: 500B?' && ok proc-delta || bad proc-delta
unset HM_TRAFFIC_LOGS

{
  i=0
  while [[ "${i}" -lt 3 ]]; do
    printf '172.16.0.1 - - [16/Nov/2026:10:00:0%d +0000] "GET / HTTP/1.1" 200 100 "-" "curl/8.0"\n' "${i}"
    i=$((i + 1))
  done
  printf '198.51.100.9 - - [16/Nov/2026:10:00:10 +0000] "GET / HTTP/1.1" 200 50 "-" "curl/8.0" "shop.example"\n'
  printf '198.51.100.10 - - [16/Nov/2026:10:00:11 +0000] "GET / HTTP/1.1" 200 10 "-" "curl/8.0"\n'
  printf '198.51.100.11 - - [16/Nov/2026:10:00:12 +0000] "GET / HTTP/1.1" 200 10 "-" "curl/8.0"\n'
  i=0
  while [[ "${i}" -lt 12 ]]; do
    printf '172.16.0.1 - - [16/Nov/2026:10:01:%02d +0000] "GET /x HTTP/1.1" 200 10 "-" "curl/8.0" cf=203.0.113.77\n' "${i}"
    i=$((i + 1))
  done
} > "${root}/home/app.example.pl/logs/access.log"

# podmiana /home → root/home przez chroot-like: iter_logs używa /home/*/logs — symlink
mkdir -p "${root}/fake-root"
# W teście ustawiamy HM_TRAFFIC_LOGS na katalog z combined + ścieżką domeny
# oraz osobno sprawdzamy domain_from_path
dom="$(hm_traffic_domain_from_path "${root}/home/app.example.pl/logs/access.log")"
[[ "${dom}" == "app.example.pl" ]] && ok dom-path || bad dom-path

export HM_TRAFFIC_LOGS="${root}/home/app.example.pl/logs"
comb="$(cmd_traffic sites)"
# 3+2 one-off + 12 cf= → 17 na app.example.pl; 1× shop.example
printf '%s\n' "${comb}" | grep -q $'app.example.pl\t17\t' && ok combined-dom || bad combined-dom
printf '%s\n' "${comb}" | grep -q $'shop.example\t1\t50' && ok combined-host || bad combined-host

spk="$(cmd_traffic spikes)"
# 12 vs avg przy 5 IP → spike; edge 172.16.0.1 nie
printf '%s\n' "${spk}" | grep -q $'spike\t203.0.113.77\t12' && ok combined-cf || bad combined-cf
printf '%s\n' "${spk}" | grep -q '172.16.0.1' && bad combined-edge || ok combined-edge
if ls "${root}/home/app.example.pl/logs"/.hm-traffic-* >/dev/null 2>&1; then
  bad combined-tmp
else
  ok combined-tmp
fi

# CF IP jako ostatnie pole / $2 — nie domena
mkdir -p "${root}/logs-cfip"
printf '%s\n' \
  '172.16.0.1 203.0.113.50 100' \
  '172.16.0.1 example.com 100 203.0.113.50' > "${root}/logs-cfip/access.log"
# domena ze ścieżki przy samym IP IP bytes
mkdir -p "${root}/home/cfip.example/logs"
printf '%s\n' '172.16.0.1 203.0.113.50 100' > "${root}/home/cfip.example/logs/access.log"
export HM_TRAFFIC_LOGS="${root}/home/cfip.example/logs"
cfip="$(cmd_traffic sites)"
printf '%s\n' "${cfip}" | grep -q '203.0.113.50' && bad sites-cfip-dom || ok sites-cfip-dom
printf '%s\n' "${cfip}" | grep -q $'cfip.example\t1\t100' && ok sites-cfip-path || bad sites-cfip-path

# --since filtruje CLF (domena ze ścieżki /home/<domena>/logs)
mkdir -p "${root}/home/since.example/logs"
{
  printf '198.51.100.1 - - [01/Jan/2020:00:00:00 +0000] "GET / HTTP/1.1" 200 10 "-" "x"\n'
  printf '198.51.100.2 - - [%s] "GET / HTTP/1.1" 200 20 "-" "x"\n' "$(date -u '+%d/%b/%Y:%H:%M:%S +0000')"
} > "${root}/home/since.example/logs/access.log"
export HM_TRAFFIC_LOGS="${root}/home/since.example/logs"
sin="$(cmd_traffic sites --since 24h)"
printf '%s\n' "${sin}" | grep -q $'since.example\t1\t20' && ok sites-since || bad sites-since

# spikes: brak skoku → komunikat
mkdir -p "${root}/logs-flat"
printf '%s\n' '1.1.1.1 a.example 10' '2.2.2.2 a.example 10' '3.3.3.3 a.example 10' \
  > "${root}/logs-flat/access.log"
export HM_TRAFFIC_LOGS="${root}/logs-flat"
flat="$(cmd_traffic spikes)"
printf '%s\n' "${flat}" | grep -q 'brak skoków' && ok spikes-none || bad spikes-none

[[ "${fail}" -eq 0 ]] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
