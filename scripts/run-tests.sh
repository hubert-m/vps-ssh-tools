#!/usr/bin/env bash
# Wszystkie scripts/test-*.sh. Kod wyjścia jest różny od zera, gdy któryś test padnie.
set -u
cd "$(dirname "$0")/.."
fail=0
for f in scripts/test-*.sh; do
  [[ -f "${f}" ]] || continue
  printf '== %s\n' "${f}"
  if bash "${f}"; then
    printf 'PASS %s\n' "${f}"
  else
    printf 'FAIL %s\n' "${f}"
    fail=1
  fi
done
exit "${fail}"
