#!/usr/bin/env bash
# Czyszczenie cache Chrome / starych buildów Puppeteer. Domyślnie dry-run.
# Nie rusza działającej binarki, cookies, historii ani całego profilu.

if [[ -n "${HM_CHROME_CLEAN_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HM_CHROME_CLEAN_LOADED=1

hm_chrome_realpath() {
  local p="${1:-}" rp
  [[ -n "${p}" ]] || return 1
  if rp="$(realpath -- "${p}" 2>/dev/null)" && [[ -n "${rp}" && "${rp}" == /* ]]; then
    printf '%s' "${rp}"
    return 0
  fi
  if rp="$(readlink -f -- "${p}" 2>/dev/null)" && [[ -n "${rp}" && "${rp}" == /* ]]; then
    printf '%s' "${rp}"
    return 0
  fi
  case "${p}" in
    /*)
      case "${p}" in
        *..*) return 1 ;;
      esac
      printf '%s' "${p}"
      return 0
      ;;
  esac
  return 1
}

# Katalog profilu albo cache Puppeteer — nie może być korzeniem systemu ani /tmp.
hm_chrome_profile_root_safe() {
  case "${1:-}" in
    /|/tmp|/var|/var/tmp|/home|/root|/usr|/etc|/dev|/proc) return 1 ;;
    /*) return 0 ;;
    *) return 1 ;;
  esac
}

# Śmieci Chrome: /tmp i /var/tmp są dozwolone, korzenie systemu nie.
hm_chrome_tmp_root_safe() {
  case "${1:-}" in
    /|/home|/root|/usr|/etc|/var|/dev|/proc) return 1 ;;
    /*) return 0 ;;
    *) return 1 ;;
  esac
}

hm_chrome_puppeteer_root() {
  local bin d
  if [[ "${HMTOOLS_TEST:-}" == "1" && -n "${HM_CHROME_PUPPETEER_ROOT:-}" ]]; then
    d="$(hm_chrome_realpath "${HM_CHROME_PUPPETEER_ROOT}")" || return 1
    hm_chrome_profile_root_safe "${d}" || return 1
    printf '%s' "${d}"
    return 0
  fi
  bin="${CHROME_BIN:-}"
  [[ -n "${bin}" ]] || return 1
  d="$(hm_chrome_realpath "$(dirname "${bin}")" 2>/dev/null || true)"
  [[ -n "${d}" ]] || return 1
  while [[ -n "${d}" && "${d}" != / ]]; do
    if [[ "${d}" == */.cache/puppeteer/chrome ]]; then
      hm_chrome_profile_root_safe "${d}" || return 1
      printf '%s' "${d}"
      return 0
    fi
    d="$(dirname "${d}")"
  done
  return 1
}

hm_chrome_keep_linux_dir() {
  local bin d base
  bin="${CHROME_BIN:-}"
  [[ -n "${bin}" ]] || return 1
  d="$(hm_chrome_realpath "$(dirname "${bin}")" 2>/dev/null || true)"
  [[ -n "${d}" ]] || return 1
  while [[ -n "${d}" && "${d}" != / ]]; do
    base="$(basename "${d}")"
    if [[ "${base}" =~ ^linux-[A-Za-z0-9._-]{1,80}$ ]]; then
      printf '%s' "${d}"
      return 0
    fi
    d="$(dirname "${d}")"
  done
  return 1
}

hm_chrome_tmp_root() {
  local t
  if [[ "${HMTOOLS_TEST:-}" == "1" && -n "${HM_CHROME_TMP_ROOT:-}" ]]; then
    t="$(hm_chrome_realpath "${HM_CHROME_TMP_ROOT}")" || return 1
  else
    t="/tmp"
  fi
  hm_chrome_tmp_root_safe "${t}" || return 1
  printf '%s' "${t}"
}

hm_chrome_user_data_dir() {
  local unit line path
  if [[ "${HMTOOLS_TEST:-}" == "1" && -n "${HM_CHROME_USER_DATA_DIR:-}" ]]; then
    path="${HM_CHROME_USER_DATA_DIR}"
  else
    unit="$(hm_chrome_unit 2>/dev/null || true)"
    [[ -n "${unit}" ]] || return 1
    hm_have_cmd systemctl || return 1
    line="$(systemctl show -p ExecStart --value "${unit}" 2>/dev/null | head -1 || true)"
    if [[ "${line}" =~ --user-data-dir=([^[:space:];]+) ]]; then
      path="${BASH_REMATCH[1]}"
    elif [[ "${line}" =~ --user-data-dir[[:space:]]+([^[:space:];]+) ]]; then
      path="${BASH_REMATCH[1]}"
    else
      return 1
    fi
    path="${path%\"}"
    path="${path#\"}"
    path="${path%\'}"
    path="${path#\'}"
  fi
  [[ "${path}" == /* ]] || return 1
  case "${path}" in
    *..*) return 1 ;;
  esac
  path="$(hm_chrome_realpath "${path}")" || return 1
  hm_chrome_profile_root_safe "${path}" || return 1
  printf '%s' "${path}"
}

hm_chrome_linux_name_ok() {
  [[ "${1:-}" =~ ^linux-[A-Za-z0-9._-]{1,80}$ ]]
}

hm_chrome_tmp_name_ok() {
  local n="${1:-}"
  [[ "${#n}" -ge 8 && "${#n}" -le 128 ]] || return 1
  [[ "${n}" =~ ^(\.org\.chromium\.|\.com\.google\.Chrome\.|\.com\.google\.chromedriver\.|puppeteer_dev_chrome_profile-|chrome_crashpad_)[A-Za-z0-9._-]{1,80}$ ]]
}

hm_chrome_cache_rel_ok() {
  case "${1:-}" in
    "Default/Cache"|"Default/Code Cache"|"Default/GPUCache"|"Default/DawnWebGPUCache"|"Default/DawnGraphiteCache"|"ShaderCache"|"GrShaderCache"|"GraphiteDawnCache"|"Crash Reports"|"Crashpad")
      return 0
      ;;
    *) return 1 ;;
  esac
}

hm_chrome_owner_ok() {
  local p="${1:-}" uid="" puid="" ppuid="" trust=""
  puid="$(stat -c '%u' "${p}" 2>/dev/null || true)"
  ppuid="$(stat -c '%u' "$(dirname "${p}")" 2>/dev/null || true)"
  if [[ -z "${puid}" || -z "${ppuid}" ]]; then
    [[ "${HMTOOLS_TEST:-}" == "1" ]] && return 0
    return 1
  fi
  trust="${HM_CHROME_UID:-}"
  if [[ -z "${trust}" ]]; then
    local pup_root=""
    pup_root="$(hm_chrome_puppeteer_root 2>/dev/null || true)"
    if [[ -n "${pup_root}" && -d "${pup_root}" ]]; then
      trust="$(stat -c '%u' "${pup_root}" 2>/dev/null || true)"
    fi
  fi
  uid="$(id -u 2>/dev/null || echo "")"
  hm_chrome_uid_allowed() {
    local u="${1:-}"
    [[ "${u}" == "0" ]] && return 0
    [[ -n "${trust}" && "${u}" == "${trust}" ]] && return 0
    [[ "${HMTOOLS_TEST:-}" == "1" && -n "${uid}" && "${u}" == "${uid}" ]] && return 0
    return 1
  }
  hm_chrome_uid_allowed "${puid}" || return 1
  hm_chrome_uid_allowed "${ppuid}" || return 1
}

hm_chrome_path_in_use() {
  local p="${1:-}" f
  if [[ -n "${HM_CHROME_BUSY:-}" ]] && grep -qxF -- "${p}" "${HM_CHROME_BUSY}" 2>/dev/null; then
    return 0
  fi
  [[ "${HMTOOLS_TEST:-}" == "1" ]] && return 1
  [[ -d /proc ]] || return 1
  for f in /proc/[0-9]*/cmdline; do
    [[ -r "${f}" ]] || continue
    if tr '\0' '\n' < "${f}" 2>/dev/null | grep -Fxq -- "${p}"; then
      return 0
    fi
  done
  return 1
}

hm_chrome_old_enough() {
  local hit=""
  hit="$(find "${1:-}" -maxdepth 0 -mmin +1440 -print 2>/dev/null || true)"
  [[ -n "${hit}" ]]
}

hm_chrome_deletable() {
  local kind="${1:-}" p="${2:-}" rp base root keep tmp data rel
  [[ -n "${p}" && -e "${p}" && ! -L "${p}" ]] || return 1
  hm_chrome_owner_ok "${p}" || return 1
  rp="$(hm_chrome_realpath "${p}")" || return 1
  case "${rp}" in
    /|/tmp|/var|/var/tmp|/home|/root|/usr|/etc|/dev|/proc) return 1 ;;
  esac
  case "${kind}" in
    puppeteer)
      root="$(hm_chrome_puppeteer_root)" || return 1
      base="$(basename "${rp}")"
      hm_chrome_linux_name_ok "${base}" || return 1
      [[ "$(dirname "${rp}")" == "${root}" ]] || return 1
      if [[ "${HMTOOLS_TEST:-}" != "1" || -z "${HM_CHROME_PUPPETEER_ROOT:-}" ]]; then
        [[ "${root}" == */.cache/puppeteer/chrome ]] || return 1
      fi
      keep="$(hm_chrome_keep_linux_dir 2>/dev/null || true)"
      # Bez działającej binarki nie wiadomo, który linux-* jest żywy.
      [[ -n "${keep}" && "$(dirname "${keep}")" == "${root}" ]] || return 1
      [[ "${rp}" != "${keep}" ]] || return 1
      return 0
      ;;
    tmp)
      tmp="$(hm_chrome_tmp_root)" || return 1
      base="$(basename "${rp}")"
      hm_chrome_tmp_name_ok "${base}" || return 1
      [[ "$(dirname "${rp}")" == "${tmp}" ]] || return 1
      hm_chrome_path_in_use "${p}" && return 1
      hm_chrome_old_enough "${p}" || return 1
      return 0
      ;;
    cache)
      data="$(hm_chrome_user_data_dir)" || return 1
      [[ "${rp}" == "${data}/"* ]] || return 1
      rel="${rp#"${data}/"}"
      hm_chrome_cache_rel_ok "${rel}" || return 1
      [[ "$(hm_chrome_realpath "${data}/${rel}")" == "${rp}" ]] || return 1
      return 0
      ;;
    *) return 1 ;;
  esac
}

