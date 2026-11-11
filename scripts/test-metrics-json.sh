#!/usr/bin/env bash
# --json list/statusów i atomowy plik Prometheus.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export HMTOOLS_ROOT="${ROOT}"
# shellcheck source=lib/common/ui.sh
source "${ROOT}/lib/common/ui.sh"

fail=0
ok() { echo "OK   $*"; }
bad() { echo "FAIL $*"; fail=1; }

hm_err() { echo "ERR: $*" >&2; }
hm_ok() { :; }
hm_info() { :; }
hm_warn() { echo "WARN: $*" >&2; }
hm_help_topic() { :; }
hm_detect_all() { :; }
_hm_cmd_help() { cat >/dev/null; }
_hm_cmd_register() { :; }
_hm_cmd_register_site() { :; }

# shellcheck source=commands/metrics/main.sh
source "${ROOT}/commands/metrics/main.sh"
# shellcheck source=commands/webs/main.sh
source "${ROOT}/commands/webs/main.sh"
# shellcheck source=commands/services/main.sh
source "${ROOT}/commands/services/main.sh"
# shellcheck source=commands/disk/main.sh
source "${ROOT}/commands/disk/main.sh"
# shellcheck source=commands/mysql/main.sh
source "${ROOT}/commands/mysql/main.sh"
# shellcheck source=commands/ssl/main.sh
source "${ROOT}/commands/ssl/main.sh"
# shellcheck source=commands/backup/main.sh
source "${ROOT}/commands/backup/main.sh"
# shellcheck source=commands/security/main.sh
source "${ROOT}/commands/security/main.sh"
# shellcheck source=commands/node/main.sh
source "${ROOT}/commands/node/main.sh"
# shellcheck source=commands/limits/main.sh
source "${ROOT}/commands/limits/main.sh"
# shellcheck source=commands/wp/main.sh
source "${ROOT}/commands/wp/main.sh"
# shellcheck source=commands/docker/main.sh
source "${ROOT}/commands/docker/main.sh"

bash -n "${ROOT}/lib/common/json.sh"
bash -n "${ROOT}/commands/metrics/json.sh"
bash -n "${ROOT}/commands/metrics/main.sh"
bash -n "${ROOT}/commands/webs/main.sh"
bash -n "${ROOT}/commands/disk/main.sh"

command -v python3 >/dev/null 2>&1 || {
  echo "FAIL brak python3"
  exit 1
}

base="$(mktemp -d)"
fix="${base}/fix"
mkdir -p "${fix}"
export HM_JSON_DIR="${fix}"

printf '%s\n' $'a"b\t8.3\tyes\t10\tactive' $'s.test\t8.2\tno\t0\tsuspended' >"${fix}/webs.tsv"
printf '%s\n' $'a"b\t6.4\t1\t0\toff\t8.3' >"${fix}/wp.tsv"
printf '%s\n' $'a.test\tok\t12\t2026-12-01' >"${fix}/ssl.tsv"
printf '%s\n' $'lsws\tlsws\tactive\tenabled' $'cron\tcron\tinactive\tdisabled' $'ghost\tghost\tunknown\tunknown' >"${fix}/services.tsv"
printf '%s\n' $'full\t20261110-120000\t100\ttrue' $'full\t20261101-120000\t900\ttrue' $'full\t20261111-120000\t10\tfalse' $'site\t20261109-000000\t50\ttrue' >"${fix}/backup-list.tsv"
printf '%s\n' $'local\tlocal\t/backup/hmtools\ttrue' >"${fix}/backup-targets.tsv"
printf '%s\n' $'ufw\tpresent\t4\t-1' >"${fix}/security-status.tsv"
printf '%s\n' $'22\ttcp\t0.0.0.0:22\tsshd' >"${fix}/ports.tsv"
printf '%s\n' $'a.test\t0.40.1\t10.2.0' >"${fix}/node.tsv"
printf '%s\n' $'web\tnginx\trunning\t8080' >"${fix}/docker.tsv"
printf '%s\n' $'a.test\twww\t100\t50%\t1G\t' >"${fix}/limits.tsv"
printf '%s\n' $'/\t40\t600\text4' >"${fix}/disk.tsv"
printf '%s\n' $'app\t100' >"${fix}/mysql.tsv"
printf '%s\n' $'a.test\ttrue\t200' >"${fix}/http.tsv"

check_json() {
  local name="$1" file="$2"
  if python3 -m json.tool "${file}" >/dev/null; then
    ok "json-${name}"
  else
    bad "json-${name}"
  fi
  if grep -q $'\033' "${file}"; then
    bad "ansi-${name}"
  else
    ok "ansi-${name}"
  fi
}

run_json() {
  local name="$1"
  shift
  local out="${base}/${name}.json" err="${base}/${name}.err"
  if "$@" >"${out}" 2>"${err}"; then
    check_json "${name}" "${out}"
  else
    bad "rc-${name}"
  fi
}

run_json webs cmd_webs --json
python3 -c 'import json,sys; d=json.load(open(sys.argv[1],encoding="utf-8")); assert d["sites"][0]["domain"]=="a\"b"; assert d["sites"][0]["size_bytes"]==10' "${base}/webs.json" \
  && ok webs-keys || bad webs-keys
run_json webs-susp cmd_webs --json --suspended
python3 -c 'import json,sys; d=json.load(open(sys.argv[1],encoding="utf-8")); assert len(d["sites"])==1 and d["sites"][0]["status"]=="suspended"' "${base}/webs-susp.json" \
  && ok webs-susp || bad webs-susp

