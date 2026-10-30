#!/usr/bin/env bash
# Moduł: delete-site


_hm_cmd_help delete-site <<'EOF'
Użycie:
  delete-site <numer|domena> [--keep-db] [--keep-ssl] [--keep-user]
  webs delete <numer|domena> […]
  (w kontekście use <domena>) delete-site […]

Całkowite, nieodwracalne usunięcie serwisu: PM2, LSPHP, cron, MySQL,
CyberPanel, vhost OLS, SSL, katalog /home/…, opcjonalnie user Unix.

Przed usunięciem: pełna inwentaryzacja + plan kroków + wpisanie yes i nazwy domeny.
Zalecane: webs archive <domena> (backup+verify+delete) lub backup site przed delete.
EOF

_HM_DEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=delete.sh
source "${_HM_DEL_DIR}/delete.sh"

_hm_cmd_register delete-site cmd_delete_site 0 deletesite destroy-site
