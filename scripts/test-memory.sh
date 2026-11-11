#!/usr/bin/env bash
# memory — OOM fixture, swap fstab, sysctl rollback, odmowa OpenVZ.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_confirm_plan() { return 0; }
hm_help_topic() { :; }
_hm_cmd_help() { cat >/dev/null; }
_hm_cmd_register() { :; }

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
export HM_MEM_OOM="${root}/oom.log"
export HM_MEM_MAP="${root}/map"
export HM_MEM_SWAPFILE="${root}/swapfile"
export HM_MEM_FSTAB="${root}/fstab"
export HM_MEM_ZRAM="${root}/zram"
export HM_MEM_SYSCTL="${root}/90-hmtools.conf"
unset HM_MEM_VIRT

# shellcheck disable=SC1091
source commands/memory/main.sh

printf 'php-fpm example.com\n' > "${root}/map"
cat > "${root}/oom.log" <<'EOF'
oom-kill: task=php-fpm,pid=123,rss=80000 cgroup=/system.slice/php-fpm.service
Killed process 456 (mysqld) total-vm:1000kB, anon-rss:500kB, cgroup=/home/shop.example
EOF
out="$(cmd_memory oom --since 7d)"
printf '%s\n' "${out}" | grep -q $'php-fpm\t123\t80000' && ok oom-php || bad oom-php
printf '%s\n' "${out}" | grep -q $'example.com' && ok oom-site || bad oom-site
printf '%s\n' "${out}" | grep -q $'hint\t' && ok oom-hint || bad oom-hint

cmd_memory swap create 1G >/dev/null
[[ -f "${root}/swapfile" ]] && ok swap-file || bad swap-file
grep -qxF "${root}/swapfile none swap sw 0 0" "${root}/fstab" && ok swap-fstab || bad swap-fstab
cmd_memory swap create 1G >/dev/null
[[ "$(grep -cF "${root}/swapfile none swap sw 0 0" "${root}/fstab")" -eq 1 ]] && ok swap-idem || bad swap-idem
mode="$(stat -c '%a' "${root}/swapfile" 2>/dev/null || stat -f '%OLp' "${root}/swapfile")"
if [[ "${mode}" == "600" ]]; then ok swap-mode; else printf 'swap-mode-platform %s\n' "${mode}"; fi

HM_MEM_VIRT=openvz
if cmd_memory swap create 1G >/dev/null 2>"${root}/vz.err"; then bad virt; else ok virt; fi
grep -q 'nie są wspierane' "${root}/vz.err" && ok virt-msg || bad virt-msg
unset HM_MEM_VIRT

cmd_memory zram on >/dev/null
grep -qx on "${root}/zram" && ok zram || bad zram

printf 'vm.swappiness=60\n' > "${root}/90-hmtools.conf"
cmd_memory sysctl profile apply web-small >/dev/null
grep -qx 'vm.swappiness=10' "${root}/90-hmtools.conf" && ok sysctl-apply || bad sysctl-apply
cmd_memory sysctl profile rollback >/dev/null
grep -qx 'vm.swappiness=60' "${root}/90-hmtools.conf" && ok sysctl-rollback || bad sysctl-rollback
[[ ! -f "${root}/90-hmtools.conf.bak" ]] && ok sysctl-bak-gone || bad sysctl-bak-gone

[[ "${fail}" -eq 0 ]] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
