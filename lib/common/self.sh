#!/usr/bin/env bash
# Common: help global, uninstall, applog, version/changelog

hm_help_global() {
  cat <<'EOF'
Komendy globalne:
  webs [--quick]     Lista usług webowych
  webs delete <d>    Całkowite usunięcie serwisu (delete-site)
  webs archive <d>   Archiwum Drive → verify → usunięcie z VPS
  use <n|domena>     Wejście w kontekst strony (Tab = podpowiedź domen)
  delete-site <d>    Alias: webs delete
  archive-site <d>   Alias: webs archive
  backup setup       Konfiguracja rclone / Google Drive
  backup config      Ustaw katalog root backupów na Drive
  backup full|site   Kopia → Drive; list / restore / prune / schedule
  applog [N]         Ostatnie N linii logu hmtools (domyślnie 50)
  disk               Zużycie dysku
  ols […]            OLS: status/reload/stats/htaccess/cache/proxy/admin
  ssl                Certyfikaty SSL stron (status / dni)
  renew-ssl [domena] Odnów Let's Encrypt (z potwierdzeniem)
  mysql / dbs        Bazy danych (globalnie)
  cron [list|edit…]  Crony systemowe / użytkowników / strony
  pm2|node|apps      Procesy PM2/Node (porty, status, proxy OLS)
  php                LSPHP: lista / set / ext / ini / restart / ps
  update-php <ver>   Aktualizacja pakietów LSPHP (np. update-php 8.4)
  health             Szybki przegląd zdrowia serwera
  security […]       Audyt: porty, SSH, Fail2Ban, skan docroot
  detect             Pokaż wykryty panel / webserver
  help [polecenie]   Lista komend lub pomoc do konkretnej (np. help use)
  version            Wersja + changelog zainstalowanej wersji
  update-hmtools     Aktualizacja z GitHuba (+ co nowego)
  uninstall-hmtools  Usuń hmtools z serwera (--yes bez pytania)
  exit / quit        Wyjście z hmtools

W kontekście strony (po 'use'):
  info, size, dbs, ssl, renew-ssl, php, logs, cron, pm2, backup, clean, htaccess, proxy, perms, exit

Szczegóły: help <polecenie>
EOF
}

cmd_uninstall_hmtools() {
  local yes=0
  local a
  for a in "$@"; do
    case "${a}" in
      --yes|-y) yes=1 ;;
      --help|-h)
        cat <<'EOF'
Użycie: uninstall-hmtools [--yes]

Usuwa hmtools z serwera:
  - katalog instalacji (domyślnie /hm-tools) — w tym conf i logi
  - symlinki /usr/bin/hmtools oraz /usr/local/bin/hmtools

Nie usuwa rclone ani backupów na Google Drive.
EOF
        return 0
        ;;
    esac
  done

  local dest="${HMTOOLS_ROOT:-/hm-tools}"
  local links=("/usr/bin/hmtools" "/usr/local/bin/hmtools")
  if [[ -n "${HMTOOLS_BIN_LINK:-}" ]]; then
    links+=("${HMTOOLS_BIN_LINK}")
  fi

  local -a plan_steps=(
    "Usunięcie symlinków /usr/bin/hmtools i /usr/local/bin/hmtools"
    "Trwałe usunięcie katalogu ${dest} (wraz z hmtools.conf i logami sesji; backupy na Google Drive zostają)"
    "Zakończenie sesji hmtools"
  )
  local yes_flag=()
  [[ "${yes}" -eq 1 ]] && yes_flag=(--yes)
  if ! hm_confirm_plan "uninstall-hmtools" \
    "Konfiguracja, logi i pliki narzędzi zostaną skasowane. rclone i backupy na Drive zostają." \
    "${yes_flag[@]}" \
    "${plan_steps[@]}"; then
    return 0
  fi

  hm_file_log INFO "uninstall-hmtools start dest=${dest}"

  for link in "${links[@]}"; do
    if [[ -L "${link}" ]]; then
      local target
      target="$(readlink -f "${link}" 2>/dev/null || readlink "${link}" 2>/dev/null || true)"
      if [[ "${target}" == "${dest}/bin/hmtools" || "${target}" == */hm-tools/bin/hmtools ]]; then
        rm -f "${link}"
        hm_ok "Usunięto symlink ${link}"
      else
        hm_warn "Pominięto ${link} (cel: ${target:-?})."
      fi
    elif [[ -e "${link}" ]]; then
      hm_warn "Pominięto ${link} (nie jest symlinkiem)."
    fi
  done

  if [[ -d "${dest}" ]]; then
    # bezpieczeństwo: nie kasuj / ani /
    case "${dest}" in
      /|/usr|/usr/local|/bin|/etc|/home|/var|/root)
        hm_err "Odmowa usunięcia niebezpiecznej ścieżki: ${dest}"
        return 1
        ;;
    esac
    rm -rf "${dest}"
    echo "Usunięto katalog ${dest}"
  else
    hm_warn "Katalog ${dest} już nie istnieje."
  fi

  echo
  echo "hmtools zostało odinstalowane."
  # kod specjalny — REPL powinien się zakończyć (katalog źródłowy mógł zniknąć)
  return 98
}

