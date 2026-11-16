#!/usr/bin/env bash
# maintenance: okno, schedule, reboot cancel, post-check, livepatch — mocki.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"
export HMTOOLS_ROOT="${ROOT}"
export HMTOOLS_TEST=1

# shellcheck disable=SC1091
source scripts/_stubs.sh
# shellcheck disable=SC1091
source commands/maintenance/main.sh

fail=0
ok() { echo "OK   $*"; }
bad() { echo "FAIL $*"; fail=1; }

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
export HM_MAINT_STATE_DIR="${tmp}/state"
export HM_MAINT_UNIT_DIR="${tmp}/units"
export HM_MAINT_SYSTEMCTL_LOG="${tmp}/systemctl.log"
export HM_MAINT_NOTIFY_LOG="${tmp}/notify.log"
export HM_MAINT_UPDATE_LOG="${tmp}/update.log"
export HM_MAINT_REBOOT_LOG="${tmp}/reboot.log"
export HM_MAINT_LIVEPATCH=canonical
export HM_MAINT_LIVEPATCH_LOG="${tmp}/livepatch.log"
export HM_MAINT_NOW="Sun 0315"
: > "${HM_MAINT_SYSTEMCTL_LOG}"
: > "${HM_MAINT_NOTIFY_LOG}"

cmd_maintenance window set "Sun 03:00-04:00" >/dev/null
[[ -f "${HM_MAINT_STATE_DIR}/window.txt" ]] && ok "window-set" || bad "window-set"
hm_maint_in_window && ok "in-window" || bad "in-window"
export HM_MAINT_NOW="Sun 0500"
hm_maint_in_window && bad "out-window" || ok "out-window"

export HM_MAINT_NOW="Sun 0315"
if cmd_maintenance reboot schedule >/dev/null 2>&1; then
  [[ -f "${HM_MAINT_STATE_DIR}/reboot.at" ]] && ok "reboot-sched" || bad "reboot-sched"
else
  bad "reboot-sched"
fi
export HM_MAINT_NOW="Mon 0315"
if cmd_maintenance reboot maybe >/dev/null 2>&1; then
  bad "reboot-blocked"
else
  ok "reboot-blocked"
fi
[[ ! -s "${HM_MAINT_REBOOT_LOG}" ]] && ok "no-reboot-outside" || bad "no-reboot-outside"

cmd_maintenance reboot cancel >/dev/null
[[ ! -f "${HM_MAINT_STATE_DIR}/reboot.at" ]] && ok "reboot-cancel" || bad "reboot-cancel"

export HM_MAINT_NOW="Sun 0315"
cmd_maintenance schedule update security --reboot-if-required >/dev/null
grep -q 'hmtools-maint-update.timer' "${HM_MAINT_SYSTEMCTL_LOG}" && ok "timer" || bad "timer"
cmd_maintenance run-scheduled >/dev/null
grep -q 'update security' "${HM_MAINT_UPDATE_LOG}" && ok "run-update" || bad "run-update"
grep -q 'maintenance update' "${HM_MAINT_NOTIFY_LOG}" && ok "notify" || bad "notify"

printf '%s\n' 'lsws=active' 'nginx=failed' 'mysql=active' > "${tmp}/svcs"
export HM_MAINT_SERVICES_FILE="${tmp}/svcs"
printf '%s\n' 'a.test OK' 'b.test DOWN' > "${tmp}/http"
export HM_MAINT_HTTP_FILE="${tmp}/http"
set +e
cmd_maintenance post-check >/dev/null 2>&1
rc=$?
set -e
[[ "${rc}" -ne 0 ]] && ok "postcheck-fail" || bad "postcheck-fail"
grep -q 'post-check FAIL' "${HM_MAINT_NOTIFY_LOG}" && ok "postcheck-notify" || bad "postcheck-notify"

cmd_maintenance livepatch enable >/dev/null
grep -q 'enable canonical' "${HM_MAINT_LIVEPATCH_LOG}" && ok "livepatch" || bad "livepatch"

if cmd_maintenance schedule update security --require-backup >/dev/null 2>&1; then
  bad "require-backup"
else
  ok "require-backup"
fi
export HM_MAINT_BACKUP_OK=1
cmd_maintenance schedule update packages --require-backup >/dev/null && ok "backup-ok" || bad "backup-ok"

st="$(cmd_maintenance status 2>/dev/null || true)"
printf '%s\n' "${st}" | grep -q 'okno' && ok "status" || bad "status"

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
