#!/usr/bin/env bash
# Moduł: limits — quota dysku/inodów, CPU/RAM/IO (systemd user slice), raport zużycia


_hm_cmd_help limits <<'EOF'
Użycie:
  limits | status              Tabela per strona (dysk cache, limity cgroup/quota)
  limits check                 cgroup v2, quota /home, OLS cgroups
  limits set --cpu 100% --mem 1G [--io 20M] [--tasks 200]
  limits set --disk 10G [--inodes 300000]
  limits clear                 Usuń limity cgroup (+ opcjonalnie quota)
  limits show                  Szczegóły bieżącej strony

CPU/RAM/IO → systemctl set-property user-<uid>.slice (+ drop-in 50-hmtools.conf).
Na OpenLiteSpeed (lsphp w system.slice): dodatkowo memSoft/HardLimit + procSoft/Hard
w extprocessor vhconf (bo user.slice nie obejmuje lsphp bez LSE cgroups).
Dysk → setquota gdy usrquota na /home; inaczej tylko raport.
EOF

hm_limits_cgroup_v2() {
  [[ -f /sys/fs/cgroup/cgroup.controllers ]] || [[ -d /sys/fs/cgroup/user.slice ]]
}

hm_limits_ols_cgroups_enabled() {
  local conf="${OLS_CONF:-/usr/local/lsws/conf/httpd_config.conf}"
  [[ -f "${conf}" ]] || return 1
  grep -qiE '^[[:space:]]*cgroups[[:space:]]+1([[:space:]]|$)' "${conf}" 2>/dev/null \
    || grep -qiE 'CGIRLimit' "${conf}" 2>/dev/null
}

# Czy żywy lsphp usera jest w user-<uid>.slice (LSE / OLS cgroups)?
# 0 = tak; 1 = nie / brak procesu / nieznane
hm_limits_lsphp_in_user_slice() {
  local user="$1" uid pid cg
  uid="$(hm_limits_uid_for_user "${user}")" || return 1
  pid="$(pgrep -u "${user}" -x lsphp 2>/dev/null | head -1 || true)"
  [[ -n "${pid}" ]] || pid="$(pgrep -u "${user}" lsphp 2>/dev/null | head -1 || true)"
  [[ -n "${pid}" && -r "/proc/${pid}/cgroup" ]] || return 1
  cg="$(tr '\n' ' ' < "/proc/${pid}/cgroup" 2>/dev/null || true)"
  [[ "${cg}" == *"user-${uid}.slice"* ]]
}

hm_limits_bytes_to_ols_m() {
  local b="${1:-0}" m
  [[ "${b}" =~ ^[0-9]+$ ]] || return 1
  m=$(( (b + 1048576 - 1) / 1048576 ))
  [[ "${m}" -lt 1 ]] && m=1
  printf '%sM' "${m}"
}

