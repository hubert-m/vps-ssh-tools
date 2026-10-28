#!/usr/bin/env bash
# Tab-complete w interaktywnym REPL (read -e + bind -x)

if [[ -n "${HMTOOLS_COMPLETE_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_COMPLETE_LOADED=1

hm_ensure_sites_cached() {
  if [[ "${#HM_SITES_LIST[@]}" -eq 0 ]]; then
    # całkowicie cicho — jakikolwiek output w bind -x gubi / brudzi prompt
    hm_discover_sites >/dev/null 2>&1 || true
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
    backup disk df ols lsws ssl renew-ssl ssl-renew mysql dbs db cron crons pm2 node apps php
    update-php php-update
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
# WAŻNE:
# - przy 0/1 wyniku NIE wolno nic pisać na stdout/stderr (prompt znika)
# - funkcja MUSI kończyć się statusem 0: przy set -e bind -x zabija cały hmtools
#   (np. ostatnie `[[ … ]] && …` przy parzystej liczbie kandydatów → exit 1)
hm_tab_complete() {
  # bind -x działa w tym samym shellu co REPL (set -euo pipefail)
  set +e

  local line="${READLINE_LINE-}"
  local point="${READLINE_POINT-0}"
  [[ "${point}" -gt ${#line} ]] && point=${#line}

  local left="${line:0:point}"
  local right="${line:point}"

  # początek aktualnego słowa (bez =~ — bezpieczne dla bind -x)
  local start=${#left}
  local ch
  while [[ ${start} -gt 0 ]]; do
    ch="${left:start-1:1}"
    case "${ch}" in
      [[:space:]]) break ;;
    esac
    start=$((start - 1))
  done
  local prefix="${left:0:start}"
  local partial="${left:start}"

  # pierwsze słowo komendy
  local cmd="" rest_line
  rest_line="${line#"${line%%[![:space:]]*}"}"
  cmd="${rest_line%%[[:space:]]*}"

  local -a matches=()
  local m
  local re_empty='^[[:space:]]*$'
  local re_backup_site='backup[[:space:]]+(site|restore|list)[[:space:]]'
  local re_cron_site='cron[[:space:]]+(site|edit)[[:space:]]'
  local re_pm2_site='(pm2|node|apps)[[:space:]]+site[[:space:]]'

  if [[ "${prefix}" =~ $re_empty ]]; then
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
        if [[ "${prefix}" =~ $re_backup_site ]]; then
          hm_ensure_sites_cached
          while IFS= read -r m; do
            [[ -n "${m}" ]] && matches+=("${m}")
          done < <(hm_complete_filter_sites "${partial}")
          for m in full; do
            [[ "${prefix}" == *list* && "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        else
          for m in setup config path root show status full site list restore prune schedule test help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        fi
        ;;
      ols|lsws)
        for m in status reload restart log logs error help; do
          [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
        done
        ;;
      ssl)
        local re_ssl_renew='ssl[[:space:]]+(renew|renewal|issue)[[:space:]]'
        if [[ "${prefix}" =~ $re_ssl_renew ]]; then
          hm_ensure_sites_cached
          while IFS= read -r m; do
            [[ -n "${m}" ]] && matches+=("${m}")
          done < <(hm_complete_filter_sites "${partial}")
        else
          for m in renew renewal issue help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        fi
        ;;
      renew-ssl|ssl-renew)
        hm_ensure_sites_cached
        while IFS= read -r m; do
          [[ -n "${m}" ]] && matches+=("${m}")
        done < <(hm_complete_filter_sites "${partial}")
        ;;
      mysql|dbs|db)
        for m in list ls dump help; do
          [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
        done
        ;;
      cron|crons)
        if [[ "${prefix}" =~ $re_cron_site ]]; then
          hm_ensure_sites_cached
          while IFS= read -r m; do
            [[ -n "${m}" ]] && matches+=("${m}")
          done < <(hm_complete_filter_sites "${partial}")
        else
          for m in list ls all global system users site user edit help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        fi
        ;;
      pm2|node|apps)
        if [[ "${prefix}" =~ $re_pm2_site ]]; then
          hm_ensure_sites_cached
          while IFS= read -r m; do
            [[ -n "${m}" ]] && matches+=("${m}")
          done < <(hm_complete_filter_sites "${partial}")
        else
          for m in list ls status all proxy site ports raw help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        fi
        ;;
      php)
        local re_php_upd='php[[:space:]]+(update|upgrade)[[:space:]]'
        if [[ "${prefix}" =~ $re_php_upd ]]; then
          local root="${OLS_ROOT:-/usr/local/lsws}" d base bn br oldnull
          oldnull="$(shopt -p nullglob || true)"
          shopt -s nullglob
          for d in "${root}"/lsphp*; do
            [[ -d "${d}" ]] || continue
            base="$(basename "${d}")"
            bn="${base#lsphp}"
            if [[ "${bn}" =~ ^[0-9][0-9]$ ]]; then
              br="${bn:0:1}.${bn:1:1}"
              [[ "${br}" == "${partial}"* || "${bn}" == "${partial}"* ]] && matches+=("${br}")
            fi
          done
          eval "${oldnull}" 2>/dev/null || shopt -u nullglob
        else
          for m in update upgrade help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        fi
        ;;
      update-php|php-update)
        local root="${OLS_ROOT:-/usr/local/lsws}" d base bn br oldnull
        oldnull="$(shopt -p nullglob || true)"
        shopt -s nullglob
        for d in "${root}"/lsphp*; do
          [[ -d "${d}" ]] || continue
          base="$(basename "${d}")"
          bn="${base#lsphp}"
          if [[ "${bn}" =~ ^[0-9][0-9]$ ]]; then
            br="${bn:0:1}.${bn:1:1}"
            [[ "${br}" == "${partial}"* || "${bn}" == "${partial}"* || "${base}" == "${partial}"* ]] && matches+=("${br}")
          fi
        done
        eval "${oldnull}" 2>/dev/null || shopt -u nullglob
        ;;
    esac
  fi

  local n="${#matches[@]}"
  if [[ "${n}" -eq 0 ]]; then
    set -e
    return 0
  fi

  if [[ "${n}" -eq 1 ]]; then
    READLINE_LINE="${prefix}${matches[0]}${right}"
    READLINE_POINT=$(( ${#prefix} + ${#matches[0]} ))
    set -e
    return 0
  fi

  # wiele trafień: najpierw tylko wspólny prefix (BEZ listy = prompt zostaje)
  local common
  common="$(printf '%s\n' "${matches[@]}" | hm_complete_common_prefix)"
  if [[ -n "${common}" && "${#common}" -gt ${#partial} ]]; then
    READLINE_LINE="${prefix}${common}${right}"
    READLINE_POINT=$(( ${#prefix} + ${#common} ))
    set -e
    return 0
  fi

  # drugi Tab przy tym samym partial — pokaż kandydatów; readline (-p) odtworzy prompt
  printf '\n'
  local col=0
  for m in "${matches[@]}"; do
    printf '  %-36s' "${m}"
    col=$((col + 1))
    if [[ $((col % 2)) -eq 0 ]]; then
      printf '\n'
    fi
  done
  if [[ $((col % 2)) -ne 0 ]]; then
    printf '\n'
  fi

  set -e
  return 0
}

hm_setup_readline_complete() {
  [[ -t 0 ]] || return 0
  bind -x '"\t": hm_tab_complete' 2>/dev/null || true
  bind 'set completion-ignore-case on' 2>/dev/null || true
  bind 'set show-all-if-ambiguous on' 2>/dev/null || true
  bind 'set skip-completed-text on' 2>/dev/null || true
  # horizontals scroll czasem zostawia „ucięty” prompt po bind -x
  bind 'set horizontal-scroll-mode off' 2>/dev/null || true
}
