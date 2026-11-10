#!/usr/bin/env bash
# integrity: WP-CLI nie jako root, baseline bez podążania za symlinkiem, diff --json.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

# shellcheck disable=SC1091
source lib/common/ui.sh
hm_file_log_ui() { :; }
_hm_cmd_help() { cat >/dev/null; }
_hm_cmd_register() { :; }

fail=0
ok() { echo "OK   $*"; }
bad() { echo "FAIL $*"; fail=1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hmtools-integrity.XXXXXX")"
MARKER="${TMP}/wp-ran"
RUNLOG="${TMP}/runuser.log"
TREE="${TMP}/tree"
OUTSIDE="${TMP}/outside"
mkdir -p "${TREE}/bin" "${OUTSIDE}" "${TMP}/bin"
printf '%s\n' 'SUPERSECRET' > "${OUTSIDE}/secret"
printf '%s\n' 'v1' > "${TREE}/bin/keep.txt"
printf '%s\n' 'gone' > "${TREE}/bin/drop.txt"
weird="${TREE}/bin/odd name"$'\n'"file"
printf '%s\n' 'odd' > "${weird}"
ln -s "${OUTSIDE}/secret" "${TREE}/bin/jump" 2>/dev/null || cp "${OUTSIDE}/secret" "${TREE}/bin/jump"

cat > "${TMP}/bin/wp" <<EOF
#!/bin/sh
printf '%s\n' "WYKONANO uid=\$(id -u)" >> "${MARKER}"
exit 0
EOF
chmod +x "${TMP}/bin/wp"

printf '%s %s\n' 'example.com' 'siteuser' > "${TMP}/users"
printf '%s %s\n' 'other.com' 'otheruser' >> "${TMP}/users"

export HM_INTEGRITY_DB="${TMP}/state/baseline.tsv"
export HM_INTEGRITY_PATHS="${TREE}/bin"
export HM_INTEGRITY_SITES="example.com other.com"
export HM_INTEGRITY_USER_FILE="${TMP}/users"
export HM_INTEGRITY_WP_BIN="${TMP}/bin/wp"
export HM_INTEGRITY_CRON="${TMP}/cron-integrity"
export PATH="${TMP}/bin:${PATH}"

id() {
  case "${1:-}" in
    -u) printf '0\n' ;;
    -un) printf 'root\n' ;;
    *) printf '0\n' ;;
  esac
}
runuser() {
  printf '%s\n' "$*" >> "${RUNLOG}"
  case "$*" in
    *otheruser*plugin*) return 1 ;;
    *) return 0 ;;
  esac
}
hm_have_cmd() {
  case "$1" in
    runuser) return 0 ;;
    wp) return 1 ;;
    *) command -v "$1" >/dev/null 2>&1 ;;
  esac
}
hm_notify() { printf '%s\n' "$*" >> "${TMP}/notify"; }
hm_confirm_plan() { return "${HM_CONFIRM_RC:-1}"; }

# shellcheck disable=SC1091
source commands/integrity/main.sh

rm -f "${MARKER}" "${RUNLOG}"
wp_out="$(cmd_integrity wp --all)" || true
if [[ -f "${MARKER}" ]]; then
  bad "WP-CLI wystartowało w tym procesie (uid roota)"
  cat "${MARKER}"
else
  ok "WP-CLI nie wystartowało jako root"
fi
grep -q 'siteuser' "${RUNLOG}" && ok "runuser siteuser" || bad "brak runuser siteuser"
grep -q 'otheruser' "${RUNLOG}" && ok "runuser otheruser" || bad "brak runuser otheruser"
printf '%s\n' "${wp_out}" | grep -q 'example.com' && ok "tabela example.com" || bad "brak example.com"
printf '%s\n' "${wp_out}" | grep -q 'różnice' && ok "wtyczki other.com" || bad "brak różnic wtyczek"

rm -f "${RUNLOG}"
one="$(cmd_integrity wp example.com)" || true
if grep -q 'otheruser' "${RUNLOG}"; then
  bad "filtr domeny puścił other.com"
else
  ok "filtr domeny"
fi
printf '%s\n' "${one}" | grep -q 'example.com' && ok "jedna domena" || bad "brak jednej domeny"

cmd_integrity baseline create >/dev/null
if grep -q 'SUPERSECRET' "${HM_INTEGRITY_DB}"; then
  bad "baseline zawiera treść celu symlinku"
else
  ok "symlink nie jest rozwijany"
