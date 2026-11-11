#!/usr/bin/env bash
# node — nvm i npm w katalogu domowym serwisu (obok public_html)
# Procesy Node/React/Next zostają przy `pm2` / `apps`.

_hm_cmd_help node <<'EOF'
Użycie (globalnie):
  node | node sites [--json]         Serwisy z katalogiem .nvm i/lub .npm
  node update nvm <domena> [--yes]  Aktualizacja nvm w ~/.nvm tej strony
  node update npm <domena> [--yes]  npm install -g npm@<najnowsza> jako user strony

Użycie (kontekst [domena]>):
  node                               Wersje nvm/npm tej strony (obecna vs najnowsza)
  node update nvm|npm [--yes]

Kryterium: katalog domowy serwisu = rodzic public_html.
  .nvm  — instalacja nvm
  .npm  — instalacja/cache npm
Brak obu katalogów = serwis pominięty na liście.

Najnowsze wersje: GitHub releases (nvm) i registry.npmjs.org (npm).
Podmiana tylko po planie (yes). `node` nie jest aliasem pm2.
EOF

# Rodzic public_html (katalog domowy serwisu). Stdout: home \t user
hm_node_home_for_site() {
  local domain="$1" row root doc rest user home
  [[ -n "${domain}" ]] || return 1
  row="$(hm_resolve_site_paths "${domain}" 2>/dev/null || true)"
  [[ -n "${row}" ]] || return 1
  IFS=$'\t' read -r _ root doc _ _ _ rest <<<"${row}"
  root="$(hm_tsv_unfield "${root}")"
  doc="$(hm_tsv_unfield "${doc}")"
  user="${rest%%|*}"
  user="$(hm_tsv_unfield "${user}")"
  if [[ -n "${doc}" && "$(basename "${doc}")" == "public_html" ]]; then
    home="$(dirname "${doc}")"
  elif [[ -n "${root}" && -d "${root}/public_html" ]]; then
    home="${root}"
  elif [[ -d "/home/${domain}" ]]; then
    home="/home/${domain}"
  else
    home="${root}"
  fi
  [[ -n "${home}" && -d "${home}" ]] || return 1
  if [[ -z "${user}" ]]; then
    user="$(stat -c '%U' "${home}" 2>/dev/null || true)"
    case "${user}" in
      root|nobody|www-data|apache|nginx|"") user="" ;;
    esac
  fi
  printf '%s\t%s\n' "$(hm_node_tsv "${home}")" "$(hm_node_tsv "${user}")"
}

hm_node_semver() {
  local raw="${1:-}"
  raw="$(printf '%s' "${raw}" | tr -d '\r')"
  printf '%s' "${raw}" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# -1 gdy a < b, 0 gdy równe, 1 gdy a > b
hm_node_ver_cmp() {
  local a="${1#v}" b="${2#v}" lo
  [[ -n "${a}" && -n "${b}" ]] || { printf '?'; return 0; }
  if [[ "${a}" == "${b}" ]]; then
    printf '0'
    return 0
  fi
  lo="$(printf '%s\n%s\n' "${a}" "${b}" | sort -V | head -1)"
  if [[ "${lo}" == "${a}" ]]; then
    printf '%s' '-1'
  else
    printf '%s' '1'
  fi
}

hm_node_run_as_user() {
  local user="$1" home="$2"
  shift 2 || true
  [[ -n "${user}" && -n "${home}" ]] || return 1
  if [[ "$(id -u)" -eq 0 ]] && hm_have_cmd runuser; then
    runuser -u "${user}" -- env HOME="${home}" USER="${user}" LOGNAME="${user}" "$@"
    return $?
  fi
  if [[ "$(id -u)" -eq 0 ]] && hm_have_cmd sudo; then
    sudo -u "${user}" -- env HOME="${home}" USER="${user}" LOGNAME="${user}" "$@"
    return $?
  fi
  if [[ "$(id -un)" == "${user}" || "$(id -u)" -ne 0 ]]; then
    env HOME="${home}" USER="${user}" LOGNAME="${user}" "$@"
    return $?
  fi
  hm_err "Nie mogę uruchomić polecenia jako ${user}."
  return 1
}

# Wersja z package.json — odczyt pliku, bez uruchamiania kodu.
hm_node_read_pkg_version() {
  local file="$1" raw
  [[ -f "${file}" && ! -L "${file}" ]] || return 1
  raw="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${file}" | head -1)"
  raw="$(hm_node_semver "${raw}")"
  [[ -n "${raw}" ]] || return 1
  printf '%s' "${raw}"
}

