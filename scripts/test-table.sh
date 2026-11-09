#!/usr/bin/env bash
# Wyrównanie tabeli: długa komórka nie przesuwa kolejnych kolumn, ANSI nie liczy się do szerokości.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/common/ui.sh
source "${ROOT}/lib/common/ui.sh"

fail=0
ok() { echo "OK   $*"; }
bad() { echo "FAIL $*"; fail=1; }

strip_ansi() {
  local s="${1:-}" out=""
  while [[ "${s}" == *$'\033'* ]]; do
    out+="${s%%$'\033'*}"
    s="${s#*$'\033'}"
    if [[ "${s:0:1}" == "[" ]]; then
      s="${s:1}"
      while [[ -n "${s}" && "${s:0:1}" == [0-9\;?] ]]; do
        s="${s:1}"
      done
      [[ -n "${s}" ]] && s="${s:1}"
    fi
  done
  printf '%s' "${out}${s}"
}

col_at() {
  local line="$1" needle="$2" plain
  plain="$(strip_ansi "${line}")"
  local prefix="${plain%%"${needle}"*}"
  if [[ "${plain}" == "${prefix}" ]]; then
    printf '%s' "-1"
    return
  fi
  printf '%s' "${#prefix}"
}

# długa domena — CORE w nagłówku i w wierszu zaczyna się w tej samej kolumnie
hm_table_begin
hm_table_row DOMENA CORE "PLUG↑" "THEME↑" MAINT PHP
hm_table_row "ac-installation-services-example-theme.justhoryzon.pl" "7.1.4" "1" "0" "off" "8.4"
hm_table_row "b2b.jubilleo.pl" "7.1.4" "7" "0" "off" "8.4"
mapfile -t lines < <(hm_table_print 2)
hcol="$(col_at "${lines[0]}" "CORE")"
dcol="$(col_at "${lines[2]}" "7.1.4")"
dcol2="$(col_at "${lines[3]}" "7.1.4")"
[[ "${hcol}" == "${dcol}" && "${dcol}" == "${dcol2}" && "${hcol}" != "-1" ]] \
  && ok "align-core (${hcol})" || bad "align-core header=${hcol} row=${dcol} row2=${dcol2}"

pcol="$(col_at "${lines[0]}" "PHP")"
pcol2="$(col_at "${lines[2]}" "8.4")"
[[ "${pcol}" == "${pcol2}" && "${pcol}" != "-1" ]] && ok "align-php (${pcol})" || bad "align-php ${pcol} vs ${pcol2}"

# ANSI nie poszerza kolumny
hm_table_begin
hm_table_row STATUS NEXT
hm_table_row $'\033[31mOK\033[0m' "X"
mapfile -t lines < <(hm_table_print 2)
hcol="$(col_at "${lines[0]}" "NEXT")"
dcol="$(col_at "${lines[2]}" "X")"
[[ "${hcol}" == "${dcol}" && "${hcol}" != "-1" ]] && ok "align-ansi (${hcol})" || bad "align-ansi ${hcol} vs ${dcol}"
[[ "$(hm_visible_len $'\033[31mOK\033[0m')" == "2" ]] && ok "vis-ansi" || bad "vis-ansi=$(hm_visible_len $'\033[31mOK\033[0m')"
[[ "$(hm_visible_len $'\033[1;31mOK\033[0m')" == "2" ]] && ok "vis-ansi-semi" || bad "vis-ansi-semi=$(hm_visible_len $'\033[1;31mOK\033[0m')"

# wyrównanie do prawej: koniec komórki w tej samej kolumnie
hm_table_begin R
hm_table_row N
hm_table_row 1
hm_table_row 100
mapfile -t lines < <(hm_table_print 2)
plain1="$(strip_ansi "${lines[2]}")"
plain2="$(strip_ansi "${lines[3]}")"
[[ "${#plain1}" == "${#plain2}" && "${plain1}" == *"1" && "${plain2}" == *"100" ]] \
  && ok "align-right" || bad "align-right '${plain1}' '${plain2}'"

# nowa linia w komórce nie rozbija wiersza
hm_table_begin
hm_table_row A B
hm_table_row $'x\ny' "z"
mapfile -t lines < <(hm_table_print 2)
[[ "${#lines[@]}" -eq 3 ]] && ok "one-line" || bad "one-line count=${#lines[@]}"
[[ "$(strip_ansi "${lines[2]}")" == *"x y"* ]] && ok "newline-space" || bad "newline=$(strip_ansi "${lines[2]}")"

# pusta tabela
hm_table_begin
out="$(hm_table_print 2)"
[[ -z "${out}" ]] && ok "empty" || bad "empty=${out}"

# pusta komórka w środku nie zjada następnej
hm_table_begin
hm_table_row A B C
hm_table_row "1" "" "3"
mapfile -t lines < <(hm_table_print 2)
ccol="$(col_at "${lines[0]}" "C")"
dcol="$(col_at "${lines[2]}" "3")"
[[ "${ccol}" == "${dcol}" && "${ccol}" != "-1" ]] && ok "empty-mid (${ccol})" || bad "empty-mid ${ccol} vs ${dcol}"

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
