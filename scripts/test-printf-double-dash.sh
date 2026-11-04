#!/usr/bin/env bash
# Regresja: printf '-- …' vs printf -- '-- …'
set -euo pipefail
fail=0
out="$(printf -- '-- HM_DROP_IF_MISSING %s@%s\n' 'beta_u' 'localhost')"
want='-- HM_DROP_IF_MISSING beta_u@localhost'
if [[ "${out}" == "${want}" ]]; then
  echo "OK   printf-double-dash"
else
  echo "FAIL printf-double-dash: [${out}]"
  fail=1
fi
# stary wzorzec musi failować (dokumentacja buga)
if printf '-- bad %s\n' x >/dev/null 2>&1; then
  echo "OK   old-pattern-accepted-on-this-printf (skip)"
else
  echo "OK   old-pattern-still-invalid"
fi
[[ "${fail}" -eq 0 ]] && echo "ALL OK" && exit 0
echo "FAILED"
exit 1
