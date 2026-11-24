#!/usr/bin/env bash
# Test: dokładne dopasowanie kolumny From przy remove from:IP (bez żywego ufw)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

hm_err() { echo "ERR: $*" >&2; }
hm_ok() { :; }
hm_info() { :; }
hm_warn() { :; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }

# shellcheck disable=SC1091
source "${ROOT}/lib/os/debian.sh"

fail=0

assert_eq() {
  local label="$1" got="$2" want="$3"
  if [[ "${got}" == "${want}" ]]; then
    echo "OK   ${label}"
  else
    echo "FAIL ${label}: got='${got}' want='${want}'"
    fail=1
  fi
}

assert_yes() {
  local label="$1"
  if eval "$2"; then
    echo "OK   yes: ${label}"
  else
    echo "FAIL expected match: ${label}"
    fail=1
  fi
}

assert_no() {
  local label="$1"
  if eval "$2"; then
    echo "FAIL expected NO match: ${label}"
    fail=1
  else
    echo "OK   no:  ${label}"
  fi
}

# Typowy wiersz ufw status numbered (reszta po „[ N] ”)
REST_EXACT='Anywhere                   ALLOW       1.2.3.4                    # hmtools whitelist'
REST_PREFIX='Anywhere                   ALLOW       11.2.3.45                   # hmtools whitelist'
REST_SUFFIX='Anywhere                   ALLOW       1.2.3.40                   # hmtools whitelist'
REST_CIDR='Anywhere                   ALLOW       1.2.3.4/32                 # hmtools whitelist'
REST_V6='Anywhere (v6)              ALLOW       2001:db8::1               # hmtools whitelist'
REST_V6_128='Anywhere (v6)              ALLOW       2001:db8::1/128           # hmtools whitelist'

assert_eq "from exact" "$(_hm_os_ufw_from_field "${REST_EXACT}")" "1.2.3.4"
assert_eq "from prefix-like IP" "$(_hm_os_ufw_from_field "${REST_PREFIX}")" "11.2.3.45"
assert_eq "from suffix-like IP" "$(_hm_os_ufw_from_field "${REST_SUFFIX}")" "1.2.3.40"
assert_eq "from /32" "$(_hm_os_ufw_from_field "${REST_CIDR}")" "1.2.3.4/32"
assert_eq "from v6" "$(_hm_os_ufw_from_field "${REST_V6}")" "2001:db8::1"

assert_yes "exact IP" '_hm_os_ufw_from_matches "1.2.3.4" "1.2.3.4"'
assert_yes "/32 == IP" '_hm_os_ufw_from_matches "1.2.3.4/32" "1.2.3.4"'
assert_yes "/128 == v6" '_hm_os_ufw_from_matches "2001:db8::1/128" "2001:db8::1"'
assert_no  "prefix IP 11.2.3.45" '_hm_os_ufw_from_matches "11.2.3.45" "1.2.3.4"'
assert_no  "suffix IP 1.2.3.40" '_hm_os_ufw_from_matches "1.2.3.40" "1.2.3.4"'
assert_no  "other host" '_hm_os_ufw_from_matches "1.2.3.5" "1.2.3.4"'

# Symulacja: needle 1.2.3.4 nie może trafić w 11.2.3.45 ani 1.2.3.40
needle="1.2.3.4"
for rest in "${REST_PREFIX}" "${REST_SUFFIX}"; do
  from="$(_hm_os_ufw_from_field "${rest}")"
  if _hm_os_ufw_from_matches "${from}" "${needle}"; then
    echo "FAIL substring false-positive: from=${from}"
    fail=1
  else
    echo "OK   no false-positive: ${from}"
  fi
done
for rest in "${REST_EXACT}" "${REST_CIDR}"; do
  from="$(_hm_os_ufw_from_field "${rest}")"
  if _hm_os_ufw_from_matches "${from}" "${needle}"; then
    echo "OK   true-positive: ${from}"
  else
    echo "FAIL missed true match: from=${from}"
    fail=1
  fi
done

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL OK"
exit 0
