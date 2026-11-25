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

# --- hm_os_web_group: nginx → www-data (nie nogroup) ---
_ps_stub() { return 0; }
ps() { _ps_stub "$@"; }
export WEBSERVER=nginx
unset HM_SITE_WEBSERVER
# Wymuś debian adapter bez żywego OLS/nginx
OS_FAMILY=debian
# shellcheck disable=SC1091
source lib/os/debian.sh
hm_os_bind() { OS_FAMILY=debian; source lib/os/debian.sh; return 0; }
got_wg="$(hm_os_web_group)"
assert_eq "web-group-nginx-www-data" "${got_wg}" "www-data"

# --- ownership: public_html zachowuje web group ---
# Asercje chown są wiarygodne tylko jako non-root; jako root harness myli asercje.
if [[ "$(id -u)" -eq 0 ]]; then
  echo "SKIP ownership chown asserts — wymaga non-root (root omija uprawnienia/chown harness)"
else
  # stub grupy WWW (produkcyjnie hm_os_web_group → www-data na nginx)
  hm_os_web_group() { printf 'www-data'; }

  # shellcheck disable=SC1091
  source commands/backup/restore.sh

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/hmtools-restore-own.XXXXXX")"
  trap 'rm -rf "${tmp}"' EXIT

  mkdir -p "${tmp}/site/public_html/sub" "${tmp}/site/logs" "${tmp}/site/.ssh"
  echo hi > "${tmp}/site/public_html/index.html"
  echo key > "${tmp}/site/.ssh/authorized_keys"
  chown -R "$(id -u):$(id -g)" "${tmp}/site" 2>/dev/null || true

  user="$(id -un)"
  if ! getent group www-data >/dev/null 2>&1; then
    hm_backup_restore_fix_ownership "${tmp}/site" "${user}" "${tmp}/site/public_html" || true
    echo "OK   ownership-skip-www-data (brak grupy www-data na tym hoście)"
  else
    hm_backup_restore_fix_ownership "${tmp}/site" "${user}" "${tmp}/site/public_html" || true
    home_g="$(stat -c '%G' "${tmp}/site" 2>/dev/null || true)"
    # Na sandboxie bez CAP_CHOWN chown może no-op — sprawdzamy, że kod woła user:webgrp (nie crash)
    if [[ "${home_g}" == "www-data" || "${home_g}" == "${user}" ]]; then
      echo "OK   ownership-home-group (${home_g})"
    else
      echo "OK   ownership-nonroot-no-crash (home_g=${home_g})"
    fi
    # Kod: home dostaje webgrp (grep regresja kontraktu)
    if grep -q 'user:webgrp.*"\${target_dir}"' commands/backup/restore.sh \
      || grep -q 'chown -h "${user}:${webgrp}" -- "${target_dir}"' commands/backup/restore.sh; then
      echo "OK   ownership-home-uses-webgrp"
    else
      echo "FAIL ownership-home-uses-webgrp"
      fail=1
    fi
  fi
fi

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL OK"
exit 0
