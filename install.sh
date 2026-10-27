#!/usr/bin/env bash
# Instalacja hmtools do /hm-tools
set -euo pipefail

DEST="${HMTOOLS_DEST:-/hm-tools}"
BIN_LINK="${HMTOOLS_BIN_LINK:-/usr/local/bin/hmtools}"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Uruchom jako root." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Instalacja hmtools → ${DEST}"

mkdir -p "${DEST}"
# Kopiuj tree (bez .git)
rsync -a --delete \
  --exclude '.git' \
  --exclude '*.plan.md' \
  "${SCRIPT_DIR}/" "${DEST}/" 2>/dev/null || {
  # fallback bez rsync
  find "${DEST}" -mindepth 1 -maxdepth 1 ! -name 'config' -exec rm -rf {} + 2>/dev/null || true
  cp -a "${SCRIPT_DIR}/bin" "${SCRIPT_DIR}/lib" "${SCRIPT_DIR}/commands" "${SCRIPT_DIR}/scripts" "${DEST}/"
  mkdir -p "${DEST}/config"
  cp -a "${SCRIPT_DIR}/config/hmtools.conf.example" "${DEST}/config/"
  [[ -f "${SCRIPT_DIR}/README.md" ]] && cp -a "${SCRIPT_DIR}/README.md" "${DEST}/"
}

chmod +x "${DEST}/bin/hmtools"
chmod +x "${DEST}/install.sh" 2>/dev/null || true
chmod +x "${DEST}/scripts/"*.sh 2>/dev/null || true

# Konfiguracja — nie nadpisuj istniejącej
if [[ ! -f "${DEST}/config/hmtools.conf" ]]; then
  cp "${DEST}/config/hmtools.conf.example" "${DEST}/config/hmtools.conf"
  echo "Utworzono ${DEST}/config/hmtools.conf (z przykładu)."
fi

ln -sfn "${DEST}/bin/hmtools" "${BIN_LINK}"
echo "Symlink: ${BIN_LINK} → ${DEST}/bin/hmtools"

echo
echo "Gotowe. Uruchom: hmtools"
echo "Konfiguracja Google Drive: hmtools → backup setup"