# Ustaw memSoft/Hard + procSoft/Hard w extprocessor vhconf (OLS limituje lsphp).
# mem_b puste = nie ruszaj mem*; tasks puste = nie ruszaj proc*; clear=1 → domyślne 2047M/400/500
hm_limits_apply_ols_ext_limits() {
  local domain="$1" user="$2" mem_b="${3:-}" tasks="${4:-}" clear="${5:-0}"
  local conf tmp mem_s="" soft_p="" hard_p=""
  conf="$(hm_vhost_conf_path "${domain}" 2>/dev/null || true)"
  [[ -n "${conf}" && -f "${conf}" ]] || {
    hm_warn "Brak vhconf dla ${domain} — pomijam limity extprocessor OLS."
    return 1
  }
  if [[ "${clear}" == "1" ]]; then
    mem_s="2047M"
    soft_p="400"
    hard_p="500"
  else
    [[ -n "${mem_b}" ]] && mem_s="$(hm_limits_bytes_to_ols_m "${mem_b}")"
    if [[ -n "${tasks}" ]]; then
      soft_p="${tasks}"
      hard_p="$((tasks + tasks / 4))"
      [[ "${hard_p}" -le "${tasks}" ]] && hard_p=$((tasks + 1))
    fi
  fi
  [[ -n "${mem_s}" || -n "${soft_p}" ]] || return 0

  tmp="$(hm_mktemp .vhconf-limits)"
  awk -v user="${user}" -v mem="${mem_s}" -v ps="${soft_p}" -v ph="${hard_p}" '
    BEGIN { inext=0; matched=0 }
    tolower($1)=="extprocessor" {
      name=$2; gsub(/[{}]/,"",name)
      inext = (name==user || name=="lsphp" || name ~ /^lsphp/)
      if (inext) matched=1
      print; next
    }
    inext && /^[[:space:]]*}/ { inext=0; print; next }
    inext && mem!="" && $1=="memSoftLimit" {
      printf "  memSoftLimit            %s\n", mem; next
    }
    inext && mem!="" && $1=="memHardLimit" {
      printf "  memHardLimit            %s\n", mem; next
    }
    inext && ps!="" && $1=="procSoftLimit" {
      printf "  procSoftLimit           %s\n", ps; next
    }
    inext && ph!="" && $1=="procHardLimit" {
      printf "  procHardLimit           %s\n", ph; next
    }
    { print }
    END { if (matched==0) exit 2 }
  ' "${conf}" > "${tmp}" || {
    local rc=$?
    rm -f "${tmp}"
    if [[ "${rc}" -eq 2 ]]; then
      hm_warn "Brak extprocessor ${user}/lsphp w vhconf — pomijam limity OLS."
      return 1
    fi
    return 1
  }
  cp -a "${conf}" "${conf}.hmtools.limits.bak" 2>/dev/null || true
  if ! cat "${tmp}" > "${conf}"; then
    hm_err "Zapis vhconf (limits) nieudany."
    rm -f "${tmp}"
    return 1
  fi
  rm -f "${tmp}"
  # oznacznik dla clear / audytu (tylko przy ustawianiu, nie przy clear)
  if [[ "${clear}" != "1" ]]; then
    if ! grep -q '# hmtools:limits-ols' "${conf}" 2>/dev/null; then
      printf '\n# hmtools:limits-ols applied\n' >> "${conf}"
    fi
  else
    local tmpc
    tmpc="$(hm_mktemp .vhconf-strip)"
    grep -v '# hmtools:limits-ols' "${conf}" > "${tmpc}" 2>/dev/null && cat "${tmpc}" > "${conf}"
    rm -f "${tmpc}"
  fi
  if declare -F hm_ols_reload >/dev/null 2>&1; then
    hm_ols_reload 2>/dev/null || hm_warn "ols reload nieudany — limity vhconf zapisane, wymagany ręczny reload."
  elif hm_have_cmd systemctl; then
    systemctl reload lsws 2>/dev/null || systemctl reload lshttpd 2>/dev/null || true
  fi
  hm_ok "OLS extprocessor: mem=${mem_s:-(bez zmian)} procSoft=${soft_p:-(bez zmian)} (${domain})"
  return 0
}

hm_limits_quota_available() {
  # /home z usrquota lub quotaon -p sukces
  if findmnt -n -o OPTIONS /home 2>/dev/null | grep -qE '(^|,)usrquota(,|$)'; then
    return 0
  fi
  if findmnt -n -o OPTIONS / 2>/dev/null | grep -qE '(^|,)usrquota(,|$)'; then
    # /home na tym samym FS
    local home_src root_src
    home_src="$(findmnt -n -o SOURCE /home 2>/dev/null || true)"
    root_src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
    [[ -n "${home_src}" && "${home_src}" == "${root_src}" ]] && return 0
  fi
  if hm_have_cmd quotaon; then
    quotaon -p /home >/dev/null 2>&1 && return 0
  fi
  return 1
}

hm_limits_uid_for_user() {
  local user="$1"
  id -u "${user}" 2>/dev/null
}