# Wersja nvm z plików (package.json, potem literał w nvm.sh). Bez source i bez git -c safe.directory.
hm_node_nvm_version() {
  local dir="$1" v="" line=""
  [[ -d "${dir}" ]] || return 1
  if [[ -f "${dir}/package.json" && ! -L "${dir}/package.json" ]]; then
    v="$(hm_node_read_pkg_version "${dir}/package.json" 2>/dev/null || true)"
  fi
  if [[ -z "${v}" && -f "${dir}/nvm.sh" && ! -L "${dir}/nvm.sh" ]]; then
    line="$(grep -E -m1 \
      'nvm_echo[[:space:]]+"[0-9]+\.[0-9]+\.[0-9]+"|NVM_VERSION[=[:space:]]+"?[0-9]+\.[0-9]+\.[0-9]+' \
      "${dir}/nvm.sh" 2>/dev/null || true)"
    v="$(hm_node_semver "${line}")"
  fi
  [[ -n "${v}" ]] || return 1
  printf '%s' "${v}"
}

# Binarka npm: domyślny Node z nvm, inaczej npm na PATH użytkownika strony.
hm_node_npm_bin() {
  local home="$1" user="${2:-}" nvm def ver base p
  nvm="${home}/.nvm"
  if [[ -d "${nvm}/versions/node" ]]; then
    def=""
    [[ -f "${nvm}/alias/default" ]] && def="$(tr -d '[:space:]' < "${nvm}/alias/default")"
    ver=""
    case "${def}" in
      v[0-9]*) ver="${def}" ;;
      [0-9]*)
        base="$(find "${nvm}/versions/node" -mindepth 1 -maxdepth 1 -type d -name "v${def}*" 2>/dev/null | sort -V | tail -1 || true)"
        ver="$(basename "${base:-}")"
        ;;
      *)
        base="$(find "${nvm}/versions/node" -mindepth 1 -maxdepth 1 -type d -name 'v*' 2>/dev/null | sort -V | tail -1 || true)"
        ver="$(basename "${base:-}")"
        ;;
    esac
    if [[ -n "${ver}" && -x "${nvm}/versions/node/${ver}/bin/npm" ]]; then
      printf '%s' "${nvm}/versions/node/${ver}/bin/npm"
      return 0
    fi
  fi
  if [[ -n "${user}" ]]; then
    p="$(hm_node_run_as_user "${user}" "${home}" bash -c 'command -v npm' 2>/dev/null || true)"
    p="$(printf '%s' "${p}" | tr -d '\r' | tail -1 | tr -d '[:space:]')"
    if [[ -n "${p}" && -x "${p}" ]]; then
      printf '%s' "${p}"
      return 0
    fi
  fi
  return 1
}

# Wersja npm z package.json obok binarki (…/lib/node_modules/npm). Bez uruchamiania npm.
hm_node_npm_version() {
  local bin="$1" prefix pkg v
  [[ -n "${bin}" ]] || return 1
  prefix="$(cd "$(dirname "${bin}")/.." 2>/dev/null && pwd)" || return 1
  pkg="${prefix}/lib/node_modules/npm/package.json"
  [[ -f "${pkg}" && ! -L "${pkg}" ]] || return 1
  v="$(hm_node_read_pkg_version "${pkg}")" || return 1
  printf '%s' "${v}"
}

hm_node_load_latest() {
  [[ -n "${HM_NODE_LATEST_LOADED:-}" ]] && return 0
  HM_NODE_LATEST_LOADED=1
  HM_NODE_LATEST_NVM="${HM_NODE_LATEST_NVM:-}"
  HM_NODE_LATEST_NPM="${HM_NODE_LATEST_NPM:-}"
  hm_have_cmd curl || return 0
  local raw
  if [[ -z "${HM_NODE_LATEST_NVM}" ]]; then
    raw="$(curl -fsSL --max-time 20 https://api.github.com/repos/nvm-sh/nvm/releases/latest 2>/dev/null || true)"
    HM_NODE_LATEST_NVM="$(hm_node_semver "$(printf '%s' "${raw}" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)")"
  fi
  if [[ -z "${HM_NODE_LATEST_NPM}" ]]; then
    raw="$(curl -fsSL --max-time 20 https://registry.npmjs.org/npm/latest 2>/dev/null || true)"
    HM_NODE_LATEST_NPM="$(hm_node_semver "$(printf '%s' "${raw}" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)")"
  fi
}

