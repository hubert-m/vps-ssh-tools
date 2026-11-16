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
printf '%s\n' 'PASSWORD=SECRET-CRON' >&2
printf '%s\n' 'token=abc123' >&2
printf '%s\n' '--password s3cret' >&2
printf '%s\n' 'Authorization: Bearer XYZ' >&2
printf '%s\n' 'mysql -pSecretPass' >&2
exit 3
EOF
cat > "${root}/slow.sh" <<'EOF'
#!/usr/bin/env bash
# dziecko w tej samej grupie co setsid
sleep 30
exit 0
EOF
chmod +x "${root}/ok.sh" "${root}/bad.sh" "${root}/slow.sh" || true

# shellcheck disable=SC1091
source commands/cron/main.sh

# nazwy . / .. odrzucone
if cmd_cron monitor add '..' --every 1h >/dev/null 2>"${root}/dot.err"; then bad name-dotdot-add; else ok name-dotdot-add; fi
if cmd_cron_run '..' --timeout 1s -- "${root}/ok.sh" >/dev/null 2>&1; then bad name-dotdot-run; else ok name-dotdot-run; fi
if cmd_cron monitor remove '..' >/dev/null 2>&1; then bad name-dotdot-rm; else ok name-dotdot-rm; fi
if cmd_cron monitor add 'bad.name' --every 1h >/dev/null 2>&1; then bad name-dot; else ok name-dot; fi
[[ ! -e "${root}/mon/.." ]] || true
find "${HM_CRON_MON}" -maxdepth 1 -type d -name '..' 2>/dev/null | grep -q . && bad name-escape || ok name-escape

cmd_cron monitor add backup --every 1h --grace 15m --user www-data >/dev/null
grep -qx 'www-data' "${HM_CRON_MON}/backup/user" && ok add-user || bad add-user

cmd_cron_run backup --timeout 5s -- "${root}/ok.sh" >/dev/null
grep -q '^rc=0$' "${HM_CRON_MON}/backup/state" && ok run-ok || bad run-ok
grep -q 'runuser -u www-data' "${HM_CRON_EXEC_LOG}" && ok run-user || bad run-user
[[ ! -d "${HM_CRON_MON}/backup/lock" ]] && ok run-unlocked || bad run-unlocked
[[ ! -f "${HM_CRON_MON}/backup/lock.pid" ]] && ok run-unlocked-pid || bad run-unlocked-pid

if cmd_cron_run backup --timeout 5s -- "${root}/bad.sh" >"${root}/bad.out" 2>"${root}/bad.err"; then
  bad run-rc
else
  ok run-rc
fi
grep -q 'SECRET-CRON' "${HM_CRON_MON}/backup/stderr" "${root}/bad.out" "${root}/notify" && bad secret || ok secret
grep -q '\[redacted\]' "${HM_CRON_MON}/backup/stderr" && ok redacted || bad redacted
grep -qE 'token=\[redacted\]|TOKEN=\[redacted\]' "${HM_CRON_MON}/backup/stderr" && ok redact-token || bad redact-token
grep -qE 'password[= ]\[redacted\]|--password.\[redacted\]' "${HM_CRON_MON}/backup/stderr" && ok redact-password-flag || bad redact-password-flag
grep -qi 'Authorization=\[redacted\]' "${HM_CRON_MON}/backup/stderr" && ok redact-auth || bad redact-auth
grep -q '\-p\[redacted\]' "${HM_CRON_MON}/backup/stderr" && ok redact-mysql-p || bad redact-mysql-p
grep -q 'rc=3' "${HM_CRON_MON}/backup/state" && ok run-err || bad run-err

# żywy lock (PID bieżącej powłoki) → rc≠0 + alert
printf '%s\n' "$$" > "${HM_CRON_MON}/backup/lock.pid"
mkdir -p "${HM_CRON_MON}/backup/lock"
if cmd_cron_run backup --timeout 5s -- "${root}/ok.sh" >"${root}/lock.out" 2>"${root}/lock.err"; then
  bad lock-rc
else
  ok lock-rc
fi
grep -q $'lock\tbackup' "${root}/lock.out" && ok lock || bad lock
rm -rf "${HM_CRON_MON}/backup/lock" "${HM_CRON_MON}/backup/lock.pid"

# stary lock (martwy PID) → przebieg OK
printf '%s\n' '999999' > "${HM_CRON_MON}/backup/lock.pid"
mkdir -p "${HM_CRON_MON}/backup/lock"
if cmd_cron_run backup --timeout 5s -- "${root}/ok.sh" >/dev/null 2>&1; then
  ok lock-stale
else
  bad lock-stale
fi
[[ ! -f "${HM_CRON_MON}/backup/lock.pid" ]] && ok lock-stale-cleared || bad lock-stale-cleared

# timeout — zabij grupę (setsid gdy dostępny)
before=0
if command -v pgrep >/dev/null 2>&1; then
  before="$(pgrep -f "sleep 30" 2>/dev/null | wc -l | tr -d ' ' || true)"
  before="${before:-0}"
fi
if cmd_cron_run backup --timeout 1s -- "${root}/slow.sh" >/dev/null 2>&1; then
  bad timeout
else
  ok timeout
fi
grep -q '^rc=124$' "${HM_CRON_MON}/backup/state" && ok timeout-rc || bad timeout-rc
[[ ! -d "${HM_CRON_MON}/backup/lock" ]] && ok timeout-lock || bad timeout-lock
sleep 0.5
if command -v pgrep >/dev/null 2>&1; then
  sleep_left="$(pgrep -f "sleep 30" 2>/dev/null | wc -l | tr -d ' ' || true)"
  sleep_left="${sleep_left:-0}"
  [[ "${sleep_left}" -le "${before}" ]] && ok timeout-no-orphan || {
    bad timeout-no-orphan
    printf 'sleep_left=%s before=%s\n' "${sleep_left}" "${before}"
  }
else
  ok timeout-no-orphan-skip
fi

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

# brak wycieku trap RETURN — ustawienie i wywołanie funkcji nie zostawia trap
trap - RETURN
cmd_cron_run backup --timeout 2s -- "${root}/ok.sh" >/dev/null
trp="$(trap -p RETURN || true)"
[[ -z "${trp}" ]] && ok trap-clean || bad trap-clean

[[ "${fail}" -eq 0 ]] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
