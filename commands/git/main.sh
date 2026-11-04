#!/usr/bin/env bash
# Moduł: git — status / klucz deploy / attach repo (site context)


_hm_cmd_help git <<'EOF'
Użycie (kontekst strony):
  git | status                 Repo: gałąź, remote, commit, dirty
  git key [--force]            Klucz deploy ed25519 (~/.ssh/hmtools_deploy)
  git attach <url> [--branch main] [--path <katalog>]
  git path [<katalog>]         Pokaż / ustaw ścieżkę repo (.hmtools-deploy)

Operacje git jako user strony (runuser). Klucz 0600 tylko w home usera.
Deploy: komenda „deploy” (osobny help).
EOF

# shellcheck source=deploy.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/deploy.sh"

hm_git_require_site() {
  [[ -n "${HM_SITE_DOMAIN:-}" ]] || {
    hm_err "Wejdź w kontekst: use <domena>"
    return 1
  }
  hm_access_require_site_user "${HM_SITE_DOMAIN}" >/dev/null || return 1
  return 0
}

hm_git_site_home() {
  local user home
  user="$(hm_access_require_site_user "${HM_SITE_DOMAIN}")" || return 1
  home="$(hm_access_unix_home "${user}")"
  [[ -n "${home}" && -d "${home}" ]] || {
    hm_err "Brak home dla ${user}"
    return 1
  }
  printf '%s' "$(realpath -m "${home}" 2>/dev/null || echo "${home}")"
}

hm_git_deploy_key_path() {
  local home
  home="$(hm_git_site_home)" || return 1
  printf '%s' "${home}/.ssh/hmtools_deploy"
}

hm_git_deploy_marker() {
  # plik konfiguracji deploy w katalogu repo lub site root
  local base="${1:-}"
  if [[ -n "${base}" && -f "${base}/.hmtools-deploy" ]]; then
    printf '%s' "${base}/.hmtools-deploy"
    return 0
  fi
  if [[ -n "${HM_SITE_ROOT:-}" && -f "${HM_SITE_ROOT}/.hmtools-deploy" ]]; then
    printf '%s' "${HM_SITE_ROOT}/.hmtools-deploy"
    return 0
  fi
  if [[ -n "${HM_SITE_DOCROOT:-}" && -f "${HM_SITE_DOCROOT}/.hmtools-deploy" ]]; then
    printf '%s' "${HM_SITE_DOCROOT}/.hmtools-deploy"
    return 0
  fi
  return 1
}

hm_git_read_cfg_path() {
  # ścieżka repo z .hmtools-deploy (klucz path=) lub domyślna
  local marker path=""
  if marker="$(hm_git_deploy_marker 2>/dev/null)"; then
    path="$(awk -F= 'tolower($1)=="path"{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}' "${marker}" 2>/dev/null || true)"
  fi
  if [[ -n "${path}" && -d "${path}" ]]; then
    printf '%s' "${path}"
    return 0
  fi
  # heurystyka: docroot, site root, site root/app
  local c
  for c in \
    "${HM_SITE_DOCROOT:-}" \
    "${HM_SITE_ROOT:-}" \
    "${HM_SITE_ROOT:-}/app" \
    "${HM_SITE_DOCROOT:-}/.."
  do
    [[ -n "${c}" ]] || continue
    c="$(realpath -m "${c}" 2>/dev/null || echo "${c}")"
    if [[ -d "${c}/.git" ]]; then
      printf '%s' "${c}"
      return 0
    fi
  done
  # domyślnie docroot nawet bez .git (attach)
  if [[ -n "${HM_SITE_DOCROOT:-}" && -d "${HM_SITE_DOCROOT}" ]]; then
    printf '%s' "${HM_SITE_DOCROOT}"
    return 0
  fi
  if [[ -n "${HM_SITE_ROOT:-}" && -d "${HM_SITE_ROOT}" ]]; then
    printf '%s' "${HM_SITE_ROOT}"
    return 0
  fi
  return 1
}

