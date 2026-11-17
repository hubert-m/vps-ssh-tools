#!/usr/bin/env bash
# memory — OOM, swap/zram i profile sysctl.

_hm_cmd_help memory <<'EOF'
Użycie:
  memory oom [--since 7d]
  memory swap status|create <rozmiar>|remove [--yes]
  memory zram on|off
  memory sysctl profile list|apply <nazwa>|rollback [--yes]

OOM: fixture HM_MEM_OOM albo journalctl -k / dmesg.
Swap: tylko plik założony przez hmtools (state); mkswap+swapon; odmowa LXC/OpenVZ.
sysctl: /etc/sysctl.d/90-hmtools.conf; pierwszy apply trzyma oryginał; rollback + sysctl -p.
EOF

hm_mem_state_dir() {
  printf '%s\n' "${HM_MEM_STATE:-/var/lib/hmtools/memory}"
}

hm_mem_detect_virt() {
  local v
  if [[ -n "${HM_MEM_VIRT:-}" ]]; then
    printf '%s\n' "${HM_MEM_VIRT}"
    return 0
  fi
  if [[ -f /proc/user_beancounters ]]; then
    printf 'openvz\n'
    return 0
  fi
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    v="$(systemd-detect-virt 2>/dev/null || true)"
    case "${v}" in
      lxc|openvz|container-other|systemd-nspawn)
        printf '%s\n' "${v}"
        return 0
        ;;
    esac
  fi
  if [[ -f /proc/1/environ ]] && tr '\0' '\n' < /proc/1/environ 2>/dev/null | grep -q 'container=lxc'; then
    printf 'lxc\n'
    return 0
  fi
  printf 'none\n'
}

hm_mem_virt_block() {
  local v
  v="$(hm_mem_detect_virt)"
  case "${v}" in
    openvz|lxc|vz|container-other|systemd-nspawn)
      hm_err "Swap i zram nie są wspierane na ${v}."
      return 1
      ;;
  esac
  return 0
}

# 7d / 24h / 30m → fraza dla journalctl --since
hm_mem_since_journal() {
  local since="${1:-7d}"
  if [[ "${since}" =~ ^([0-9]+)([smhd])$ ]]; then
    local n="${BASH_REMATCH[1]}" u="${BASH_REMATCH[2]}" unit=""
    case "${u}" in
      s) unit="seconds" ;;
      m) unit="minutes" ;;
      h) unit="hours" ;;
      d) unit="days" ;;
    esac
    printf '%s %s ago' "${n}" "${unit}"
    return 0
  fi
  printf '%s' "${since}"
}

# Czy treść journala to realne logi (nie „-- No entries --”).
hm_mem_oom_body_usable() {
  local f="$1"
  [[ -f "${f}" ]] || return 1
  grep -vE '^[[:space:]]*$|^-- ' "${f}" | grep -q . 
}

hm_mem_oom_source() {
  local since="${1:-}" tmp jc_since f
  if [[ -n "${HM_MEM_OOM:-}" && -f "${HM_MEM_OOM}" ]]; then
    printf '%s\n' "${HM_MEM_OOM}"
    return 0
  fi
  # W testach bez fixture — nie wołaj prawdziwego journalctl (niestabilne środowisko).
  if [[ "${HMTOOLS_TEST:-}" == "1" ]]; then
    return 1
  fi
  tmp="$(mktemp "${TMP_DIR:-${TMPDIR:-/tmp}}/hm-oom.XXXXXX")"
  : > "${tmp}"
  jc_since="$(hm_mem_since_journal "${since:-7d}")"
  if command -v journalctl >/dev/null 2>&1; then
    # bez -b: też poprzednie boote w oknie --since
    journalctl -k -q --no-pager --since "${jc_since}" 2>/dev/null | grep -vE '^-- ' >> "${tmp}" || true
  fi
  if ! hm_mem_oom_body_usable "${tmp}"; then
    : > "${tmp}"
    for f in /var/log/kern.log /var/log/kern.log.1 /var/log/messages; do
      [[ -f "${f}" ]] || continue
      # proste okno: ostatnie 5000 linii (daty filtruje awk poniżej przy potrzebie)
      tail -n 5000 "${f}" 2>/dev/null >> "${tmp}" || true
    done
  fi
  if ! hm_mem_oom_body_usable "${tmp}" && command -v dmesg >/dev/null 2>&1; then
    : > "${tmp}"
    dmesg 2>/dev/null | grep -vE '^-- ' >> "${tmp}" || true
  fi
  if ! hm_mem_oom_body_usable "${tmp}"; then
    rm -f "${tmp}"
    return 1
  fi
  printf '%s\n' "${tmp}"
}

