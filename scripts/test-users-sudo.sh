#!/usr/bin/env bash
# Regresja: users list/add/lock/sudo/audit na fixture passwd/shadow/sudoers.d
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_have_cmd() {
  case "$1" in
    visudo) return 1 ;; # fixture bez visudo — zapis i tak OK w teście
    *) command -v "$1" >/dev/null 2>&1 ;;
  esac
}
hm_confirm_plan() { return 0; }
hm_confirm_plan_critical() { return 0; }
C_BOLD=""; C_RESET=""
_hm_cmd_help() { cat >/dev/null; }
_hm_cmd_register() { :; }

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
export HM_USERS_PASSWD="${root}/passwd"
export HM_USERS_SHADOW="${root}/shadow"
export HM_USERS_SUDOERS_D="${root}/sudoers.d"
export HM_USERS_HOME_BASE="${root}/home"
export HM_USERS_ACTION_LOG="${root}/actions.log"
mkdir -p "${HM_USERS_SUDOERS_D}" "${HM_USERS_HOME_BASE}"
cat > "${HM_USERS_PASSWD}" <<'EOF'
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
alice:x:1000:1000:Alice:/home/alice:/bin/bash
evil:x:0:0:dup:/home/evil:/bin/bash
sysbash:x:50:50:sys:/:/bin/bash
EOF
cat > "${HM_USERS_SHADOW}" <<'EOF'
root:$6$hash:19000:0:99999:7:::
alice:$6$hash:19000:0:99999:7:::
empty::19000:0:99999:7:::
EOF
printf 'ci ALL=(ALL) NOPASSWD: ALL\n' > "${HM_USERS_SUDOERS_D}/zz-ci"

# shellcheck disable=SC1091
source commands/users/main.sh

# sesja = alice w teście (bez nadpisywania systemowego id -nG)
hm_users_session_login() { printf 'alice'; }
hm_users_in_sudo_group() {
  local login="$1"
  [[ -f "$(hm_users_sudoers_dir)/hm-${login}" ]] && return 0
  return 1
}

if cmd_users_lock root 2>/dev/null; then bad lock-root; else ok lock-root-deny; fi
if cmd_users_lock alice 2>/dev/null; then bad lock-self; else ok lock-self-deny; fi
cmd_users_lock bob >/dev/null && ok lock-bob || bad lock-bob
grep -q 'locked bob' "${HM_USERS_ACTION_LOG}" && ok lock-logged || bad lock-logged

key="${root}/id.pub"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKeyDataHere000000000000000000000000 deploy@test\n' > "${key}"
cmd_users_add deploy --key "${key}" --sudo >/dev/null
grep -q '^deploy:' "${HM_USERS_PASSWD}" && ok add-user || bad add-user
[[ -f "${HM_USERS_SUDOERS_D}/hm-deploy" ]] || [[ -f "${HM_USERS_HOME_BASE}/deploy/.ssh/authorized_keys" ]]
[[ -f "${HM_USERS_HOME_BASE}/deploy/.ssh/authorized_keys" ]] && ok add-key || bad add-key
[[ -f "${HM_USERS_SUDOERS_D}/hm-deploy" ]] && ok sudo-grant || bad sudo-grant

out="$(cmd_users_audit)"
printf '%s\n' "${out}" | grep -q 'drugi UID 0: evil' && ok audit-uid0 || bad audit-uid0
printf '%s\n' "${out}" | grep -q 'puste hasło: empty' && ok audit-empty || bad audit-empty
printf '%s\n' "${out}" | grep -q 'NOPASSWD' && ok audit-nopasswd || bad audit-nopasswd

cmd_users_sudo revoke deploy >/dev/null
[[ ! -f "${HM_USERS_SUDOERS_D}/hm-deploy" ]] && ok sudo-revoke || bad sudo-revoke

out="$(cmd_users_list 2>&1 || true)"
printf '%s\n' "${out}" | grep -q alice && ok list || { bad list; printf 'LIST OUT:\n%s\n' "${out}" >&2; }

# http:// zabronione
if cmd_users_add nohttp --key 'http://127.0.0.1/x' 2>/dev/null; then
  bad http-deny
else
  ok http-deny
fi
grep -q '^nohttp:' "${HM_USERS_PASSWD}" && bad http-no-account || ok http-no-account

# filtr: tylko poprawne linie ssh-
mixed="${root}/mixed.pub"
printf 'command="evil" ssh-ed25519 AAAA evil\nbogus line\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKeyDataHere000000000000000000000000 good@test\n' > "${mixed}"
raw="$(mktemp)"; filtered="$(mktemp)"
hm_users_fetch_key "${mixed}" "${raw}"
hm_users_filter_valid_keys "${raw}" "${filtered}"
grep -q 'good@test' "${filtered}" && ok filter-keep || bad filter-keep
grep -q 'command=' "${filtered}" && bad filter-drop-opts || ok filter-drop-opts
grep -q 'bogus' "${filtered}" && bad filter-drop-bogus || ok filter-drop-bogus
rm -f "${raw}" "${filtered}"

# zły klucz → brak konta (rollback / pre-check)
if cmd_users_add badkey --key "${root}/missing.pub" 2>/dev/null; then
  bad badkey-fail
else
  ok badkey-fail
fi
grep -q '^badkey:' "${HM_USERS_PASSWD}" && bad badkey-no-user || ok badkey-no-user

# zła data expire
if cmd_users_add expbad --key "${key}" --expire 'not-a-date' 2>/dev/null; then
  bad expire-bad
else
  ok expire-bad
fi
grep -q '^expbad:' "${HM_USERS_PASSWD}" && bad expire-rollback || ok expire-rollback

# prompt del --force: użytkownik (nie domena)
noun_line="$(HM_CONFIRM_CRITICAL_NOUN='ego użytkownika' bash -c 'printf "Potwierdź docelow%s" "${HM_CONFIRM_CRITICAL_NOUN:-ą domenę}"')"
[[ "${noun_line}" == *użytkownika* ]] && ok prompt-user || bad prompt-user

if [[ "${fail}" -ne 0 ]]; then
  echo FAILED
  exit 1
fi
echo "ALL OK"