hm_git_ssh_cmd() {
  local key
  key="$(hm_git_deploy_key_path)" || return 1
  if [[ -f "${key}" ]]; then
    printf 'ssh -i %q -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new' "${key}"
  else
    printf 'ssh -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new'
  fi
}

# Uruchom komendę jako user strony z HOME + opcjonalnym GIT_SSH_COMMAND.
# Użycie: hm_git_run_as_user [--git-ssh] -- cmd args…
hm_git_run_as_user() {
  local use_git_ssh=0
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --git-ssh) use_git_ssh=1; shift ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  [[ $# -gt 0 ]] || return 1
  local user home
  user="$(hm_access_require_site_user "${HM_SITE_DOMAIN}")" || return 1
  home="$(hm_git_site_home)" || return 1

  local -a envp=(
    "HOME=${home}"
    "USER=${user}"
    "LOGNAME=${user}"
    "PATH=/usr/local/bin:/usr/bin:/bin"
  )
  if [[ "${use_git_ssh}" -eq 1 ]]; then
    local gssh
    gssh="$(hm_git_ssh_cmd)" || return 1
    envp+=("GIT_SSH_COMMAND=${gssh}")
  fi

  if [[ "$(id -u)" -eq 0 ]] && hm_have_cmd runuser; then
    runuser -u "${user}" -- env "${envp[@]}" "$@"
    return $?
  fi
  if [[ "$(id -u)" -eq 0 ]] && hm_have_cmd sudo; then
    sudo -u "${user}" -- env "${envp[@]}" "$@"
    return $?
  fi
  # nie-root: uruchom bezpośrednio (dev/test)
  env "${envp[@]}" "$@"
}

hm_git_ensure_ssh_dir() {
  local user home
  user="$(hm_access_require_site_user "${HM_SITE_DOMAIN}")" || return 1
  # reuse access ensure (authorized_keys) — tworzy ~/.ssh 700
  hm_access_ssh_keys_ensure_dir "${user}" >/dev/null || return 1
  home="$(hm_git_site_home)" || return 1
  hm_access_ssh_path_ok "${user}" "${home}" "${home}/.ssh" || return 1
}

hm_git_key_generate() {
  local force="${1:-0}"
  hm_git_require_site || return 1
  local user home key pub
  user="$(hm_access_require_site_user "${HM_SITE_DOMAIN}")" || return 1
  home="$(hm_git_site_home)" || return 1
  hm_git_ensure_ssh_dir || return 1
  key="$(hm_git_deploy_key_path)" || return 1
  pub="${key}.pub"

  if [[ -e "${key}" || -e "${pub}" ]]; then
    if [[ "${force}" -ne 1 ]]; then
      hm_info "Klucz już istnieje: ${key}"
      hm_git_key_show
      return 0
    fi
    if ! hm_confirm_plan "git key --force — ${HM_SITE_DOMAIN}" \
      "Nadpisanie istniejącego klucza deploy unieważni go w GitHub/GitLab." \
      "Usunięcie ${key} (+ .pub)" \
      "Generacja nowego ed25519 (user=${user}, mode 0600)"; then
      return 0
    fi
    hm_access_ssh_path_ok "${user}" "${home}" "${key}" 2>/dev/null || true
    rm -f "${key}" "${pub}" 2>/dev/null || true
  else
    if ! hm_confirm_plan "git key — ${HM_SITE_DOMAIN}" \
      "" \
      "Utworzenie ${key} (ed25519, 0600, owner=${user})" \
      "Wyświetlenie klucza publicznego do wklejenia w GitHub/GitLab Deploy keys"; then
      return 0
    fi
  fi

  # generuj jako user — unikamy root:root
  if ! hm_git_run_as_user -- ssh-keygen -t ed25519 -N "" -f "${key}" -C "hmtools-deploy@${HM_SITE_DOMAIN}"; then
    # fallback: install-owned empty + keygen z wymuszonym ownerem
    if hm_have_cmd install; then
      install -o "${user}" -g "${user}" -m 600 /dev/null "${key}" || return 1
      install -o "${user}" -g "${user}" -m 644 /dev/null "${pub}" || true
    fi
    if ! hm_git_run_as_user -- ssh-keygen -t ed25519 -N "" -f "${key}" -C "hmtools-deploy@${HM_SITE_DOMAIN}"; then
      hm_err "ssh-keygen nieudany."
      return 1
    fi
  fi

  # weryfikacja właściciela / symlink / mode
  if [[ -L "${key}" || -L "${pub}" ]]; then
    hm_err "Odmowa: klucz jest symlinkiem."
    rm -f "${key}" "${pub}" 2>/dev/null || true
    return 1
  fi
  hm_access_ssh_path_ok "${user}" "${home}" "${key}" || return 1
  chmod 600 "${key}"
  [[ -f "${pub}" ]] && chmod 644 "${pub}"
  local owner
  owner="$(stat -c '%U' "${key}" 2>/dev/null || true)"
  if [[ -n "${owner}" && "${owner}" != "${user}" ]]; then
    chown -h "${user}:${user}" "${key}" "${pub}" 2>/dev/null || {
      hm_err "Klucz ma owner=${owner}, oczekiwano ${user}."
      return 1
    }
  fi
  hm_ok "Utworzono klucz deploy."
  hm_git_key_show
}

hm_git_key_show() {
  hm_git_require_site || return 1
  local user home key pub
  user="$(hm_access_require_site_user "${HM_SITE_DOMAIN}")" || return 1
  home="$(hm_git_site_home)" || return 1
  key="$(hm_git_deploy_key_path)" || return 1
  pub="${key}.pub"
  echo "${C_BOLD}Deploy key — ${HM_SITE_DOMAIN}${C_RESET}  (user=${user})"
  if [[ ! -f "${key}" ]]; then
    hm_info "Brak klucza. Wygeneruj: git key"
    return 0
  fi
  hm_access_ssh_path_ok "${user}" "${home}" "${key}" || return 1
  echo "  private: ${key}  mode=$(stat -c '%a' "${key}" 2>/dev/null || echo '?')  owner=$(stat -c '%U' "${key}" 2>/dev/null || echo '?')"
  if [[ -f "${pub}" ]]; then
    echo "  public:"
    # czytaj jako user
    hm_git_run_as_user -- cat "${pub}" 2>/dev/null | sed 's/^/    /' || cat "${pub}" | sed 's/^/    /'
  else
    hm_warn "Brak ${pub}"
  fi
  hm_info "Wklej klucz publiczny jako Deploy key (read-only) w GitHub/GitLab."
}

hm_git_status() {
  hm_git_require_site || return 1
  if ! hm_have_cmd git; then
    hm_err "Brak git w PATH."
    return 1
  fi
  local repo
  repo="$(hm_git_read_cfg_path)" || {
    hm_err "Brak katalogu repo (docroot/root)."
    return 1
  }
  echo "${C_BOLD}git — ${HM_SITE_DOMAIN}${C_RESET}"
  echo "  path: ${repo}"
  if [[ ! -d "${repo}/.git" ]]; then
    hm_warn "Brak .git w ${repo}. Podłącz: git attach <url>"
    local key
    key="$(hm_git_deploy_key_path 2>/dev/null || true)"
    [[ -f "${key}" ]] && echo "  deploy-key: ${key}" || echo "  deploy-key: (brak — git key)"
    return 0
  fi
  local branch remote sha dirty ahead
  branch="$(hm_git_run_as_user --git-ssh -- git -C "${repo}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  remote="$(hm_git_run_as_user --git-ssh -- git -C "${repo}" remote get-url origin 2>/dev/null || echo '-')"
  sha="$(hm_git_run_as_user --git-ssh -- git -C "${repo}" rev-parse --short HEAD 2>/dev/null || echo '?')"
  dirty="$(hm_git_run_as_user -- git -C "${repo}" status --porcelain 2>/dev/null || true)"
  echo "  branch: ${branch}"
  echo "  remote: ${remote}"
  echo "  commit: ${sha}"
  if [[ -n "${dirty}" ]]; then
    echo "  dirty:  TAK (lokalne zmiany — deploy zablokowany bez --force)"
    printf '%s\n' "${dirty}" | head -20 | sed 's/^/    /'
  else
    echo "  dirty:  nie"
  fi
  local marker logf
  marker="$(hm_git_deploy_marker "${repo}" 2>/dev/null || true)"
  [[ -n "${marker}" ]] && echo "  config: ${marker}"
  logf="${repo}/.hmtools-deploy.log"
  if [[ -f "${logf}" ]]; then
    echo "  last deploy:"
    tail -n 3 "${logf}" | sed 's/^/    /'
  fi
}

hm_git_attach() {
  hm_git_require_site || return 1
  if ! hm_have_cmd git; then
    hm_err "Brak git w PATH."
    return 1
  fi
  local url="" branch="main" path="" auto_yes=0
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --branch|-b) branch="${2:-main}"; shift 2 || true ;;
      --branch=*) branch="${1#*=}"; shift ;;
      --path|-C) path="${2:-}"; shift 2 || true ;;
      --path=*) path="${1#*=}"; shift ;;
      --yes|-y) auto_yes=1; shift ;;
      help|-h|--help)
        echo "Użycie: git attach <url> [--branch main] [--path <katalog>]"
        return 0
        ;;
      -*)
        hm_err "Nieznana flaga: ${1}"
        return 1
        ;;
      *)
        if [[ -z "${url}" ]]; then url="${1}"; else
          hm_err "Niespodziewany argument: ${1}"; return 1
        fi
        shift
        ;;
    esac
  done
  [[ -n "${url}" ]] || { hm_err "Użycie: git attach <url> [--branch main] [--path …]"; return 1; }
  # prosta walidacja URL (git@ / https / ssh)
  case "${url}" in
    git@*|ssh://*|https://*|http://*|*/*.git) ;;
    *)
      hm_err "Podejrzany URL repo: ${url}"
      return 1
      ;;
  esac
  if [[ -z "${path}" ]]; then
    path="$(hm_git_read_cfg_path)" || path="${HM_SITE_DOCROOT:-${HM_SITE_ROOT}}"
  fi
  path="$(realpath -m "${path}" 2>/dev/null || echo "${path}")"
  local user home
  user="$(hm_access_require_site_user "${HM_SITE_DOMAIN}")" || return 1
  home="$(hm_git_site_home)" || return 1
  # path musi być ⊆ home lub site root
  local root_ok="${HM_SITE_ROOT:-${home}}"
  root_ok="$(realpath -m "${root_ok}" 2>/dev/null || echo "${root_ok}")"
  case "${path}" in
    "${root_ok}"|"${root_ok}"/*|"${home}"|"${home}"/*) ;;
    *)
      hm_err "Ścieżka ${path} poza home/site root (${root_ok})."
      return 1
      ;;
  esac

  local -a steps=(
    "Katalog docelowy: ${path}"
    "git clone/fetch origin ${url} (branch ${branch}) jako ${user}"
    "Zapis path= w .hmtools-deploy"
  )
  if [[ "${auto_yes}" -eq 1 ]]; then
    if ! hm_confirm_plan "git attach — ${HM_SITE_DOMAIN}" "" --yes "${steps[@]}"; then
      return 1
    fi
  else
    if ! hm_confirm_plan "git attach — ${HM_SITE_DOMAIN}" \
      "Klonowanie/przypięcie zdalnego repozytorium do katalogu strony." \
      "${steps[@]}"; then
      return 0
    fi
  fi

  hm_git_ensure_ssh_dir || true
  if [[ ! -d "${path}" ]]; then
    if hm_have_cmd install; then
      install -d -o "${user}" -g "${user}" -m 755 "${path}" || return 1
    else
      mkdir -p "${path}" && chown -h "${user}:${user}" "${path}"
    fi
  fi

  if [[ -d "${path}/.git" ]]; then
    hm_info "Repo już istnieje — ustawiam remote origin + fetch."
    hm_git_run_as_user --git-ssh -- git -C "${path}" remote remove origin 2>/dev/null || true
    hm_git_run_as_user --git-ssh -- git -C "${path}" remote add origin "${url}" || return 1
    hm_git_run_as_user --git-ssh -- git -C "${path}" fetch origin "${branch}" || return 1
    hm_git_run_as_user --git-ssh -- git -C "${path}" checkout -B "${branch}" "origin/${branch}" || \
      hm_git_run_as_user --git-ssh -- git -C "${path}" checkout "${branch}" || return 1
  else
    # pusty katalog → clone .
    local entries
    entries="$(hm_git_run_as_user -- ls -A "${path}" 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "${entries}" != "0" ]]; then
      hm_err "Katalog ${path} niepusty i bez .git — podaj --path lub wyczyść."
      return 1
    fi
    hm_git_run_as_user --git-ssh -- git clone --branch "${branch}" --single-branch "${url}" "${path}" || return 1
  fi

  # zapisz path w markerze
  local marker="${path}/.hmtools-deploy"
  local tmp
  tmp="$(hm_mktemp .deploy)"
  {
    echo "# hmtools deploy config — ${HM_SITE_DOMAIN}"
    echo "path=${path}"
    echo "branch=${branch}"
    echo "# build steps (whitelist: composer|npm|yarn|pnpm|php artisan …)"
    echo "#build=composer install --no-dev --optimize-autoloader"
    echo "#build=npm ci && npm run build"
  } > "${tmp}"
  if [[ -f "${marker}" ]]; then
    # zaktualizuj path/branch, zachowaj build=
    awk -v p="${path}" -v b="${branch}" '
      BEGIN{hp=0;hb=0}
      /^[ \t]*path=/ { print "path=" p; hp=1; next }
      /^[ \t]*branch=/ { print "branch=" b; hb=1; next }
      { print }
      END {
        if (!hp) print "path=" p
        if (!hb) print "branch=" b
      }
    ' "${marker}" > "${tmp}"
  fi
  # zapis jako user (tee)
  if hm_have_cmd runuser && [[ "$(id -u)" -eq 0 ]]; then
    runuser -u "${user}" -- tee "${marker}" < "${tmp}" >/dev/null || {
      cat "${tmp}" > "${marker}"
      chown -h "${user}:${user}" "${marker}"
    }
  else
    cat "${tmp}" > "${marker}"
    chown -h "${user}:${user}" "${marker}" 2>/dev/null || true
  fi
  rm -f "${tmp}"
  chmod 644 "${marker}" 2>/dev/null || true
  hm_ok "Przypięto ${url} → ${path} (${branch})"
  hm_git_status
}

cmd_git() {
  local sub="${1:-status}"
  shift || true
  case "${sub}" in
    ""|status|st|info)
      hm_git_status
      ;;
    key|keys|deploy-key)
      local force=0
      case "${1:-}" in
        --force|-f|force) force=1 ;;
        show|pub|"") ;;
        help|-h|--help)
          echo "Użycie: git key [--force]"
          return 0
          ;;
      esac
      if [[ "${force}" -eq 1 || ! -f "$(hm_git_deploy_key_path 2>/dev/null || echo /nonexistent)" ]]; then
        hm_git_key_generate "${force}"
      else
        hm_git_key_show
      fi
      ;;
    attach|clone|add)
      hm_git_attach "$@"
      ;;
    path)
      hm_git_require_site || return 1
      if [[ -n "${1:-}" ]]; then
        hm_err "Zmiana path: edytuj .hmtools-deploy lub: git attach <url> --path ${1}"
        return 1
      fi
      hm_git_read_cfg_path
      ;;
    help|-h|--help)
      hm_help_topic git
      ;;
    *)
      hm_err "Nieznane: git ${sub}. help git"
      return 1
      ;;
  esac
}

_hm_cmd_register git cmd_git 0
_hm_cmd_register_site git cmd_git
