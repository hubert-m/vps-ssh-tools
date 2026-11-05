#!/usr/bin/env bash
# deploy — pull + build (whitelist) + reload PHP/PM2 + rollback


_hm_cmd_help deploy <<'EOF'
Użycie (kontekst strony) — git:
  deploy [--branch main] [--no-build] [--force] [--yes]
  deploy rollback [<sha>]
  deploy config [--init]
  deploy log

Użycie — staging → produkcja (moduł clone; gdy 1. arg = domena):
  deploy <produkcja> [--files] [--db] [--exclude PATH] [--yes]
  deploy rollback <stamp>          (snapshot w /var/lib/hmtools/deploy-snaps/)
  staging deploy <produkcja> […]   (to samo)

Git: dirty → fetch → pull --ff-only → build whitelist → reload PHP/PM2.
Staging: obowiązkowy snapshot produkcji przed rsync/DB; confirm_critical.
EOF

hm_deploy_log_path() {
  local repo
  repo="$(hm_git_read_cfg_path)" || return 1
  printf '%s' "${repo}/.hmtools-deploy.log"
}

hm_deploy_log_append() {
  local repo msg="$1"
  local logf user
  repo="$(hm_git_read_cfg_path)" || return 1
  logf="${repo}/.hmtools-deploy.log"
  user="$(hm_access_require_site_user "${HM_SITE_DOMAIN}" 2>/dev/null || echo "")"
  local line
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) ${msg}"
  if [[ -n "${user}" ]] && hm_have_cmd runuser && [[ "$(id -u)" -eq 0 ]]; then
    printf '%s\n' "${line}" | runuser -u "${user}" -- tee -a "${logf}" >/dev/null 2>&1 || \
      printf '%s\n' "${line}" >> "${logf}"
  else
    printf '%s\n' "${line}" >> "${logf}"
  fi
  if [[ -n "${user}" ]]; then
    chown -h "${user}:${user}" "${logf}" 2>/dev/null || true
  fi
}

hm_deploy_last_sha() {
  local logf
  logf="$(hm_deploy_log_path 2>/dev/null || true)"
  [[ -f "${logf}" ]] || return 1
  # szukaj ostatniego DEPLOY ok sha=
  awk '/DEPLOY ok sha=/{sha=$0; sub(/.*sha=/,"",sha); sub(/ .*/,"",sha); last=sha} END{if(last) print last}' "${logf}"
}

hm_deploy_prev_sha() {
  # SHA przed ostatnim udanym deployem (do rollback bez argumentu)
  local logf
  logf="$(hm_deploy_log_path 2>/dev/null || true)"
  [[ -f "${logf}" ]] || return 1
  awk '
    /DEPLOY ok sha=/ {
      sha=$0; sub(/.*sha=/,"",sha); sub(/ .*/,"",sha);
      if (prev!="") { pprev=prev }
      prev=sha
    }
    /PREV sha=/ {
      p=$0; sub(/.*sha=/,"",p); sub(/ .*/,"",p); lastprev=p
    }
    END {
      if (lastprev!="") print lastprev
      else if (pprev!="") print pprev
    }
  ' "${logf}"
}

# Whitelist build line: composer|npm|yarn|pnpm|php (+ artisan) oraz && / ;
hm_deploy_build_line_ok() {
  local line="$1"
  # usuń komentarze / puste
  [[ -n "${line}" ]] || return 1
  [[ "${line}" =~ ^[#\;] ]] && return 1
  # zabronione metaznaki
  case "${line}" in
    *'`'*|*'$('*|*'>'*|*'\<'*|*'|'*|*';'*|*'\n'*) return 1 ;;
  esac
  # każdy segment po && musi zaczynać się od dozwolonego bin
  local seg rest="${line}"
  while [[ -n "${rest}" ]]; do
    if [[ "${rest}" == *"&&"* ]]; then
      seg="${rest%%&&*}"
      rest="${rest#*&&}"
    else
      seg="${rest}"
      rest=""
    fi
    seg="${seg#"${seg%%[![:space:]]*}"}"
    seg="${seg%"${seg##*[![:space:]]}"}"
    [[ -n "${seg}" ]] || continue
    case "${seg}" in
      composer\ *|composer)
        ;;
      npm\ *|npm)
        ;;
      yarn\ *|yarn)
        ;;
      pnpm\ *|pnpm)
        ;;
      php\ artisan*|php)
        ;;
      npx\ *)
        ;;
      *)
        return 1
        ;;
    esac
  done
  return 0
}

