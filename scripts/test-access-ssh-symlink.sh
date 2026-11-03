#!/usr/bin/env bash
# Regresja: symlink / ścieżka poza home → odmowa; cel bez zmian
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

hm_err() { echo "ERR: $*" >&2; }
hm_ok() { :; }
hm_info() { :; }
hm_warn() { echo "WARN: $*"; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }

# shellcheck disable=SC1091
source "${ROOT}/commands/access/ssh.sh"

fail=0
ME="$(whoami)"
assert_fail() {
  local label="$1"; shift
  if "$@"; then echo "FAIL expected deny: ${label}"; fail=1; else echo "OK   deny: ${label}"; fi
}
assert_ok() {
  local label="$1"; shift
  if "$@"; then echo "OK   ${label}"; else echo "FAIL ${label}"; fail=1; fi
}
assert_eq() {
  local label="$1" got="$2" want="$3"
  if [[ "${got}" == "${want}" ]]; then echo "OK   ${label}"; else echo "FAIL ${label}: got='${got}' want='${want}'"; fail=1; fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hmtools-ssh-symlink.XXXXXX")"
HOME_U="${TMP}/home/blog"
ROOT_SSH="${TMP}/root/.ssh"
mkdir -p "${HOME_U}/.ssh" "${ROOT_SSH}"
printf 'root-key-original\n' > "${ROOT_SSH}/authorized_keys"
chmod 600 "${ROOT_SSH}/authorized_keys"
ORIG="$(cat "${ROOT_SSH}/authorized_keys")"

hm_access_unix_home() { printf '%s' "${HOME_U}"; }

assert_fail "path outside home" hm_access_ssh_path_ok "${ME}" "${HOME_U}" "/etc/hosts"
assert_ok "safe .ssh dir" hm_access_ssh_path_ok "${ME}" "${HOME_U}" "${HOME_U}/.ssh"

# Symlinki — tylko gdy OS naprawdę tworzy -L
if ln -sfn "${ROOT_SSH}/authorized_keys" "${HOME_U}/.ssh/authorized_keys" 2>/dev/null \
  && [[ -L "${HOME_U}/.ssh/authorized_keys" ]]; then
  assert_fail "symlink authorized_keys" hm_access_ssh_path_ok "${ME}" "${HOME_U}" "${HOME_U}/.ssh/authorized_keys"
  assert_fail "ensure_dir symlink file" hm_access_ssh_keys_ensure_dir "${ME}"
  assert_eq "target unchanged after file symlink" "$(cat "${ROOT_SSH}/authorized_keys")" "${ORIG}"
  rm -f "${HOME_U}/.ssh/authorized_keys"

  rmdir "${HOME_U}/.ssh" 2>/dev/null || rm -rf "${HOME_U}/.ssh"
  ln -sfn "${ROOT_SSH}" "${HOME_U}/.ssh"
  if [[ -L "${HOME_U}/.ssh" ]]; then
    assert_fail "ensure_dir symlink .ssh" hm_access_ssh_keys_ensure_dir "${ME}"
    assert_eq "target unchanged after dir symlink" "$(cat "${ROOT_SSH}/authorized_keys")" "${ORIG}"
  else
    echo "SKIP dir symlink (OS)"
  fi
  rm -rf "${HOME_U}/.ssh"
  mkdir -p "${HOME_U}/.ssh"
else
  echo "SKIP file symlink tests (OS nie tworzy prawdziwych symlinków)"
  rm -f "${HOME_U}/.ssh/authorized_keys"
fi

# ensure_dir na czystym katalogu (bez symlinków) — nie wymaga roota przy install -o jeśli jesteśmy ME
# install -o otheruser fails without root; używamy ME
keysf="$(hm_access_ssh_keys_ensure_dir "${ME}" 2>/dev/null || true)"
if [[ -n "${keysf}" && -f "${keysf}" && ! -L "${keysf}" ]]; then
  echo "OK   ensure_dir creates regular authorized_keys"
else
  # bez uprawnień do chown/install -o — akceptuj odmowę owner check na istniejącym pustym
  echo "WARN ensure_dir skipped/partial (brak uprawnień install -o?) keysf=${keysf:--}"
fi

assert_eq "root keys never modified" "$(cat "${ROOT_SSH}/authorized_keys")" "${ORIG}"

rm -rf "${TMP}"

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
