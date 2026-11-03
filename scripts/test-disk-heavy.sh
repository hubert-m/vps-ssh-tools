#!/usr/bin/env bash
# Regresja: hm_disk_top_entries + heavy walk (małe drzewo w TMP)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

hm_err() { echo "ERR: $*" >&2; }
hm_ok() { :; }
hm_info() { :; }
hm_warn() { :; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }
hm_status_line() { :; }
hm_status_clear() { :; }
C_BOLD=""; C_RESET=""; C_DIM=""

# shellcheck disable=SC1091
# źródłujemy funkcje przez wycięcie — main rejestruje komendę; ładujemy ręcznie
# Najprościej: source z stubem _hm_cmd_*
_hm_cmd_help() { :; }
_hm_cmd_register() { :; }
# shellcheck disable=SC1091
source "${ROOT}/commands/disk/main.sh"

fail=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hmtools-disk-heavy.XXXXXX")"
mkdir -p "${TMP}/a/sub" "${TMP}/b" "${TMP}/c"
# rozmiary: a największy (3 pliki), b średni, c mały
dd if=/dev/zero of="${TMP}/a/big1" bs=1024 count=30 status=none 2>/dev/null || \
  head -c 30720 /dev/zero > "${TMP}/a/big1"
dd if=/dev/zero of="${TMP}/a/big2" bs=1024 count=20 status=none 2>/dev/null || \
  head -c 20480 /dev/zero > "${TMP}/a/big2"
dd if=/dev/zero of="${TMP}/a/sub/x" bs=1024 count=10 status=none 2>/dev/null || \
  head -c 10240 /dev/zero > "${TMP}/a/sub/x"
dd if=/dev/zero of="${TMP}/b/m" bs=1024 count=15 status=none 2>/dev/null || \
  head -c 15360 /dev/zero > "${TMP}/b/m"
echo small > "${TMP}/c/s"

# top 2 w TMP — oczekujemy a i b (lub a i plik)
mapfile -t tops < <(hm_disk_top_entries "${TMP}" 2)
if [[ "${#tops[@]}" -ge 1 && "${tops[0]}" == *$'\t'*/a ]]; then
  echo "OK   top1 = …/a"
else
  echo "FAIL top1 expected …/a got='${tops[0]:-}'"
  fail=1
fi
if [[ "${#tops[@]}" -ge 2 ]]; then
  echo "OK   top2 obecny (${tops[1]%%$'\t'*})"
else
  echo "FAIL brak top2"
  fail=1
fi

# walk count=2 deep=2 nie powinien crashować
out="$(hm_disk_heavy_walk "${TMP}" 2 2 1 2>&1 || true)"
if [[ -n "${out}" ]]; then
  echo "OK   heavy_walk wygenerował output"
else
  echo "FAIL heavy_walk pusty"
  fail=1
fi
if printf '%s' "${out}" | grep -q '/a'; then
  echo "OK   walk zawiera /a"
else
  echo "FAIL walk bez /a: ${out}"
  fail=1
fi

# human size
h="$(hm_disk_human_size 1024)"
if [[ -n "${h}" ]]; then
  echo "OK   human_size(1024)=${h}"
else
  echo "FAIL human_size"
  fail=1
fi

rm -rf "${TMP}"

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
