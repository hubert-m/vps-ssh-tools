#!/usr/bin/env bash
# Wspólne stuby dla scripts/test-*.sh — ładuj po ustawieniu HMTOOLS_ROOT.
# Nie nadpisuje funkcji, jeśli test już je zdefiniował.

: "${HMTOOLS_ROOT:?HMTOOLS_ROOT wymagane}"

if ! declare -F hm_file_log_ui >/dev/null 2>&1; then
  hm_file_log_ui() { :; }
fi

if [[ -f "${HMTOOLS_ROOT}/lib/common/ui.sh" ]]; then
  # shellcheck disable=SC1091
  source "${HMTOOLS_ROOT}/lib/common/ui.sh"
fi

if ! declare -F hm_err >/dev/null 2>&1; then
  hm_err() { echo "ERR: $*" >&2; }
fi
if ! declare -F hm_warn >/dev/null 2>&1; then
  hm_warn() { echo "WARN: $*"; }
fi
if ! declare -F hm_ok >/dev/null 2>&1; then
  hm_ok() { echo "OK: $*"; }
fi
if ! declare -F hm_info >/dev/null 2>&1; then
  hm_info() { echo "INFO: $*"; }
fi
if ! declare -F hm_have_cmd >/dev/null 2>&1; then
  hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }
fi
if ! declare -F hm_confirm_plan >/dev/null 2>&1; then
  hm_confirm_plan() { return 0; }
fi
if ! declare -F hm_is_valid_domain >/dev/null 2>&1; then
  hm_is_valid_domain() { [[ "${1:-}" == *.* ]]; }
fi
if ! declare -F hm_is_valid_unix_user >/dev/null 2>&1; then
  hm_is_valid_unix_user() { [[ "${1:-}" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; }
fi
if ! declare -F hm_print_secret >/dev/null 2>&1; then
  hm_print_secret() { :; }
fi
if ! declare -F hm_gen_password >/dev/null 2>&1; then
  hm_gen_password() { printf 'x'; }
fi
if ! declare -F _hm_cmd_help >/dev/null 2>&1; then
  _hm_cmd_help() { cat >/dev/null; }
fi
if ! declare -F _hm_cmd_register >/dev/null 2>&1; then
  _hm_cmd_register() { :; }
fi
if ! declare -F _hm_cmd_register_site >/dev/null 2>&1; then
  _hm_cmd_register_site() { :; }
fi
