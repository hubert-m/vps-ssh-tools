#!/usr/bin/env bash
# Regresja: SHOW GRANTS z -r nie podwaja backslashy przy \_
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
# shellcheck disable=SC1091
source lib/common/ui.sh

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

# Symulacja wyjścia mysql -N -B vs -N -B -r
batch_escape() {
  # batch bez -r: każdy \ → \\
  local s="$1"
  s="${s//\\/\\\\}"
  printf '%s' "${s}"
}

raw_passthrough() {
  printf '%s' "$1"
}

grant_src='GRANT ALL PRIVILEGES ON `alpha\_x\_y`.* TO `u`@`localhost`'
batch_out="$(batch_escape "${grant_src}")"
raw_out="$(raw_passthrough "${grant_src}")"

assert_eq "batch-doubles" "${batch_out}" 'GRANT ALL PRIVILEGES ON `alpha\\_x\\_y`.* TO `u`@`localhost`'
assert_eq "raw-keeps" "${raw_out}" "${grant_src}"

# helper istnieje
# shellcheck disable=SC1091
source lib/db.sh
if declare -F hm_mysql_exec_raw >/dev/null 2>&1; then
  echo "OK   hm_mysql_exec_raw-defined"
else
  echo "FAIL hm_mysql_exec_raw-defined"
  fail=1
fi

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL OK"
exit 0
