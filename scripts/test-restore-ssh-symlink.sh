#!/usr/bin/env bash
# safety: restore authorized_keys nie podąża za symlinkiem ~/.ssh / pliku.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { :; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }

# shellcheck disable=SC1091
source commands/backup/restore.sh

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hm-restore-ssh.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
export TMP_DIR="${TMP}"

ME="$(whoami)"
HOME_U="${TMP}/home/${ME}"
VICTIM_DIR="${TMP}/victim"
VICTIM_FILE="${TMP}/victim_file"
mkdir -p "${HOME_U}" "${VICTIM_DIR}"
printf 'SAFE_DIR\n' > "${VICTIM_DIR}/authorized_keys"
printf 'SAFE_FILE\n' > "${VICTIM_FILE}"
ORIG_DIR="$(cat "${VICTIM_DIR}/authorized_keys")"
ORIG_FILE="$(cat "${VICTIM_FILE}")"

KEYS_SRC="${TMP}/keys_src"
printf 'ssh-ed25519 AAAATEST restore-key comment\n' > "${KEYS_SRC}"

# --- (a) ~/.ssh → victim dir ---
if ln -sfn "${VICTIM_DIR}" "${HOME_U}/.ssh" 2>/dev/null && [[ -L "${HOME_U}/.ssh" ]]; then
  set +e
  hm_backup_restore_authorized_keys_safe "${ME}" "${ME}" "${HOME_U}" "${KEYS_SRC}" >/dev/null 2>&1
  rc=$?
  set -e
  if [[ "${rc}" -eq 0 ]]; then
    [[ ! -L "${HOME_U}/.ssh" && -d "${HOME_U}/.ssh" ]] && pass "(a) .ssh symlink → zwykły katalog" || fail "(a) .ssh nadal symlink/niekatalog"
    [[ "$(cat "${VICTIM_DIR}/authorized_keys")" == "${ORIG_DIR}" ]] && pass "(a) victim dir nietknięty" || fail "(a) victim dir zmieniony"
    [[ -f "${HOME_U}/.ssh/authorized_keys" && ! -L "${HOME_U}/.ssh/authorized_keys" ]] \
      && grep -q 'AAAATEST' "${HOME_U}/.ssh/authorized_keys" \
      && pass "(a) klucz w zwykłym authorized_keys" || fail "(a) brak klucza w home"
  else
    # odmowa też OK jeśli symlink nie został usunięty — victim musi zostać
    [[ "$(cat "${VICTIM_DIR}/authorized_keys")" == "${ORIG_DIR}" ]] && pass "(a) odmowa + victim nietknięty (rc=${rc})" || fail "(a) victim zmieniony przy odmowie"
  fi
  rm -rf "${HOME_U}/.ssh"
else
  echo "SKIP (a) OS nie tworzy symlinków katalogu"
  pass "(a) skip platform"
  pass "(a) skip platform"
  pass "(a) skip platform"
fi

mkdir -p "${HOME_U}/.ssh"
chmod 700 "${HOME_U}/.ssh"

# --- (b) authorized_keys → victim file ---
if ln -sfn "${VICTIM_FILE}" "${HOME_U}/.ssh/authorized_keys" 2>/dev/null \
  && [[ -L "${HOME_U}/.ssh/authorized_keys" ]]; then
  set +e
  hm_backup_restore_authorized_keys_safe "${ME}" "${ME}" "${HOME_U}" "${KEYS_SRC}" >/dev/null 2>&1
  rc=$?
  set -e
  [[ "$(cat "${VICTIM_FILE}")" == "${ORIG_FILE}" ]] && pass "(b) victim_file nietknięty" || fail "(b) victim_file zmieniony"
  if [[ "${rc}" -eq 0 ]]; then
    [[ -f "${HOME_U}/.ssh/authorized_keys" && ! -L "${HOME_U}/.ssh/authorized_keys" ]] \
      && grep -q 'AAAATEST' "${HOME_U}/.ssh/authorized_keys" \
      && pass "(b) zwykły authorized_keys z kluczem" || fail "(b) plik nadal symlink/bez klucza"
  else
    pass "(b) odmowa przy symlinku pliku (rc=${rc})"
  fi
else
  echo "SKIP (b) OS nie tworzy symlinków pliku"
  pass "(b) skip platform"
  pass "(b) skip platform"
fi

echo ""
echo "Wynik: ${PASS} pass, ${FAIL} fail"
[[ "${FAIL}" -eq 0 ]]
