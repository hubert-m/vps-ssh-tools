#!/usr/bin/env bash
# config history — lokalne git, bez sekretów, bezpieczny rollback.
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
mkdir -p "${src}/etc" "${src}/vhost" "${root}/cwd"
export HM_CONFIG_GIT="${repo}"
export HM_CONFIG_SRC="${src}"
export HM_CONFIG_PATHS="${root}/paths.txt"
export HM_CONFIG_LIMIT_KB=1
printf '%s\n' 'alpha' > "${src}/etc/a.conf"
printf '%s\n' 'beta-b' > "${src}/etc/b.conf"
printf '%s\n' 'SECRET-SHADOW' > "${src}/etc/shadow"
printf '%s\n' 'SECRET-GSHADOW' > "${src}/etc/gshadow"
printf '%s\n' 'SECRET-KEY' > "${src}/etc/id_rsa"
printf '%s\n' 'SECRET-RCLONE' > "${src}/etc/rclone.conf"
printf '%s\n' '-----BEGIN PRIVATE KEY-----' > "${src}/etc/custom.pem"
printf '%s\n' 'PASS=SECRET-HM' > "${src}/etc/hmtools.conf"
printf '%s\n' 'SECRET-DEB' > "${src}/etc/debian.cnf"
printf '%s\n' 'cf-token-value' > "${src}/etc/cloudflare.token"
mkdir -p "${src}/etc/cyberpanel" "${src}/etc/postfix" "${src}/etc/powerdns" "${src}/etc/ssl/private"
printf '%s\n' 'mysql-root-secret' > "${src}/etc/cyberpanel/mysqlPassword"
printf '%s\n' 'user = mail\npassword = postfix-secret-XYZ' > "${src}/etc/postfix/mysql-virtual.cf"
printf '%s\n' 'gmysql-password=pdns-secret-ABC' > "${src}/etc/powerdns/pdns.conf"
printf '%s\n' 'host=db' 'password = inline-secret-123' > "${src}/etc/app-with-pass.conf"
printf '%s\n' 'PRIVATE' > "${src}/etc/ssl/private/site.key"
chmod 0640 "${src}/etc/a.conf" || true
cat > "${HM_CONFIG_PATHS}" <<EOF
${src}/etc/a.conf
${src}/etc/b.conf
${src}/etc/shadow
${src}/etc/gshadow
${src}/etc/id_rsa
${src}/etc/rclone.conf
${src}/etc/custom.pem
${src}/etc/hmtools.conf
${src}/etc/debian.cnf
${src}/etc/cloudflare.token
${src}/etc/cyberpanel/mysqlPassword
${src}/etc/postfix/mysql-virtual.cf
${src}/etc/powerdns/pdns.conf
${src}/etc/app-with-pass.conf
${src}/etc/ssl/private/site.key
${src}/etc/gone.conf
EOF
printf '%s\n' 'will-delete' > "${src}/etc/gone.conf"

# shellcheck disable=SC1091
source commands/confighist/main.sh
# shellcheck disable=SC1091
source lib/common/ui.sh

# potwierdzenie NIE dostaje --yes na sztywno
confirm_args=()
hm_confirm_plan() {
  confirm_args=("$@")
  # wywołaj prawdziwy hook before jak ui.sh
  if declare -F hm_config_before >/dev/null 2>&1; then
    hm_config_before "${1:-}" || true
  fi
  return 0
}

cmd_config track init >/dev/null
[[ -d "${repo}/.git" ]] && ok init || bad init
mode_repo="$(stat -c '%a' "${repo}" 2>/dev/null || echo unknown)"
[[ "${mode_repo}" == "700" || "${mode_repo}" == "0700" ]] && ok repo-0700 || printf 'repo-mode-platform %s\n' "${mode_repo}"
git -C "${repo}" remote | grep -q . && bad remote || ok remote
git -C "${repo}" grep -F SECRET-SHADOW >/dev/null 2>&1 && bad shadow || ok shadow
git -C "${repo}" grep -F SECRET-GSHADOW >/dev/null 2>&1 && bad gshadow || ok gshadow
git -C "${repo}" grep -F SECRET-KEY >/dev/null 2>&1 && bad key || ok key
git -C "${repo}" grep -F SECRET-RCLONE >/dev/null 2>&1 && bad rclone || ok rclone
git -C "${repo}" grep -F 'BEGIN PRIVATE KEY' >/dev/null 2>&1 && bad pem || ok pem
git -C "${repo}" grep -F SECRET-HM >/dev/null 2>&1 && bad hmtools-conf || ok hmtools-conf
git -C "${repo}" grep -F SECRET-DEB >/dev/null 2>&1 && bad debian-cnf || ok debian-cnf
git -C "${repo}" grep -F 'cf-token-value' >/dev/null 2>&1 && bad token-file || ok token-file
git -C "${repo}" grep -F 'mysql-root-secret' >/dev/null 2>&1 && bad cyberpanel-pw || ok cyberpanel-pw
git -C "${repo}" grep -F 'postfix-secret-XYZ' >/dev/null 2>&1 && bad postfix-mysql || ok postfix-mysql
git -C "${repo}" grep -F 'pdns-secret-ABC' >/dev/null 2>&1 && bad pdns-conf || ok pdns-conf
git -C "${repo}" grep -F 'inline-secret-123' >/dev/null 2>&1 && bad content-password || ok content-password
git -C "${repo}" grep -F 'PRIVATE' >/dev/null 2>&1 && bad ssl-private || ok ssl-private
[[ -f "${repo}/etc/rclone.conf.meta" ]] && ok meta || bad meta
[[ -f "${repo}/etc/app-with-pass.conf.meta" ]] && ok content-meta || bad content-meta
[[ ! -f "${repo}/etc/app-with-pass.conf" ]] && ok no-content-secret-file || bad no-content-secret-file
[[ ! -f "${repo}/etc/shadow" ]] && ok no-shadow-file || bad no-shadow-file
[[ ! -f "${repo}/etc/hmtools.conf" ]] && ok no-hmtools-file || bad no-hmtools-file
grep -q 'secret-redacted' "${repo}/.gitignore" && ok gitignore-note || bad gitignore-note
grep -q 'git push' commands/confighist/main.sh && bad no-push || ok no-push

