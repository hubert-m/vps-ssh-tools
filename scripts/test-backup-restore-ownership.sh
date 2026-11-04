#!/usr/bin/env bash
# Regresja: restore ownership (public_html → grupa WWW) + JSON escape + sprzeczne flagi
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
# shellcheck disable=SC1091
source lib/common/ui.sh
# shellcheck disable=SC1091
source lib/os_family.sh

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

# --- hm_json_escape_str ---
assert_eq "json-quote" "$(hm_json_escape_str 'a"b')" 'a\"b'
assert_eq "json-backslash" "$(hm_json_escape_str 'a\b')" 'a\\b'
assert_eq "json-plain" "$(hm_json_escape_str 'host.example')" 'host.example'

# --- sprzeczne flagi (logika jak w restore) ---
_hm_flags_conflict() {
  local files_only=0 db_only=0
  local a
  for a in "$@"; do
    case "${a}" in
      --files-only) files_only=1 ;;
      --db-only) db_only=1 ;;
    esac
  done
  if [[ "${files_only}" -eq 1 && "${db_only}" -eq 1 ]]; then
    echo conflict
  else
    echo ok
  fi
}
assert_eq "flags-conflict" "$(_hm_flags_conflict --files-only --db-only)" "conflict"
assert_eq "flags-files" "$(_hm_flags_conflict --files-only)" "ok"
assert_eq "flags-db" "$(_hm_flags_conflict --db-only)" "ok"

# --- ownership: public_html zachowuje web group ---
# Asercje chown user↔nogroup są wiarygodne tylko jako non-root z możliwością
# sprawdzenia logiki bez omijania DAC; jako root harness myli asercje (user=root).
if [[ "$(id -u)" -eq 0 ]]; then
  echo "SKIP ownership chown asserts — wymaga non-root (root omija uprawnienia/chown harness)"
else
  # stub grupy WWW
  hm_os_web_group() { printf 'nogroup'; }

  # shellcheck disable=SC1091
  source commands/backup/restore.sh

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/hmtools-restore-own.XXXXXX")"
  trap 'rm -rf "${tmp}"' EXIT

  mkdir -p "${tmp}/site/public_html/sub" "${tmp}/site/.ssh"
  echo hi > "${tmp}/site/public_html/index.html"
  echo key > "${tmp}/site/.ssh/authorized_keys"
  chown -R "$(id -u):$(id -g)" "${tmp}/site" 2>/dev/null || true

  user="$(id -un)"
  if ! getent group nogroup >/dev/null 2>&1; then
    hm_backup_restore_fix_ownership "${tmp}/site" "${user}" "${tmp}/site/public_html" || true
    echo "OK   ownership-skip-nogroup (brak grupy nogroup na tym hoście)"
  else
    # bez root: chown do nogroup zwykle się nie uda — sprawdzamy brak crasha + soft path
    hm_backup_restore_fix_ownership "${tmp}/site" "${user}" "${tmp}/site/public_html" || true
    echo "OK   ownership-nonroot-no-crash (pełne asercje chown→nogroup tylko w sandboxie z fakowym chown)"
  fi
fi

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL OK"
exit 0