hm_chrome_clean_candidates() {
  local root d tmp data rel p
  root="$(hm_chrome_puppeteer_root 2>/dev/null || true)"
  if [[ -n "${root}" && -d "${root}" && ! -L "${root}" ]]; then
    while IFS= read -r d; do
      [[ -n "${d}" ]] || continue
      hm_chrome_deletable puppeteer "${d}" || continue
      printf 'puppeteer\t%s\n' "$(hm_chrome_realpath "${d}")"
    done < <(
      shopt -s nullglob
      for d in "${root}/linux-"*; do
        printf '%s\n' "${d}"
      done
    )
  fi
  tmp="$(hm_chrome_tmp_root 2>/dev/null || true)"
  if [[ -n "${tmp}" && -d "${tmp}" && ! -L "${tmp}" ]]; then
    while IFS= read -r d; do
      [[ -n "${d}" ]] || continue
      hm_chrome_deletable tmp "${d}" || continue
      printf 'tmp\t%s\n' "$(hm_chrome_realpath "${d}")"
    done < <(
      shopt -s nullglob
      for d in \
        "${tmp}/.org.chromium."* \
        "${tmp}/.com.google.Chrome."* \
        "${tmp}/.com.google.chromedriver."* \
        "${tmp}/puppeteer_dev_chrome_profile-"* \
        "${tmp}/chrome_crashpad_"*
      do
        printf '%s\n' "${d}"
      done
    )
  fi
  data="$(hm_chrome_user_data_dir 2>/dev/null || true)"
  if [[ -n "${data}" && -d "${data}" && ! -L "${data}" ]]; then
    for rel in \
      "Default/Cache" \
      "Default/Code Cache" \
      "Default/GPUCache" \
      "Default/DawnWebGPUCache" \
      "Default/DawnGraphiteCache" \
      "ShaderCache" \
      "GrShaderCache" \
      "GraphiteDawnCache" \
      "Crash Reports" \
      "Crashpad"
    do
      p="${data}/${rel}"
      hm_chrome_deletable cache "${p}" || continue
      printf 'cache\t%s\n' "$(hm_chrome_realpath "${p}")"
    done
  fi
  return 0
}

