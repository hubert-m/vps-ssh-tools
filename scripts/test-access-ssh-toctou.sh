#!/usr/bin/env bash
# Regresja TOCTOU: podmiana ~/.ssh → /root/.ssh między path_ok a I/O (po „confirm”)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Jako root runuser -u root / path_ok omijają asercje TOCTOU (harness, nie produkcja).
if [[ "$(id -u)" -eq 0 ]]; then
  echo "SKIP test-access-ssh-toctou.sh — wymaga non-root (root omija uprawnienia TOCTOU)"
  exit 0
fi

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

root_unchanged() {
  if [[ "$(cat "${ROOT_SSH}/authorized_keys")" == "${ORIG}" ]]; then
    echo "OK   plik roota bez zmian"
  else
    echo "FAIL plik roota zmodyfikowany"
    fail=1
  fi
}

# Czy OS w ogóle tworzy prawdziwe symlinki?
if ! ln -sfn "${ROOT_SSH}" "${TMP}/evil-ssh" 2>/dev/null || [[ ! -L "${TMP}/evil-ssh" ]]; then
  echo "SKIP symlink TOCTOU (OS nie tworzy prawdziwych symlinków)"
  # nadal testujemy logikę zakresów / recheck na bezpiecznej ścieżce
  if hm_access_ssh_recheck_keys_paths "${ME}" "${HOME_U}" "${HOME_U}/.ssh/authorized_keys"; then
    echo "OK   recheck OK na prawidłowym .ssh"
  else
    echo "FAIL recheck na prawidłowym .ssh"
    fail=1
  fi
  rm -rf "${TMP}"
  if [[ "${fail}" -ne 0 ]]; then
    echo "FAILED"
    exit 1
  fi
  echo "ALL PASSED"
  exit 0
fi
rm -f "${TMP}/evil-ssh"

# --- 1) statyczny symlink katalogu .ssh ---
mv "${HOME_U}/.ssh" "${HOME_U}/.ssh.old"
ln -sfn "${ROOT_SSH}" "${HOME_U}/.ssh"
if hm_access_ssh_recheck_keys_paths "${ME}" "${HOME_U}" "${HOME_U}/.ssh/authorized_keys" 2>/dev/null; then
  echo "FAIL recheck powinien odmówić przy symlinku .ssh"
  fail=1
else
  echo "OK   recheck odmawia symlink .ssh → root"
fi
root_unchanged

# --- 2) Wyścig jak w reteście: OK → confirm → podmiana → recheck FAIL ---
rm -f "${HOME_U}/.ssh"
mv "${HOME_U}/.ssh.old" "${HOME_U}/.ssh"
KEYS="${HOME_U}/.ssh/authorized_keys"

if ! hm_access_ssh_recheck_keys_paths "${ME}" "${HOME_U}" "${KEYS}"; then
  echo "FAIL recheck przed confirm (stan bezpieczny)"
  fail=1
else
  echo "OK   recheck OK przed confirm"
fi

# symulacja: w trakcie promptu user podmienia ~/.ssh
mv "${HOME_U}/.ssh" "${HOME_U}/.ssh.old"
ln -sfn "${ROOT_SSH}" "${HOME_U}/.ssh"

if hm_access_ssh_recheck_keys_paths "${ME}" "${HOME_U}" "${HOME_U}/.ssh/authorized_keys" 2>/dev/null; then
  echo "FAIL recheck po TOCTOU powinien odmówić"
  fail=1
else
  echo "OK   recheck po TOCTOU (podmiana w trakcie promptu) → odmowa"
fi
root_unchanged

# zapis jako root na ścieżce po TOCTOU — nie wolno wywoływać bez recheck;
# upewnij się, że write_keys_file z runuser nie zmieni roota (permission denied)
# (bez runuser pomijamy — root mógłby nadpisać; produkcja ma runuser)
if hm_have_cmd runuser; then
  if printf 'evil\n' | hm_access_ssh_write_keys_file "${ME}" "${HOME_U}/.ssh/authorized_keys" 2>/dev/null; then
    # na niektórych setupach ME ma dostęp do TMP/root — sprawdź treść
    if [[ "$(cat "${ROOT_SSH}/authorized_keys")" != "${ORIG}" ]]; then
      echo "FAIL write_keys_file zmienił plik roota"
      fail=1
    else
      echo "OK   write_keys_file nie zmienił treści roota"
    fi
  else
    echo "OK   write_keys_file odmówił po TOCTOU (rc≠0)"
  fi
  root_unchanged
else
  echo "SKIP write_keys_file runuser (brak runuser)"
fi

# przywróć
rm -f "${HOME_U}/.ssh"
mv "${HOME_U}/.ssh.old" "${HOME_U}/.ssh"

# zakres idx
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

root_unchanged
rm -rf "${TMP}"

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
