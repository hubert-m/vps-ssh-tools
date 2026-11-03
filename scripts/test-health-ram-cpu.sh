#!/usr/bin/env bash
# Regresja: health — mapowanie site + flagi --ram/--cpu
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

hm_err() { echo "ERR: $*" >&2; }
hm_ok() { :; }
hm_info() { :; }
hm_warn() { :; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }
hm_human_size() {
  local b="${1:-0}"
  awk -v b="${b}" 'BEGIN {
    split("B KB MB GB TB PB", u, " ");
    i=1; while (b >= 1024 && i < 6) { b/=1024; i++ }
    if (i==1) printf "%d %s", b, u[i]; else printf "%.2f %s", b, u[i];
  }'
}
C_BOLD=""; C_RESET=""; C_DIM=""
HM_SITES_LIST=(api.example.com shop.pl)

tmpf="$(mktemp)"
awk '
  /^hm_health_site_for_text\(\)/ {p=1}
  /^hm_health_hint\(\)/ {p=0}
  p {print}
  p && /^}$/ {p=0}
' "${ROOT}/commands/health/main.sh" > "${tmpf}"
# shellcheck disable=SC1090
source "${tmpf}"
rm -f "${tmpf}"

fail=0
got="$(hm_health_site_for_text "/home/api.example.com/public_html node server.js")"
if [[ "${got}" == "api.example.com" ]]; then
  echo "OK   site from cwd path"
else
  echo "FAIL site got='${got}'"
  fail=1
fi

got="$(hm_health_site_for_text "something /home/shop.pl/app")"
if [[ "${got}" == "shop.pl" ]]; then
  echo "OK   site from cmdline path"
else
  echo "FAIL shop got='${got}'"
  fail=1
fi

got="$(hm_health_site_for_text "unrelated process")"
if [[ -z "${got}" ]]; then
  echo "OK   no false site"
else
  echo "FAIL unexpected site='${got}'"
  fail=1
fi

if grep -q 'health --ram' "${ROOT}/commands/health/main.sh" \
  && grep -q 'hm_health_section_cpu' "${ROOT}/commands/health/main.sh"; then
  echo "OK   --ram/--cpu wired"
else
  echo "FAIL missing sections"
  fail=1
fi

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
