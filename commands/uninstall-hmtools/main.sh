#!/usr/bin/env bash
# Moduł: uninstall-hmtools (implementacja w lib/common/self.sh → cmd_uninstall_hmtools)


_hm_cmd_help uninstall-hmtools <<'EOF'
Użycie: uninstall-hmtools [--yes]

Usuwa katalog /hm-tools oraz symlinki /usr/bin/hmtools i /usr/local/bin/hmtools.
Wymaga potwierdzenia (pomiń przez --yes).

Nie usuwa rclone ani backupów na Google Drive.
EOF

_hm_cmd_register uninstall-hmtools cmd_uninstall_hmtools 1
