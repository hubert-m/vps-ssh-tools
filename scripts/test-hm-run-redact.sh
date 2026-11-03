#!/usr/bin/env bash
# Regresja: hm_run_cmd_redacted + hm_run nie loguje hasła (--password)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

hm_log_stream_to_file() { cat >/dev/null; }
hm_ui_tty_fd() { return 1; }
C_CYAN=""; C_DIM=""; C_RESET=""
LOG_RUN_MAX_LINES=400
TMP_DIR="${TMPDIR:-/tmp}"

# shellcheck disable=SC1091
source "${ROOT}/lib/logging.sh"

# po source — przechwyt logu (logging.sh definiuje własne hm_file_log)
CAPTURE=""
hm_file_log() { CAPTURE+="${2:-}"$'\n'; }

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

# Pełna ścieżka hm_run → RUN/RUN_END (jak ftp add CyberPanel)
BINDIR="$(mktemp -d "${TMPDIR:-/tmp}/hmtools-redact-bin.XXXXXX")"
cat > "${BINDIR}/cyberpanel" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${BINDIR}/cyberpanel"
PASS='AZt4FtpSecretXYZ!'
CAPTURE=""
PATH="${BINDIR}:${PATH}" hm_run cyberpanel createFTPAccount \
  --domainName shop.pl --userName u1 --password "${PASS}" --path /public_html >/dev/null 2>&1 || true

hits="$(printf '%s' "${CAPTURE}" | grep -cF "${PASS}" || true)"
if [[ "${hits}" -eq 0 ]] && printf '%s' "${CAPTURE}" | grep -q 'RUN:.*--password \*\*\*'; then
  echo "OK   hm_run log bez hasła (RUN z --password ***)"
elif [[ "${hits}" -eq 0 ]] && printf '%s' "${CAPTURE}" | grep -q 'password'; then
  echo "OK   hm_run log bez hasła (0 trafień Secret)"
else
  echo "FAIL hm_run log wyciek hasła (hits=${hits}):"
  printf '%s\n' "${CAPTURE}"
  fail=1
fi
if printf '%s' "${CAPTURE}" | grep -q 'RUN_END:.*--password \*\*\*'; then
  echo "OK   RUN_END też zredagowany"
else
  # akceptuj brak dokładnego *** jeśli format inny, byle bez PASS
  if [[ "${hits}" -eq 0 ]]; then
    echo "OK   RUN_END bez plaintext hasła"
  else
    echo "FAIL RUN_END"
    fail=1
  fi
fi
rm -rf "${BINDIR}"

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