hm_limits_slice_name() {
  local uid="$1"
  printf 'user-%s.slice' "${uid}"
}

hm_limits_slice_dropin_dir() {
  local uid="$1"
  printf '/etc/systemd/system/user-%s.slice.d' "${uid}"
}

hm_limits_slice_dropin_file() {
  local uid="$1"
  printf '%s/50-hmtools.conf' "$(hm_limits_slice_dropin_dir "${uid}")"
}

hm_limits_parse_cpu_quota() {
  # 100% → 100% ; 50 → 50%
  local raw="${1:-}"
  raw="$(printf '%s' "${raw}" | tr -d '[:space:]')"
  [[ -n "${raw}" ]] || return 1
  if [[ "${raw}" =~ ^([0-9]+)%?$ ]]; then
    printf '%s%%' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

hm_limits_cgroup_memory_current() {
  local uid="$1" p
  p="/sys/fs/cgroup/user.slice/user-${uid}.slice/memory.current"
  [[ -f "${p}" ]] || p="/sys/fs/cgroup/user.slice/user-${uid}.slice/memory.usage_in_bytes"
  [[ -f "${p}" ]] || { printf '-'; return 1; }
  cat "${p}" 2>/dev/null || printf '-'
}

hm_limits_cgroup_cpu_usage() {
  # cpu.stat usage_usec — surowa wartość
  local uid="$1" p
  p="/sys/fs/cgroup/user.slice/user-${uid}.slice/cpu.stat"
  [[ -f "${p}" ]] || { printf '-'; return 1; }
  awk '/^usage_usec/{print $2; exit}' "${p}" 2>/dev/null || printf '-'
}

hm_limits_read_dropin_props() {
  local f="$1"
  [[ -f "${f}" ]] || return 1
  # wypisz CPUQuota= MemoryMax= … (jedna linia skrócona)
  awk -F= '
    /^CPUQuota=/{cpu=$2}
    /^MemoryMax=/{mem=$2}
    /^IOWriteBandwidthMax=/{io=$2}
    /^TasksMax=/{tasks=$2}
    END {
      out=""
      if (cpu!="") out=out "cpu=" cpu " "
      if (mem!="") out=out "mem=" mem " "
      if (io!="") out=out "io=" io " "
      if (tasks!="") out=out "tasks=" tasks " "
      if (out=="") exit 1
      print out
    }
  ' "${f}"
}

hm_limits_quota_show() {
  local user="$1"
  if ! hm_have_cmd quota; then
    printf '-'
    return 1
  fi
  # quota -u user — bloki soft/hard
  quota -u "${user}" 2>/dev/null | awk '
    /blocks/ { next }
    NF>=3 && $2 ~ /^[0-9]+$/ {
      # filesystem line: blocks soft hard …
      printf "used=%sb soft=%s hard=%s", $2*1024, ($3>0?$3*1024:"-"), ($4>0?$4*1024:"-")
      exit
    }
  ' || printf '-'
}

hm_limits_check() {
  echo "${C_BOLD}limits check${C_RESET}"
  if hm_limits_cgroup_v2; then
    hm_ok "cgroup v2 / user.slice: dostępne"
  else
    hm_warn "Brak cgroup v2 (user.slice) — limity CPU/RAM/IO niedostępne."
  fi
  if hm_have_cmd systemctl; then
    hm_ok "systemctl: $(command -v systemctl)"
  else
    hm_warn "Brak systemctl — set-property niedostępne."
  fi
  if hm_limits_quota_available; then
    hm_ok "quota usrquota: wykryte (setquota możliwe)"
  else
    hm_warn "Brak usrquota na /home — limity dysku tylko jako raport. Włącz: mount -o usrquota /home + quotacheck/quotaon."
  fi
  if hm_have_cmd setquota; then
    echo "  setquota: tak"
  else
    echo "  setquota: brak w PATH"
  fi
  if hm_limits_ols_cgroups_enabled; then
    hm_ok "OLS cgroups: włączone w httpd_config (lsphp w cgroup usera)"
  else
    hm_warn "OLS cgroups: nie wykryto (cgroups 1 / CGIRLimit). user.slice NIE obejmuje lsphp OpenLiteSpeed — `limits set --mem/--tasks` ustawi też limity w extprocessor vhconf."
  fi
  if [[ -n "${HM_SITE_USER:-}" ]]; then
    if hm_limits_lsphp_in_user_slice "${HM_SITE_USER}"; then
      hm_ok "lsphp ${HM_SITE_USER}: w user-$(hm_limits_uid_for_user "${HM_SITE_USER}").slice"
    else
      hm_warn "lsphp ${HM_SITE_USER}: poza user.slice (lub brak procesu) — limity CPU/IO na slice nie ograniczą lsphp; używane limity OLS extprocessor dla --mem/--tasks."
    fi
  fi
}

hm_limits_require_site_user() {
  [[ -n "${HM_SITE_DOMAIN:-}" ]] || {
    hm_err "Wejdź w kontekst: use <domena>"
    return 1
  }
  local user="${HM_SITE_USER:-}"
  [[ -n "${user}" ]] || {
    hm_err "Brak HM_SITE_USER dla ${HM_SITE_DOMAIN}"
    return 1
  }
  if [[ "${user}" == "root" ]]; then
    hm_err "Odmowa: nie nakładam limitów na root."
    return 1
  fi
  local uid
  uid="$(hm_limits_uid_for_user "${user}")" || {
    hm_err "UID nieznany dla ${user}"
    return 1
  }
  if [[ "${uid}" -lt 1000 ]]; then
    hm_err "UID ${uid} wygląda na systemowy — odmowa."
    return 1
  fi
  printf '%s' "${user}"
}

hm_limits_write_dropin() {
  local uid="$1"
  shift
  # remaining: lines "CPUQuota=50%" …
  local dir f tmp
  dir="$(hm_limits_slice_dropin_dir "${uid}")"
  f="$(hm_limits_slice_dropin_file "${uid}")"
  mkdir -p "${dir}" || return 1
  tmp="$(hm_mktemp .slice)"
  {
    echo "# hmtools limits — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "[Slice]"
    local line
    for line in "$@"; do
      [[ -n "${line}" ]] && printf '%s\n' "${line}"
    done
  } > "${tmp}"
  if [[ -f "${f}" ]]; then
    cp -a "${f}" "${f}.hmtools.bak" 2>/dev/null || true
  fi
  cat "${tmp}" > "${f}"
  rm -f "${tmp}"
  chmod 644 "${f}" 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
}

hm_limits_apply_slice_props() {
  local uid="$1"
  shift
  local slice
  slice="$(hm_limits_slice_name "${uid}")"
  # systemctl set-property (runtime+persist via drop-in we write)
  local -a props=("$@")
  local -a setp=()
  local p
  for p in "${props[@]}"; do
    [[ -n "${p}" ]] && setp+=("${p}")
  done
  [[ "${#setp[@]}" -gt 0 ]] || return 0
  if hm_have_cmd systemctl; then
    # shellcheck disable=SC2086
    systemctl set-property "${slice}" "${setp[@]}" 2>/dev/null \
      || systemctl set-property --runtime "${slice}" "${setp[@]}" 2>/dev/null \
      || hm_warn "systemctl set-property częściowo nieudany — drop-in zapisany."
  fi
}

hm_limits_set() {
  local user uid
  user="$(hm_limits_require_site_user)" || return 1
  uid="$(hm_limits_uid_for_user "${user}")" || return 1

  if ! hm_limits_cgroup_v2 && [[ -n "${1:-}" ]]; then
    # pozwól na --disk nawet bez cgroup
    :
  fi

  local cpu="" mem="" io="" tasks="" disk="" inodes="" auto_yes=0
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --cpu) cpu="${2:-}"; shift 2 || true ;;
      --cpu=*) cpu="${1#*=}"; shift ;;
      --mem|--memory|--ram) mem="${2:-}"; shift 2 || true ;;
      --mem=*|--memory=*|--ram=*) mem="${1#*=}"; shift ;;
      --io) io="${2:-}"; shift 2 || true ;;
      --io=*) io="${1#*=}"; shift ;;
      --tasks) tasks="${2:-}"; shift 2 || true ;;
      --tasks=*) tasks="${1#*=}"; shift ;;
      --disk) disk="${2:-}"; shift 2 || true ;;
      --disk=*) disk="${1#*=}"; shift ;;
      --inodes) inodes="${2:-}"; shift 2 || true ;;
      --inodes=*) inodes="${1#*=}"; shift ;;
      --yes|-y) auto_yes=1; shift ;;
      help|-h|--help)
        echo "Użycie: limits set --cpu 100% --mem 1G [--io 20M] [--tasks 200] [--disk 10G] [--inodes N]"
        return 0
        ;;
      *)
        hm_err "Nieznany argument: ${1}"; return 1 ;;
    esac
  done

  if [[ -z "${cpu}${mem}${io}${tasks}${disk}${inodes}" ]]; then
    hm_err "Podaj co najmniej jedną opcję (--cpu/--mem/--io/--tasks/--disk/--inodes)."
    return 1
  fi

  local -a drop_lines=() set_props=() steps=()
  local cpuq mem_b io_b

  if [[ -n "${cpu}" ]]; then
    cpuq="$(hm_limits_parse_cpu_quota "${cpu}")" || { hm_err "Złe --cpu: ${cpu}"; return 1; }
    drop_lines+=("CPUQuota=${cpuq}")
    set_props+=("CPUQuota=${cpuq}")
    steps+=("CPUQuota=${cpuq} na user-${uid}.slice (${user})")
  fi
  if [[ -n "${mem}" ]]; then
    mem_b="$(hm_parse_size_bytes "${mem}")" || { hm_err "Złe --mem: ${mem}"; return 1; }
    drop_lines+=("MemoryMax=${mem_b}")
    set_props+=("MemoryMax=${mem_b}")
    steps+=("MemoryMax=$(hm_human_size "${mem_b}") na user-${uid}.slice")
  fi
  if [[ -n "${io}" ]]; then
    io_b="$(hm_parse_size_bytes "${io}")" || { hm_err "Złe --io: ${io}"; return 1; }
    # IOWriteBandwidthMax=/dev/disk 20M — użyj wspólnego device (cały dysk trudny)
    # systemd: IOWriteBandwidthMax=<device> <bytes>
    local rootdev
    rootdev="$(findmnt -n -o SOURCE / 2>/dev/null | sed 's/[0-9]*$//' || true)"
    [[ -n "${rootdev}" ]] || rootdev="/dev/sda"
    drop_lines+=("IOWriteBandwidthMax=${rootdev} ${io_b}")
    set_props+=("IOWriteBandwidthMax=${rootdev} ${io_b}")
    steps+=("IOWriteBandwidthMax=${rootdev} $(hm_human_size "${io_b}")/s")
  fi
  if [[ -n "${tasks}" ]]; then
    [[ "${tasks}" =~ ^[0-9]+$ ]] || { hm_err "Złe --tasks"; return 1; }
    drop_lines+=("TasksMax=${tasks}")
    set_props+=("TasksMax=${tasks}")
    steps+=("TasksMax=${tasks}")
  fi

  local disk_b="" inode_n=""
  if [[ -n "${disk}" ]]; then
    disk_b="$(hm_parse_size_bytes "${disk}")" || { hm_err "Złe --disk"; return 1; }
    steps+=("setquota blocks hard=$(hm_human_size "${disk_b}") user=${user}")
  fi
  if [[ -n "${inodes}" ]]; then
    [[ "${inodes}" =~ ^[0-9]+$ ]] || { hm_err "Złe --inodes"; return 1; }
    inode_n="${inodes}"
    steps+=("setquota inodes hard=${inode_n} user=${user}")
  fi

  if [[ "${#drop_lines[@]}" -gt 0 ]] && ! hm_limits_cgroup_v2; then
    hm_err "Brak cgroup v2 — nie mogę ustawić CPU/RAM/IO. Zobacz: limits check"
    return 1
  fi

  local lsphp_in_slice=0
  if hm_limits_lsphp_in_user_slice "${user}"; then
    lsphp_in_slice=1
  fi
  local need_ols=0
  if [[ -n "${mem}${tasks}" ]] && [[ "${lsphp_in_slice}" -eq 0 ]]; then
    need_ols=1
    steps+=("OLS extprocessor vhconf: memSoft/HardLimit / procSoft/Hard (lsphp poza user.slice)")
  fi
  if [[ -n "${cpu}${io}" ]] && [[ "${lsphp_in_slice}" -eq 0 ]]; then
    steps+=("UWAGA: --cpu/--io na user.slice NIE ograniczy lsphp OpenLiteSpeed (zostaje dla sesji SSH/cron)" )
  fi

  steps+=("Drop-in: $(hm_limits_slice_dropin_file "${uid}")")
  steps+=("Bez wpływu na root/system i innych userów stron")

  local plan_warn="Slice dotyczy procesów w user-${uid}.slice (SSH/cron; lsphp tylko przy LSE/OLS cgroups)."
  if [[ "${need_ols}" -eq 1 ]]; then
    plan_warn="lsphp poza user.slice — --mem/--tasks także w extprocessor vhconf OLS."
  fi

  if [[ "${auto_yes}" -eq 1 ]]; then
    hm_confirm_plan "limits set — ${HM_SITE_DOMAIN}" "${plan_warn}" --yes "${steps[@]}" || return 1
  else
    hm_confirm_plan "limits set — ${HM_SITE_DOMAIN} (user=${user} uid=${uid})" \
      "${plan_warn}" \
      "${steps[@]}" || return 0
  fi

  if [[ "${#drop_lines[@]}" -gt 0 ]]; then
    hm_limits_write_dropin "${uid}" "${drop_lines[@]}" || return 1
    hm_limits_apply_slice_props "${uid}" "${set_props[@]}"
    if [[ "${lsphp_in_slice}" -eq 1 ]]; then
      hm_ok "Cgroup: zapisano limity dla user-${uid}.slice (lsphp w slice — OK)"
    else
      hm_ok "Cgroup: zapisano limity dla user-${uid}.slice (sesje SSH/cron; lsphp OLS → osobno)"
      if [[ -n "${cpu}${io}" ]]; then
        hm_warn "--cpu/--io nie ograniczą lsphp OpenLiteSpeed (proces w system.slice/lsws)."
      fi
    fi
  fi

  if [[ "${need_ols}" -eq 1 ]]; then
    hm_limits_apply_ols_ext_limits "${HM_SITE_DOMAIN}" "${user}" "${mem_b:-}" "${tasks:-}" 0 \
      || hm_warn "Nie udało się ustawić limitów OLS extprocessor."
  fi

  if [[ -n "${disk_b}" || -n "${inode_n}" ]]; then
    if ! hm_limits_quota_available || ! hm_have_cmd setquota; then
      hm_warn "Quota niedostępna — pomijam --disk/--inodes. limits check"
    else
      # bloki w 1K units dla setquota
      local soft_b hard_b soft_i hard_i
      hard_b=$((disk_b / 1024))
      soft_b="${hard_b}"
      [[ -n "${disk_b}" ]] || { soft_b=0; hard_b=0; }
      if [[ -n "${inode_n}" ]]; then
        soft_i="${inode_n}"; hard_i="${inode_n}"
      else
        soft_i=0; hard_i=0
      fi
      local fs
      fs="$(findmnt -n -o TARGET /home 2>/dev/null || echo /home)"
      if setquota -u "${user}" "${soft_b}" "${hard_b}" "${soft_i}" "${hard_i}" "${fs}" 2>/dev/null; then
        hm_ok "Quota: user=${user} blocks_hard=${hard_b}K inodes_hard=${hard_i}"
      else
        hm_err "setquota nieudany"
        return 1
      fi
    fi
  fi
  hm_limits_show_one "${HM_SITE_DOMAIN}"
}

