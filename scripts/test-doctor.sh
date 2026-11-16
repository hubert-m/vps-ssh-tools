#!/usr/bin/env bash
# doctor: raport + --json, bez zmian w systemie.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"
export HMTOOLS_ROOT="${ROOT}"
export HMTOOLS_TEST=1

# shellcheck disable=SC1091
source scripts/_stubs.sh
# shellcheck disable=SC1091
source commands/doctor/main.sh

fail=0
ok() { echo "OK   $*"; }
bad() { echo "FAIL $*"; fail=1; }

hm_installed_version() { printf 'v0.1.13'; }
hm_latest_remote_version() { printf 'v0.1.13'; }
hm_version_is_newer() { return 1; }
hm_help_topic() { :; }

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
export HMTOOLS_CONF="${tmp}/hmtools.conf"
export HMTOOLS_LOG_DIR="${tmp}/logs"
mkdir -p "${HMTOOLS_LOG_DIR}"
printf 'x=1\n' > "${HMTOOLS_CONF}"
chmod 0600 "${HMTOOLS_CONF}"
chmod 0700 "${HMTOOLS_LOG_DIR}"

out="$(cmd_doctor 2>/dev/null || true)"
printf '%s\n' "${out}" | grep -q 'hmtools doctor' && ok "text-header" || bad "text-header"
printf '%s\n' "${out}" | grep -q 'wersja' && ok "text-version" || bad "text-version"

json="$(cmd_doctor --json 2>/dev/null || true)"
printf '%s\n' "${json}" | python3 -m json.tool >/dev/null && ok "json-parse" || bad "json-parse"
printf '%s\n' "${json}" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["version"]=="v0.1.13"
assert "tools" in d and "curl" in d["tools"]
assert d.get("conf_mode") in ("ok","missing","bad:644","bad:666") or d["conf_mode"].startswith("bad") or d["conf_mode"]=="ok"
' && ok "json-keys" || bad "json-keys"

# doctor nie tworzy/nie kasuje poza odczytem
[[ -f "${HMTOOLS_CONF}" && -d "${HMTOOLS_LOG_DIR}" ]] && ok "no-mutate" || bad "no-mutate"

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
