#!/usr/bin/env bash
# Regresja: istniejący MySQL user — GRANT bez IDENTIFIED BY PASSWORD
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

# shellcheck disable=SC1091
source commands/backup/restore.sh

g1="GRANT USAGE ON *.* TO 'beta_u'@'localhost' IDENTIFIED BY PASSWORD '*ABCDEF0123456789';"
out="$(hm_backup_grant_without_identified "${g1}" 2>/dev/null)" && {
  echo "FAIL usage-identified: expected rc=1 (skip), got out=[${out}]"
  fail=1
} || {
  case "${out}" in
    *IDENTIFIED*)
      echo "FAIL usage-identified: still has IDENTIFIED: ${out}"
      fail=1
      ;;
    *GRANT*USAGE*)
      echo "OK   usage-identified-stripped-skip"
      ;;
    *)
      echo "FAIL usage-identified: unexpected=[${out}]"
      fail=1
      ;;
  esac
}

g2="GRANT SELECT, INSERT ON \`beta_db\`.* TO 'beta_u'@'localhost' IDENTIFIED BY PASSWORD '*DEADBEEF';"
if ! out="$(hm_backup_grant_without_identified "${g2}")"; then
  echo "FAIL select-identified: expected rc=0"
  fail=1
fi
case "${out}" in
  *IDENTIFIED*)
    echo "FAIL select-identified: still IDENTIFIED: ${out}"
    fail=1
    ;;
  *GRANT*SELECT*beta_db*beta_u*)
    echo "OK   select-identified-stripped"
    ;;
  *)
    echo "FAIL select-identified: unexpected=[${out}]"
    fail=1
    ;;
esac

g3="GRANT ALL PRIVILEGES ON \`beta_db\`.* TO 'beta_u'@'localhost';"
if ! out="$(hm_backup_grant_without_identified "${g3}")"; then
  echo "FAIL plain-grant: expected rc=0"
  fail=1
fi
assert_eq "plain-grant" "${out}" "${g3}"

g4="GRANT USAGE ON *.* TO 'u'@'%' IDENTIFIED WITH mysql_native_password AS '*HASH';"
out="$(hm_backup_grant_without_identified "${g4}" 2>/dev/null)" && {
  echo "FAIL usage-with: expected rc=1"
  fail=1
} || {
  case "${out}" in
    *IDENTIFIED*)
      echo "FAIL usage-with: still IDENTIFIED"
      fail=1
      ;;
    *)
      echo "OK   usage-with-stripped-skip"
      ;;
  esac
}

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL OK"
exit 0
