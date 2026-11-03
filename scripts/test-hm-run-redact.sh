#!/usr/bin/env bash
# Regresja: hm_run_cmd_redacted maskuje --password / --pass / -p
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# minimalne stuby logowania
hm_file_log() { :; }
hm_log_stream_to_file() { cat >/dev/null; }
hm_ui_tty_fd() { return 1; }
C_CYAN=""; C_DIM=""; C_RESET=""
LOG_RUN_MAX_LINES=400
TMP_DIR="${TMPDIR:-/tmp}"

# shellcheck disable=SC1091
source "${ROOT}/lib/logging.sh"

fail=0
got="$(hm_run_cmd_redacted cyberpanel createFTPAccount --domainName shop.pl --userName u1 --password 'SecretPass123!' --path /public_html)"
if [[ "${got}" == *'SecretPass123!'* ]]; then
  echo "FAIL hasło nadal w zredagowanym argv: ${got}"
  fail=1
elif [[ "${got}" == *'--password ***'* ]]; then
  echo "OK   --password zredagowane"
else
  echo "FAIL oczekiwano --password ***: ${got}"
  fail=1
fi

got2="$(hm_run_cmd_redacted tool --password=InlineSecret --other x)"
if [[ "${got2}" == *'InlineSecret'* ]]; then
  echo "FAIL --password= nadal widoczne: ${got2}"
  fail=1
elif [[ "${got2}" == *'--password=***'* ]]; then
  echo "OK   --password=VALUE zredagowane"
else
  echo "FAIL format --password=***: ${got2}"
  fail=1
fi

got3="$(hm_run_cmd_redacted echo hello)"
if [[ "${got3}" == "echo hello" ]]; then
  echo "OK   bez sekretów bez zmian"
else
  echo "FAIL niespodziewana redakcja: ${got3}"
  fail=1
fi

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
