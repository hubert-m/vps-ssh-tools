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
