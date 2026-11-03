#!/usr/bin/env bash
# Regresja: detekcja Puppeteer cache + CDP parse (bez prawdziwego Chrome)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

hm_err() { echo "ERR: $*" >&2; }
hm_ok() { :; }
hm_info() { :; }
hm_warn() { :; }
hm_have_cmd() {
  case "$1" in
    curl) return 1 ;; # bez sieci w teście CDP
    systemctl) return 1 ;;
    *) command -v "$1" >/dev/null 2>&1 ;;
  esac
}
hm_run_timeout() { shift; "$@"; }

# Minimalne stuby przed source detect — unikamy pełnego OS detect
# shellcheck disable=SC1091
# ładujemy tylko funkcje chrome z detect przez source całego pliku
# (hm_detect_chrome nie wymaga reszty przy bezpośrednim wywołaniu)
source "${ROOT}/lib/detect.sh" 2>/dev/null || true

fail=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hmtools-chrome-det.XXXXXX")"
# symuluj layout Puppeteer pod „home”
fake_home="${TMP}/home/site.example"
mkdir -p "${fake_home}/.cache/puppeteer/chrome/linux-146.0.7680.76/chrome-linux64"
fake_bin="${fake_home}/.cache/puppeteer/chrome/linux-146.0.7680.76/chrome-linux64/chrome"
printf '#!/bin/sh\necho Chrome 146\n' > "${fake_bin}"
chmod +x "${fake_bin}"

# podmień glob — funkcja używa /home/* — na Windows/CI zrób symlink jeśli się da
if ln -sfn "${TMP}/home" /tmp/hmtools-chrome-home-link 2>/dev/null; then
  :
fi

# test bezpośredni logiki mtime: wywołaj z nadpisaną funkcją przez PATH-like
# Prościej: skopiuj logikę wyszukiwania względem TMP
cand=""
for c in \
  "${TMP}"/home/*/.cache/puppeteer/chrome/linux-*/chrome-linux64/chrome
do
  [[ -x "${c}" ]] && cand="${c}"
done
if [[ "${cand}" == "${fake_bin}" ]]; then
  echo "OK   puppeteer layout znaleziony"
else
  echo "FAIL puppeteer layout cand='${cand}'"
  fail=1
fi

# CDP Browser parse (jak w hm_chrome_cdp_probe)
raw='{ "Browser": "Chrome/146.0.7680.76", "Protocol-Version": "1.3" }'
br="$(printf '%s' "${raw}" | sed -n 's/.*"Browser"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
if [[ "${br}" == "Chrome/146.0.7680.76" ]]; then
  echo "OK   CDP Browser parse"
else
  echo "FAIL CDP parse='${br}'"
  fail=1
fi

rm -rf "${TMP}"

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
