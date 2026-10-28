#!/usr/bin/env bash
# Complete: bind -x Tab handler + setup readline

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
        for m in info size logs clean htaccess proxy; do
          [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
        done
        ;;
      htaccess|hta)
        for m in check enable help; do
          [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
        done
        ;;
      proxy)
        for m in status set-port help; do
          [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
        done
        ;;
      clean)
        for m in --lscache help; do
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
        local re_ols_sub='(ols|lsws)[[:space:]]+(htaccess|hta|cache|lscache|proxy|admin|webadmin)[[:space:]]'
        if [[ "${prefix}" =~ $re_ols_sub ]]; then
          case "${BASH_REMATCH[2]}" in
            htaccess|hta)
              for m in check enable help; do
                [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
              done
              ;;
            cache|lscache)
              for m in status flush all help; do
                [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
              done
              ;;
            proxy)
              for m in status set-port help; do
                [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
              done
              ;;
            admin|webadmin)
              for m in status pass help; do
                [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
              done
              ;;
          esac
        else
          for m in status reload restart log logs error stats top htaccess cache proxy admin help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        fi
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
        local re_php_ver='php[[:space:]]+(update|upgrade|set)[[:space:]]'
        local re_php_ext_inst='php[[:space:]]+ext[[:space:]]+install[[:space:]]'
        local re_php_ext='php[[:space:]]+ext[[:space:]]'
        local re_php_ini_set='php[[:space:]]+ini[[:space:]]+set[[:space:]]'
        local re_php_ini='php[[:space:]]+ini[[:space:]]'
        if [[ "${prefix}" =~ $re_php_ver ]]; then
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
        elif [[ "${prefix}" =~ $re_php_ext_inst ]]; then
          for m in imagick redis memcached intl zip soap gd mbstring bcmath opcache apcu; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        elif [[ "${prefix}" =~ $re_php_ext ]]; then
          for m in list ls install modules help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        elif [[ "${prefix}" =~ $re_php_ini_set ]]; then
          for m in memory_limit upload_max_filesize post_max_size max_execution_time max_input_vars opcache.enable; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        elif [[ "${prefix}" =~ $re_php_ini ]]; then
          for m in set show help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        else
          for m in update upgrade set ext ini restart ps help; do
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
