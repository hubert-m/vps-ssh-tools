#!/usr/bin/env bash
# Moduł: applog (implementacja w lib/common/self.sh → cmd_applog)


_hm_cmd_help applog <<'EOF'
Użycie: applog [N]

Ostatnie N linii logu pracy hmtools (domyślnie 50).
Pliki: /hm-tools/logs/hmtools-YYYY-MM-DD.log
EOF

_hm_cmd_register applog cmd_applog 0 selflog hmlog