hm_chrome_rm_tree() {
  local kind="${1:-}" p="${2:-}" uid="" owner=""
  hm_chrome_deletable "${kind}" "${p}" || return 1
  [[ -e "${p}" && ! -L "${p}" ]] || return 1
  if [[ "${HMTOOLS_TEST:-}" == "1" ]]; then
    command rm -rf -- "${p}"
    return $?
  fi
  uid="$(stat -c '%u' "${p}" 2>/dev/null || echo 0)"
  if [[ "${uid}" == "0" ]]; then
    command rm -rf -- "${p}"
    return $?
  fi
  owner="$(stat -c '%U' "${p}" 2>/dev/null || true)"
  if [[ -n "${owner}" ]] && command -v runuser >/dev/null 2>&1; then
    runuser -u "${owner}" -- rm -rf -- "${p}"
    return $?
  fi
  hm_err "Brak runuser. Nie kasuję jako root: ${p}"
  return 1
}

hm_chrome_bytes() {
  local p="${1:-}" b=""
  [[ -e "${p}" ]] || {
    printf '0'
    return 0
  }
  if declare -F hm_dir_size_bytes >/dev/null 2>&1; then
    b="$(hm_dir_size_bytes "${p}" 2>/dev/null || echo 0)"
  elif du -sb "${p}" >/dev/null 2>&1; then
    b="$(du -sb "${p}" 2>/dev/null | awk 'NR==1 { print $1; exit }')"
  else
    b="$(du -sk "${p}" 2>/dev/null | awk 'NR==1 { print $1; exit }')"
    if [[ "${b}" =~ ^[0-9]+$ ]]; then
      b=$((b * 1024))
    fi
  fi
  [[ "${b}" =~ ^[0-9]+$ ]] || b=0
  printf '%s' "${b}"
}

