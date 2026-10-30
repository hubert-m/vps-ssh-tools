#!/usr/bin/env bash
# Moduł: version

cmd_version() {
  local cur latest
  cur="$(hm_installed_version)"
  [[ -n "${cur}" ]] || cur="?"
  echo "Zainstalowana: ${cur}"
  latest="$(hm_latest_remote_version)"
  if [[ -n "${latest}" ]]; then
    echo "Najnowsza:     ${latest}"
    if hm_version_is_newer "${cur}" "${latest}"; then
      hm_warn "Dostępna aktualizacja: ${cur} → ${latest}"
      hm_warn "curl -fsSL https://raw.githubusercontent.com/${HMTOOLS_REPO:-hubert-m/vps-ssh-tools}/${HMTOOLS_BRANCH:-develop}/install.sh | bash"
      hm_warn "Albo: update-hmtools"
    else
      hm_ok "Jesteś na najnowszej wersji."
    fi
  else
    hm_warn "Nie udało się sprawdzić najnowszej wersji na GitHubie."
  fi
  hm_print_changelog "${cur}" "Co zawiera zainstalowana wersja (${cur})"
}

_hm_cmd_register version cmd_version 1 ver
