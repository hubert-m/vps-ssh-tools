#!/usr/bin/env bash
# Regresja: hm_parse_size_bytes + hm_mysql_heavy (mock SQL)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/common/ui.sh
source "${ROOT}/lib/common/ui.sh"

hm_err() { echo "ERR: $*" >&2; return 1; }
hm_ok() { :; }
hm_info() { :; }
hm_warn() { echo "WARN: $*"; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }
hm_status_line() { :; }
hm_status_clear() { :; }
hm_mysql_cli() { printf 'mysql'; return 0; }
hm_human_size() {
  local b="${1:-0}"
  if [[ "${b}" -ge 1073741824 ]]; then
    awk -v b="${b}" 'BEGIN { printf "%.2f GB", b/1073741824 }'
  elif [[ "${b}" -ge 1048576 ]]; then
    awk -v b="${b}" 'BEGIN { printf "%.2f MB", b/1048576 }'
  else
    printf '%s B' "${b}"
  fi
}
C_BOLD=""; C_RESET=""; C_DIM=""

tmpf="$(mktemp)"
awk '
  /^hm_parse_size_bytes\(\)/ {p=1}
  /^hm_mysql_heavy\(\)/ {p=1}
  p {print}
  p && /^}$/ {p=0}
' "${ROOT}/lib/db.sh" > "${tmpf}"
# shellcheck disable=SC1090
source "${tmpf}"
rm -f "${tmpf}"

fail=0
assert_eq() {
  local label="$1" got="$2" want="$3"
  if [[ "${got}" != "${want}" ]]; then
    echo "FAIL ${label}: got='${got}' want='${want}'"
    fail=1
  else
    echo "OK   ${label}"
  fi
}

b="$(hm_parse_size_bytes 1G)" || b=bad
assert_eq "1G" "${b}" "1073741824"
b="$(hm_parse_size_bytes 1GB)" || b=bad
assert_eq "1GB" "${b}" "1073741824"
b="$(hm_parse_size_bytes 500M)" || b=bad
assert_eq "500M" "${b}" "$((500 * 1024 * 1024))"

hm_mysql_exec() {
  cat <<'EOF'
small_db	t1	100
big_db	huge_table	2000000000
big_db	tiny	1000
EOF
}

out="$(hm_mysql_heavy 1073741824 2>&1 || true)"
if printf '%s\n' "${out}" | grep -q 'big_db'; then
  echo "OK   big_db listed"
else
  echo "FAIL big_db missing in: ${out}"
  fail=1
fi
if printf '%s\n' "${out}" | grep -q 'huge_table'; then
  echo "OK   huge_table listed"
else
  echo "FAIL huge_table missing"
  fail=1
fi
if printf '%s\n' "${out}" | grep -q 'small_db'; then
  echo "FAIL small_db should be filtered"
  fail=1
else
  echo "OK   small_db filtered"
fi
if printf '%s\n' "${out}" | grep -q 'tiny'; then
  echo "FAIL tiny table should be filtered"
  fail=1
else
  echo "OK   tiny filtered"
fi

if grep -q 'mysql heavy' "${ROOT}/commands/mysql/main.sh"; then
  echo "OK   cmd_mysql heavy wired"
else
  echo "FAIL cmd_mysql heavy missing"
  fail=1
fi
if grep -q -- '--mysql' "${ROOT}/commands/disk/main.sh"; then
  echo "FAIL disk nadal ma --mysql"
  fail=1
else
  echo "OK   disk bez --mysql"
fi

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
