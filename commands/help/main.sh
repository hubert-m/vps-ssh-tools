#!/usr/bin/env bash
# Moduł: help (implementacja hm_cmd_help w lib/help.sh)


_hm_cmd_help help <<'EOF'
Użycie:
  help              Lista wszystkich komend
  help <polecenie>  Szczegółowa pomoc dla komendy

Przykłady:
  help use
  help backup
  help ols
EOF

_hm_cmd_help exit <<'EOF'
Użycie: exit | quit

W kontekście strony: powrót do hmtools>
Na poziomie głównym: wyjście z hmtools do SSH.
EOF

_hm_cmd_help quit <<'EOF'
Użycie: exit | quit

W kontekście strony: powrót do hmtools>
Na poziomie głównym: wyjście z hmtools do SSH.
EOF

cmd_help() {
  hm_cmd_help "$@"
}

_hm_cmd_register help cmd_help 1 h '?'
