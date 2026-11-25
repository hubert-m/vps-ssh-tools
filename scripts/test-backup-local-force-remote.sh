#!/usr/bin/env bash
# backup local: HM_BACKUP_FORCE_REMOTE przeżywa hm_load_config w hm_backup_site.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hm-local-force.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

LOCAL_ROOT="${TMP}/localroot"
REMOTE_MOCK="${TMP}/rclone-remote"
mkdir -p "${LOCAL_ROOT}" "${REMOTE_MOCK}"
CONF="${TMP}/hmtools.conf"
printf 'RCLONE_REMOTE="%s"\nBACKUP_LOCAL_ROOT="%s"\n' "${REMOTE_MOCK}" "${LOCAL_ROOT}" > "${CONF}"
export HMTOOLS_CONF="${CONF}"

# stub load_config: jak produkcja — czyta conf i nadpisuje RCLONE_REMOTE
hm_load_config() {
  # shellcheck disable=SC1090
  source "${HMTOOLS_CONF}"
  export RCLONE_REMOTE BACKUP_LOCAL_ROOT
}
hm_err() { echo "ERR: $*" >&2; }
hm_warn() { :; }
hm_ok() { :; }
hm_info() { :; }

# Wyciąg logiki pin z hm_backup_site (bez pełnego backupu)
_simulate_site_after_local_pin() {
  local _force_remote="${HM_BACKUP_FORCE_REMOTE:-}"
  hm_load_config
  if [[ -n "${_force_remote}" ]]; then
    RCLONE_REMOTE="${_force_remote}"
    export RCLONE_REMOTE
  fi
  printf '%s' "${RCLONE_REMOTE}"
}

# (1) bez pin → conf remote
unset HM_BACKUP_FORCE_REMOTE
export RCLONE_REMOTE="should-be-overwritten"
got="$(_simulate_site_after_local_pin)"
[[ "${got}" == "${REMOTE_MOCK}" ]] && pass "(1) load_config ustawia RCLONE z conf" || fail "(1) got=${got}"

# (2) z pin local → zostaje local mimo conf
export HM_BACKUP_FORCE_REMOTE="${LOCAL_ROOT}"
export RCLONE_REMOTE="${LOCAL_ROOT}"
got="$(_simulate_site_after_local_pin)"
[[ "${got}" == "${LOCAL_ROOT}" ]] && pass "(2) FORCE_REMOTE przeżywa load_config" || fail "(2) got=${got} want=${LOCAL_ROOT}"

# (3) lokalny root z conf po load
hm_load_config
# shellcheck disable=SC1091
source commands/backup/local.sh
root="$(hm_backup_local_root)"
[[ "${root}" == "${LOCAL_ROOT}" ]] && pass "(3) hm_backup_local_root z conf" || fail "(3) root=${root}"

# (4) kontrakt w core.sh
if grep -q 'HM_BACKUP_FORCE_REMOTE' commands/backup/core.sh \
  && grep -q 'HM_BACKUP_FORCE_REMOTE' commands/backup/local.sh; then
  pass "(4) pin w local.sh + core.sh"
else
  fail "(4) brak HM_BACKUP_FORCE_REMOTE"
fi

if [[ "${FAIL}" -eq 0 ]]; then
  echo "ALL PASSED (${PASS})"
else
  echo "FAILED (${FAIL} fail, ${PASS} pass)" >&2
  exit 1
fi