cmd_applog() {
  local n="${1:-50}"
  local f
  hm_log_init
  f="$(hm_log_file_path)"
  if [[ ! -f "${f}" ]]; then
    # pokaż najnowszy istniejący plik
    f="$(ls -1t "${LOG_DIR}"/hmtools-*.log 2>/dev/null | head -1 || true)"
  fi
  if [[ -z "${f}" || ! -f "${f}" ]]; then
    hm_warn "Brak plików logów w ${LOG_DIR}"
    return 0
  fi
  echo "Log: ${f} (ostatnie ${n} linii)"
  echo "----"
  tail -n "${n}" "${f}"
}

hm_installed_version() {
  if [[ -f "${HMTOOLS_ROOT}/VERSION" ]]; then
    tr -d '[:space:]' < "${HMTOOLS_ROOT}/VERSION"
    return 0
  fi
  echo ""
}

hm_latest_remote_version() {
  # najnowszy tag (fallback: plik VERSION z brancha); cicho przy braku sieci
  local repo="${HMTOOLS_REPO:-hubert-m/vps-ssh-tools}"
  local branch="${HMTOOLS_BRANCH:-develop}"
  local latest=""
  latest="$(curl -fsSL --connect-timeout 2 --max-time 5 --retry 0 \
    -H 'Accept: application/vnd.github+json' -H 'User-Agent: hmtools' \
    "https://api.github.com/repos/${repo}/tags?per_page=100" 2>/dev/null \
    | grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]+"' \
    | sed -E 's/.*"([^"]+)"$/\1/' \
    | sort -V | tail -1 || true)"
  if [[ -z "${latest}" ]]; then
    latest="$(curl -fsSL --connect-timeout 2 --max-time 5 --retry 0 \
      "https://raw.githubusercontent.com/${repo}/${branch}/VERSION" 2>/dev/null \
      | tr -d '[:space:]' || true)"
  fi
  printf '%s' "${latest}"
}

hm_version_is_newer() {
  # 0 = remote ($2) nowsze niż local ($1)
  local cur="$1" remote="$2" top
  [[ -n "${cur}" && -n "${remote}" ]] || return 1
  [[ "${cur}" == "${remote}" ]] && return 1
  top="$(printf '%s\n%s\n' "${cur}" "${remote}" | sort -V | tail -1)"
  [[ "${top}" == "${remote}" ]]
}

hm_welcome_update_notice() {
  local cur remote repo branch
  cur="$(hm_installed_version)"
  [[ -n "${cur}" ]] || return 0
  remote="$(hm_latest_remote_version)"
  [[ -n "${remote}" ]] || return 0
  hm_version_is_newer "${cur}" "${remote}" || return 0

  repo="${HMTOOLS_REPO:-hubert-m/vps-ssh-tools}"
  branch="${HMTOOLS_BRANCH:-develop}"
  hm_warn "Dostępna nowsza wersja: masz ${cur}, najnowsza ${remote}"
  hm_warn "Aktualizacja: curl -fsSL https://raw.githubusercontent.com/${repo}/${branch}/install.sh | bash"
  hm_warn "Albo w REPL: update-hmtools"
}

hm_changelog_path() {
  local ver="${1:-}"
  local f
  if [[ -n "${ver}" ]]; then
    f="${HMTOOLS_ROOT}/changelogs/${ver}.txt"
    if [[ -f "${f}" ]]; then
      echo "${f}"
      return 0
    fi
    if [[ "${ver}" == v* ]]; then
      f="${HMTOOLS_ROOT}/changelogs/${ver#v}.txt"
    else
      f="${HMTOOLS_ROOT}/changelogs/v${ver}.txt"
    fi
    if [[ -f "${f}" ]]; then
      echo "${f}"
      return 0
    fi
  fi
  # fallback: najnowszy plik w changelogs/
  f="$(ls -1 "${HMTOOLS_ROOT}/changelogs"/v*.txt 2>/dev/null | sort -V | tail -1 || true)"
  [[ -n "${f}" && -f "${f}" ]] || return 1
  echo "${f}"
}

hm_print_changelog() {
  local ver="${1:-}"
  local title="${2:-}"
  local f
  if ! f="$(hm_changelog_path "${ver}")"; then
    hm_warn "Brak pliku changelog dla wersji ${ver}."
    return 0
  fi
  if [[ -n "${title}" ]]; then
    echo
    echo "${C_BOLD}${title}${C_RESET}"
    echo
  fi
  cat "${f}"
  echo
}
