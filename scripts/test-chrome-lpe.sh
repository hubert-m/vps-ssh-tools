#!/usr/bin/env bash
# Podłożona binarka Chrome w katalogu usera nie może wystartować z uid 0.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail=0
ok() { echo "OK   $*"; }
bad() { echo "FAIL $*"; fail=1; }

_hm_cmd_help() { cat >/dev/null; }
_hm_cmd_register() { :; }
declare -A HM_CMD_HELP 2>/dev/null || true

# shellcheck disable=SC1091
source "${ROOT}/lib/detect.sh"

hm_have_cmd() {
  case "$1" in
    google-chrome-stable|google-chrome|chromium|chromium-browser|chrome|systemctl|curl|sudo)
      return 1 ;;
    *) command -v "$1" >/dev/null 2>&1 ;;
  esac
}
hm_run_timeout() { shift; "$@"; }

# shellcheck disable=SC1091
source "${ROOT}/commands/chrome/main.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hmtools-chrome-lpe.XXXXXX")"
STAT="${TMP}/stat.tsv"
MARKER="${TMP}/marker"
export HM_CHROME_SYSTEM_PATHS=""
export HM_CHROME_STAT_FILE="${STAT}"
export HM_CHROME_LPE_MARKER="${MARKER}"
export HM_CHROME_HOME_ROOT="${TMP}/home"

write_chain() {
  local path="$1" uid="$2" mode="$3" user="$4" cur canon
  cur="${path}"
  while [[ "${cur}" != "/" ]]; do
    printf '%s\t%s\t%s\t%s\n' "${uid}" "${mode}" "${user}" "${cur}"
    cur="$(dirname "${cur}")"
  done
  printf '%s\t%s\t%s\t%s\n' "0" "755" "root" "/"
  canon="$(readlink -f "${path}" 2>/dev/null || true)"
  if [[ -n "${canon}" && "${canon}" != "${path}" ]]; then
    cur="${canon}"
    while [[ "${cur}" != "/" ]]; do
      printf '%s\t%s\t%s\t%s\n' "${uid}" "${mode}" "${user}" "${cur}"
      cur="$(dirname "${cur}")"
    done
  fi
}

plant() {
  local dest="$1"
  mkdir -p "$(dirname "${dest}")"
  cat > "${dest}" <<'EOF'
#!/bin/sh
printf 'WYKONANO jako uid=%s args=%s\n' "$(id -u)" "$*" >> "${HM_CHROME_LPE_MARKER}"
echo "Google Chrome 999.0.0"
EOF
  chmod +x "${dest}"
}

assert_not_root_exec() {
  local label="$1"
  if [[ -f "${MARKER}" ]] && grep -q 'uid=0' "${MARKER}"; then
    bad "${label}: binarka wykonana jako uid 0"
    cat "${MARKER}"
  else
    ok "${label}: brak wykonania jako uid 0"
  fi
}

fake="${TMP}/home/siteuser/.cache/puppeteer/chrome/linux-999.0.0/chrome-linux64/chrome"
plant "${fake}"
write_chain "${fake}" 1000 755 siteuser > "${STAT}"

rm -f "${MARKER}"
hm_detect_chrome
if [[ "${CHROME_BIN}" == "${fake}" ]]; then
  ok "detect wskazuje binarkę z home usera"
else
  bad "detect bin='${CHROME_BIN:-}'"
fi
hm_chrome_fetch_version "${CHROME_BIN}" || true
ver_out="$(cmd_chrome version || true)"
if printf '%s' "${CHROME_VERSION}${ver_out}" | grep -q '999.0.0'; then
  ok "wersja z nazwy katalogu linux-999.0.0"
else
  bad "wersja='${CHROME_VERSION:-}' out='${ver_out}'"
fi
assert_not_root_exec "detect/version"
if [[ -f "${MARKER}" ]]; then
  bad "detect/version uruchomiło binarkę"
else
  ok "detect/version bez exec"
fi

rm -f "${MARKER}"
cmd_chrome test >/dev/null 2>&1 || true
assert_not_root_exec "chrome test"

# Katalog roota, ale zapis grupy — też bez exec.
rm -f "${MARKER}"
write_chain "${fake}" 0 755 root > "${STAT}"
printf '%s\t%s\t%s\t%s\n' "0" "775" "root" "${TMP}/home/siteuser" >> "${STAT}"
CHROME_VERSION=""
if hm_chrome_path_trusted "${fake}"; then
  bad "ścieżka z katalogiem 775 uznana za zaufaną"
else
  ok "katalog 775 jest niezaufany"
fi
hm_chrome_fetch_version "${fake}" || true
assert_not_root_exec "katalog 775"
if [[ "${CHROME_VERSION}" == "Chrome 999.0.0" ]]; then
  ok "wersja przy katalogu 775 bez exec"
