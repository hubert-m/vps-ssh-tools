#!/usr/bin/env bash
# memory — OOM, swap/zram i profile sysctl.

_hm_cmd_help memory <<'EOF'
Użycie:
  memory oom [--since 7d]
  memory swap status|create <rozmiar>|remove [--yes]
  memory zram on|off
  memory sysctl profile list|apply <nazwa>|rollback [--yes]

OOM czyta journal/dmesg (HM_MEM_OOM). Swap odmawia na OpenVZ i LXC.
Profil sysctl ląduje w /etc/sysctl.d/90-hmtools.conf, a rollback wraca do kopii.
EOF

hm_mem_virt_block() {
  case "${HM_MEM_VIRT:-}" in
    openvz|lxc|vz)
      hm_err "Swap i zram nie są wspierane na ${HM_MEM_VIRT}."
      return 1
      ;;
  esac
  return 0
}

hm_mem_oom() {
  local since="" file="${HM_MEM_OOM:-}" map="${HM_MEM_MAP:-}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --since) since="${2:-}"; shift 2 || true ;;
      *) shift ;;
    esac
  done
  [[ -n "${file}" && -f "${file}" ]] || { hm_err "Brak journala OOM."; return 1; }
  awk -v map="${map}" '
    function site_of(task, cg,   line, a, s) {
      if (map != "") {
        while ((getline line < map) > 0) {
          split(line, a, " ")
          if (a[1] == task && a[2] != "") { close(map); return a[2] }
        }
        close(map)
      }
      if (match(cg, /\/home\/[A-Za-z0-9.-]+/)) {
        s=substr(cg, RSTART+6, RLENGTH-6)
        return s
      }
      return ""
    }
    /oom-kill/ || /Killed process/ || /Out of memory/ {
      task=""; pid=""; rss=""; cg=""
      if (match($0, /task=[^, ]+/)) task=substr($0, RSTART+5, RLENGTH-5)
      else if (match($0, /Killed process [0-9]+ \([^)]+\)/)) {
        pid=substr($0, RSTART+15, RLENGTH-15)
        sub(/ .*/, "", pid)
        if (match($0, /\([^)]+\)/)) task=substr($0, RSTART+1, RLENGTH-2)
      }
      if (match($0, /pid=[0-9]+/)) pid=substr($0, RSTART+4, RLENGTH-4)
      if (match($0, /rss=[0-9]+/)) rss=substr($0, RSTART+4, RLENGTH-4)
      else if (match($0, /anon-rss:[0-9]+/)) rss=substr($0, RSTART+9, RLENGTH-9)
      if (match($0, /cgroup=[^ ]+/)) cg=substr($0, RSTART+7, RLENGTH-7)
      site=site_of(task, cg)
      printf "%s\t%s\t%s\t%s\t%s\n", task, pid, rss, cg, site
      if (site != "") n[site]++
      else if (task != "") n[task]++
    }
    END {
      top=""; best=0
      for (k in n) if (n[k] > best) { best=n[k]; top=k }
      if (top != "") printf "hint\t%s\tlimits\n", top
    }
  ' "${file}"
  if [[ -n "${since}" ]]; then
    hm_info "Okno: ${since} (bez odcinania dat w fixture)."
  fi
}

hm_mem_swap_file() { printf '%s\n' "${HM_MEM_SWAPFILE:-/swapfile}"; }
hm_mem_fstab() { printf '%s\n' "${HM_MEM_FSTAB:-/etc/fstab}"; }

hm_mem_swap_status() {
  local swap fstab
  swap="$(hm_mem_swap_file)"
  fstab="$(hm_mem_fstab)"
  if [[ -f "${swap}" ]]; then
    printf 'swap: %s\n' "${swap}"
  else
    printf 'swap: brak\n'
  fi
  if [[ -f "${fstab}" ]] && grep -qF "${swap} none swap sw 0 0" "${fstab}"; then
    printf 'fstab: tak\n'
  else
    printf 'fstab: nie\n'
  fi
}