hm_deploy_read_build_steps() {
  local marker repo
  repo="$(hm_git_read_cfg_path)" || return 1
  marker="$(hm_git_deploy_marker "${repo}" 2>/dev/null || true)"
  [[ -n "${marker}" && -f "${marker}" ]] || return 0
  local line raw
  while IFS= read -r line || [[ -n "${line}" ]]; do
    raw="${line}"
    [[ "${raw}" =~ ^[Bb][Uu][Ii][Ll][Dd]= ]] || continue
    raw="${raw#*=}"
    raw="${raw#"${raw%%[![:space:]]*}"}"
    if hm_deploy_build_line_ok "${raw}"; then
      printf '%s\n' "${raw}"
    else
      hm_warn "Pominięto niebezpieczny/niewhitelistowany build=: ${raw}" >&2
    fi
  done < "${marker}"
}

hm_deploy_run_build() {
  local repo="$1"
  local step rc=0
  local -a steps=()
  while IFS= read -r step; do
    [[ -n "${step}" ]] && steps+=("${step}")
  done < <(hm_deploy_read_build_steps)
  if [[ "${#steps[@]}" -eq 0 ]]; then
    hm_info "Brak kroków build w .hmtools-deploy — pomijam."
    return 0
  fi
  for step in "${steps[@]}"; do
    hm_info "build: ${step}"
    # shellcheck disable=SC2086
    if ! hm_git_run_as_user -- bash -lc "cd $(printf '%q' "${repo}") && ${step}"; then
      hm_err "Build nieudany: ${step}"
      return 1
    fi
  done
  return 0
}

hm_deploy_reload_services() {
  # PHP workers strony + opcjonalnie PM2 reload all w PM2_HOME strony
  if declare -F hm_php_restart_workers >/dev/null 2>&1; then
    hm_php_restart_workers || true
  fi
  if declare -F hm_ols_reload_soft >/dev/null 2>&1; then
    hm_ols_reload_soft || true
  fi
  if declare -F hm_pm2_ctl >/dev/null 2>&1 && declare -F hm_pm2_home_dirs >/dev/null 2>&1; then
    local home
    home="$(hm_pm2_home_dirs 2>/dev/null | head -1 || true)"
    if [[ -n "${home}" ]]; then
      hm_info "pm2 reload all (PM2_HOME=${home})"
      # bez confirm — już w planie deploy
      if declare -F hm_pm2_run_as_owner >/dev/null 2>&1; then
        hm_pm2_run_as_owner "${home}" reload all 2>/dev/null || \
          hm_pm2_run_as_owner "${home}" restart all 2>/dev/null || true
      fi
    fi
  fi
}