# return 0 gdy serwis ma .nvm lub .npm. Stdout TSV:
# home user has_nvm nvm_ver has_npm npm_ver
hm_node_probe_site() {
  local domain="$1" info home user has_nvm=0 has_npm=0 nvm_ver="" npm_ver="" npm_bin=""
  info="$(hm_node_home_for_site "${domain}")" || return 1
  IFS=$'\t' read -r home user <<<"${info}"
  home="$(hm_tsv_unfield "${home}")"
  user="$(hm_tsv_unfield "${user}")"
  [[ -d "${home}/.nvm" ]] && has_nvm=1
  [[ -d "${home}/.npm" ]] && has_npm=1
  [[ "${has_nvm}" -eq 1 || "${has_npm}" -eq 1 ]] || return 1
  if [[ "${has_nvm}" -eq 1 ]]; then
    nvm_ver="$(hm_node_nvm_version "${home}/.nvm" 2>/dev/null || true)"
  fi
  npm_bin="$(hm_node_npm_bin "${home}" "${user}" 2>/dev/null || true)"
  if [[ -n "${npm_bin}" ]]; then
    npm_ver="$(hm_node_npm_version "${npm_bin}" 2>/dev/null || true)"
  fi
  # Puste pola jako "-" — IFS=$'\t' skleja sąsiednie tabulatory.
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(hm_node_tsv "${home}")" "$(hm_node_tsv "${user}")" \
    "${has_nvm}" "$(hm_node_tsv "${nvm_ver}")" \
    "${has_npm}" "$(hm_node_tsv "${npm_ver}")"
}

hm_node_tsv() {
  if [[ -z "${1-}" ]]; then
    printf '-'
  else
    printf '%s' "$1"
  fi
}

hm_node_take_probe() {
  local line="$1"
  IFS=$'\t' read -r HM_NODE_HOME HM_NODE_USER HM_NODE_HAS_NVM HM_NODE_NVM_VER HM_NODE_HAS_NPM HM_NODE_NPM_VER <<<"${line}"
  HM_NODE_HOME="$(hm_tsv_unfield "${HM_NODE_HOME}")"
  HM_NODE_USER="$(hm_tsv_unfield "${HM_NODE_USER}")"
  HM_NODE_NVM_VER="$(hm_tsv_unfield "${HM_NODE_NVM_VER}")"
  HM_NODE_NPM_VER="$(hm_tsv_unfield "${HM_NODE_NPM_VER}")"
}

hm_node_update_mark() {
  local has_nvm="$1" nvm_ver="$2" has_npm="$3" npm_ver="$4"
  local nvm_l="${HM_NODE_LATEST_NVM:-}" npm_l="${HM_NODE_LATEST_NPM:-}"
  local parts="" unknown=0
  if [[ "${has_nvm}" == "1" ]]; then
    if [[ -z "${nvm_ver}" || -z "${nvm_l}" ]]; then
      unknown=1
    elif [[ "$(hm_node_ver_cmp "${nvm_ver}" "${nvm_l}")" == "-1" ]]; then
      parts="${parts}nvm "
    fi
  fi
  if [[ "${has_npm}" == "1" || -n "${npm_ver}" ]]; then
    if [[ -z "${npm_ver}" || -z "${npm_l}" ]]; then
      unknown=1
    elif [[ "$(hm_node_ver_cmp "${npm_ver}" "${npm_l}")" == "-1" ]]; then
      parts="${parts}npm "
    fi
  fi
  parts="${parts%" "}"
  if [[ -n "${parts}" ]]; then
    printf '%s' "${parts}"
  elif [[ "${unknown}" -eq 1 ]]; then
    printf '?'
  else
    printf 'nie'
  fi
}