hm_chrome_human_size() {
  local b="${1:-0}"
  [[ "${b}" =~ ^[0-9]+$ ]] || b=0
  if declare -F hm_human_size >/dev/null 2>&1; then
    hm_human_size "${b}"
    return 0
  fi
  if [[ "${b}" -ge 1073741824 ]]; then
    awk -v b="${b}" 'BEGIN { printf "%.1fG", b / 1073741824 }'
  elif [[ "${b}" -ge 1048576 ]]; then
    awk -v b="${b}" 'BEGIN { printf "%.1fM", b / 1048576 }'
  elif [[ "${b}" -ge 1024 ]]; then
    awk -v b="${b}" 'BEGIN { printf "%.0fK", b / 1024 }'
  else
    printf '%sB' "${b}"
  fi
}

cmd_chrome_disk() {
  local keep="" root="" sib="" b="" kind="" path="" n=0
  if declare -F hm_chrome_require >/dev/null 2>&1; then
    hm_chrome_require || true
  fi
  echo "${C_BOLD:-}Chrome dysk${C_RESET:-}"
  keep="$(hm_chrome_keep_linux_dir 2>/dev/null || true)"
  root="$(hm_chrome_puppeteer_root 2>/dev/null || true)"
  if [[ -n "${root}" && -d "${root}" ]]; then
    b="$(hm_chrome_bytes "${root}")"
    echo "  Puppeteer : $(hm_chrome_human_size "${b}")  ${root}"
  fi
  if [[ -n "${keep}" ]]; then
    b="$(hm_chrome_bytes "${keep}")"
    echo "  Działa    : $(hm_chrome_human_size "${b}")  ${keep}"
  else
    hm_info "Brak działającej binarki Puppeteer — stare linux-* nie wejdą do chrome clean."
  fi
  if [[ -n "${root}" ]]; then
    sib="$(dirname "${root}")/chrome-headless-shell"
    if [[ -d "${sib}" && ! -L "${sib}" ]]; then
      b="$(hm_chrome_bytes "${sib}")"
      echo "  Shell     : $(hm_chrome_human_size "${b}")  ${sib}  (poza chrome clean)"
    fi
  fi
  echo "  Do usunięcia:"
  hm_table_begin LRL
  hm_table_row RODZAJ ROZMIAR ŚCIEŻKA
  while IFS=$'\t' read -r kind path; do
    [[ -n "${path}" ]] || continue
    n=$((n + 1))
    hm_table_row "${kind}" "$(hm_chrome_human_size "$(hm_chrome_bytes "${path}")")" "${path}"
  done < <(hm_chrome_clean_candidates)
  if [[ "${n}" -eq 0 ]]; then
    echo "    —"
  else
    hm_table_print 4
  fi
  hm_info "chrome clean pokazuje to samo i nic nie kasuje, dopóki nie podasz --execute."
  return 0
}

