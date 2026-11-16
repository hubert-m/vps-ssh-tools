#!/usr/bin/env bash
# Panel HTML z --json: escape, brak sekretów, nasłuch tylko na loopback.
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
hm_info() { printf '%s\n' "$*" >&2; }
hm_warn() { echo "WARN: $*" >&2; }
hm_help_topic() { :; }
_hm_cmd_help() { cat >/dev/null; }
_hm_cmd_register() { :; }
_hm_cmd_register_site() { :; }

# shellcheck source=commands/metrics/main.sh
source "${ROOT}/commands/metrics/main.sh"
# shellcheck source=commands/dashboard/main.sh
source "${ROOT}/commands/dashboard/main.sh"

bash -n "${ROOT}/commands/dashboard/main.sh"
bash -n "${ROOT}/commands/dashboard/html.sh"

base="$(mktemp -d)"
fix="${base}/fix"
mkdir -p "${fix}"
export HM_JSON_DIR="${fix}"
export HM_DASHBOARD_NOW="2026-11-11T00:00:00Z"
export HM_DASHBOARD_PASS="sekret-panel-1"

printf '%s\n' $'<script>alert(1)</script>\t8.3\tyes\tactive' >"${fix}/webs.tsv"
printf '%s\n' $'a.test\tok\t9\t2026-12-01' >"${fix}/ssl.tsv"
printf '%s\n' $'lsws\tlsws\tactive\tenabled' >"${fix}/services.tsv"
printf '%s\n' $'full\t20261110-120000\t100\ttrue' $'restic.pass\t20261101-120000\t9\ttrue' >"${fix}/backup-list.tsv"
printf '%s\n' $'ufw\tpresent\t2\t3' >"${fix}/security-status.tsv"
printf '%s\n' $'a.test\ttrue\t200' >"${fix}/http.tsv"

hm_health_check() {
  printf '%s\n' '{"ok":true,"alerts":[],"disk_used":11}'
}
cmd_security_audit() {
  printf '%s\n' '{"score":80,"checks":[{"id":"/etc/shadow","group":"ssh","weight":5,"status":"FAIL","desc":"<b>x</b>","fix":"restic.pass"}]}'
}

html="${base}/site/index.html"
cmd_dashboard build --out "${base}/site" >/dev/null
[[ -f "${html}" ]] && ok build || bad build
grep -q '&lt;script&gt;' "${html}" && ok xss-esc || bad xss-esc
grep -q '<script>' "${html}" && bad xss-raw || ok xss-raw
grep -q 'restic.pass' "${html}" && bad secret-pass || ok secret-pass
grep -q '/etc/shadow' "${html}" && bad secret-shadow || ok secret-shadow
grep -q 'sekret-panel-1' "${html}" && bad secret-auth || ok secret-auth
grep -q '\[ukryte\]' "${html}" && ok redacted || bad redacted
grep -q 'disk_used' "${html}" && ok health || bad health

plan="${base}/plan.txt"
cmd_dashboard serve --dry-run --port 8765 >"${plan}"
grep -q 'bind=127.0.0.1' "${plan}" && ok bind || bad bind
grep -q 'ssh -L 8765:127.0.0.1:8765' "${plan}" && ok tunnel || bad tunnel
grep -q '0.0.0.0' "${plan}" && bad bind-any || ok bind-any
cmd_dashboard serve --dry-run --python --port 8765 >"${base}/py.txt"
grep -q 'cmd=python3 -m http.server --bind 127.0.0.1 8765' "${base}/py.txt" && ok py-bind || bad py-bind
cmd_dashboard serve --dry-run --bind ::1 --port 9 >"${base}/v6.txt"
grep -q 'bind=::1' "${base}/v6.txt" && ok bind6 || bad bind6

set +e
cmd_dashboard serve --bind 0.0.0.0 --port 8765 >"${base}/badbind.out" 2>"${base}/badbind.err"
rc=$?
set -e
[[ "${rc}" -ne 0 && ! -s "${base}/badbind.out" ]] && ok reject-any || bad reject-any

resp="$(hm_dashboard_http_response "${base}/site" "GET /etc/passwd HTTP/1.1")"
printf '%s' "${resp}" | grep -q '404' && ok http-404 || bad http-404
printf '%s' "${resp}" | grep -q 'sekret-panel-1' && bad http-secret || ok http-secret
resp="$(hm_dashboard_http_response "${base}/site" "GET /../../etc/shadow HTTP/1.1")"
printf '%s' "${resp}" | grep -q '404' && ok http-dot || bad http-dot
resp="$(hm_dashboard_http_response "${base}/site" "GET / HTTP/1.1")"
printf '%s' "${resp}" | grep -q '200' && ok http-ok || bad http-ok
printf '%s' "${resp}" | grep -q '&lt;script&gt;' && ok http-body || bad http-body

