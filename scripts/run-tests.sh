#!/usr/bin/env bash
# Alias: deleguje do run-all-tests.sh (timeout, --only, podsumowanie).
exec "$(cd "$(dirname "$0")" && pwd)/run-all-tests.sh" "$@"