hm_limits_clear() {
  local user uid
  user="$(hm_limits_require_site_user)" || return 1
  uid="$(hm_limits_uid_for_user "${user}")" || return 1
  local f
  f="$(hm_limits_slice_dropin_file "${uid}")"
  local -a clear_steps=(
    "Usunięcie ${f}"
    "systemctl set-property …=infinity / reset"
    "Opcjonalnie: setquota 0 0 0 0 (jeśli quota dostępna)"
  )
  local vh
  vh="$(hm_vhost_conf_path "${HM_SITE_DOMAIN}" 2>/dev/null || true)"
  if [[ -n "${vh}" && -f "${vh}" ]] && grep -q '# hmtools:limits-ols' "${vh}" 2>/dev/null; then
    clear_steps+=("OLS extprocessor: przywróć mem 2047M / proc 400–500 (marker hmtools:limits-ols)")
  fi
  if ! hm_confirm_plan "limits clear — ${HM_SITE_DOMAIN}" \
    "" \
    "${clear_steps[@]}"; then
    return 0
  fi
  if [[ -f "${f}" ]]; then
    cp -a "${f}" "${f}.hmtools.bak" 2>/dev/null || true
    rm -f "${f}"
    systemctl daemon-reload 2>/dev/null || true
  fi
  local slice
  slice="$(hm_limits_slice_name "${uid}")"
  if hm_have_cmd systemctl; then
    systemctl set-property "${slice}" CPUQuota= MemoryMax=infinity TasksMax=infinity 2>/dev/null || true
  fi
  if hm_limits_quota_available && hm_have_cmd setquota; then
    local fs
    fs="$(findmnt -n -o TARGET /home 2>/dev/null || echo /home)"
    setquota -u "${user}" 0 0 0 0 "${fs}" 2>/dev/null || true
  fi
  if [[ -n "${vh}" && -f "${vh}" ]] && grep -q '# hmtools:limits-ols' "${vh}" 2>/dev/null; then
    hm_limits_apply_ols_ext_limits "${HM_SITE_DOMAIN}" "${user}" "" "" 1 || true
  fi
  hm_ok "Wyczyszczono limity dla ${user} (uid=${uid})."
}

