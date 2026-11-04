#!/usr/bin/env bash
# Regresja: hm_ensure_secure_tmpdir odrzuca cudzy/symlink TMP_DIR
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
# shellcheck disable=SC1091
source lib/common/ui.sh
hm_file_log_ui() { :; }
# shellcheck disable=SC1091
source lib/common/config.sh

fail=0
assert_eq() {
  local name="$1" got="$2" want="$3"
  if [[ "${got}" != "${want}" ]]; then
    echo "FAIL ${name}: got=[${got}] want=[${want}]"
    fail=1
    return
  fi
  echo "OK   ${name}"
}
assert_ne() {
  local name="$1" got="$2" bad="$3"
  if [[ "${got}" == "${bad}" ]]; then
    echo "FAIL ${name}: got unexpected [${got}]"
    fail=1
    return
  fi
  echo "OK   ${name}"
}

base="$(mktemp -d "${TMPDIR:-/tmp}/hmtools-tdtest.XXXXXX")"
trap 'rm -rf "${base}"' EXIT

# --- symlink TMP_DIR → fallback ---
evil="${base}/evil-link"
mkdir -p "${base}/attacker"
chmod 0777 "${base}/attacker" 2>/dev/null || true
ln -sfn "${base}/attacker" "${evil}"
# world-writable katalog (symulacja ataku w /tmp) — wymaga FS z POSIX mode
ww="${base}/world"
mkdir -p "${ww}"
chmod 0777 "${ww}" 2>/dev/null || true
ww_mode="$(stat -c '%a' "${ww}" 2>/dev/null || echo 0)"
if [[ "${ww_mode}" == *7 || "${ww_mode}" == "777" || "${ww_mode}" == "0777" ]]; then
  TMP_DIR="${ww}"
  hm_ensure_secure_tmpdir
  assert_ne "world-writable-rejected" "${TMP_DIR}" "${ww}"
  owner="$(stat -c '%u' "${TMP_DIR}")"
  assert_eq "ww-fallback-owner" "${owner}" "$(id -u)"
  rm -rf "${TMP_DIR}" 2>/dev/null || true
else
  echo "OK   world-writable-skip (chmod 0777 nieskuteczny na tym FS: ${ww_mode})"
fi

# symlink — tylko gdy [[ -L ]] działa (Linux); na Git Bash/Windows często nie
if [[ -L "${evil}" ]]; then
  TMP_DIR="${evil}"
  hm_ensure_secure_tmpdir
  assert_ne "symlink-rejected" "${TMP_DIR}" "${evil}"
  [[ ! -L "${TMP_DIR}" ]] && echo "OK   fallback-not-link" || { echo "FAIL fallback-still-link"; fail=1; }
  owner="$(stat -c '%u' "${TMP_DIR}")"
  assert_eq "symlink-fallback-owner" "${owner}" "$(id -u)"
  rm -rf "${TMP_DIR}" 2>/dev/null || true
else
  echo "OK   symlink-skip ([[ -L ]] nieskuteczne na tym FS)"
fi

# --- cudzy właściciel (symulacja: katalog 0777 — chmod 0700 się uda u nas;
#     wymuszamy fail przez plik zamiast katalogu) ---
notdir="${base}/not-a-dir"
echo x > "${notdir}"
TMP_DIR="${notdir}"
hm_ensure_secure_tmpdir
assert_ne "nondir-rejected" "${TMP_DIR}" "${notdir}"
rm -rf "${TMP_DIR}" 2>/dev/null || true

# --- legacy /tmp/hmtools-backup → nie zostaje na world-writable bez walidacji ---
TMP_DIR="/tmp/hmtools-backup"
hm_ensure_secure_tmpdir
# albo bezpieczny /var/lib/... albo izolowany fallback — nigdy nieufny symlink
[[ ! -L "${TMP_DIR}" ]] || { echo "FAIL legacy-still-symlink"; fail=1; }
mode="$(stat -c '%a' "${TMP_DIR}")"
# nie world-writable
case "${mode}" in
  *7|777|0777) echo "FAIL legacy-still-world-writable mode=${mode}"; fail=1 ;;
  *) echo "OK   legacy-not-world-writable (${mode})" ;;
esac
owner="$(stat -c '%u' "${TMP_DIR}")"
assert_eq "legacy-owner" "${owner}" "$(id -u)"
# nie sprzątaj /var/lib jeśli to domyślny — tylko izolowane
case "${TMP_DIR}" in
  */hmtools-safe.*|/var/lib/hmtools/tmp.*) rm -rf "${TMP_DIR}" 2>/dev/null || true ;;
esac

# --- hm_mktemp tworzy plik w TMP_DIR ---
safe="$(mktemp -d "${base}/safe.XXXXXX")"
chmod 0700 "${safe}"
TMP_DIR="${safe}"
f="$(hm_mktemp .cron)"
[[ -f "${f}" ]] && echo "OK   mktemp-file" || { echo "FAIL mktemp-file"; fail=1; }
case "${f}" in
  "${safe}"/*) echo "OK   mktemp-under-tmpdir" ;;
  *) echo "FAIL mktemp-outside"; fail=1 ;;
esac
# plik nie jest symlinkiem
[[ ! -L "${f}" ]] && echo "OK   mktemp-not-symlink" || { echo "FAIL mktemp-is-symlink"; fail=1; }

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL OK"
exit 0
