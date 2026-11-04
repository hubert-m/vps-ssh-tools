#!/usr/bin/env bash
# Regresja: hm_ensure_secure_tmpdir — symlink / other-writable / cleanup
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
trap 'hm_secure_tmpdir_cleanup 2>/dev/null || true; rm -rf "${base}"' EXIT

# reset stanu izolacji między przypadkami
_reset_iso() {
  hm_secure_tmpdir_cleanup 2>/dev/null || true
  HM_SECURE_TMP_ISOLATED=""
  HM_SECURE_TMP_CLEANUP_DIRS=()
  # nie resetuj TRAP_SET — jeden EXIT trap na skrypt OK
}

# --- helper other-writable ---
hm_fs_mode_other_writable "1777" && echo "OK   helper-1777" || { echo "FAIL helper-1777"; fail=1; }
hm_fs_mode_other_writable "0777" && echo "OK   helper-0777" || { echo "FAIL helper-0777"; fail=1; }
hm_fs_mode_other_writable "0700" && { echo "FAIL helper-0700"; fail=1; } || echo "OK   helper-0700-no"
hm_fs_mode_other_writable "0755" && { echo "FAIL helper-0755"; fail=1; } || echo "OK   helper-0755-no"

# --- world-writable: fallback BEZ chmod oryginału ---
ww="${base}/world"
mkdir -p "${ww}"
chmod 0777 "${ww}" 2>/dev/null || true
ww_mode="$(stat -c '%a' "${ww}" 2>/dev/null || echo 0)"
if hm_fs_mode_other_writable "${ww_mode}"; then
  _reset_iso
  TMP_DIR="${ww}"
  hm_ensure_secure_tmpdir
  assert_ne "world-writable-rejected" "${TMP_DIR}" "${ww}"
  after="$(stat -c '%a' "${ww}" 2>/dev/null || echo 0)"
  assert_eq "world-writable-no-chmod" "${after}" "${ww_mode}"
  owner="$(stat -c '%u' "${TMP_DIR}")"
  assert_eq "ww-fallback-owner" "${owner}" "$(id -u)"
else
  echo "OK   world-writable-skip (chmod 0777 nieskuteczny: ${ww_mode})"
fi

# --- 1777 sticky (jak /tmp): też fallback, bez chmod ---
st="${base}/sticky"
mkdir -p "${st}"
chmod 1777 "${st}" 2>/dev/null || true
st_mode="$(stat -c '%a' "${st}" 2>/dev/null || echo 0)"
if hm_fs_mode_other_writable "${st_mode}"; then
  _reset_iso
  TMP_DIR="${st}"
  hm_ensure_secure_tmpdir
  assert_ne "sticky-1777-rejected" "${TMP_DIR}" "${st}"
  after="$(stat -c '%a' "${st}" 2>/dev/null || echo 0)"
  assert_eq "sticky-1777-no-chmod" "${after}" "${st_mode}"
else
  echo "OK   sticky-1777-skip (chmod 1777 nieskuteczny: ${st_mode})"
fi

# --- symlink ---
evil="${base}/evil-link"
mkdir -p "${base}/attacker"
ln -sfn "${base}/attacker" "${evil}"
if [[ -L "${evil}" ]]; then
  _reset_iso
  TMP_DIR="${evil}"
  hm_ensure_secure_tmpdir
  assert_ne "symlink-rejected" "${TMP_DIR}" "${evil}"
  [[ ! -L "${TMP_DIR}" ]] && echo "OK   fallback-not-link" || { echo "FAIL fallback-still-link"; fail=1; }
else
  echo "OK   symlink-skip ([[ -L ]] nieskuteczne na tym FS)"
fi

# --- niedirectory ---
_reset_iso
notdir="${base}/not-a-dir"
echo x > "${notdir}"
TMP_DIR="${notdir}"
hm_ensure_secure_tmpdir
assert_ne "nondir-rejected" "${TMP_DIR}" "${notdir}"

# --- reuse + cleanup izolowanego (wymaga other-writable FS albo symlink) ---
_reset_iso
# wymuś fallback przez symlink na katalog (gdy -L działa) albo plik-notdir już dał izolowany
force_fb="${base}/force-fallback-link"
mkdir -p "${base}/force-tgt"
if ln -sfn "${base}/force-tgt" "${force_fb}" 2>/dev/null && [[ -L "${force_fb}" ]]; then
  TMP_DIR="${force_fb}"
  hm_ensure_secure_tmpdir
  first="${TMP_DIR}"
  case "${first}" in
    /var/lib/hmtools/tmp.*|*/hmtools-safe.*)
      TMP_DIR="${force_fb}"
      hm_ensure_secure_tmpdir
      assert_eq "fallback-reuse" "${TMP_DIR}" "${first}"
      iso="${TMP_DIR}"
      hm_secure_tmpdir_cleanup
      if [[ -d "${iso}" ]]; then
        echo "FAIL cleanup-left-dir ${iso}"
        fail=1
      else
        echo "OK   cleanup-removes-isolated"
      fi
      ;;
    *)
      echo "OK   fallback-reuse-skip (niespodziewana ścieżka: ${first})"
      ;;
  esac
else
  # Windows / FS bez symlinków: bezpośredni fallback (bez command substitution)
  hm_secure_tmpdir_fallback
  first="${TMP_DIR}"
  hm_secure_tmpdir_fallback
  assert_eq "fallback-reuse" "${TMP_DIR}" "${first}"
  iso="${TMP_DIR}"
  hm_secure_tmpdir_cleanup
  if [[ -d "${iso}" ]]; then
    echo "FAIL cleanup-left-dir ${iso}"
    fail=1
  else
    echo "OK   cleanup-removes-isolated"
  fi
fi

# --- legacy path ---
_reset_iso
TMP_DIR="/tmp/hmtools-backup"
hm_ensure_secure_tmpdir
[[ ! -L "${TMP_DIR}" ]] || { echo "FAIL legacy-still-symlink"; fail=1; }
mode="$(stat -c '%a' "${TMP_DIR}")"
if hm_fs_mode_other_writable "${mode}"; then
  echo "FAIL legacy-still-other-writable mode=${mode}"
  fail=1
else
  echo "OK   legacy-not-other-writable (${mode})"
fi
owner="$(stat -c '%u' "${TMP_DIR}")"
assert_eq "legacy-owner" "${owner}" "$(id -u)"

# --- hm_mktemp ---
_reset_iso
safe="$(mktemp -d "${base}/safe.XXXXXX")"
chmod 0700 "${safe}" 2>/dev/null || true
TMP_DIR="${safe}"
f="$(hm_mktemp .cron)"
[[ -f "${f}" ]] && echo "OK   mktemp-file" || { echo "FAIL mktemp-file"; fail=1; }
case "${f}" in
  "${safe}"/*) echo "OK   mktemp-under-tmpdir" ;;
  *) echo "FAIL mktemp-outside"; fail=1 ;;
esac
[[ ! -L "${f}" ]] && echo "OK   mktemp-not-symlink" || { echo "FAIL mktemp-is-symlink"; fail=1; }

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL OK"
exit 0