hm_mem_swap_create() {
  local size="${1:-}" swap fstab
  hm_mem_virt_block || return 1
  [[ "${size}" =~ ^[0-9]+[MG]$ ]] || { hm_err "Rozmiar jak 1G albo 512M."; return 1; }
  hm_confirm_plan "Swap ${size}" "Plik i wpis fstab." "" "memory swap create ${size}" || return 1
  swap="$(hm_mem_swap_file)"
  fstab="$(hm_mem_fstab)"
  mkdir -p "$(dirname "${swap}")" "$(dirname "${fstab}")"
  if [[ ! -f "${swap}" ]]; then
    if [[ "${HMTOOLS_TEST:-}" == "1" ]]; then
      printf '%s\n' "${size}" > "${swap}"
    elif command -v fallocate >/dev/null 2>&1; then
      fallocate -l "${size}" "${swap}"
    else
      dd if=/dev/zero of="${swap}" bs=1M count="${size%[MG]}" status=none
    fi
  fi
  chmod 0600 "${swap}" || true
  touch "${fstab}"
  grep -qxF "${swap} none swap sw 0 0" "${fstab}" || printf '%s\n' "${swap} none swap sw 0 0" >> "${fstab}"
  hm_ok "Swap ${swap} (${size})."
}

hm_mem_swap_remove() {
  local swap fstab tmp
  hm_mem_virt_block || return 1
  hm_confirm_plan "Usunięcie swap" "Plik i wpis fstab." "" "memory swap remove" || return 1
  swap="$(hm_mem_swap_file)"
  fstab="$(hm_mem_fstab)"
  if [[ -f "${fstab}" ]]; then
    tmp="$(mktemp)"
    grep -vxF "${swap} none swap sw 0 0" "${fstab}" > "${tmp}" || true
    cat "${tmp}" > "${fstab}"
    rm -f "${tmp}"
  fi
  rm -f "${swap}"
  hm_ok "Swap usunięty."
}

hm_mem_zram() {
  local mode="${1:-}" file="${HM_MEM_ZRAM:-/run/hmtools-zram}"
  hm_mem_virt_block || return 1
  case "${mode}" in
    on|off) ;;
    *) hm_err "Użycie: memory zram on|off"; return 1 ;;
  esac
  mkdir -p "$(dirname "${file}")"
  printf '%s\n' "${mode}" > "${file}"
  printf 'zram: %s\n' "${mode}"
}

hm_mem_sysctl_file() { printf '%s\n' "${HM_MEM_SYSCTL:-/etc/sysctl.d/90-hmtools.conf}"; }

hm_mem_profile_body() {
  case "$1" in
    web-small)
      printf '%s\n' \
        'vm.swappiness=10' \
        'vm.vfs_cache_pressure=50' \
        'net.core.somaxconn=1024' \
        'net.ipv4.tcp_fin_timeout=15'
      ;;
    *)
      return 1
      ;;
  esac
}

hm_mem_sysctl() {
  local sub="${1:-list}" name conf bak
  shift || true
  conf="$(hm_mem_sysctl_file)"
  case "${sub}" in
    list)
      printf '%s\n' web-small
      ;;
    apply)
      name="${1:-}"
      hm_mem_profile_body "${name}" >/dev/null || { hm_err "Nieznany profil ${name}."; return 1; }
      hm_confirm_plan "sysctl ${name}" "Kopia i zapis ${conf}." "" "memory sysctl apply ${name}" || return 1
      mkdir -p "$(dirname "${conf}")"
      bak="${conf}.bak"
      if [[ -f "${conf}" ]]; then
        cp -f "${conf}" "${bak}"
      else
        : > "${bak}"
      fi
      hm_mem_profile_body "${name}" > "${conf}"
      hm_ok "Profil ${name}."
      ;;
    rollback)
      bak="${conf}.bak"
      [[ -f "${bak}" ]] || { hm_err "Brak kopii sysctl."; return 1; }
      hm_confirm_plan "sysctl rollback" "Przywrócenie ${conf}." "" "memory sysctl rollback" || return 1
      cat "${bak}" > "${conf}"
      rm -f "${bak}"
      hm_ok "Przywrócono sysctl."
      ;;
    *)
      hm_err "Użycie: memory sysctl profile list|apply|rollback"
      return 1
      ;;
  esac
}

cmd_memory() {
  local sub="${1:-}"
  shift || true
  case "${sub}" in
    oom) hm_mem_oom "$@" ;;
    swap)
      case "${1:-status}" in
        status|"") hm_mem_swap_status ;;
        create) shift; hm_mem_swap_create "$@" ;;
        remove|rm) hm_mem_swap_remove ;;
        *) hm_err "Użycie: memory swap status|create|remove"; return 1 ;;
      esac
      ;;
    zram) hm_mem_zram "$@" ;;
    sysctl)
      shift || true
      hm_mem_sysctl "$@"
      ;;
    help|-h|--help|"") hm_help_topic memory ;;
    *) hm_err "Nieznane: memory ${sub}"; return 1 ;;
  esac
}

_hm_cmd_register memory cmd_memory 0
