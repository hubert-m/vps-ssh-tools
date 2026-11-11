#!/usr/bin/env bash
# Parser releases-index.json: kanał, faza, domyślny LTS.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

# shellcheck disable=SC1091
source lib/site/dotnet.sh
fix="scripts/fixtures/dotnet/releases-index.json"
rows="$(hm_dotnet_index_rows "${fix}")"
printf '%s\n' "${rows}" | grep -q $'8.0\tlts\tactive\t2026-11-10\t8.0.11\t8.0.404' && ok row-lts || bad row-lts
printf '%s\n' "${rows}" | grep -q $'9.0\tsts\tactive\t2026-05-12\t9.0.1\t9.0.102' && ok row-sts || bad row-sts
printf '%s\n' "${rows}" | grep -q $'6.0\tlts\teol\t2024-11-12\t6.0.36\t6.0.428' && ok row-eol || bad row-eol
def="$(hm_dotnet_default_lts "${fix}")"
[[ "${def}" == "8.0" ]] && ok default-lts || bad default-lts

[[ "${fail}" -eq 0 ]] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
