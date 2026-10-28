#!/usr/bin/env bash
# Guided setup: rclone + Google Drive dla hmtools
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HMTOOLS_ROOT="${HMTOOLS_ROOT:-$(cd "${_SCRIPT_DIR}/.." && pwd)}"
HMTOOLS_CONF="${HMTOOLS_CONF:-${HMTOOLS_ROOT}/config/hmtools.conf}"
CONF="${HMTOOLS_CONF}"

# shellcheck source=../lib/common.sh
source "${HMTOOLS_ROOT}/lib/common.sh"
# shellcheck source=../lib/rclone_drive.sh
source "${HMTOOLS_ROOT}/lib/rclone_drive.sh"

echo "=== hmtools: konfiguracja rclone / Google Drive ==="
echo

if ! hm_have_cmd rclone; then
  echo "rclone nie jest zainstalowany."
  if hm_confirm "Zainstalować rclone teraz"; then
    curl -fsSL https://rclone.org/install.sh | bash
  else
    echo "Zainstaluj ręcznie: https://rclone.org/install/"
    exit 1
  fi
fi

echo
echo "rclone: $(rclone version | head -1)"
echo
echo "Teraz uruchomimy 'rclone config'."
echo "Zalecane kroki:"
echo "  1) n) New remote"
echo "  2) name> gdrive   (lub inna nazwa)"
echo "  3) Storage> Google Drive  (numer z listy)"
echo "  4) client_id / secret — Enter (puste OK dla startu)"
echo "  5) scope> 1 (Full access) — lub zgodnie z potrzebą"
echo "  6) autokonfiguracja — na VPS bez przeglądarki użyj"
echo "     'rclone authorize \"drive\"' na lokalnym PC i wklej token,"
echo "     albo uruchom z --rc / postępuj według promptów rclone."
echo "  7) Zapisz remote i wyjdź (q)."
echo
read -r -p "Uruchomić rclone config? [T/n]: " go
case "${go}" in
  n|N|nie) ;;
  *)
    # prawdziwe TTY — nie przez tee logów sesji hmtools
    hm_run_on_tty rclone config
    ;;
esac

echo
echo "Katalog ROOT na Google Drive — jednorazowa konfiguracja."
echo "Wewnątrz hmtools utworzy:"
echo "  full/           — pełne kopie serwera"
echo "  <domena>/       — kopie poszczególnych stron (np. projects.unideverse.com/)"
echo "  db-dumps/       — jednorazowe zrzuty baz"
echo
read -r -p "Nazwa remote rclone [gdrive]: " remote_name
remote_name="${remote_name:-gdrive}"

read -r -p "Ścieżka katalogu root na Drive [vps-backups]: " remote_path
remote_path="${remote_path:-vps-backups}"
remote_path="${remote_path#/}"
remote_path="${remote_path%/}"

RCLONE_REMOTE="${remote_name}:${remote_path}"
hm_rclone_save_remote_conf "${RCLONE_REMOTE}"

echo
echo "Zapisano RCLONE_REMOTE=\"${RCLONE_REMOTE}\" w ${CONF}"
echo "Tworzenie katalogów root/ i full/ …"
hm_rclone_ensure_backup_layout

echo "Test:"
if rclone lsd "${remote_name}:" >/dev/null 2>&1; then
  echo "OK — połączenie działa."
  rclone lsd "${RCLONE_REMOTE}" 2>/dev/null || true
else
  echo "UWAGA: nie udało się wypisać remote. Sprawdź: rclone config"
  exit 1
fi

echo
echo "Gotowe."
echo "  Zmiana root później:  hmtools → backup config"
echo "  Backup strony:        hmtools → use <domena> → backup"
echo "  Backup serwera:       hmtools → backup full"
