#!/usr/bin/env bash
# Uruchamia wszystkie scripts/test-*.sh z timeoutem i podsumowaniem OK/FAIL.
# Użycie: scripts/run-all-tests.sh [--only WZORZEC] [--timeout SEK]
set -u
cd "$(dirname "$0")/.."
only=""
timeout_sec="${HMTOOLS_TEST_TIMEOUT:-120}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)
      only="${2:-}"
      shift 2 || true
      ;;
    --only=*)
      only="${1#*=}"
      shift
      ;;
    --timeout)
      timeout_sec="${2:-120}"
      shift 2 || true
      ;;
    --timeout=*)
      timeout_sec="${1#*=}"
      shift
      ;;
    -h|--help)
      echo "Użycie: scripts/run-all-tests.sh [--only WZORZEC] [--timeout SEK]"
      exit 0
      ;;
    *)
      echo "Nieznana flaga: $1" >&2
      exit 2
      ;;
  esac
done

have_timeout=0
if command -v timeout >/dev/null 2>&1; then
  have_timeout=1
fi

fail=0
ok_n=0
fail_n=0
skip_n=0
declare -a failed=()

for f in scripts/test-*.sh; do
  [[ -f "${f}" ]] || continue
  base="$(basename "${f}")"
  if [[ -n "${only}" && "${base}" != *"${only}"* && "${f}" != *"${only}"* ]]; then
    skip_n=$((skip_n + 1))
    continue
  fi
  printf '== %s\n' "${f}"
  rc=0
  if [[ "${have_timeout}" -eq 1 ]]; then
    timeout --signal=TERM "${timeout_sec}" bash "${f}" || rc=$?
  else
    bash "${f}" || rc=$?
  fi
  if [[ "${rc}" -eq 0 ]]; then
    printf 'PASS %s\n' "${f}"
    ok_n=$((ok_n + 1))
  else
    printf 'FAIL %s (rc=%s)\n' "${f}" "${rc}"
    fail=1
    fail_n=$((fail_n + 1))
    failed+=("${f}")
  fi
done

echo
echo "Podsumowanie: OK=${ok_n} FAIL=${fail_n} SKIP=${skip_n}"
if [[ "${fail_n}" -gt 0 ]]; then
  echo "Nieudane:"
  for f in "${failed[@]}"; do
    printf '  - %s\n' "${f}"
  done
fi
exit "${fail}"
