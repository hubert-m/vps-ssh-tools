#!/usr/bin/env bash
# Alias: deleguje do run-all-tests.sh (timeout, --only, podsumowanie).
# Wywołanie przez bash — działa też gdy run-all-tests.sh nie ma +x w gicie (100644).
ROOT="$(cd "$(dirname "$0")" && pwd)"
exec bash "${ROOT}/run-all-tests.sh" "$@"