cmd_deploy() {
  local sub="${1:-}"

  # Staging/clone: deploy <domena-prod> … albo rollback stamp ze snaps clone
  if declare -F hm_clone_deploy >/dev/null 2>&1; then
    if [[ -n "${sub}" ]] && hm_is_valid_domain "${sub}" 2>/dev/null; then
      hm_clone_deploy "$@"
      return $?
    fi
    if [[ "${sub}" == "rollback" || "${sub}" == "rb" || "${sub}" == "undo" ]]; then
      local stamp="${2:-}" snap
      if [[ -n "${stamp}" ]] && declare -F hm_clone_snap_root >/dev/null 2>&1; then
        snap="$(hm_clone_snap_root "${HM_SITE_DOMAIN:-}")/${stamp}"
        if [[ -d "${snap}" && -f "${snap}/meta.txt" ]]; then
          hm_clone_deploy "$@"
          return $?
        fi
      fi
    fi
  fi

  # jeśli pierwszy arg to flaga lub puste → run deploy (git)
  case "${sub}" in
    rollback|rb|undo)
      shift || true
      hm_deploy_rollback "$@"
      return $?
      ;;
    config|cfg)
      shift || true
      hm_deploy_config "$@"
      return $?
      ;;
    log|logs)
      hm_git_require_site || return 1
      local logf
      logf="$(hm_deploy_log_path)" || { hm_err "Brak repo."; return 1; }
      if [[ -f "${logf}" ]]; then
        tail -n "${2:-30}" "${logf}"
      else
        hm_info "Brak ${logf}"
      fi
      return 0
      ;;
    help|-h|--help)
      hm_help_topic deploy
      return 0
      ;;
    ""|--*)
      ;;
    *)
      if [[ "${sub}" != --* && "${sub}" != "" ]]; then
        :
      fi
      ;;
  esac
  hm_deploy_run "$@"
}

hm_deploy_config() {
  hm_git_require_site || return 1
  local init=0
  case "${1:-}" in
    --init|init|create) init=1 ;;
    help|-h|--help)
      echo "Użycie: deploy config [--init]"
      return 0
      ;;
  esac
  local repo marker
  repo="$(hm_git_read_cfg_path)" || return 1
  marker="${repo}/.hmtools-deploy"
  if [[ ! -f "${marker}" ]]; then
    if [[ "${init}" -ne 1 ]]; then
      hm_info "Brak ${marker}. Utwórz: deploy config --init"
      return 0
    fi
    local user
    user="$(hm_access_require_site_user "${HM_SITE_DOMAIN}")" || return 1
    if ! hm_confirm_plan "deploy config --init — ${HM_SITE_DOMAIN}" \
      "" \
      "Utworzenie ${marker} z przykładowymi krokami build (zakomentowane)"; then
      return 0
    fi
    local tmp
    tmp="$(hm_mktemp .deploy)"
    cat > "${tmp}" <<EOF
# hmtools deploy — ${HM_SITE_DOMAIN}
path=${repo}
branch=main
# Odkomentuj dozwolone kroki (whitelist: composer / npm / yarn / pnpm / php artisan):
#build=composer install --no-dev --optimize-autoloader
#build=npm ci
#build=npm run build
#build=php artisan migrate --force
EOF
    if hm_have_cmd runuser && [[ "$(id -u)" -eq 0 ]]; then
      runuser -u "${user}" -- tee "${marker}" < "${tmp}" >/dev/null || cat "${tmp}" > "${marker}"
      chown -h "${user}:${user}" "${marker}" 2>/dev/null || true
    else
      cat "${tmp}" > "${marker}"
    fi
    rm -f "${tmp}"
    hm_ok "Utworzono ${marker}"
  fi
  echo "${C_BOLD}deploy config — ${marker}${C_RESET}"
  cat "${marker}"
  echo
  echo "${C_BOLD}Aktywne kroki build:${C_RESET}"
  local s any=0
  while IFS= read -r s; do
    echo "  - ${s}"
    any=1
  done < <(hm_deploy_read_build_steps)
  [[ "${any}" -eq 1 ]] || echo "  (brak — odkomentuj build= w pliku)"
}