hm_mem_oom() {
  local since="" file map="${HM_MEM_MAP:-}" tmp=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --since) since="${2:-}"; shift 2 || true ;;
      *) shift ;;
    esac
  done
  file="$(hm_mem_oom_source "${since}")" || { hm_err "Brak journala OOM."; return 1; }
  [[ "${file}" == "${HM_MEM_OOM:-}" ]] || tmp=1
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
    /^-- / { next }
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
  [[ "${tmp}" -eq 1 ]] && rm -f "${file}"
  if [[ -n "${since}" && -n "${HM_MEM_OOM:-}" ]]; then
    hm_info "Okno: ${since} (fixture — bez odcinania dat)."
  elif [[ -n "${since}" ]]; then
    hm_info "Okno journalctl: $(hm_mem_since_journal "${since}")"
  fi
}

hm_mem_swap_file() { printf '%s\n' "${HM_MEM_SWAPFILE:-/swapfile}"; }
hm_mem_fstab() { printf '%s\n' "${HM_MEM_FSTAB:-/etc/fstab}"; }
hm_mem_swap_marker() {
  printf '%s/swap.owned' "$(hm_mem_state_dir)"
}
hm_mem_fstab_line() {
  printf '%s none swap sw 0 0' "$(hm_mem_swap_file)"
}

hm_mem_swap_status() {
  local swap fstab
  swap="$(hm_mem_swap_file)"
  fstab="$(hm_mem_fstab)"
  if [[ -f "${swap}" ]]; then
    printf 'swap: %s\n' "${swap}"
  else
    printf 'swap: brak\n'
  fi
  if [[ -f "${fstab}" ]] && grep -qF "$(hm_mem_fstab_line)" "${fstab}"; then
    printf 'fstab: tak\n'
  else
    printf 'fstab: nie\n'
  fi
  if [[ -f "$(hm_mem_swap_marker)" ]]; then
    printf 'owned: tak\n'
  else
    printf 'owned: nie\n'
  fi
}

hm_mem_swap_create() {
  local size="${1:-}" swap fstab yes=0 a
  shift || true
  for a in "$@"; do
    [[ "${a}" == "--yes" ]] && yes=1
  done
  hm_mem_virt_block || return 1
  [[ "${size}" =~ ^[0-9]+[MG]$ ]] || { hm_err "Rozmiar jak 1G albo 512M."; return 1; }
  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "Swap ${size}" "Plik, mkswap, swapon, fstab." --yes "memory swap create ${size}" || return 1
  else
    hm_confirm_plan "Swap ${size}" "Plik, mkswap, swapon, fstab." "" "memory swap create ${size}" || return 1
  fi
  swap="$(hm_mem_swap_file)"
  fstab="$(hm_mem_fstab)"
  mkdir -p "$(dirname "${swap}")" "$(dirname "${fstab}")" "$(hm_mem_state_dir)"
  if [[ ! -f "${swap}" ]]; then
    if [[ "${HMTOOLS_TEST:-}" == "1" ]]; then
      printf '%s\n' "${size}" > "${swap}"
    elif command -v fallocate >/dev/null 2>&1; then
      fallocate -l "${size}" "${swap}" || return 1
    else
      local mb="${size%[MG]}"
      [[ "${size}" == *G ]] && mb=$((mb * 1024))
      dd if=/dev/zero of="${swap}" bs=1M count="${mb}" status=none || return 1
    fi
  fi
  chmod 0600 "${swap}" || true
  if [[ "${HMTOOLS_TEST:-}" != "1" ]]; then
    command -v mkswap >/dev/null 2>&1 || { hm_err "Brak mkswap."; return 1; }
    mkswap "${swap}" >/dev/null || return 1
    swapon "${swap}" || hm_warn "swapon nieudany — plik i fstab i tak zapisane."
  fi
  touch "${fstab}"
  grep -qxF "$(hm_mem_fstab_line)" "${fstab}" || printf '%s\n' "$(hm_mem_fstab_line)" >> "${fstab}"
  printf '%s\n' "${swap}" > "$(hm_mem_swap_marker)"
  hm_ok "Swap ${swap} (${size})."
}