hm_node_print_row() {
  local domain="$1" line home _user has_nvm nvm_ver has_npm npm_ver mark
  line="$(hm_node_probe_site "${domain}" 2>/dev/null || true)"
  [[ -n "${line}" ]] || return 1
  hm_node_take_probe "${line}"
  home="${HM_NODE_HOME}"
  has_nvm="${HM_NODE_HAS_NVM}"
  nvm_ver="${HM_NODE_NVM_VER}"
  has_npm="${HM_NODE_HAS_NPM}"
  npm_ver="${HM_NODE_NPM_VER}"
  mark="$(hm_node_update_mark "${has_nvm}" "${nvm_ver}" "${has_npm}" "${npm_ver}")"
  local nvm_show="-" npm_show="-" nvm_l="-" npm_l="-"
  [[ "${has_nvm}" == "1" ]] && nvm_show="${nvm_ver:-?}"
  [[ "${has_nvm}" == "1" && -n "${HM_NODE_LATEST_NVM:-}" ]] && nvm_l="${HM_NODE_LATEST_NVM}"
  if [[ "${has_npm}" == "1" || -n "${npm_ver}" ]]; then
    npm_show="${npm_ver:-?}"
    [[ -n "${HM_NODE_LATEST_NPM:-}" ]] && npm_l="${HM_NODE_LATEST_NPM}"
  fi
  hm_table_row "${domain}" "${nvm_show}" "${nvm_l}" "${npm_show}" "${npm_l}" "${mark}"
}

hm_node_list_sites() {
  hm_node_load_latest
  hm_discover_sites
  echo "${C_BOLD}nvm / npm — serwisy ${C_RESET}"
  if [[ -z "${HM_NODE_LATEST_NVM:-}" || -z "${HM_NODE_LATEST_NPM:-}" ]]; then
    hm_warn "Nie pobrano najnowszej wersji (nvm=${HM_NODE_LATEST_NVM:-?} npm=${HM_NODE_LATEST_NPM:-?})."
  else
    echo "  Najnowsze: nvm ${HM_NODE_LATEST_NVM}    npm ${HM_NODE_LATEST_NPM}"
  fi
  hm_table_begin
  hm_table_row DOMENA NVM NVM-NEW NPM NPM-NEW UPDATE
  local d found=0
  for d in "${HM_SITES_LIST[@]:-}"; do
    [[ -n "${d}" ]] || continue
    if hm_node_print_row "${d}"; then
      found=1
    fi
  done
  hm_table_print
  [[ "${found}" -eq 1 ]] || echo "  (brak serwisów z .nvm lub .npm)"
}

hm_node_print_one() {
  local domain="$1" line
  hm_node_load_latest
  echo "${C_BOLD}nvm / npm — ${domain}${C_RESET}"
  line="$(hm_node_probe_site "${domain}" 2>/dev/null || true)"
  if [[ -z "${line}" ]]; then
    local info home
    info="$(hm_node_home_for_site "${domain}" 2>/dev/null || true)"
    home="$(hm_tsv_unfield "${info%%$'\t'*}")"
    hm_warn "Brak .nvm i .npm w ${home:-katalogu serwisu} (obok public_html)."
    return 1
  fi
  hm_table_begin
  hm_table_row DOMENA NVM NVM-NEW NPM NPM-NEW UPDATE
  hm_node_print_row "${domain}"
  hm_table_print
}

hm_node_resolve_domain() {
  local domain="$1" resolved
  [[ -n "${domain}" ]] || {
    hm_err "Podaj domenę albo wejdź w kontekst (use)."
    return 1
  }
  if ! hm_is_valid_domain "${domain}"; then
    hm_err "Nieprawidłowa domena: ${domain}"
    return 1
  fi
  if declare -F hm_find_site_by_arg_exact >/dev/null 2>&1; then
    resolved="$(hm_find_site_by_arg_exact "${domain}" 2>/dev/null || true)"
    [[ -n "${resolved}" ]] && domain="${resolved}"
  fi
  printf '%s' "${domain}"
}

