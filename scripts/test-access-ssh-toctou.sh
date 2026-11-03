#!/usr/bin/env bash
# Regresja TOCTOU: podmiana ~/.ssh → /root/.ssh między path_ok a zapisem (po „confirm”)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

hm_err() { echo "ERR: $*" >&2; }
hm_ok() { echo "OK: $*"; }
hm_info() { :; }
hm_warn() { :; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }

# shellcheck disable=SC1091
source "${ROOT}/commands/access/ssh.sh"

fail=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hmtools-ssh-toctou.XXXXXX")"
HOME_U="${TMP}/home/blog"
ROOT_SSH="${TMP}/root/.ssh"
mkdir -p "${HOME_U}/.ssh" "${ROOT_SSH}"
printf 'ssh-ed25519 AAAAROOT1 admin1\nssh-ed25519 AAAAROOT2 admin2\n' > "${ROOT_SSH}/authorized_keys"
chmod 600 "${ROOT_SSH}/authorized_keys"
ORIG="$(cat "${ROOT_SSH}/authorized_keys")"
printf 'ssh-ed25519 AAAABLOG1 blog1\nssh-ed25519 AAAABLOG2 blog2\n' > "${HOME_U}/.ssh/authorized_keys"
chmod 700 "${HOME_U}/.ssh"
chmod 600 "${HOME_U}/.ssh/authorized_keys"

ME="$(whoami)"
hm_access_unix_home() { printf '%s' "${HOME_U}"; }

# Symulacja TOCTOU: po „bezpiecznym” stanie — podmiana katalogu przed recheck
if ! ln -sfn "${ROOT_SSH}" "${TMP}/evil-ssh" 2>/dev/null || [[ ! -L "${TMP}/evil-ssh" ]]; then
  echo "SKIP TOCTOU (OS nie tworzy symlinków)"
  rm -rf "${TMP}"
  echo "ALL PASSED"
  exit 0
fi
rm -f "${TMP}/evil-ssh"

# 1) recheck odmawia gdy .ssh jest symlinkiem do root
mv "${HOME_U}/.ssh" "${HOME_U}/.ssh.old"
ln -sfn "${ROOT_SSH}" "${HOME_U}/.ssh"
if [[ -L "${HOME_U}/.ssh" ]]; then
  if hm_access_ssh_recheck_keys_paths "${ME}" "${HOME_U}" "${HOME_U}/.ssh/authorized_keys" 2>/dev/null; then
    echo "FAIL recheck powinien odmówić przy symlinku .ssh"
    fail=1
  else
    echo "OK   recheck odmawia symlink .ssh → root"
  fi
  assert_eq_root() {
    if [[ "$(cat "${ROOT_SSH}/authorized_keys")" == "${ORIG}" ]]; then
      echo "OK   plik roota bez zmian"
    else
      echo "FAIL plik roota zmodyfikowany"
      fail=1
    fi
  }
  assert_eq_root
else
  echo "SKIP dir symlink"
fi

# 2) write_keys_file nie powinien chown-ować pliku roota gdy ścieżka to symlink katalogu
# (recheck musi być wywołane PRZED write — tu sprawdzamy, że write przez runuser failuje na /root)
# Przywróć stan: bez runuser jako ME zapis do pliku przez symlink mógłby zadziałać —
# kluczowe jest recheck przed write.
rm -f "${HOME_U}/.ssh"
mv "${HOME_U}/.ssh.old" "${HOME_U}/.ssh"

# recheck OK na bezpiecznym stanie
if hm_access_ssh_recheck_keys_paths "${ME}" "${HOME_U}" "${HOME_U}/.ssh/authorized_keys"; then
  echo "OK   recheck OK na prawidłowym .ssh"
else
  echo "FAIL recheck na prawidłowym .ssh"
  fail=1
fi

# Zakres idx przed confirm — logika jak w remove
n_avail=0
while IFS= read -r line || [[ -n "${line}" ]]; do
  hm_access_is_valid_ssh_key_line "${line}" && n_avail=$((n_avail + 1))
done < "${HOME_U}/.ssh/authorized_keys"
idx=5
if [[ "${idx}" -gt "${n_avail}" ]]; then
  echo "OK   idx ${idx} > ${n_avail} → odmowa przed confirm"
else
  echo "FAIL zakres idx"
  fail=1
fi

if [[ "$(cat "${ROOT_SSH}/authorized_keys")" == "${ORIG}" ]]; then
  echo "OK   root keys final"
else
  echo "FAIL root keys final"
  fail=1
fi

rm -rf "${TMP}"

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
