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
printf '%s\n' $'a.test\tok\t12\t2026-12-01' $'b.missing\tmissing\t0\t' >"${fix}/ssl.tsv"
printf '%s\n' $'lsws\tlsws\tactive\tenabled' $'cron\tcron\tinactive\tdisabled' $'ghost\tghost\tunknown\tunknown' >"${fix}/services.tsv"
printf '%s\n' $'full\t20261110-120000\t100\ttrue' $'full\t20261101-120000\t900\ttrue' $'full\t20261111-120000\t10\tfalse' $'site\t20261109-000000\t50\ttrue' >"${fix}/backup-list.tsv"
printf '%s\n' $'local\tlocal\t/backup/hmtools\ttrue' >"${fix}/backup-targets.tsv"
printf '%s\n' $'ufw\tpresent\t4\t-1' >"${fix}/security-status.tsv"
printf '%s\n' $'22\ttcp\t0.0.0.0:22\tsshd' >"${fix}/ports.tsv"
printf '%s\n' $'a.test\t0.40.1\t10.2.0' >"${fix}/node.tsv"
printf '%s\n' $'web\tnginx\trunning\t8080' >"${fix}/docker.tsv"
printf '%s\n' $'a.test\twww\t100\t50%\t1G\t' >"${fix}/limits.tsv"
printf '%s\n' $'/\t40\t600\text4\t/dev/sda1' >"${fix}/disk.tsv"
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
mode="$(stat -c '%a' "${dest}" 2>/dev/null || stat -f '%OLp' "${dest}" 2>/dev/null || echo '?')"
[[ "${mode}" == "644" || "${mode}" == "0644" ]] && ok prom-mode || bad "prom-mode=${mode}"
leftover="$(find "${base}/text" -name 'hmtools.prom.*' | wc -l | tr -d ' ')"
[[ "${leftover}" == "0" ]] && ok prom-atomic || bad "prom-atomic=${leftover}"
grep -q 'hmtools_backup_age_seconds{target="full"} 100' "${dest}" && ok prom-backup || bad prom-backup
grep -q 'hmtools_backup_age_seconds{target="site"} 50' "${dest}" && ok prom-site || bad prom-site
grep -q 'hmtools_cert_present{domain="a.test"} 1' "${dest}" && ok prom-cert-present || bad prom-cert-present
grep -q 'hmtools_cert_days_left{domain="a.test"} 12' "${dest}" && ok prom-cert || bad prom-cert
grep -q 'hmtools_cert_present{domain="b.missing"} 0' "${dest}" && ok prom-cert-miss || bad prom-cert-miss
grep -q 'hmtools_cert_days_left{domain="b.missing"}' "${dest}" && bad prom-cert-miss-days || ok prom-cert-miss-days
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

# Ochrona ścieżki: tylko .prom + odmowa obcych plików
set +e
cmd_metrics export --textfile "${base}/text/hmtools.txt" >"${base}/bad-ext.out" 2>"${base}/bad-ext.err"
rc=$?
set -e
[[ "${rc}" -ne 0 ]] && ok prom-ext || bad prom-ext
printf '%s\n' '# HELP other_metric' >"${base}/text/other.prom"
set +e
cmd_metrics export --textfile "${base}/text/other.prom" >"${base}/bad-foreign.out" 2>"${base}/bad-foreign.err"
rc=$?
set -e
[[ "${rc}" -ne 0 ]] && ok prom-foreign || bad prom-foreign

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
    # jak df -PT
    printf '%s\n' 'Filesystem     Type 1024-blocks Used Available Capacity Mounted on' \
      '/dev/sda1      ext4       1000  400       600      40% /data'
  }
  hm_json_emit disk
)"
printf '%s\n' "${out}" >"${base}/df.json"
python3 -m json.tool "${base}/df.json" >/dev/null && ok df-json || bad df-json
python3 -c 'import json,sys; d=json.load(open(sys.argv[1],encoding="utf-8")); f=d["filesystems"][0]; assert f["mount"]=="/data" and f["used_percent"]==40 and f["fstype"]=="ext4" and f["device"]=="/dev/sda1"' "${base}/df.json" \
  && ok df-parse || bad df-parse

# ss -lntup: adres w $5 (nie $4)
out="$(
  unset HM_JSON_DIR
  ss() {
    printf '%s\n' \
      'Netid State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process' \
      'tcp   LISTEN 0      128          0.0.0.0:8099      0.0.0.0:*    users:(("nc",pid=9,fd=3))' \
      'tcp   LISTEN 0      128        127.0.0.1:3306      0.0.0.0:*    users:(("mysqld",pid=1,fd=1))'
  }
  hm_json_emit ports
)"
printf '%s\n' "${out}" >"${base}/ss.json"
python3 -m json.tool "${base}/ss.json" >/dev/null && ok ss-json || bad ss-json
python3 -c 'import json,sys; d=json.load(open(sys.argv[1],encoding="utf-8")); ports={p["port"] for p in d["ports"]}; assert 8099 in ports and 3306 not in ports' "${base}/ss.json" \
  && ok ss-parse || bad ss-parse

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
