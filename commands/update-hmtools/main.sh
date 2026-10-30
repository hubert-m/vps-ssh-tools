#!/usr/bin/env bash
# Moduł: update-hmtools

cmd_update_hmtools() {
  local force=0
  local a
  for a in "$@"; do
    case "${a}" in
      --force|-f) force=1 ;;
      --help|-h)
        echo "Użycie: update-hmtools [--force]"
        echo "  Porównuje /hm-tools/VERSION z najnowszym tagiem GitHuba."
        echo "  Aktualizuje tylko gdy jest nowsza wersja (albo --force)."
        return 0
        ;;
    esac
  done
  hm_info "Sprawdzanie aktualizacji hmtools..."
  local branch="${HMTOOLS_BRANCH:-develop}"
  local url="https://raw.githubusercontent.com/hubert-m/vps-ssh-tools/${branch}/install.sh"
  if [[ "${force}" -eq 1 ]]; then
    HMTOOLS_FORCE=1 curl -fsSL "${url}" | bash
  else
    curl -fsSL "${url}" | bash
  fi
  hm_ok "Po update-hmtools uruchom ponownie hmtools, jeśli jesteś w REPL."
}

_hm_cmd_register update-hmtools cmd_update_hmtools 0
