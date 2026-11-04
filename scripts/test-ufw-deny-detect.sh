#!/usr/bin/env bash
# Test: pełny DENY Anywhere przed ALLOW vs za ALLOW / port-only — bez żywego ufw
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
assert_yes() {
  local label="$1" ip="$2" sample="$3"
  if printf '%s\n' "${sample}" | _hm_os_ufw_parse_has_full_deny "${ip}"; then
    echo "OK   yes: ${label}"
  else
    echo "FAIL expected full deny: ${label}"
    fail=1
  fi
}
assert_no() {
  local label="$1" ip="$2" sample="$3"
  if printf '%s\n' "${sample}" | _hm_os_ufw_parse_has_full_deny "${ip}"; then
    echo "FAIL expected NO full deny: ${label}"
    fail=1
  else
    echo "OK   no:  ${label}"
  fi
}

# DENY przed pierwszym ALLOW = skuteczny ban
SAMPLE_FULL='Status: active

To                         Action      From
--                         ------      ----
Anywhere                   DENY        10.99.0.45
22/tcp                     ALLOW       Anywhere
80/tcp                     ALLOW       Anywhere
Anywhere (v6)              DENY        fd00::2
22/tcp (v6)                ALLOW       Anywhere (v6)'

assert_yes "Anywhere DENY v4 przed ALLOW" "10.99.0.45" "${SAMPLE_FULL}"
assert_yes "Anywhere (v6) DENY przed ALLOW v6" "fd00::2" "${SAMPLE_FULL}"
assert_no  "other IP" "10.99.0.4" "${SAMPLE_FULL}"

# DENY za ALLOW = nieskuteczny (ufw first-match) — nie uznawać za ban
SAMPLE_AFTER='Status: active

To                         Action      From
--                         ------      ----
22/tcp                     ALLOW       Anywhere
80/tcp                     ALLOW       Anywhere
443/tcp                    ALLOW       Anywhere
Anywhere                   DENY        10.99.0.2
22/tcp (v6)                ALLOW       Anywhere (v6)
80/tcp (v6)                ALLOW       Anywhere (v6)
Anywhere (v6)              DENY        fd00::99'

assert_no "DENY v4 za ALLOW (append)" "10.99.0.2" "${SAMPLE_AFTER}"
assert_no "DENY v6 za ALLOW v6" "fd00::99" "${SAMPLE_AFTER}"

SAMPLE_PORT='To                         Action      From
--                         ------      ----
22/tcp                     ALLOW       Anywhere
80                         DENY        10.99.0.45
[ 3] 443/tcp               DENY IN     10.99.0.45'

assert_no "port 80 DENY only" "10.99.0.45" "${SAMPLE_PORT}"
assert_no "port 443 DENY IN" "10.99.0.45" "${SAMPLE_PORT}"

SAMPLE_NUM='[ 1] Anywhere                   DENY IN     10.99.0.2
[ 2] 22/tcp                     ALLOW IN    Anywhere
[ 3] Anywhere                   ALLOW IN    10.99.0.3'

assert_yes "numbered DENY IN na [1]" "10.99.0.2" "${SAMPLE_NUM}"
assert_no  "ALLOW from IP ≠ ban" "10.99.0.3" "${SAMPLE_NUM}"

SAMPLE_NUM_AFTER='[ 1] 22/tcp                     ALLOW IN    Anywhere
[ 2] 80/tcp                     ALLOW IN    Anywhere
[ 3] 443/tcp                    ALLOW IN    Anywhere
[10] Anywhere                   DENY IN     10.99.0.2'

assert_no "numbered DENY za ALLOW [10]" "10.99.0.2" "${SAMPLE_NUM_AFTER}"

SAMPLE_CIDR='Anywhere                   DENY        10.99.0.45/32
22/tcp                     ALLOW       Anywhere
Anywhere (v6)              DENY        fd00::2/128
22/tcp (v6)                ALLOW       Anywhere (v6)'
assert_yes "DENY /32 przed ALLOW" "10.99.0.45" "${SAMPLE_CIDR}"
assert_yes "DENY /128 przed ALLOW v6" "fd00::2" "${SAMPLE_CIDR}"

# any-full-deny: pozycja nieważna (do usuwania przed prepend)
assert_any_yes() {
  local label="$1" ip="$2" sample="$3"
  if printf '%s\n' "${sample}" | _hm_os_ufw_parse_has_any_full_deny "${ip}"; then
    echo "OK   any-yes: ${label}"
  else
    echo "FAIL expected any full deny: ${label}"
    fail=1
  fi
}
assert_any_yes "DENY za ALLOW nadal any" "10.99.0.2" "${SAMPLE_AFTER}"
assert_any_yes "numbered [10] any" "10.99.0.2" "${SAMPLE_NUM_AFTER}"

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