hm_deploy_run() {
  hm_git_require_site || return 1
  if ! hm_have_cmd git; then
    hm_err "Brak git w PATH."
    return 1
  fi
  local branch="" no_build=0 force=0 auto_yes=0
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --branch|-b) branch="${2:-}"; shift 2 || true ;;
      --branch=*) branch="${1#*=}"; shift ;;
      --no-build) no_build=1; shift ;;
      --force|-f) force=1; shift ;;
      --yes|-y) auto_yes=1; shift ;;
      help|-h|--help)
        hm_help_topic deploy
        return 0
        ;;
      *)
        hm_err "Nieznany argument: ${1}"
        return 1
        ;;
    esac
  done

  local repo user
  repo="$(hm_git_read_cfg_path)" || return 1
  user="$(hm_access_require_site_user "${HM_SITE_DOMAIN}")" || return 1
  [[ -d "${repo}/.git" ]] || {
    hm_err "Brak .git w ${repo}. Najpierw: git attach <url>"
    return 1
  }

  # branch z cfg jeśli nie podano
  if [[ -z "${branch}" ]]; then
    local marker
    marker="$(hm_git_deploy_marker "${repo}" 2>/dev/null || true)"
    if [[ -n "${marker}" ]]; then
      branch="$(awk -F= 'tolower($1)=="branch"{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}' "${marker}" 2>/dev/null || true)"
    fi
  fi
  if [[ -z "${branch}" ]]; then
    branch="$(hm_git_run_as_user -- git -C "${repo}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
  fi

  local dirty
  dirty="$(hm_git_run_as_user -- git -C "${repo}" status --porcelain 2>/dev/null || true)"
  if [[ -n "${dirty}" && "${force}" -ne 1 ]]; then
    hm_err "Lokalne zmiany w ${repo} — deploy zablokowany."
    printf '%s\n' "${dirty}" | head -20 | sed 's/^/  /'
    hm_info "Schowaj zmiany albo użyj: deploy --force (ostrożnie)."
    return 1
  fi

  hm_info "git fetch origin ${branch}…"
  if ! hm_git_run_as_user --git-ssh -- git -C "${repo}" fetch origin "${branch}"; then
    hm_err "git fetch nieudany (klucz deploy? git key)."
    return 1
  fi

  local cur_sha remote_sha range
  cur_sha="$(hm_git_run_as_user -- git -C "${repo}" rev-parse HEAD 2>/dev/null || true)"
  remote_sha="$(hm_git_run_as_user -- git -C "${repo}" rev-parse "origin/${branch}" 2>/dev/null || true)"
  [[ -n "${remote_sha}" ]] || {
    hm_err "Brak origin/${branch} po fetch."
    return 1
  }

  if [[ "${cur_sha}" == "${remote_sha}" ]]; then
    hm_ok "Już aktualne (${cur_sha:0:8}) — brak commitów do wdrożenia."
    return 0
  fi

  range="$(hm_git_run_as_user -- git -C "${repo}" log --oneline "${cur_sha}..${remote_sha}" 2>/dev/null | head -30 || true)"

  local -a steps=(
    "Zapis PREV sha=${cur_sha:0:12} do .hmtools-deploy.log"
    "git pull --ff-only origin ${branch}  (${cur_sha:0:8} → ${remote_sha:0:8}) jako ${user}"
  )
  if [[ "${no_build}" -eq 0 ]]; then
    local bs
    while IFS= read -r bs; do
      [[ -n "${bs}" ]] && steps+=("build: ${bs}")
    done < <(hm_deploy_read_build_steps)
  else
    steps+=("Pominięcie build (--no-build)")
  fi
  steps+=("Reload: php workers strony + opcjonalnie pm2 reload")
  steps+=("Log DEPLOY ok sha=${remote_sha:0:12}")

  local warn="" short_c
  [[ "${force}" -eq 1 && -n "${dirty}" ]] && warn="--force: lokalne zmiany zostaną nadpisane przez pull/reset."
  if [[ -n "${range}" ]]; then
    short_c="$(printf '%s\n' "${range}" | awk '{print $1}' | head -5 | paste -sd',' -)"
    warn="${warn:+${warn} }Commity: ${short_c}"
  fi

  if [[ "${auto_yes}" -eq 1 ]]; then
    if ! hm_confirm_plan "deploy — ${HM_SITE_DOMAIN}" "${warn}" --yes "${steps[@]}"; then
      return 1
    fi
  else
    echo "${C_BOLD}Commity do wdrożenia:${C_RESET}"
    if [[ -n "${range}" ]]; then
      printf '%s\n' "${range}" | sed 's/^/  /'
    else
      echo "  (brak listy — fast-forward?)"
    fi
    if ! hm_confirm_plan "deploy — ${HM_SITE_DOMAIN}" "${warn}" "${steps[@]}"; then
      return 0
    fi
  fi

  hm_deploy_log_append "PREV sha=${cur_sha} branch=${branch}"

  if [[ "${force}" -eq 1 && -n "${dirty}" ]]; then
    hm_git_run_as_user --git-ssh -- git -C "${repo}" reset --hard "origin/${branch}" || {
      hm_err "git reset --hard nieudany"
      return 1
    }
  else
    if ! hm_git_run_as_user --git-ssh -- git -C "${repo}" pull --ff-only origin "${branch}"; then
      hm_err "git pull --ff-only nieudany"
      return 1
    fi
  fi

  local new_sha
  new_sha="$(hm_git_run_as_user -- git -C "${repo}" rev-parse HEAD 2>/dev/null || true)"

  if [[ "${no_build}" -eq 0 ]]; then
    if ! hm_deploy_run_build "${repo}"; then
      hm_err "Build fail — rozważ: deploy rollback ${cur_sha}"
      hm_deploy_log_append "DEPLOY fail sha=${new_sha} build=error prev=${cur_sha}"
      return 1
    fi
  fi

  hm_deploy_reload_services
  hm_deploy_log_append "DEPLOY ok sha=${new_sha} prev=${cur_sha} branch=${branch}"
  hm_ok "Deploy OK: ${cur_sha:0:8} → ${new_sha:0:8} (${branch})"
}