hm_mem_swap_remove() {
  local swap fstab tmp marker yes=0 a line
  for a in "$@"; do
    [[ "${a}" == "--yes" ]] && yes=1
  done
  hm_mem_virt_block || return 1
  swap="$(hm_mem_swap_file)"
  marker="$(hm_mem_swap_marker)"
  if [[ ! -f "${marker}" ]] || [[ "$(cat "${marker}" 2>/dev/null)" != "${swap}" ]]; then
    hm_err "Brak swapu założonego przez hmtools (${swap}). Nie ruszam obcego pliku."
    return 1
  fi
  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "Usunięcie swap" "swapoff, plik i wpis fstab hmtools." --yes "memory swap remove" || return 1
  else
    hm_confirm_plan "Usunięcie swap" "swapoff, plik i wpis fstab hmtools." "" "memory swap remove" || return 1
  fi
  fstab="$(hm_mem_fstab)"
  if [[ "${HMTOOLS_TEST:-}" != "1" ]] && command -v swapoff >/dev/null 2>&1; then
    swapoff "${swap}" 2>/dev/null || hm_warn "swapoff nieudany — sprawdzam RAM i kontynuuję."
  fi
  line="$(hm_mem_fstab_line)"
  if [[ -f "${fstab}" ]]; then
    tmp="$(mktemp "${TMP_DIR:-${TMPDIR:-/tmp}}/hm-fstab.XXXXXX")"
    grep -vxF "${line}" "${fstab}" > "${tmp}" || true
    cat "${tmp}" > "${fstab}"
    rm -f "${tmp}"
  fi
  rm -f "${swap}" "${marker}"
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
  if [[ "${HMTOOLS_TEST:-}" == "1" ]]; then
    printf '%s\n' "${mode}" > "${file}"
    printf 'zram: %s\n' "${mode}"
    return 0
  fi
  case "${mode}" in
    on)
      modprobe zram 2>/dev/null || { hm_err "Nie załadowano modułu zram."; return 1; }
      if [[ -e /sys/block/zram0/disksize ]]; then
        echo "$((1 * 1024 * 1024 * 1024))" > /sys/block/zram0/disksize 2>/dev/null || true
        mkswap /dev/zram0 >/dev/null 2>&1 || true
        swapon /dev/zram0 2>/dev/null || hm_warn "swapon /dev/zram0 nieudany."
      fi
      ;;
    off)
      swapoff /dev/zram0 2>/dev/null || true
      modprobe -r zram 2>/dev/null || true
      ;;
  esac
  printf '%s\n' "${mode}" > "${file}"
  printf 'zram: %s\n' "${mode}"
}

hm_mem_sysctl_file() { printf '%s\n' "${HM_MEM_SYSCTL:-/etc/sysctl.d/90-hmtools.conf}"; }

hm_mem_sysctl_live() {
  local key="$1"
  if [[ -n "${HM_MEM_SYSCTL_LIVE:-}" && -f "${HM_MEM_SYSCTL_LIVE}" ]]; then
    awk -F= -v k="${key}" '$1==k { print $2; exit }' "${HM_MEM_SYSCTL_LIVE}"
    return 0
  fi
  if command -v sysctl >/dev/null 2>&1; then
    sysctl -n "${key}" 2>/dev/null || true
  fi
}

