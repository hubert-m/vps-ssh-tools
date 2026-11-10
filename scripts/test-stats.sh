#!/usr/bin/env bash
# stats: agregaty, wykres, retencja, mapowanie strony jak health, rozmiar 90 dni.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hmtools-stats-test.XXXXXX")"
fail=0
ok() { echo "OK   $*"; }
bad() { echo "FAIL $*"; fail=1; }

_hm_cmd_help() { cat >/dev/null; }
_hm_cmd_register() { :; }
hm_err() { echo "$*" >&2; }
hm_confirm_plan() { return 0; }
hm_file_log_ui() { :; }

export HM_STATS_DIR="${TMP}/db"
export HM_STATS_CRON="${TMP}/cron/hmtools-stats"
export LOG_DIR="${TMP}/logs"
export HM_STATS_NOW=1700000000
mkdir -p "${HM_STATS_DIR}" "${LOG_DIR}" "$(dirname "${HM_STATS_CRON}")"

# shellcheck disable=SC1091
source commands/health/main.sh
# shellcheck disable=SC1091
source commands/stats/main.sh

HM_SITES_LIST=(example.pl foo.example.pl)
health_site="$(hm_health_site_for_text "/home/foo.example.pl/public_html lsphp")"
stats_site="$(hm_stats_site_from_text "/home/foo.example.pl/public_html lsphp")"
if [[ "${health_site}" == "foo.example.pl" && "${stats_site}" == "${health_site}" ]]; then
  ok "mapowanie /home jak health"
else
  bad "site health=${health_site} stats=${stats_site}"
fi
printf '%s\n' '1001 example.pl' > "${TMP}/uid.map"
export HM_STATS_UID_MAP="${TMP}/uid.map"
cg_site="$(hm_stats_resolve_site "/usr/sbin/lsphp" "0::/user.slice/user-1001.slice")"
[[ "${cg_site}" == "example.pl" ]] && ok "cgroup user-uid.slice" || bad "cgroup=${cg_site}"

# seria 0..9
file="$(hm_stats_file)"
: > "${file}"
for i in 0 1 2 3 4 5 6 7 8 9; do
  printf '%s\t-\tcpu\t%s\n' "$((HM_STATS_NOW - 600 + i * 60))" "${i}" >> "${file}"
  printf '%s\texample.pl\tcpu\t%s\n' "$((HM_STATS_NOW - 600 + i * 60))" "$((i + 10))" >> "${file}"
  printf '%s\tother.pl\tcpu\t%s\n' "$((HM_STATS_NOW - 600 + i * 60))" "1" >> "${file}"
done

text="$(cmd_stats day --metric cpu)"
printf '%s\n' "${text}" | grep -q 'min=0.0000' && ok "min" || bad "brak min: ${text}"
printf '%s\n' "${text}" | grep -q 'max=9.0000' && ok "max" || bad "brak max"
printf '%s\n' "${text}" | grep -q 'avg=4.5000' && ok "avg" || bad "brak avg"
printf '%s\n' "${text}" | grep -q 'p95=9.0000' && ok "p95" || bad "brak p95"
printf '%s\n' "${text}" | grep -q '#' && ok "sparkline" || bad "brak wykresu"
site_text="$(cmd_stats day --metric cpu --site example.pl)"
printf '%s\n' "${site_text}" | grep -q 'min=10.0000' && ok "per-site" || bad "per-site: ${site_text}"

js="$(cmd_stats day --metric cpu --json)"
printf '%s\n' "${js}" | grep -q '"p95":9.0000' && ok "json" || bad "json: ${js}"

top="$(cmd_stats top --since 24h --metric cpu)"
first="$(printf '%s\n' "${top}" | awk 'NR==2 {print $1}')"
[[ "${first}" == "example.pl" ]] && ok "top strona" || bad "top=${first}"

when="$(date -d '2026-11-09 03:00' +%s)"
printf '%s\t-\tload\t1.25\n' "${when}" >> "${file}"
at="$(cmd_stats at "2026-11-09 03:00")"
printf '%s\n' "${at}" | grep -q 'load  1.25' && ok "migawka at" || bad "at: ${at}"