# usunięcie pliku ze źródła → znika z repo przy następnym snapshocie
rm -f "${src}/etc/gone.conf"
# usuń z paths albo zostaw — pliku nie ma, each go nie zwróci
hm_config_commit "po: delete-gone" >/dev/null
[[ ! -f "${repo}/etc/gone.conf" ]] && ok deleted-from-repo || bad deleted-from-repo

mode0="$(stat -c '%a' "${src}/etc/a.conf" 2>/dev/null || echo unknown)"
printf '%s\n' 'beta-a' > "${src}/etc/a.conf"
printf '%s\n' 'gamma-b' > "${src}/etc/b.conf"
# symulacja confirm z ui (hook)
hm_confirm_plan "hook" "" "krok" >/dev/null
printf '%s\n' 'beta-a2' > "${src}/etc/a.conf"
log="$(cmd_config log)"
printf '%s\n' "${log}" | grep -q 'przed: hook' && ok hook-before || bad hook-before
printf '%s\n' "${log}" | grep -q 'po: hook' && ok hook-after || bad hook-after

first="$(git -C "${repo}" rev-list --max-parents=0 HEAD)"
confirm_args=()
cmd_config rollback "${first}" "${src}/etc/a.conf" >/dev/null
printf '%s\n' "${confirm_args[*]}" | grep -q -- '--yes' && bad rollback-forced-yes || ok rollback-no-forced-yes
grep -qx 'alpha' "${src}/etc/a.conf" && ok rollback-a || bad rollback-a
grep -qx 'gamma-b' "${src}/etc/b.conf" && ok rollback-keeps-b || bad rollback-keeps-b
mode1="$(stat -c '%a' "${src}/etc/a.conf" 2>/dev/null || echo unknown)"
if [[ "${mode0}" == "640" && "${mode1}" == "640" ]]; then
  ok rollback-mode
else
  printf 'rollback-mode-platform %s->%s\n' "${mode0}" "${mode1}"
fi

# zła rewizja — NIE obcina pliku
printf '%s\n' 'KEEP-ME' > "${src}/etc/a.conf"
if cmd_config rollback 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef' "${src}/etc/a.conf" >/dev/null 2>"${root}/badrev.err"; then
  bad rollback-badrev-rc
else
  ok rollback-badrev-rc
fi
grep -qx 'KEEP-ME' "${src}/etc/a.conf" && ok rollback-badrev-intact || bad rollback-badrev-intact

# zła ścieżka — nie tworzy/zeruje
printf '%s\n' 'SHADOW-LIVE' > "${src}/etc/shadow"
if cmd_config rollback "${first}" "${src}/etc/nope.conf" >/dev/null 2>"${root}/badpath.err"; then
  bad rollback-badpath-rc
else
  ok rollback-badpath-rc
fi
grep -qx 'SHADOW-LIVE' "${src}/etc/shadow" && ok rollback-shadow-intact || bad rollback-shadow-intact

# bez HM_CONFIG_SRC — dest absolutny względem „/” mapowany na fake root przez HM_CONFIG_SRC unset
# używamy osobnego repo z paths w /... — symulacja: dest musi zaczynać się od /
unset HM_CONFIG_SRC
export HM_CONFIG_SRC=""
# funkcja dest_abs
d="$(hm_config_dest_abs 'etc/a.conf')"
[[ "${d}" == "/etc/a.conf" ]] && ok dest-abs || bad dest-abs
export HM_CONFIG_SRC="${src}"

# odmowa rollbacku sekretu
if cmd_config rollback "${first}" "${src}/etc/shadow" >/dev/null 2>"${root}/sec.err"; then
  bad rollback-secret-rc
else
  ok rollback-secret-rc
fi

gc="$(cmd_config track gc 2>"${root}/gc.err")"
printf '%s\n' "${gc}" | grep -q 'size_kb:' && ok gc || bad gc
grep -q 'limit' "${root}/gc.err" && ok gc-limit || bad gc-limit

[[ "${fail}" -eq 0 ]] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