else
  bad "wersja przy 775='${CHROME_VERSION:-}'"
fi

# Plik VERSION, ścieżka poza linux-*
verbin="${TMP}/opt/chrome"
plant "${verbin}"
printf '%s\n' '120.0.1' > "${TMP}/opt/VERSION"
rm -f "${MARKER}"
write_chain "${verbin}" 1000 755 siteuser > "${STAT}"
CHROME_VERSION=""
hm_chrome_fetch_version "${verbin}" || true
if [[ "${CHROME_VERSION}" == "Chrome 120.0.1" ]]; then
  ok "wersja z pliku VERSION"
else
  bad "VERSION='${CHROME_VERSION:-}'"
fi
assert_not_root_exec "plik VERSION"
if [[ -f "${MARKER}" ]]; then
  bad "odczyt VERSION uruchomił binarkę"
else
  ok "plik VERSION bez exec"
fi

# Zaufana ścieżka (uid 0, 755) nadal może wykonać --version.
trust="${TMP}/usr/bin/google-chrome"
plant "${trust}"
rm -f "${MARKER}"
write_chain "${trust}" 0 755 root > "${STAT}"
unset HM_CHROME_HOME_ROOT
unset FORCE_CHROME_BIN || true
export FORCE_CHROME_BIN="${trust}"
CHROME_VERSION=""
if hm_chrome_path_trusted "${trust}"; then
  ok "ścieżka root 755 jest zaufana"
else
  bad "ścieżka root 755 odrzucona"
fi
cmd_chrome version >/dev/null || true
if [[ -f "${MARKER}" ]] && grep -q 'WYKONANO' "${MARKER}"; then
  ok "zaufana binarka nadal się uruchamia"
else
  bad "zaufana binarka nie wystartowała"
fi

# timeout jest poleceniem przed binarką, argv[1] Chrome zaczyna się od --.
# Mock śpiący 30 s kończy się po ~15 s z rc 124.
bin="${TMP}/bin"
mkdir -p "${bin}"
cat > "${bin}/id" <<'EOF'
#!/bin/sh
if [ "$1" = "-u" ]; then
  echo 0
  exit 0
fi
echo siteuser
EOF
cat > "${bin}/runuser" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do
  if [ "$1" = "--" ]; then
    shift
    break
  fi
  shift
done
exec "$@"
EOF
cat > "${bin}/timeout" <<'EOF'
#!/bin/bash
dur="${1:-15}"
shift
"$@" &
pid=$!
elapsed=0
while kill -0 "${pid}" 2>/dev/null; do
  if [ "${elapsed}" -ge "${dur}" ]; then
    kill -TERM "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
    exit 124
  fi
  sleep 1
  elapsed=$((elapsed + 1))
done
wait "${pid}"
status=$?
exit "${status}"
EOF
chmod +x "${bin}/id" "${bin}/runuser" "${bin}/timeout"
export PATH="${bin}:${PATH}"
unset CHROME_CDP_URL || true
write_chain "${fake}" 1000 755 siteuser > "${STAT}"
export FORCE_CHROME_BIN="${fake}"
export CHROME_BIN="${fake}"
rm -f "${MARKER}"
cmd_chrome test >/dev/null 2>&1 || true
if [[ -f "${MARKER}" ]] && grep -q 'args=--' "${MARKER}" && ! grep -q 'args=timeout' "${MARKER}"; then
  ok "chrome test: argv Chrome zaczyna się od --"
else
  bad "chrome test argv='$(cat "${MARKER}" 2>/dev/null || true)'"
fi

sleeper="${TMP}/home/siteuser/.cache/puppeteer/chrome/linux-1.0/chrome-linux64/chrome"
mkdir -p "$(dirname "${sleeper}")"
cat > "${sleeper}" <<'EOF'
#!/bin/sh
sleep 30
EOF
chmod +x "${sleeper}"
write_chain "${sleeper}" 1000 755 siteuser > "${STAT}"
rc=0
start="${SECONDS}"
hm_chrome_run_as_owner "${sleeper}" --headless --dump-dom about:blank || rc=$?
elapsed=$((SECONDS - start))
if [[ "${rc}" -eq 124 && "${elapsed}" -ge 12 && "${elapsed}" -le 22 ]]; then
  ok "timeout 15 s kończy sen 30 s (rc 124, ${elapsed}s)"
else
  bad "timeout rc=${rc} elapsed=${elapsed}"
fi

rm -rf "${TMP}"
unset HM_CHROME_STAT_FILE HM_CHROME_LPE_MARKER FORCE_CHROME_BIN CHROME_BIN PATH

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