# retencja: 100 dni znika, 3 dni schodzą do 15 min, ostatnia godzina zostaje
: > "${file}"
printf '%s\t-\tcpu\t1\n' "$((HM_STATS_NOW - 100 * 86400))" >> "${file}"
base="$(( (HM_STATS_NOW - 3 * 86400) / 900 * 900 ))"
i=0
while [[ "${i}" -lt 120 ]]; do
  printf '%s\t-\tcpu\t%s\n' "$((base + i * 60))" "${i}" >> "${file}"
  i=$((i + 1))
done
printf '%s\t-\tcpu\t7\n' "$((HM_STATS_NOW - 60))" >> "${file}"
hm_stats_compact
if grep -q $'^\t' "${file}"; then
  bad "pusta kolumna po kompaktowaniu"
fi
old="$(awk -F '\t' -v t="$((HM_STATS_NOW - 100 * 86400))" '$1+0==t' "${file}" | wc -l | tr -d '[:space:]')"
[[ "${old}" == "0" ]] && ok "retencja 90 dni" || bad "stara próbka została (${old})"
recent="$(awk -F '\t' -v t="$((HM_STATS_NOW - 60))" '$1+0==t && $4+0==7' "${file}" | wc -l | tr -d '[:space:]')"
[[ "${recent}" == "1" ]] && ok "świeża próbka bez zmian" || bad "świeża=${recent}"
buckets="$(awk -F '\t' -v b="${base}" -v e="$((base + 120 * 60))" '$1+0>=b && $1+0<e' "${file}" | wc -l | tr -d '[:space:]')"
[[ "${buckets}" == "8" ]] && ok "kompakt 15 min (${buckets})" || bad "kubełki=${buckets} (oczekiwane 8)"

# 90 dni × 15 min × 8 metryk mieści się w 50 MB
big="${TMP}/db/samples.tsv"
awk -v now="${HM_STATS_NOW}" '
  BEGIN {
    start = now - 90 * 86400
    split("cpu ram swap load io net disk inodes", m, " ")
    for (t = start; t < now; t += 900) {
      for (i = 1; i <= 8; i++) printf "%d\t-\t%s\t1.5\n", t, m[i]
    }
  }
' > "${big}"
bytes="$(wc -c < "${big}" | tr -d '[:space:]')"
if [[ "${bytes}" -lt $((50 * 1024 * 1024)) ]]; then
  ok "90 dni ${bytes} B < 50 MB"
else
  bad "baza za duża: ${bytes}"
fi

# kolektor z sar (bez sieci) i cron
export HM_STATS_NOW=1700000000
printf '%s\n' 'Average:        all      1.00      0.00      0.50      0.00      0.00     82.50' > "${TMP}/sar.txt"
export HM_STATS_SAR="${TMP}/sar.txt"
printf '%s\n' 'eth0: 1000 0 0 0 0 0 0 0 2000' > "${TMP}/net1"
printf '%s\n' 'eth0: 1500 0 0 0 0 0 0 0 2500' > "${TMP}/net2"
export HM_STATS_NET_FILE="${TMP}/net1"
unset HM_STATS_FIXTURE || true
: > "${file}"
start_s="${SECONDS}"
cmd_stats collect run >/dev/null
export HM_STATS_NET_FILE="${TMP}/net2"
cmd_stats collect run >/dev/null
elapsed="$((SECONDS - start_s))"
if [[ "${elapsed}" -le 5 ]]; then
  ok "kolektor ${elapsed}s"
else
  bad "kolektor za wolny: ${elapsed}s"
fi
grep -q $'\tcpu\t17.50' "${file}" && ok "sar cpu" || bad "brak cpu z sar"
grep -q $'\tnet\t1000' "${file}" && ok "delta sieci" || bad "brak delty sieci"
cmd_stats collect install >/dev/null
grep -q 'stats collect run' "${HM_STATS_CRON}" && ok "cron 5 min" || bad "brak crona"
cmd_stats collect disable >/dev/null
[[ ! -f "${HM_STATS_CRON}" ]] && ok "cron usunięty" || bad "cron został"

rm -rf "${TMP}"
if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
