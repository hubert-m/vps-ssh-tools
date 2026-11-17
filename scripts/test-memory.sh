#!/usr/bin/env bash
# memory — OOM fixture, swap fstab+owned, sysctl orig, odmowa OpenVZ, live OOM err.
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
export HM_MEM_STATE="${root}/state"
export HM_MEM_SYSCTL_LIVE="${root}/live-sysctl"
unset HM_MEM_VIRT
mkdir -p "${HM_MEM_STATE}"
printf 'net.core.somaxconn=4096\n' > "${HM_MEM_SYSCTL_LIVE}"

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

# Hermetycznie: brak fixture + HMTOOLS_TEST=1 (bez żywego journalctl); jawny brak pliku
unset HM_MEM_OOM
export HM_MEM_OOM="/nonexistent-oom-$$"
if cmd_memory oom >/dev/null 2>"${root}/oom.err"; then bad oom-no-src; else ok oom-no-src; fi
grep -q 'Brak journala OOM' "${root}/oom.err" && ok oom-no-src-msg || bad oom-no-src-msg
unset HM_MEM_OOM
[[ "$(hm_mem_since_journal 7d)" == "7 days ago" ]] && ok since-7d || bad since-7d
[[ "$(hm_mem_since_journal 2h)" == "2 hours ago" ]] && ok since-2h || bad since-2h
printf -- '-- No entries --\n' > "${root}/empty-j"
hm_mem_oom_body_usable "${root}/empty-j" && bad usable-noise || ok usable-noise
printf -- '-- No entries --\noom-kill: task=x,pid=1,rss=1\n' > "${root}/ok-j"
hm_mem_oom_body_usable "${root}/ok-j" && ok usable-real || bad usable-real
export HM_MEM_OOM="${root}/oom.log"

cmd_memory swap create 1G >/dev/null
[[ -f "${root}/swapfile" ]] && ok swap-file || bad swap-file
grep -qxF "${root}/swapfile none swap sw 0 0" "${root}/fstab" && ok swap-fstab || bad swap-fstab
[[ -f "${HM_MEM_STATE}/swap.owned" ]] && ok swap-owned || bad swap-owned
cmd_memory swap create 1G >/dev/null
[[ "$(grep -cF "${root}/swapfile none swap sw 0 0" "${root}/fstab")" -eq 1 ]] && ok swap-idem || bad swap-idem
mode="$(stat -c '%a' "${root}/swapfile" 2>/dev/null || stat -f '%OLp' "${root}/swapfile")"
if [[ "${mode}" == "600" ]]; then ok swap-mode; else printf 'swap-mode-platform %s\n' "${mode}"; fi

# Obcy swap — bez markera nie kasujemy
rm -f "${HM_MEM_STATE}/swap.owned"
printf 'provider\n' > "${root}/swap-foreign"
export HM_MEM_SWAPFILE="${root}/swap-foreign"
if cmd_memory swap remove >/dev/null 2>"${root}/rm.err"; then bad swap-foreign; else ok swap-foreign; fi
[[ -f "${root}/swap-foreign" ]] && ok swap-foreign-kept || bad swap-foreign-kept
export HM_MEM_SWAPFILE="${root}/swapfile"
printf '%s\n' "${root}/swapfile" > "${HM_MEM_STATE}/swap.owned"
cmd_memory swap remove --yes >/dev/null
[[ ! -f "${root}/swapfile" ]] && ok swap-rm || bad swap-rm
grep -qF "${root}/swapfile none swap sw 0 0" "${root}/fstab" && bad swap-fstab-rm || ok swap-fstab-rm

HM_MEM_VIRT=openvz
if cmd_memory swap create 1G >/dev/null 2>"${root}/vz.err"; then bad virt; else ok virt; fi
grep -q 'nie są wspierane' "${root}/vz.err" && ok virt-msg || bad virt-msg
unset HM_MEM_VIRT

cmd_memory zram on >/dev/null
grep -qx on "${root}/zram" && ok zram || bad zram

printf 'vm.swappiness=60\n' > "${root}/90-hmtools.conf"
cmd_memory sysctl profile apply web-small >/dev/null
grep -qx 'vm.swappiness=10' "${root}/90-hmtools.conf" && ok sysctl-apply || bad sysctl-apply
# nie obniżaj somaxconn poniżej live 4096
grep -qx 'net.core.somaxconn=4096' "${root}/90-hmtools.conf" && ok sysctl-soma || bad sysctl-soma
[[ -f "${root}/90-hmtools.conf.hmtools-orig" ]] && ok sysctl-orig || bad sysctl-orig
# drugi apply nie niszczy orig
cmd_memory sysctl profile apply web-small >/dev/null
cmd_memory sysctl profile rollback >/dev/null
grep -qx 'vm.swappiness=60' "${root}/90-hmtools.conf" && ok sysctl-rollback || bad sysctl-rollback

[[ "${fail}" -eq 0 ]] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