err="${base}/bad.err"
out="${base}/bad.out"
set +e
cmd_webs --json --nope >"${out}" 2>"${err}"
rc=$?
set -e
[[ "${rc}" -ne 0 && ! -s "${out}" && -s "${err}" ]] && ok webs-bad || bad webs-bad

run_json wp cmd_wp sites --json
run_json ssl cmd_ssl --json
run_json services cmd_services --json
run_json backup-list cmd_backup list --json
run_json backup-targets cmd_backup targets --json
run_json sec cmd_security status --json
run_json ports cmd_security ports --json
run_json node cmd_node --json
run_json docker cmd_docker --json
run_json limits cmd_limits --json
run_json disk cmd_disk --json
run_json mysql cmd_mysql --json

python3 -c 'import json,sys; d=json.load(open(sys.argv[1],encoding="utf-8")); assert d["snapshots"][2]["ok"] is False' "${base}/backup-list.json" \
  && ok backup-ok || bad backup-ok
python3 -c 'import json,sys; d=json.load(open(sys.argv[1],encoding="utf-8")); assert d["updates_pending"]==-1 and d["bans"]==4' "${base}/sec.json" \
  && ok sec-keys || bad sec-keys

dest="${base}/text/hmtools.prom"
printf '%s\n' "$(cmd_metrics export --textfile "${dest}")" >/dev/null
[[ -f "${dest}" ]] && ok prom-file || bad prom-file
leftover="$(find "${base}/text" -name 'hmtools.prom.*' | wc -l | tr -d ' ')"
[[ "${leftover}" == "0" ]] && ok prom-atomic || bad "prom-atomic=${leftover}"
grep -q 'hmtools_backup_age_seconds{target="full"} 100' "${dest}" && ok prom-backup || bad prom-backup
grep -q 'hmtools_backup_age_seconds{target="site"} 50' "${dest}" && ok prom-site || bad prom-site
grep -q 'hmtools_cert_days_left{domain="a.test"} 12' "${dest}" && ok prom-cert || bad prom-cert
grep -q 'hmtools_service_up{name="lsws"} 1' "${dest}" && ok prom-up || bad prom-up
grep -q 'hmtools_service_up{name="cron"} 0' "${dest}" && ok prom-down || bad prom-down
grep -q 'ghost' "${dest}" && bad prom-unknown || ok prom-unknown
grep -q 'hmtools_http_up{domain="a.test"} 1' "${dest}" && ok prom-http || bad prom-http
grep -q 'hmtools_fail2ban_bans 4' "${dest}" && ok prom-bans || bad prom-bans
grep -q 'hmtools_security_updates_pending' "${dest}" && bad prom-upd-omit || ok prom-upd-omit
grep -q $'\033' "${dest}" && bad prom-ansi || ok prom-ansi

rm -f "${fix}/http.tsv"
printf '%s\n' $'ufw\tpresent\t4\t2' >"${fix}/security-status.tsv"
dest2="${base}/text/hmtools2.prom"
cmd_metrics export --textfile "${dest2}" >/dev/null
grep -q 'hmtools_http_up' "${dest2}" && bad prom-no-http || ok prom-no-http
grep -q 'hmtools_security_updates_pending 2' "${dest2}" && ok prom-upd || bad prom-upd

cron="${base}/cron.d/hmtools-metrics"
HM_METRICS_CRON="${cron}" HM_METRICS_TEXTFILE="${dest}" cmd_metrics timer --yes >/dev/null
grep -q 'metrics export --textfile' "${cron}" && ok timer || bad timer

set +e
cmd_metrics nope >"${base}/nope.out" 2>"${base}/nope.err"
rc=$?
set -e
[[ "${rc}" -ne 0 && ! -s "${base}/nope.out" && -s "${base}/nope.err" ]] && ok metrics-bad || bad metrics-bad

set +e
cmd_disk --json --drive >"${base}/diskbad.out" 2>"${base}/diskbad.err"
rc=$?
set -e
[[ "${rc}" -ne 0 && ! -s "${base}/diskbad.out" ]] && ok disk-mix || bad disk-mix

out="$(
  unset HM_JSON_DIR
  df() {
    printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted on' '/dev/sda1 1000 400 600 40% /data'
  }
  hm_json_emit disk
)"
printf '%s\n' "${out}" >"${base}/df.json"
python3 -m json.tool "${base}/df.json" >/dev/null && ok df-json || bad df-json
python3 -c 'import json,sys; d=json.load(open(sys.argv[1],encoding="utf-8")); assert d["filesystems"][0]["mount"]=="/data" and d["filesystems"][0]["used_percent"]==40' "${base}/df.json" \
  && ok df-parse || bad df-parse

set +e
(
  unset HM_JSON_DIR
  hm_json_emit mysql
) >"${base}/mysql-live.out" 2>"${base}/mysql-live.err"
rc=$?
set -e
[[ "${rc}" -ne 0 && ! -s "${base}/mysql-live.out" && -s "${base}/mysql-live.err" ]] && ok mysql-miss || bad mysql-miss

for f in webs ssl services backup security node docker limits disk mysql wp; do
  grep -q 'hm_json_emit' "${ROOT}/commands/${f}/main.sh" && ok "wire-${f}" || bad "wire-${f}"
done
grep -q 'metrics)' "${ROOT}/lib/complete/tab.sh" && ok tab || bad tab

rm -rf "${base}"
if [[ "${fail}" -eq 0 ]]; then
  echo "ALL PASSED"
else
  echo "FAILED"
  exit 1
fi