hm_deploy_rollback() {
  hm_git_require_site || return 1
  local sha="${1:-}" auto_yes=0
  shift || true
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --yes|-y) auto_yes=1; shift ;;
      *) shift ;;
    esac
  done

  local repo
  repo="$(hm_git_read_cfg_path)" || return 1
  [[ -d "${repo}/.git" ]] || { hm_err "Brak .git"; return 1; }

  if [[ -z "${sha}" ]]; then
    sha="$(hm_deploy_prev_sha 2>/dev/null || true)"
  fi
  if [[ -z "${sha}" ]]; then
    hm_err "Brak SHA do rollback (brak wpisu PREV w .hmtools-deploy.log). Podaj: deploy rollback <sha>"
    return 1
  fi

  # zweryfikuj obiekt
  if ! hm_git_run_as_user -- git -C "${repo}" cat-file -t "${sha}" >/dev/null 2>&1; then
    hm_err "Nieznany commit: ${sha}"
    return 1
  fi

  local cur
  cur="$(hm_git_run_as_user -- git -C "${repo}" rev-parse HEAD)"
  local -a steps=(
    "git reset --hard ${sha} w ${repo} (obecnie ${cur:0:8})"
    "Reload PHP/PM2"
    "Wpis ROLLBACK w .hmtools-deploy.log"
  )
  if [[ "${auto_yes}" -eq 1 ]]; then
    if ! hm_confirm_plan "deploy rollback — ${HM_SITE_DOMAIN}" \
      "Hard reset kodu do ${sha}." --yes "${steps[@]}"; then
      return 1
    fi
  else
    if ! hm_confirm_plan_critical "${HM_SITE_DOMAIN}" "deploy rollback — ${HM_SITE_DOMAIN}" \
      "Hard reset do ${sha} — utrata commitów nowszych lokalnie." \
      "${steps[@]}"; then
      return 0
    fi
  fi

  if ! hm_git_run_as_user --git-ssh -- git -C "${repo}" reset --hard "${sha}"; then
    hm_err "rollback nieudany"
    return 1
  fi
  hm_deploy_reload_services
  local now
  now="$(hm_git_run_as_user -- git -C "${repo}" rev-parse HEAD)"
  hm_deploy_log_append "ROLLBACK ok sha=${now} from=${cur}"
  hm_ok "Rollback OK → ${now:0:8}"
}

_hm_cmd_register deploy cmd_deploy 0
_hm_cmd_register_site deploy cmd_deploy
