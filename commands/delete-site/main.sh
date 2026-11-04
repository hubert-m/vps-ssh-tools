#!/usr/bin/env bash
# Moduł: delete-site


_hm_cmd_help delete-site <<'EOF'
Użycie:
  delete-site <numer|domena> [--keep-db] [--keep-ssl] [--keep-user] [--force-nested]
  webs delete <numer|domena> […]
  (w kontekście use <domena>) delete-site […]

Całkowite, nieodwracalne usunięcie serwisu: PM2, LSPHP, cron (nie przy shared user),
MySQL, CyberPanel, vhost OLS, SSL, katalog (child→docroot), opcjonalnie user Unix.

Master z domenami podrzędnymi w katalogu → odmowa (najpierw archive child) albo --force-nested.
Przed usunięciem: inwentaryzacja + plan + wpisanie yes i nazwy domeny.
Zalecane: webs archive <domena> (backup+verify+delete).
EOF

_HM_DEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=delete.sh
source "${_HM_DEL_DIR}/delete.sh"

_hm_cmd_register delete-site cmd_delete_site 0 deletesite destroy-site
