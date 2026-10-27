#!/usr/bin/env bash
# Komenda: disk

cmd_disk() {
  echo "${C_BOLD}Zużycie dysku${C_RESET}"
  df -hT 2>/dev/null || df -h
  echo
  echo "${C_BOLD}Inody${C_RESET}"
  df -i 2>/dev/null | head -20
  echo
  if [[ -d /home ]]; then
    echo "${C_BOLD}Top katalogi w /home${C_RESET}"
    du -h --max-depth=1 /home 2>/dev/null | sort -hr | head -25
  fi
  echo
  hm_info "Wolne: $(hm_disk_free_percent /)%  |  Zajęte: $(hm_disk_used_percent /)%"
}
