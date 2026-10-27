#!/usr/bin/env bash
# Guided setup: rclone + Google Drive dla hmtools
set -euo pipefail

HMTOOLS_ROOT="${HMTOOLS_ROOT:-/hm-tools}"
CONF="${HMTOOLS_CONF:-${HMTOOLS_ROOT}/config/hmtools.conf}"

echo "=== hmtools: konfiguracja rclone / Google Drive ==="
echo

if ! command -v rclone >/dev/null 2>&1; then
  echo "rclone nie jest zainstalowany."
  read -r -p "Zainstalować rclone teraz? [t/N]: " ans
  case "${ans}" in
    t|T|tak|y|Y)
      curl -fsSL https://rclone.org/install.sh | bash
      ;;
    *)
      echo "Zainstaluj ręcznie: https://rclone.org/install/"
      exit 1
      ;;
  esac
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
  *) rclone config ;;
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

mkdir -p "$(dirname "${CONF}")"
if [[ -f "${CONF}" ]]; then
  if grep -q '^RCLONE_REMOTE=' "${CONF}" 2>/dev/null; then
    sed -i.bak "s|^RCLONE_REMOTE=.*|RCLONE_REMOTE=\"${RCLONE_REMOTE}\"|" "${CONF}"
  else
    echo "RCLONE_REMOTE=\"${RCLONE_REMOTE}\"" >> "${CONF}"
  fi
else
  if [[ -f "${HMTOOLS_ROOT}/config/hmtools.conf.example" ]]; then
    cp "${HMTOOLS_ROOT}/config/hmtools.conf.example" "${CONF}"
    sed -i.bak "s|^RCLONE_REMOTE=.*|RCLONE_REMOTE=\"${RCLONE_REMOTE}\"|" "${CONF}"
  else
    echo "RCLONE_REMOTE=\"${RCLONE_REMOTE}\"" > "${CONF}"
  fi
fi

echo
echo "Zapisano RCLONE_REMOTE=\"${RCLONE_REMOTE}\" w ${CONF}"
echo "Tworzenie katalogów root/ i full/ …"
rclone mkdir "${RCLONE_REMOTE}" 2>/dev/null || true
rclone mkdir "${RCLONE_REMOTE}/full" 2>/dev/null || true

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