# Rzeczywista podmiana nvm (po confirm). $1=home $2=user $3=tag vX.Y.Z
hm_node_apply_nvm_update() {
  local home="$1" user="$2" tag="$3" dir="${1}/.nvm" tmp
  if [[ -d "${dir}/.git" ]] && hm_have_cmd git; then
    # jako właściciel repo — bez -c safe.directory (nie omijamy ochrony git)
    hm_node_run_as_user "${user}" "${home}" \
      git -C "${dir}" fetch --tags origin || return 1
    hm_node_run_as_user "${user}" "${home}" \
      git -C "${dir}" checkout "${tag}" || return 1
    return 0
  fi
  tmp="$(hm_mktemp .nvm-install.sh)"
  if ! curl -fsSL --max-time 60 -o "${tmp}" \
    "https://raw.githubusercontent.com/nvm-sh/nvm/${tag}/install.sh"; then
    rm -f "${tmp}"
    hm_err "Nie pobrano instalatora nvm ${tag}."
    return 1
  fi
  if ! grep -q 'NVM_DIR' "${tmp}"; then
    rm -f "${tmp}"
    hm_err "Instalator nvm nie wygląda na oficjalny skrypt."
    return 1
  fi
  chmod 755 "${tmp}"
  if ! hm_node_run_as_user "${user}" "${home}" env NVM_DIR="${dir}" bash "${tmp}"; then
    rm -f "${tmp}"
    return 1
  fi
  rm -f "${tmp}"
}

hm_node_apply_npm_update() {
  local home="$1" user="$2" ver="$3" bin="$4"
  hm_node_run_as_user "${user}" "${home}" "${bin}" install -g "npm@${ver}"
}

hm_node_update_nvm() {
  local domain="$1" yes="${2:-0}" line home user has_nvm nvm_ver latest tag cmp
  domain="$(hm_node_resolve_domain "${domain}")" || return 1
  hm_node_load_latest
  line="$(hm_node_probe_site "${domain}" 2>/dev/null || true)"
  [[ -n "${line}" ]] || { hm_err "Brak .nvm/.npm dla ${domain}."; return 1; }
  hm_node_take_probe "${line}"
  home="${HM_NODE_HOME}"
  user="${HM_NODE_USER}"
  has_nvm="${HM_NODE_HAS_NVM}"
  nvm_ver="${HM_NODE_NVM_VER}"
  [[ "${has_nvm}" == "1" ]] || { hm_err "${domain}: brak katalogu ${home}/.nvm"; return 1; }
  [[ -n "${user}" ]] || { hm_err "Nie ustalono użytkownika strony ${domain}."; return 1; }
  latest="${HM_NODE_LATEST_NVM:-}"
  [[ "${latest}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    hm_err "Nie znam najnowszej wersji nvm (brak odpowiedzi GitHub)."
    return 1
  }
  tag="v${latest}"
  if [[ -n "${nvm_ver}" ]]; then
    cmp="$(hm_node_ver_cmp "${nvm_ver}" "${latest}")"
    if [[ "${cmp}" != "-1" ]]; then
      hm_ok "nvm ${nvm_ver} jest aktualne (najnowsza ${latest})."
      return 0
    fi
  fi
  local -a steps=(
    "Katalog: ${home}/.nvm (user ${user})"
    "Obecna: ${nvm_ver:-?}  →  ${latest}"
  )
  if [[ -d "${home}/.nvm/.git" ]]; then
    steps+=("git fetch --tags && git checkout ${tag} (jako ${user})")
  else
    steps+=("Oficjalny install.sh nvm ${tag} do ${home}/.nvm (jako ${user})")
  fi
  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "node update nvm — ${domain}" "" --yes "${steps[@]}" || return 1
  else
    hm_confirm_plan "node update nvm — ${domain}" \
      "Aktualizacja nvm w katalogu użytkownika strony." \
      "${steps[@]}" || return 1
  fi
  if ! hm_node_apply_nvm_update "${home}" "${user}" "${tag}"; then
    hm_err "Aktualizacja nvm nieudana."
    return 1
  fi
  hm_ok "nvm zaktualizowane do ${latest} (${domain})."
}

hm_node_update_npm() {
  local domain="$1" yes="${2:-0}" line home user has_npm npm_ver latest bin cmp
  domain="$(hm_node_resolve_domain "${domain}")" || return 1
  hm_node_load_latest
  line="$(hm_node_probe_site "${domain}" 2>/dev/null || true)"
  [[ -n "${line}" ]] || { hm_err "Brak .nvm/.npm dla ${domain}."; return 1; }
  hm_node_take_probe "${line}"
  home="${HM_NODE_HOME}"
  user="${HM_NODE_USER}"
  has_npm="${HM_NODE_HAS_NPM}"
  npm_ver="${HM_NODE_NPM_VER}"
  [[ "${has_npm}" == "1" || -n "${npm_ver}" ]] || {
    hm_err "${domain}: brak katalogu ${home}/.npm"
    return 1
  }
  [[ -n "${user}" ]] || { hm_err "Nie ustalono użytkownika strony ${domain}."; return 1; }
  bin="$(hm_node_npm_bin "${home}" "${user}" || true)"
  [[ -n "${bin}" ]] || { hm_err "Nie znaleziono binarki npm dla ${domain}."; return 1; }
  latest="${HM_NODE_LATEST_NPM:-}"
  [[ "${latest}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    hm_err "Nie znam najnowszej wersji npm (brak odpowiedzi registry)."
    return 1
  }
  if [[ -n "${npm_ver}" ]]; then
    cmp="$(hm_node_ver_cmp "${npm_ver}" "${latest}")"
    if [[ "${cmp}" != "-1" ]]; then
      hm_ok "npm ${npm_ver} jest aktualne (najnowsza ${latest})."
      return 0
    fi
  fi
  local -a steps=(
    "Binarka: ${bin} (user ${user}, HOME ${home})"
    "Obecna: ${npm_ver:-?}  →  ${latest}"
    "npm install -g npm@${latest}"
  )
  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "node update npm — ${domain}" "" --yes "${steps[@]}" || return 1
  else
    hm_confirm_plan "node update npm — ${domain}" \
      "Globalny npm w prefixie tej binarki (nvm albo PATH usera)." \
      "${steps[@]}" || return 1
  fi
  if ! hm_node_apply_npm_update "${home}" "${user}" "${latest}" "${bin}"; then
    hm_err "Aktualizacja npm nieudana."
    return 1
  fi
  hm_ok "npm zaktualizowane do ${latest} (${domain})."
}

hm_node_update_cmd() {
  local what="${1:-}"
  shift || true
  local domain="" yes=0 a
  while [[ $# -gt 0 ]]; do
    a="$1"
    shift || true
    case "${a}" in
      --yes|-y) yes=1 ;;
      help|-h|--help)
        echo "Użycie: node update nvm|npm [domena] [--yes]"
        return 0
        ;;
      -*) hm_err "Nieznana flaga: ${a}"; return 1 ;;
      *) domain="${a}" ;;
    esac
  done
  [[ -n "${domain}" ]] || domain="${HM_SITE_DOMAIN:-}"
  case "${what}" in
    nvm) hm_node_update_nvm "${domain}" "${yes}" ;;
    npm) hm_node_update_npm "${domain}" "${yes}" ;;
    *)
      hm_err "Użycie: node update nvm|npm [domena] [--yes]"
      return 1
      ;;
  esac
}

