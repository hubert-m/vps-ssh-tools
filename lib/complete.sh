#!/usr/bin/env bash
# Tab-complete w interaktywnym REPL (read -e + bind -x)

if [[ -n "${HMTOOLS_COMPLETE_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_COMPLETE_LOADED=1

hm_ensure_sites_cached() {
  if [[ "${#HM_SITES_LIST[@]}" -eq 0 ]]; then
    hm_discover_sites 2>/dev/null || true
  fi
}

hm_complete_common_prefix() {
  # stdin: linie kandydatów → stdout: wspólny prefix
  local first rest i c
  if ! IFS= read -r first; then
    echo ""
    return
  fi
  while IFS= read -r rest; do
    i=0
    while [[ $i -lt ${#first} && $i -lt ${#rest} && "${first:$i:1}" == "${rest:$i:1}" ]]; do
      i=$((i + 1))
    done
    first="${first:0:$i}"
  done
  printf '%s' "${first}"
}

hm_complete_filter_sites() {
  local partial="$1"
  local s partial_lc alt
  partial_lc="$(printf '%s' "${partial}" | tr '[:upper:]' '[:lower:]')"
  alt="$(printf '%s' "${partial_lc}" | sed 's/[-_]/./g')"

  local -a out=()
  # 1) prefix
  for s in "${HM_SITES_LIST[@]}"; do
    local slc
    slc="$(printf '%s' "${s}" | tr '[:upper:]' '[:lower:]')"
    if [[ "${slc}" == "${partial_lc}"* ]]; then
      out+=("${s}")
    fi
  done
  # 2) prefix po zamianie -/_ na kropki (projects-uni → projects.uni…)
  if [[ "${#out[@]}" -eq 0 && "${alt}" != "${partial_lc}" ]]; then
    for s in "${HM_SITES_LIST[@]}"; do
      local slc
      slc="$(printf '%s' "${s}" | tr '[:upper:]' '[:lower:]')"
      if [[ "${slc}" == "${alt}"* ]]; then
        out+=("${s}")
      fi
    done
  fi
  # 3) substring
  if [[ "${#out[@]}" -eq 0 && -n "${partial_lc}" ]]; then
    for s in "${HM_SITES_LIST[@]}"; do
      local slc
      slc="$(printf '%s' "${s}" | tr '[:upper:]' '[:lower:]')"
      if [[ "${slc}" == *"${partial_lc}"* || "${slc}" == *"${alt}"* ]]; then
        out+=("${s}")
      fi
    done
  fi
  # numery 1..N gdy partial to cyfry
  if [[ "${partial}" =~ ^[0-9]+$ ]]; then
    local i n="${#HM_SITES_LIST[@]}"
    for ((i = 1; i <= n; i++)); do
      if [[ "${i}" == "${partial}"* ]]; then
        out+=("${i}")
      fi
    done
  fi
  printf '%s\n' "${out[@]}"
}

hm_complete_commands() {
  local partial="$1"
  local cmds=(
    webs sites list use enter cd
    backup disk df ols lsws ssl mysql dbs db php
    health status applog selflog hmlog detect env
    update-hmtools version ver uninstall-hmtools
    help h exit quit q
  )
  local c
  for c in "${cmds[@]}"; do
    if [[ "${c}" == "${partial}"* ]]; then
      printf '%s\n' "${c}"
    fi
  done
}

# Wywoływane przez: bind -x '"\t": hm_tab_complete'
hm_tab_complete() {
  local line="${READLINE_LINE-}"
  local point="${READLINE_POINT-0}"
  [[ "${point}" -gt ${#line} ]] && point=${#line}

  local left="${line:0:point}"
  local right="${line:point}"

  # początek aktualnego słowa
  local start=${#left}
  while [[ ${start} -gt 0 && ! "${left:start-1:1}" =~ [[:space:]] ]]; do
    start=$((start - 1))
  done
  local prefix="${left:0:start}"
  local partial="${left:start}"

  # pierwsze słowo komendy
  local cmd=""
  if [[ "${line}" =~ ^[[:space:]]*([^[:space:]]+) ]]; then
    cmd="${BASH_REMATCH[1]}"
  fi

  local -a matches=()
  local m

  if [[ "${prefix}" =~ ^[[:space:]]*$ ]]; then
    # pierwsze słowo → komendy
    while IFS= read -r m; do
      [[ -n "${m}" ]] && matches+=("${m}")
    done < <(hm_complete_commands "${partial}")
  else
    case "${cmd}" in
      help|h|\?)
        while IFS= read -r m; do
          [[ -n "${m}" ]] && matches+=("${m}")
        done < <(hm_complete_commands "${partial}")
        for m in info size logs clean; do
          [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
        done
        ;;
      use|enter|cd)
        hm_ensure_sites_cached
        while IFS= read -r m; do
          [[ -n "${m}" ]] && matches+=("${m}")
        done < <(hm_complete_filter_sites "${partial}")
        ;;
      backup)
        if [[ "${prefix}" =~ backup[[:space:]]+site[[:space:]] ]]; then
          hm_ensure_sites_cached
          while IFS= read -r m; do
            [[ -n "${m}" ]] && matches+=("${m}")
          done < <(hm_complete_filter_sites "${partial}")
        else
          for m in setup full site test help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        fi
        ;;
      ols|lsws)
        for m in status reload restart log logs error help; do
          [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
        done
        ;;
      mysql|dbs|db)
        for m in list ls dump help; do
          [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
        done
        ;;
    esac
  fi

  if [[ "${#matches[@]}" -eq 0 ]]; then
    return 0
  fi

  if [[ "${#matches[@]}" -eq 1 ]]; then
    READLINE_LINE="${prefix}${matches[0]}${right}"
    READLINE_POINT=$(( ${#prefix} + ${#matches[0]} ))
    # spacja po komendzie jednoargumentowej? nie — użytkownik sam dopisze
    return 0
  fi

  # wiele trafień — wspólny prefix + lista
  local common
  common="$(printf '%s\n' "${matches[@]}" | hm_complete_common_prefix)"
  if [[ -n "${common}" && "${#common}" -gt ${#partial} ]]; then
    READLINE_LINE="${prefix}${common}${right}"
    READLINE_POINT=$(( ${#prefix} + ${#common} ))
  fi

  printf '\n' >&2
  local col=0
  for m in "${matches[@]}"; do
    printf '  %-36s' "${m}" >&2
    col=$((col + 1))
    if [[ $((col % 2)) -eq 0 ]]; then
      printf '\n' >&2
    fi
  done
  [[ $((col % 2)) -ne 0 ]] && printf '\n' >&2
}

hm_setup_readline_complete() {
  # tylko sesja interaktywna z TTY
  [[ -t 0 ]] || return 0
  bind -x '"\t": hm_tab_complete' 2>/dev/null || true
  bind 'set completion-ignore-case on' 2>/dev/null || true
  bind 'set show-all-if-ambiguous on' 2>/dev/null || true
  bind 'set skip-completed-text on' 2>/dev/null || true
}
