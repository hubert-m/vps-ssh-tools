#!/usr/bin/env bash
# Complete: cache domen, filtry, lista komend

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

# Filtr nazw ze stdin (+ opcjonalne stałe kandydaty): prefix, potem substring.
# Użycie: { echo a; echo b; } | hm_complete_filter_names partial [extra…]
hm_complete_filter_names() {
  local partial="${1:-}"
  shift || true
  local partial_lc name nlc e elc
  partial_lc="$(printf '%s' "${partial}" | tr '[:upper:]' '[:lower:]')"
  local -a out=()

  for e in "$@"; do
    [[ -n "${e}" ]] || continue
    elc="$(printf '%s' "${e}" | tr '[:upper:]' '[:lower:]')"
    if [[ -z "${partial_lc}" || "${elc}" == "${partial_lc}"* || "${elc}" == *"${partial_lc}"* ]]; then
      out+=("${e}")
    fi
  done

  while IFS= read -r name || [[ -n "${name:-}" ]]; do
    [[ -n "${name}" ]] || continue
    nlc="$(printf '%s' "${name}" | tr '[:upper:]' '[:lower:]')"
    if [[ -z "${partial_lc}" || "${nlc}" == "${partial_lc}"* || "${nlc}" == *"${partial_lc}"* ]]; then
      out+=("${name}")
    fi
  done

  local seen="|" c
  for c in "${out[@]}"; do
    [[ "${seen}" == *"|${c}|"* ]] && continue
    seen+="${c}|"
    printf '%s\n' "${c}"
  done
}

# Tab: nazwy workerów Supervisora (group:name) + „all”.
hm_complete_filter_supervisor() {
  local partial="${1:-}"
  {
    if declare -F hm_supervisor_list_names >/dev/null 2>&1; then
      hm_supervisor_list_names 2>/dev/null || true
    fi
  } | hm_complete_filter_names "${partial}" all
}

# Tab: bazy MySQL (SHOW DATABASES bez systemowych).
hm_complete_filter_mysql_dbs() {
  local partial="${1:-}"
  {
    if declare -F hm_list_all_databases >/dev/null 2>&1; then
      hm_list_all_databases 2>/dev/null || true
    fi
  } | hm_complete_filter_names "${partial}"
}

# Tab: procesy PM2 + „all”.
hm_complete_filter_pm2() {
  local partial="${1:-}"
  {
    if declare -F hm_pm2_parse_apps >/dev/null 2>&1; then
      hm_pm2_parse_apps 2>/dev/null | awk -F'|' 'NF && $1 != "" { print $1 }' || true
    fi
  } | hm_complete_filter_names "${partial}" all
}

# Tab: indeksy Redis dbN z INFO keyspace.
hm_complete_filter_redis_dbs() {
  local partial="${1:-}"
  {
    if declare -F hm_redis_cli >/dev/null 2>&1; then
      hm_redis_cli INFO keyspace 2>/dev/null \
        | sed -n 's/^db\([0-9][0-9]*\):.*/\1/p' || true
    fi
  } | hm_complete_filter_names "${partial}"
}

# Tab: id klientów Redis (CLIENT LIST).
hm_complete_filter_redis_clients() {
  local partial="${1:-}"
  {
    if declare -F hm_redis_cli >/dev/null 2>&1; then
      hm_redis_cli CLIENT LIST 2>/dev/null \
        | sed -n 's/.*\<id=\([0-9][0-9]*\).*/\1/p' || true
    fi
  } | hm_complete_filter_names "${partial}"
}

# Tab: użytkownicy z crontabem (cron user / cron edit).
hm_complete_filter_cron_users() {
  local partial="${1:-}"
  {
    if declare -F hm_cron_list_users_with_crontab >/dev/null 2>&1; then
      hm_cron_list_users_with_crontab 2>/dev/null || true
    fi
  } | hm_complete_filter_names "${partial}"
}

# Wygodny helper do tab.sh — dopisz domeny do tablicy matches.
hm_complete_push_sites() {
  local partial="${1:-}"
  local m
  hm_ensure_sites_cached
  while IFS= read -r m; do
    [[ -n "${m}" ]] && matches+=("${m}")
  done < <(hm_complete_filter_sites "${partial}")
}

hm_complete_commands() {
  local partial="$1"
  local -a cmds=()
  local c k
  # Z rejestru modułów (nazwy + aliasy); fallback gdy _load jeszcze nie
  if [[ "${#HM_CMD_ALIAS_MAP[@]}" -gt 0 ]]; then
    for k in "${!HM_CMD_ALIAS_MAP[@]}"; do
      cmds+=("${k}")
    done
  else
    cmds=(
      webs sites list use enter cd delete-site archive-site
      backup disk df ols lsws ssl renew-ssl ssl-renew mysql dbs db cron crons pm2 node apps php
      update update-php php-update chrome chromium headless supervisor docker
      health status security sec applog selflog hmlog detect env
      update-hmtools version ver uninstall-hmtools
      help h
    )
  fi
  cmds+=(exit quit q)
  # w kontekście strony — komendy lokalne (info/size/…)
  if [[ -n "${HM_SITE_DOMAIN:-}" ]]; then
    if [[ "${#HM_CMD_SITE_ENTRY[@]}" -gt 0 ]]; then
      for k in "${!HM_CMD_SITE_ENTRY[@]}"; do
        cmds+=("${k}")
      done
    fi
    cmds+=(info size logs clean htaccess proxy perms back dbs renew-ssl delete-site archive supervisor docker vhost rewrite headers cache)
  fi
  # unikalne + filtr partial
  local seen="|"
  for c in "${cmds[@]}"; do
    [[ "${seen}" == *"|${c}|"* ]] && continue
    seen+="${c}|"
    if [[ "${c}" == "${partial}"* ]]; then
      printf '%s\n' "${c}"
    fi
  done
}
