#!/usr/bin/env bash
# cron-run — sukces, błąd, timeout, lock, brak sekretu, brak uruchomienia.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*" >&2; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_confirm_plan() { return 0; }
hm_help_topic() { :; }
hm_notify() { printf 'notify %s %s\n' "$2" "$3" >> "${root}/notify"; }
_hm_cmd_help() { cat >/dev/null; }
_hm_cmd_register() { :; }

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
export HM_CRON_MON="${root}/mon"
export HM_CRON_EXEC_LOG="${root}/exec.log"
export HM_CRON_ALERTS="${root}/alerts"
: > "${root}/notify"
: > "${HM_CRON_EXEC_LOG}"

cat > "${root}/ok.sh" <<'EOF'
#!/usr/bin/env bash
printf 'ok\n'
exit 0
EOF
cat > "${root}/bad.sh" <<'EOF'
#!/usr/bin/env bash
printf 'PASSWORD=SECRET-CRON\n' >&2
exit 3
EOF
cat > "${root}/slow.sh" <<'EOF'
#!/usr/bin/env bash
sleep 3
exit 0
EOF
chmod +x "${root}/ok.sh" "${root}/bad.sh" "${root}/slow.sh" || true

# shellcheck disable=SC1091
source commands/cron/main.sh

cmd_cron monitor add backup --every 1h --grace 15m --user www-data >/dev/null
grep -qx 'www-data' "${HM_CRON_MON}/backup/user" && ok add-user || bad add-user

cmd_cron_run backup --timeout 5s -- "${root}/ok.sh" >/dev/null
grep -q '^rc=0$' "${HM_CRON_MON}/backup/state" && ok run-ok || bad run-ok
grep -q 'runuser -u www-data' "${HM_CRON_EXEC_LOG}" && ok run-user || bad run-user
[[ ! -d "${HM_CRON_MON}/backup/lock" ]] && ok run-unlocked || bad run-unlocked

if cmd_cron_run backup --timeout 5s -- "${root}/bad.sh" >"${root}/bad.out" 2>"${root}/bad.err"; then
  bad run-rc
else
  ok run-rc
fi
grep -q 'SECRET-CRON' "${HM_CRON_MON}/backup/stderr" "${root}/bad.out" "${root}/notify" && bad secret || ok secret
grep -q '\[redacted\]' "${HM_CRON_MON}/backup/stderr" && ok redacted || bad redacted
grep -q 'rc=3' "${HM_CRON_MON}/backup/state" && ok run-err || bad run-err

mkdir "${HM_CRON_MON}/backup/lock"
cmd_cron_run backup --timeout 5s -- "${root}/ok.sh" >"${root}/lock.out"
grep -q $'lock\tbackup' "${root}/lock.out" && ok lock || bad lock
rmdir "${HM_CRON_MON}/backup/lock"

if cmd_cron_run backup --timeout 1s -- "${root}/slow.sh" >/dev/null 2>&1; then
  bad timeout
else
  ok timeout
fi
grep -q '^rc=124$' "${HM_CRON_MON}/backup/state" && ok timeout-rc || bad timeout-rc
[[ ! -d "${HM_CRON_MON}/backup/lock" ]] && ok timeout-lock || bad timeout-lock

printf 'end=100\nrc=0\n' > "${HM_CRON_MON}/backup/state"
export HM_CRON_NOW=100000
st="$(cmd_cron monitor status)"
printf '%s\n' "${st}" | grep -q $'alert\tbackup\tbrak' && ok missing || bad missing
n1="$(grep -c 'backup' "${root}/notify" || true)"
cmd_cron monitor status >/dev/null
n2="$(grep -c 'backup' "${root}/notify" || true)"
[[ "${n1}" -eq "${n2}" ]] && ok missing-dedup || bad missing-dedup

wrap="$(cmd_cron monitor wrap www-data '* * * * * php PASSWORD=SECRET-CRON')"
printf '%s\n' "${wrap}" | grep -q 'cron-run' && ok wrap || bad wrap
printf '%s\n' "${wrap}" | grep -q 'SECRET-CRON' && bad wrap-secret || ok wrap-secret
printf '%s\n' "${wrap}" | grep -q $'user\twww-data' && ok wrap-user || bad wrap-user

[[ "${fail}" -eq 0 ]] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
