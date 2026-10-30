#!/usr/bin/env bash
# Komenda: disk


_hm_cmd_help disk <<'EOF'
Użycie: disk

Pokazuje zajętość dysków (df), inody oraz największe katalogi w /home.
EOF

cmd_disk() {
  echo "${C_BOLD}Zużycie dysku${C_RESET}"
  df -hT 2>/dev/null || df -h
  echo
  echo "${C_BOLD}Inody${C_RESET}"
  df -i 2>/dev/null | head -20
  echo
  if [[ -d /home ]]; then
    echo "${C_BOLD}Top katalogi w /home${C_RESET}"
    hm_status_line "Obliczanie rozmiaru katalogów w /home..."
    du -h --max-depth=1 /home 2>/dev/null | sort -hr | head -25
    hm_status_clear
  fi
  echo
  hm_info "Wolne: $(hm_disk_free_percent /)%  |  Zajęte: $(hm_disk_used_percent /)%"
}

_hm_cmd_register disk cmd_disk 0 df