cron="${base}/cron"
HM_DASHBOARD_CRON="${cron}" cmd_dashboard schedule enable --yes >/dev/null
grep -q 'dashboard build' "${cron}" && ok sched-on || bad sched-on
HM_DASHBOARD_CRON="${cron}" cmd_dashboard schedule disable --yes >/dev/null
[[ ! -f "${cron}" ]] && ok sched-off || bad sched-off

hm_is_valid_domain() { [[ "$1" == *.* ]]; }
hm_print_secret() { printf 'SECRET %s\n' "$*" >>"${base}/secrets.txt"; }
hm_have_cmd() {
  case "$1" in
    openssl|python3) command -v "$1" >/dev/null 2>&1 ;;
    htpasswd) return 1 ;;
    *) command -v "$1" >/dev/null 2>&1 ;;
  esac
}
# stub openssl apr1 for determinism when openssl missing apr1
if ! openssl passwd -apr1 test >/dev/null 2>&1; then
  openssl() {
    if [[ "${1:-}" == "passwd" ]]; then
      printf '$apr1$testsalt$testhash\n'
      return 0
    fi
    command openssl "$@"
  }
fi

vhost="${base}/vh.conf"
auth="${base}/auth"
mapf="${base}/httpd_config.conf"
: >"${mapf}"
printf 'old-vhost\n' >"${vhost}"
HM_DASHBOARD_VHOST="${vhost}" HM_DASHBOARD_AUTH="${auth}" HM_DASHBOARD_OLS_MAP="${mapf}" \
  cmd_dashboard publish --domain status.example.com --allow 203.0.113.5,198.51.100.2 --yes \
  >"${base}/pub.out" 2>"${base}/pub.err"
grep -q 'poza tunelem' "${base}/pub.err" && ok warn-pub || bad warn-pub
grep -q 'allow                   203.0.113.5, 198.51.100.2' "${vhost}" && ok allow || bad allow
grep -q 'userDB' "${vhost}" && ok ols-realm || bad ols-realm
grep -q 'sekret-panel-1' "${vhost}" && bad vhost-secret || ok vhost-secret
grep -q 'sekret-panel-1' "${auth}" && bad auth-plaintext || ok auth-hashed
grep -q '^hmtools:' "${auth}" && ok auth-user || bad auth-user
grep -q 'sekret-panel-1' "${html}" && bad html-after-pub || ok html-after-pub
if ls "${base}"/vh.conf.hmbak.* >/dev/null 2>&1; then ok vhost-bak; else bad vhost-bak; fi
grep -q 'hmtools-dashboard:status.example.com' "${mapf}" && ok ols-map || bad ols-map
grep -q 'sekret-panel-1' "${base}/secrets.txt" && ok secret-tty || bad secret-tty

set +e
cmd_dashboard publish --domain status.example.com --yes >"${base}/noallow.out" 2>"${base}/noallow.err"
rc=$?
set -e
[[ "${rc}" -ne 0 ]] && ok pub-need-allow || bad pub-need-allow

set +e
HM_DASHBOARD_VHOST="${vhost}" HM_DASHBOARD_AUTH="${auth}" \
  cmd_dashboard publish --domain status.example.com --allow 0.0.0.0 --yes \
  >"${base}/zero.out" 2>"${base}/zero.err"
rc=$?
set -e
[[ "${rc}" -ne 0 ]] && ok reject-zero || bad reject-zero

# session: dry + cleanup restores bak / removes map
svh="${base}/session/vhconf.conf"
sauth="${base}/session.htpasswd"
smap="${base}/session-httpd.conf"
mkdir -p "$(dirname "${svh}")"
printf 'ORIG\n' >"${svh}"
: >"${smap}"
export HM_DASHBOARD_RELOAD_LOG="${base}/reload.log"
: >"${HM_DASHBOARD_RELOAD_LOG}"
HM_DASHBOARD_VHOST_DIR="$(dirname "${svh}")" HM_DASHBOARD_AUTH="${sauth}" \
  HM_DASHBOARD_OLS_MAP="${smap}" HM_DASHBOARD_DRY=1 \
  cmd_dashboard session --domain dash.example.com --allow 203.0.113.9 \
  >"${base}/sess.out" 2>"${base}/sess.err"
grep -q 'session=active' "${base}/sess.out" && ok session-run || bad session-run
grep -q 'ORIG' "${svh}" && ok session-restore || bad session-restore
grep -q 'hmtools-dashboard:dash.example.com' "${smap}" && bad session-map-left || ok session-map-clean
grep -q 'reload' "${HM_DASHBOARD_RELOAD_LOG}" && ok session-reload || bad session-reload

grep -q 'dashboard)' "${ROOT}/lib/complete/tab.sh" && ok tab || bad tab

rm -rf "${base}"
if [[ "${fail}" -eq 0 ]]; then
  echo "ALL PASSED"
else
  echo "FAILED"
  exit 1
fi