hm_limits_show_one() {
  local domain="${1:-${HM_SITE_DOMAIN:-}}"
  [[ -n "${domain}" ]] || return 1
  local row root doc user status uid
  row="$(hm_resolve_site_paths "${domain}" 2>/dev/null || true)"
  [[ -n "${row}" ]] || { hm_err "Nieznana strona: ${domain}"; return 1; }
  # TSV fields — użyj hm_tsv_field jeśli jest
  if declare -F hm_tsv_field >/dev/null 2>&1; then
    root="$(hm_tsv_field "${row}" 2)"
    doc="$(hm_tsv_field "${row}" 3)"
    user="$(hm_tsv_field "${row}" 7)"
  else
    IFS=$'\t' read -r _ root doc _ _ _ user _ <<<"${row}"
  fi
  [[ "${user}" == "-" ]] && user=""
  echo "${C_BOLD}limits — ${domain}${C_RESET}"
  echo "  user: ${user:--}   root: ${root:--}"
  local path="${root:-${doc}}"
  local sz="-"
  if [[ -n "${path}" && -d "${path}" ]]; then
    sz="$(hm_dir_size_bytes_cached "${path}" 300)"
    sz="$(hm_human_size "${sz}")"
  fi
  echo "  disk used: ${sz} (cache ≤5 min)"

  if [[ -n "${user}" ]]; then
    uid="$(hm_limits_uid_for_user "${user}" || true)"
    if [[ -n "${uid}" ]]; then
      local memc cpust drop props
      memc="$(hm_limits_cgroup_memory_current "${uid}")"
      [[ "${memc}" =~ ^[0-9]+$ ]] && memc="$(hm_human_size "${memc}")"
      cpust="$(hm_limits_cgroup_cpu_usage "${uid}")"
      echo "  cgroup mem.current: ${memc}  cpu.usage_usec: ${cpust}"
      drop="$(hm_limits_slice_dropin_file "${uid}")"
      if props="$(hm_limits_read_dropin_props "${drop}" 2>/dev/null)"; then
        echo "  limits: ${props}"
      else
        echo "  limits: (brak drop-in hmtools)"
      fi
      echo "  quota: $(hm_limits_quota_show "${user}")"
    fi
  fi
}