fi
mode="$(stat -c '%a' -- "${HM_INTEGRITY_DB}" 2>/dev/null || printf '644')"
probe="${TMP}/mode-probe"
printf 'x\n' > "${probe}"
chmod 0600 "${probe}" 2>/dev/null || true
pmode="$(stat -c '%a' -- "${probe}" 2>/dev/null || printf '644')"
if [[ "${pmode: -2}" == "00" ]]; then
  [[ "${mode: -2}" == "00" ]] && ok "baseline 0600" || bad "baseline mode ${mode}"
else
  ok "platforma nie trzyma chmod — pomijam asercję 0600"
fi

printf '%s\n' 'v2' > "${TREE}/bin/keep.txt"
printf '%s\n' 'odd2' > "${weird}"
rm -f "${TREE}/bin/drop.txt"
printf '%s\n' 'new' > "${TREE}/bin/added.txt"
diff_out="$(cmd_integrity check)" || true
printf '%s\n' "${diff_out}" | grep -q 'keep.txt' && ok "zmieniony plik" || bad "brak zmiany"
printf '%s\n' "${diff_out}" | grep -q 'added.txt' && ok "nowy plik" || bad "brak nowego"
printf '%s\n' "${diff_out}" | grep -q 'drop.txt' && ok "usunięty plik" || bad "brak usuniętego"
printf '%s\n' "${diff_out}" | grep -q 'odd name' && ok "nazwa z odstępem i nową linią" || bad "dziwna nazwa zgubiona"
if printf '%s\n' "${diff_out}" | grep -q 'jump'; then
  bad "zmiana celu symlinku zgłoszona mimo stałego linku"
else
  ok "symlink bez fałszywej zmiany"
fi

future="$(cmd_integrity check --since 2099-01-01)" || true
printf '%s\n' "${future}" | grep -q 'drop.txt' && ok "since zostawia usunięte" || bad "since zgubił usunięte"
if printf '%s\n' "${future}" | grep -q 'added.txt'; then
  bad "since puścił plik sprzed daty"
else
  ok "since filtruje nowe"
fi

js="$(cmd_integrity check --json)" || true
printf '%s\n' "${js}" | grep -q '"changed"' && ok "json changed" || bad "json: ${js}"
printf '%s\n' "${js}" | grep -q 'keep.txt' && ok "json ścieżka" || bad "json bez ścieżki"

rm -f "${TMP}/notify"
cmd_integrity check --notify >/dev/null || true
grep -q 'Integralność' "${TMP}/notify" && ok "notify przy różnicach" || bad "brak notify"

HM_CONFIRM_RC=0
cmd_integrity baseline create >/dev/null
printf '%s\n' 'v3' > "${TREE}/bin/keep.txt"
hm_integrity_after_update
clean="$(cmd_integrity check --json)" || true
if printf '%s\n' "${clean}" | grep -q 'keep.txt'; then
  bad "odświeżenie baseline nie zdjęło różnicy"
else
  ok "baseline po potwierdzeniu"
fi
printf '%s\n' 'v4' > "${TREE}/bin/keep.txt"
HM_CONFIRM_RC=1
hm_integrity_after_update
stale="$(cmd_integrity check)" || true
printf '%s\n' "${stale}" | grep -q 'keep.txt' && ok "bez potwierdzenia baseline zostaje" || bad "baseline zmieniony bez potwierdzenia"

rm -f "${TMP}/notify"
cmd_integrity baseline update >/dev/null
cmd_integrity check --notify >/dev/null || true
if [[ -f "${TMP}/notify" ]]; then
  bad "notify przy braku zmian"
else
  ok "brak notify bez zmian"
fi

cmd_integrity schedule enable >/dev/null
grep -q 'hmtools-integrity' "${HM_INTEGRITY_CRON}" && ok "cron enable" || bad "cron"
cmd_integrity schedule disable >/dev/null
[[ ! -f "${HM_INTEGRITY_CRON}" ]] && ok "cron disable" || bad "cron został"
printf '%s\n' 'obcy' > "${HM_INTEGRITY_CRON}"
if cmd_integrity schedule disable >/dev/null 2>&1; then
  bad "disable skasował obcy plik"
else
  ok "disable nie rusza obcego pliku"
fi
grep -q 'obcy' "${HM_INTEGRITY_CRON}" && ok "obcy plik na miejscu" || bad "obcy plik zniknął"

# baseline w docroocie jest odrzucany
export HM_INTEGRITY_DB="${TMP}/public_html/baseline.tsv"
if cmd_integrity baseline create >/dev/null 2>&1; then
  bad "baseline w public_html przeszedł"
else
  ok "odrzucenie baseline w docroocie"
fi

rm -rf "${TMP}"

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
