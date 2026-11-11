#!/usr/bin/env bash
# config history — lokalne git, bez sekretów, rollback jednego pliku.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1

hm_file_log() { :; }
hm_file_log_ui() { :; }
_hm_cmd_help() { cat >/dev/null; }
_hm_cmd_register() { :; }
hm_help_topic() { :; }

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
src="${root}/src"
repo="${root}/git"
mkdir -p "${src}/etc" "${src}/vhost"
export HM_CONFIG_GIT="${repo}"
export HM_CONFIG_SRC="${src}"
export HM_CONFIG_PATHS="${root}/paths.txt"
export HM_CONFIG_LIMIT_KB=1
printf '%s\n' 'alpha' > "${src}/etc/a.conf"
printf '%s\n' 'beta-b' > "${src}/etc/b.conf"
printf '%s\n' 'SECRET-SHADOW' > "${src}/etc/shadow"
printf '%s\n' 'SECRET-KEY' > "${src}/etc/id_rsa"
printf '%s\n' 'SECRET-RCLONE' > "${src}/etc/rclone.conf"
printf '%s\n' '-----BEGIN PRIVATE KEY-----' > "${src}/etc/custom.pem"
chmod 0640 "${src}/etc/a.conf" || true
cat > "${HM_CONFIG_PATHS}" <<EOF
${src}/etc/a.conf
${src}/etc/b.conf
${src}/etc/shadow
${src}/etc/id_rsa
${src}/etc/rclone.conf
${src}/etc/custom.pem
EOF

# shellcheck disable=SC1091
source commands/confighist/main.sh
# shellcheck disable=SC1091
source lib/common/ui.sh

cmd_config track init >/dev/null
[[ -d "${repo}/.git" ]] && ok init || bad init
git -C "${repo}" remote | grep -q . && bad remote || ok remote
git -C "${repo}" grep -F SECRET-SHADOW >/dev/null 2>&1 && bad shadow || ok shadow
git -C "${repo}" grep -F SECRET-KEY >/dev/null 2>&1 && bad key || ok key
git -C "${repo}" grep -F SECRET-RCLONE >/dev/null 2>&1 && bad rclone || ok rclone
git -C "${repo}" grep -F 'BEGIN PRIVATE KEY' >/dev/null 2>&1 && bad pem || ok pem
[[ -f "${repo}/etc/rclone.conf.meta" ]] && ok meta || bad meta
[[ ! -f "${repo}/etc/shadow" ]] && ok no-shadow-file || bad no-shadow-file
grep -q 'git push' commands/confighist/main.sh && bad no-push || ok no-push

mode0="$(stat -c '%a' "${src}/etc/a.conf" 2>/dev/null || echo unknown)"
printf '%s\n' 'beta-a' > "${src}/etc/a.conf"
printf '%s\n' 'gamma-b' > "${src}/etc/b.conf"
hm_confirm_plan "hook" "" --yes "krok" >/dev/null
printf '%s\n' 'beta-a2' > "${src}/etc/a.conf"
log="$(cmd_config log)"
printf '%s\n' "${log}" | grep -q 'przed: hook' && ok hook-before || bad hook-before
printf '%s\n' "${log}" | grep -q 'po: hook' && ok hook-after || bad hook-after

first="$(git -C "${repo}" rev-list --max-parents=0 HEAD)"
cmd_config rollback "${first}" "${src}/etc/a.conf" >/dev/null
grep -qx 'alpha' "${src}/etc/a.conf" && ok rollback-a || bad rollback-a
grep -qx 'gamma-b' "${src}/etc/b.conf" && ok rollback-keeps-b || bad rollback-keeps-b
mode1="$(stat -c '%a' "${src}/etc/a.conf" 2>/dev/null || echo unknown)"
if [[ "${mode0}" == "640" && "${mode1}" == "640" ]]; then
  ok rollback-mode
else
  printf 'rollback-mode-platform %s->%s\n' "${mode0}" "${mode1}"
fi

gc="$(cmd_config track gc 2>"${root}/gc.err")"
printf '%s\n' "${gc}" | grep -q 'size_kb:' && ok gc || bad gc
grep -q 'limit' "${root}/gc.err" && ok gc-limit || bad gc-limit

[[ "${fail}" -eq 0 ]] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
