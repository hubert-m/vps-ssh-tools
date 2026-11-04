#!/usr/bin/env bash
# Regresja: master z child (wspólny vhRoot) → pełny HOME; child → tylko docroot
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

base="$(mktemp -d "${TMPDIR:-/tmp}/hmtools-prefdoc.XXXXXX")"
trap 'rm -rf "${base}"' EXIT
mkdir -p "${base}/alpha.test/public_html/child.alpha.test" \
  "${base}/alpha.test/.ssh" \
  "${base}/alpha.test/app" \
  "${base}/alpha.test/logs"

HM_SITES_LIST=("alpha.test" "child.alpha.test")
hm_discover_sites() { :; }
hm_ols_vhroot_for_domain() {
  case "$1" in
    alpha.test|child.alpha.test) printf '%s\n' "${base}/alpha.test" ;;
    *) return 1 ;;
  esac
}

# shellcheck disable=SC1091
source commands/backup/core.sh

got="$(hm_backup_prefer_docroot_if_shared_home \
  alpha.test "${base}/alpha.test" "${base}/alpha.test/public_html")"
assert_eq "master-full-home" "${got}" "${base}/alpha.test"

got="$(hm_backup_prefer_docroot_if_shared_home \
  child.alpha.test "${base}/alpha.test" "${base}/alpha.test/public_html/child.alpha.test")"
assert_eq "child-docroot-only" "${got}" "${base}/alpha.test/public_html/child.alpha.test"

# solo bez child — pełny root
HM_SITES_LIST=("solo.test")
mkdir -p "${base}/solo.test/public_html"
hm_ols_vhroot_for_domain() {
  [[ "$1" == "solo.test" ]] && printf '%s\n' "${base}/solo.test"
}
got="$(hm_backup_prefer_docroot_if_shared_home \
  solo.test "${base}/solo.test" "${base}/solo.test/public_html")"
assert_eq "solo-full-home" "${got}" "${base}/solo.test"

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL OK"
exit 0