cmd_chrome_clean() {
  local dry=1 yes=0 a kind path n=0 total=0 bytes i removed=0 keep=""
  local -a kinds=() paths=()
  for a in "$@"; do
    case "${a}" in
      --dry-run|--dry) dry=1 ;;
      --execute|--apply) dry=0 ;;
      --yes|-y) yes=1 ;;
      -h|--help)
        hm_info "Użycie: chrome clean [--dry-run|--execute] [--yes]"
        hm_info "Domyślnie dry-run. --yes bez --execute nic nie usuwa."
        hm_info "Zakres: stare linux-* Puppeteer (nie działająca binarka), cache profilu, śmieci w /tmp."
        return 0
        ;;
      *)
        hm_err "Nieznana flaga: ${a}"
        return 1
        ;;
    esac
  done
  if declare -F hm_chrome_require >/dev/null 2>&1; then
    hm_chrome_require || hm_info "Czyszczę tylko to, co da się ustalić bez wykrytej binarki."
  fi
  keep="$(hm_chrome_keep_linux_dir 2>/dev/null || true)"
  echo "${C_BOLD:-}Chrome clean${C_RESET:-}"
  if [[ -n "${keep}" ]]; then
    echo "  Zostaje : ${keep}"
  else
    hm_info "Brak działającej binarki Puppeteer — katalogi linux-* zostają."
  fi
  hm_table_begin LRL
  hm_table_row RODZAJ ROZMIAR ŚCIEŻKA
  while IFS=$'\t' read -r kind path; do
    [[ -n "${path}" ]] || continue
    hm_chrome_deletable "${kind}" "${path}" || continue
    bytes="$(hm_chrome_bytes "${path}")"
    total=$((total + bytes))
    n=$((n + 1))
    hm_table_row "${kind}" "$(hm_chrome_human_size "${bytes}")" "${path}"
    kinds+=("${kind}")
    paths+=("${path}")
  done < <(hm_chrome_clean_candidates)
  if [[ "${n}" -gt 0 ]]; then
    hm_table_print
  fi
  if [[ "${n}" -eq 0 ]]; then
    hm_ok "Nic do usunięcia."
    return 0
  fi
  echo "  Razem   : $(hm_chrome_human_size "${total}")  (${n})"
  hm_info "Nietknięte: cookies, historia, hasła, działająca binarka."
  if [[ "${dry}" -eq 1 ]]; then
    if [[ "${yes}" -eq 1 ]]; then
      hm_info "--yes bez --execute nic nie usuwa."
    fi
    hm_info "Dry-run. Aby usunąć: chrome clean --execute"
    return 0
  fi
  hm_chrome_confirm "Usunąć pliki tymczasowe Chrome" \
    "Cache profilu i stare buildy. Cookies i historia zostają. Chrome może być uruchomiony." \
    "${yes}" \
    "Usunąć ${n} ścieżek (~$(hm_chrome_human_size "${total}")) z listy powyżej" || {
    hm_info "Anulowano."
    return 1
  }
  for i in "${!paths[@]}"; do
    if hm_chrome_rm_tree "${kinds[$i]}" "${paths[$i]}"; then
      removed=$((removed + 1))
    else
      hm_warn "Pominięto: ${paths[$i]}"
    fi
  done
  hm_ok "Usunięto ${removed} z ${n}."
  return 0
}

cmd_chrome_ps() {
  local unit="" pid="" state="" args="" line=""
  if declare -F hm_chrome_require >/dev/null 2>&1; then
    hm_chrome_require || true
  fi
  echo "${C_BOLD:-}Chrome proces${C_RESET:-}"
  echo "  Binary   : ${CHROME_BIN:--}"
  if [[ -n "${CHROME_CDP_URL:-}" ]]; then
    echo "  CDP      : $(hm_chrome_cdp_url_display)"
  else
    echo "  CDP      : —"
  fi
  unit="$(hm_chrome_unit 2>/dev/null || true)"
  if [[ -z "${unit}" ]]; then
    hm_info "Brak znanego unitu (chrome-headless, chromium-headless, google-chrome-headless)."
  elif ! hm_have_cmd systemctl; then
    hm_info "Brak systemctl."
  else
    state="$(systemctl is-active "${unit}" 2>/dev/null || echo unknown)"
    echo "  Service  : ${unit} (${state})"
    pid="$(systemctl show -p MainPID --value "${unit}" 2>/dev/null || true)"
    if [[ "${pid}" =~ ^[0-9]+$ && "${pid}" != "0" ]]; then
      echo "  MainPID  : ${pid}"
      if hm_have_cmd ps; then
        line="$(ps -o user=,rss=,etime= -p "${pid}" 2>/dev/null | head -1 || true)"
        if [[ -n "${line}" ]]; then
          echo "  ps       : ${line}"
        fi
      fi
      if [[ -r "/proc/${pid}/cmdline" ]]; then
        args="$(tr '\0' ' ' < "/proc/${pid}/cmdline" || true)"
        args="$(hm_chrome_one_line "${args}" 160)"
        echo "  Cmd      : ${args}"
      fi
    else
      echo "  MainPID  : —"
    fi
  fi
  hm_chrome_info_listen || true
  return 0
}