hm_mem_profile_body() {
  local name="$1" sw=10 vfs=50 soma=1024 fin=15 cur
  case "${name}" in
    web-small)
      cur="$(hm_mem_sysctl_live net.core.somaxconn)"
      if [[ "${cur}" =~ ^[0-9]+$ ]] && [[ "${cur}" -gt "${soma}" ]]; then
        soma="${cur}"
      fi
      printf '%s\n' \
        "vm.swappiness=${sw}" \
        "vm.vfs_cache_pressure=${vfs}" \
        "net.core.somaxconn=${soma}" \
        "net.ipv4.tcp_fin_timeout=${fin}"
      ;;
    *)
      return 1
      ;;
  esac
}

hm_mem_sysctl_apply_live() {
  local conf="$1" line key val
  [[ -f "${conf}" ]] || return 0
  if [[ "${HMTOOLS_TEST:-}" == "1" ]]; then
    return 0
  fi
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" == \#* || -z "${line}" ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    sysctl -w "${key}=${val}" >/dev/null 2>&1 || true
  done < "${conf}"
  sysctl --system >/dev/null 2>&1 || true
}

hm_mem_sysctl() {
  local sub="${1:-list}" name conf orig bak
  shift || true
  # memory sysctl profile …
  if [[ "${sub}" == "profile" ]]; then
    sub="${1:-list}"
    shift || true
  fi
  conf="$(hm_mem_sysctl_file)"
  orig="${conf}.hmtools-orig"
  bak="${conf}.bak"
  case "${sub}" in
    list)
      printf '%s\n' web-small
      ;;
    apply)
      name="${1:-}"
      hm_mem_profile_body "${name}" >/dev/null || { hm_err "Nieznany profil ${name}."; return 1; }
      hm_confirm_plan "sysctl ${name}" "Kopia oryginału (raz) i zapis ${conf}." "" "memory sysctl profile apply ${name}" || return 1
      mkdir -p "$(dirname "${conf}")"
      if [[ ! -f "${orig}" ]]; then
        if [[ -f "${conf}" ]]; then
          cp -f "${conf}" "${orig}"
        else
          : > "${orig}"
        fi
      fi
      # .bak = poprzedni stan (jedno cofnięcie), nie nadpisuje orig
      if [[ -f "${conf}" ]]; then
        cp -f "${conf}" "${bak}"
      else
        : > "${bak}"
      fi
      hm_mem_profile_body "${name}" > "${conf}"
      hm_mem_sysctl_apply_live "${conf}"
      hm_ok "Profil ${name}."
      ;;
    rollback)
      [[ -f "${orig}" || -f "${bak}" ]] || { hm_err "Brak kopii sysctl."; return 1; }
      hm_confirm_plan "sysctl rollback" "Przywrócenie ${conf}." "" "memory sysctl profile rollback" || return 1
      if [[ -f "${orig}" ]]; then
        cat "${orig}" > "${conf}"
      else
        cat "${bak}" > "${conf}"
      fi
      rm -f "${bak}"
      hm_mem_sysctl_apply_live "${conf}"
      hm_ok "Przywrócono sysctl."
      ;;
    *)
      hm_err "Użycie: memory sysctl profile list|apply <nazwa>|rollback"
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
        remove|rm) shift; hm_mem_swap_remove "$@" ;;
        *) hm_err "Użycie: memory swap status|create|remove"; return 1 ;;
      esac
      ;;
    zram) hm_mem_zram "$@" ;;
    sysctl) hm_mem_sysctl "$@" ;;
    help|-h|--help|"") hm_help_topic memory ;;
    *) hm_err "Nieznane: memory ${sub}"; return 1 ;;
  esac
}

_hm_cmd_register memory cmd_memory 0