cmd_node() {
  local sub="${1:-}"
  case "${sub}" in
    help|-h|--help)
      hm_help_topic node
      ;;
    sites|list|ls|--json)
      shift || true
      if [[ "${sub}" == "--json" ]] || hm_has_json_flag "$@"; then
        hm_json_emit node
        return $?
      fi
      hm_node_list_sites
      ;;
    update)
      shift || true
      hm_node_update_cmd "$@"
      ;;
    "")
      if hm_has_json_flag "$@"; then
        hm_json_emit node
        return $?
      fi
      if [[ -n "${HM_SITE_DOMAIN:-}" ]]; then
        hm_node_print_one "${HM_SITE_DOMAIN}"
      else
        hm_node_list_sites
      fi
      ;;
    *)
      if hm_is_valid_domain "${sub}" 2>/dev/null; then
        local resolved
        resolved="$(hm_find_site_by_arg_exact "${sub}" 2>/dev/null || true)"
        if [[ -n "${resolved}" ]]; then
          shift || true
          if [[ $# -eq 0 ]]; then
            hm_node_print_one "${resolved}"
          else
            hm_with_site_context "${resolved}" cmd_node "$@"
          fi
          return $?
        fi
      fi
      hm_err "Nieznana podkomenda: ${sub}. Zobacz: node help"
      return 1
      ;;
  esac
}

_hm_cmd_register node cmd_node 0
_hm_cmd_register_site node cmd_node
