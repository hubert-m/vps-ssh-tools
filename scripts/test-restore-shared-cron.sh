#!/usr/bin/env bash
# Regresja: restore child/shared NIE nadpisuje crontab mastera
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
# shellcheck disable=SC1091
source lib/common/ui.sh
hm_file_log_ui() { :; }

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

# stubs przed source core
hm_discover_sites() { :; }
hm_tsv_unfield() { printf '%s' "${1:-}"; }
hm_resolve_site_paths() {
  # puste pola jako "-" (jak hm_tsv_field) — bash read zwija same \t
  case "$1" in
    alpha.test) printf 'alpha.test\t/home/alpha.test\t/home/alpha.test/public_html\t-\t-\t?\talpha1|active\n' ;;
    child.alpha.test) printf 'child.alpha.test\t/home/alpha.test\t/home/alpha.test/child.alpha.test\t-\t-\t?\talpha1|active\n' ;;
    solo.test) printf 'solo.test\t/home/solo.test\t/home/solo.test/public_html\t-\t-\t?\tsolo1|active\n' ;;
    *) return 1 ;;
  esac
}

# shellcheck disable=SC1091
source commands/backup/core.sh

HM_SITES_LIST=("alpha.test" "child.alpha.test" "solo.test")

hm_backup_site_user_shared_live alpha1 child.alpha.test && echo "OK   shared-child" || { echo "FAIL shared-child"; fail=1; }
hm_backup_site_user_shared_live alpha1 alpha.test && echo "OK   shared-master" || { echo "FAIL shared-master"; fail=1; }
hm_backup_site_user_shared_live solo1 solo.test && { echo "FAIL solo-should-not-be-shared"; fail=1; } || echo "OK   solo-exclusive"
hm_backup_site_user_shared_live alpha1 nosuch.test && echo "OK   shared-vs-missing-domain" || { echo "FAIL shared-vs-missing"; fail=1; }

# hm_backup_restore_crontab — shared → skip (bez rclone/crontab)
id() { return 0; }
rclone() { return 0; }
crontab() { echo "CRONTAB_CALLED $*"; return 0; }
hm_warn() { printf 'WARN:%s\n' "$*"; }
hm_info() { :; }
hm_ok() { :; }

# shellcheck disable=SC1091
source commands/backup/restore.sh

out="$(hm_backup_restore_crontab remote://x alpha1 child.alpha.test 2>&1 || true)"
case "${out}" in
  *CRONTAB_CALLED*)
    echo "FAIL crontab-shared-skip: crontab was applied: ${out}"
    fail=1
    ;;
  *pomijam*|*współdzielony*|*WARN:*)
    echo "OK   crontab-shared-skip"
    ;;
  *)
    echo "FAIL crontab-shared-skip: unexpected=[${out}]"
    fail=1
    ;;
esac

# exclusive solo — crontab powinno się wykonać (rclone cat stub OK, tmp write)
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hmtools-cron-test.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT
rclone() {
  if [[ "$1" == "cat" ]]; then
    echo "# solo cron"
    return 0
  fi
  return 0
}
out="$(hm_backup_restore_crontab remote://x solo1 solo.test 2>&1 || true)"
case "${out}" in
  *CRONTAB_CALLED*)
    echo "OK   crontab-exclusive-apply"
    ;;
  *)
    echo "FAIL crontab-exclusive-apply: ${out}"
    fail=1
    ;;
esac

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL OK"
exit 0
