#!/usr/bin/env bash
# Katalogi wersji dla site new (fixture / cache). Bez sieci.

if [[ -n "${HMTOOLS_SITE_CATALOG_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_SITE_CATALOG_LOADED=1

# nvm ls-remote: unikalne major, bez prerelease (linia z '-').
hm_site_catalog_nvm_majors() {
  local file="$1" line ver major seen="|"
  local re='v([0-9]+)\.[0-9]+\.[0-9]+'
  [[ -f "${file}" ]] || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" == *-* ]] && continue
    [[ "${line}" =~ $re ]] || continue
    major="${BASH_REMATCH[1]}"
    [[ "${seen}" == *"|${major}|"* ]] && continue
    seen="${seen}${major}|"
    printf '%s\n' "${major}"
  done < "${file}"
}

# releases-index.json: channel-version + support-phase.
hm_site_catalog_dotnet() {
  local file="$1" line ver="" phase=""
  local re_ver='"channel-version"[[:space:]]*:[[:space:]]*"([^"]+)"'
  local re_phase='"support-phase"[[:space:]]*:[[:space:]]*"([^"]+)"'
  [[ -f "${file}" ]] || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" =~ $re_ver ]]; then
      ver="${BASH_REMATCH[1]}"
    elif [[ "${line}" =~ $re_phase ]]; then
      phase="${BASH_REMATCH[1]}"
      if [[ -n "${ver}" ]]; then
        printf '%s\t%s\n' "${ver}" "${phase}"
      fi
      ver=""
      phase=""
    fi
  done < "${file}"
}

# python.org / statusy: "version" potem "status".
hm_site_catalog_python() {
  local file="$1" line ver="" st=""
  local re_ver='"version"[[:space:]]*:[[:space:]]*"([^"]+)"'
  local re_st='"status"[[:space:]]*:[[:space:]]*"([^"]+)"'
  [[ -f "${file}" ]] || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" =~ $re_ver ]]; then
      ver="${BASH_REMATCH[1]}"
    fi
    if [[ "${line}" =~ $re_st ]]; then
      st="${BASH_REMATCH[1]}"
    fi
    if [[ -n "${ver}" && -n "${st}" ]]; then
      printf '%s\t%s\n' "${ver}" "${st}"
      ver=""
      st=""
    fi
  done < "${file}"
}
