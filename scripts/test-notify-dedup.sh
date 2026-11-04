#!/usr/bin/env bash
# Regresja: walidacja email/webhook, dedup 24h, recovery, JSON escape w payload
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*" >&2; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }
hm_mktemp() { mktemp "${TMPDIR:-/tmp}/hm.XXXXXX${1:-}"; }
hm_file_log() { :; }
hm_load_config() { :; }
hm_json_escape_str() {
  local s="${1:-}"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"
  printf '%s' "${s}"
}
C_BOLD=""; C_RESET=""

fail=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
export NOTIFY_STATE_DIR="${tmpdir}/notify"
export NOTIFY_DEDUP_HOURS=24
export NOTIFY_EMAIL="admin@example.com"
export NOTIFY_WEBHOOK_URL=""

# shellcheck disable=SC1091
source lib/notify.sh

# --- validation ---
if hm_notify_is_valid_email "admin@example.com"; then echo "OK   email-ok"; else echo "FAIL email-ok"; fail=1; fi
if hm_notify_is_valid_email "bad"; then echo "FAIL email-bad"; fail=1; else echo "OK   email-bad"; fi
if hm_notify_is_valid_webhook "https://hooks.slack.com/services/XXX"; then echo "OK   wh-https"; else echo "FAIL wh-https"; fail=1; fi
if hm_notify_is_valid_webhook "http://localhost:8080/hook"; then echo "OK   wh-local"; else echo "FAIL wh-local"; fail=1; fi
if hm_notify_is_valid_webhook "http://evil.com/x"; then echo "FAIL wh-http-remote"; fail=1; else echo "OK   wh-http-remote-deny"; fi
if hm_notify_is_valid_webhook 'https://x.com/`id`'; then echo "FAIL wh-meta"; fail=1; else echo "OK   wh-meta-deny"; fi

# --- gate dedup ---
# mock send to always succeed without network
hm_notify_send_email() { return 0; }
hm_notify_send_webhook() { return 0; }

if hm_notify_gate "backup.full" "error"; then echo "OK   gate-first"; else echo "FAIL gate-first"; fail=1; fi
hm_notify_mark "backup.full" "error"
if hm_notify_gate "backup.full" "error"; then echo "FAIL gate-dedup"; fail=1; else echo "OK   gate-dedup"; fi
# recovery
if hm_notify_gate "backup.full" "ok"; then echo "OK   gate-recovery"; else echo "FAIL gate-recovery"; fail=1; fi
hm_notify_mark "backup.full" "ok"
if hm_notify_gate "backup.full" "ok"; then echo "FAIL gate-ok-no-pending"; fail=1; else echo "OK   gate-ok-no-pending"; fi

# full hm_notify twice
rm -f "${NOTIFY_STATE_DIR}"/*.state
hm_notify error "t1" "body" "t.type" || true
if hm_notify error "t1" "body" "t.type"; then
  # second should skip (return 0) but not re-mark as new send — gate returns 1 → function returns 0 early
  echo "OK   notify-second-dedup-rc"
else
  echo "FAIL notify-second"
  fail=1
fi
# state still present
if [[ -n "$(find "${NOTIFY_STATE_DIR}" -name '*.state' 2>/dev/null)" ]]; then
  echo "OK   state-kept"
else
  echo "FAIL state-kept"
  fail=1
fi

# recovery clears
hm_notify ok "fixed" "body" "t.type" || true
if [[ -z "$(find "${NOTIFY_STATE_DIR}" -name '*.state' 2>/dev/null)" ]]; then
  echo "OK   recovery-clears"
else
  echo "FAIL recovery-clears"
  fail=1
fi

# webhook path never logs URL — check function source doesn't hm_file_log the url var expanded badly
if grep -n 'NOTIFY_WEBHOOK_URL' lib/notify.sh | grep -v 'redacted\|walid\|VALID\|configured\|status\|is_valid\|local url' | grep -q 'hm_file_log.*NOTIFY_WEBHOOK'; then
  echo "FAIL webhook-in-log"
  fail=1
else
  echo "OK   webhook-not-logged"
fi

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL OK"
exit 0