hm_limits_table() {
  hm_discover_sites 2>/dev/null || true
  echo "${C_BOLD}limits — strony${C_RESET}  ${C_DIM}(dysk z cache; limity z drop-in)${C_RESET}"
  hm_table_begin
  hm_table_row DOMAIN USER DISK LIMITS
  local d row user root doc uid path sz props drop
  local n=0
  for d in "${HM_SITES_LIST[@]:-}"; do
    [[ -n "${d}" ]] || continue
    n=$((n + 1))
    # twardy limit czasu — max ~40 stron z cache
    if [[ "${n}" -gt 80 ]]; then
      hm_warn "Pominięto pozostałe strony (>80) — użyj use <domena> + limits show"
      break
    fi
    row="$(hm_resolve_site_paths "${d}" 2>/dev/null || true)"
    user="-"; root=""; doc=""
    if [[ -n "${row}" ]]; then
      if declare -F hm_tsv_field >/dev/null 2>&1; then
        root="$(hm_tsv_field "${row}" 2)"
        doc="$(hm_tsv_field "${row}" 3)"
        user="$(hm_tsv_field "${row}" 7)"
      else
        IFS=$'\t' read -r _ root doc _ _ _ user _ <<<"${row}"
      fi
      [[ "${user}" == "-" || -z "${user}" ]] && user="-"
    fi
    path="${root:-${doc}}"
    sz="-"
    if [[ -n "${path}" && -d "${path}" ]]; then
      sz="$(hm_human_size "$(hm_dir_size_bytes_cached "${path}" 300)")"
    fi
    props="-"
    if [[ "${user}" != "-" ]]; then
      uid="$(hm_limits_uid_for_user "${user}" 2>/dev/null || true)"
      if [[ -n "${uid}" ]]; then
        drop="$(hm_limits_slice_dropin_file "${uid}")"
        props="$(hm_limits_read_dropin_props "${drop}" 2>/dev/null || echo "-")"
      fi
    fi
    hm_table_row "${d}" "${user}" "${sz}" "${props}"
  done
  hm_table_print
  if [[ "${n}" -eq 0 ]]; then
    hm_info "Brak stron (discover)."
  fi
}

cmd_limits() {
  local sub="${1:-}"
  # w kontekście bez sub → show; globalnie → table
  case "${sub}" in
    check)
      hm_limits_check
      ;;
    set)
      shift || true
      hm_limits_set "$@"
      ;;
    clear|unset|reset)
      hm_limits_clear
      ;;
    show)
      hm_limits_show_one
      ;;
    status|"" )
      if [[ -n "${HM_SITE_DOMAIN:-}" ]]; then
        hm_limits_show_one
      else
        hm_limits_table
      fi
      ;;
    table|list|ls|all)
      hm_limits_table
      ;;
    help|-h|--help)
      hm_help_topic limits
      ;;
    *)
      if [[ "${sub}" == --* ]]; then
        hm_limits_set "${sub}" "$@"
      else
        hm_err "Nieznane: limits ${sub}. help limits"
        return 1
      fi
      ;;
  esac
}

_hm_cmd_register limits cmd_limits 0
_hm_cmd_register_site limits cmd_limits