cmd_chrome_restart() {
  local yes=0 a unit="" st=""
  for a in "$@"; do
    case "${a}" in
      --yes|-y) yes=1 ;;
      -h|--help)
        hm_info "Użycie: chrome restart [--yes]"
        hm_info "Tylko unity: chrome-headless, chromium-headless, google-chrome-headless."
        return 0
        ;;
      *)
        hm_err "Nieznana flaga: ${a}"
        return 1
        ;;
    esac
  done
  if declare -F hm_chrome_require >/dev/null 2>&1; then
    hm_chrome_require || true
  fi
  unit="$(hm_chrome_unit 2>/dev/null || true)"
  if [[ -z "${unit}" ]]; then
    hm_err "Brak znanego unitu chrome-headless. Nie restartuję procesu ręcznie."
    return 1
  fi
  hm_have_cmd systemctl || {
    hm_err "Brak systemctl."
    return 1
  }
  systemctl cat "${unit}" >/dev/null 2>&1 || {
    hm_err "Unit ${unit} nie istnieje."
    return 1
  }
  hm_chrome_confirm "Restart ${unit}" \
    "Headless Chrome wstanie od nowa. Otwarte karty znikną." \
    "${yes}" \
    "systemctl restart ${unit}" \
    "sprawdzenie is-active" || {
    hm_info "Anulowano."
    return 1
  }
  if declare -F hm_run_timeout >/dev/null 2>&1; then
    hm_run_timeout 30 systemctl restart "${unit}" || {
      hm_err "systemctl restart ${unit} nie powiódł się."
      cmd_chrome_log 20 || true
      return 1
    }
  else
    systemctl restart "${unit}" || {
      hm_err "systemctl restart ${unit} nie powiódł się."
      return 1
    }
  fi
  st="$(systemctl is-active "${unit}" 2>/dev/null || echo unknown)"
  if [[ "${st}" == "active" ]]; then
    hm_ok "${unit} jest active."
    return 0
  fi
  hm_err "${unit} po restarcie: ${st}"
  cmd_chrome_log 20 || true
  return 1
}

cmd_chrome_log() {
  local n="" a unit=""
  for a in "$@"; do
    case "${a}" in
      -h|--help)
        hm_info "Użycie: chrome log [N]   (1..200, domyślnie 40)"
        return 0
        ;;
      "")
        ;;
      *[!0-9]*)
        hm_err "N musi być liczbą 1..200."
        return 1
        ;;
      *)
        if [[ -n "${n}" ]]; then
          hm_err "Podaj jedno N."
          return 1
        fi
        n="${a}"
        ;;
    esac
  done
  [[ -n "${n}" ]] || n=40
  if [[ "${n}" -lt 1 || "${n}" -gt 200 ]]; then
    hm_err "N musi być od 1 do 200."
    return 1
  fi
  if declare -F hm_chrome_require >/dev/null 2>&1; then
    hm_chrome_require || true
  fi
  unit="$(hm_chrome_unit 2>/dev/null || true)"
  if [[ -z "${unit}" ]]; then
    hm_err "Brak znanego unitu do journalctl."
    return 1
  fi
  hm_have_cmd journalctl || {
    hm_err "Brak journalctl."
    return 1
  }
  echo "${C_BOLD:-}journalctl -u ${unit} -n ${n}${C_RESET:-}"
  journalctl -u "${unit}" -n "${n}" --no-pager 2>/dev/null | sed 's/^/  /' || true
  return 0
}
