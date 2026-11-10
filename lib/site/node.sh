#!/usr/bin/env bash
# Runtime Node.js dla site new: nvm z tagu (nie master), wersje, corepack, PM2/systemd.

if [[ -n "${HMTOOLS_SITE_NODE_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_SITE_NODE_LOADED=1

HM_NODE_NVM_PIN_VER="${HM_NODE_NVM_PIN_VER:-0.40.3}"
HM_NODE_NVM_PIN_SHA256="${HM_NODE_NVM_PIN_SHA256:-2d8359a64a3cb07c02389ad88ceecd43f2fa469c06104f92f98df5b6f315275f}"
HM_SITE_PNPM_PIN="${HM_SITE_PNPM_PIN:-9.15.0}"
HM_SITE_YARN_PIN="${HM_SITE_YARN_PIN:-1.22.22}"
HM_SITE_BUN_PIN="${HM_SITE_BUN_PIN:-1.2.4}"

hm_site_node_nvm_url() {
  printf 'https://raw.githubusercontent.com/nvm-sh/nvm/v%s/install.sh' "${HM_NODE_NVM_PIN_VER}"
}

hm_site_node_assert_pinned_url() {
  local url="$1" expect
  case "${url}" in
    *"/master/"*|*"refs/heads/master"*)
      hm_err "nvm tylko z tagu, nie z gałęzi master."
      return 1
      ;;
  esac
  expect="$(hm_site_node_nvm_url)"
  [[ "${url}" == "${expect}" ]] || {
    hm_err "Nieznany URL instalatora nvm."
    return 1
  }
}

hm_site_node_fetch() {
  local url="$1" dest="$2"
  hm_site_node_assert_pinned_url "${url}" || return 1
  if [[ -n "${HM_NODE_FETCH_LOG:-}" ]]; then
    printf '%s\n' "${url}" >> "${HM_NODE_FETCH_LOG}"
  fi
  if [[ "${HM_NODE_FETCH_MOCK:-}" == "1" ]]; then
    [[ -n "${HM_NODE_FETCH_BODY:-}" && -f "${HM_NODE_FETCH_BODY}" ]] || {
      hm_err "Brak fixture instalatora nvm."
      return 1
    }
    cp "${HM_NODE_FETCH_BODY}" "${dest}" || return 1
    return 0
  fi
  hm_have_cmd curl || { hm_err "Brak curl — nie pobieram nvm."; return 1; }
  curl -fsSL --max-time 60 -o "${dest}" "${url}"
}

hm_site_node_sha256() {
  local file="$1"
  if hm_have_cmd sha256sum; then
    sha256sum "${file}" | awk '{print $1}'
    return 0
  fi
  if hm_have_cmd shasum; then
    shasum -a 256 "${file}" | awk '{print $1}'
    return 0
  fi
  hm_err "Brak sha256sum — nie weryfikuję instalatora nvm."
  return 1
}

hm_site_node_as_user() {
  local user="$1" home="$2"
  shift 2 || return 1
  if [[ "${HM_SITE_NODE_MOCK:-}" == "1" ]]; then
    if [[ -n "${HM_SITE_NODE_LOG:-}" ]]; then
      printf '%s\n' "$*" >> "${HM_SITE_NODE_LOG}"
    fi
    if [[ "${1:-}" == "env" ]]; then
      local nvm_dir="${home}/.nvm" script="" arg
      for arg in "$@"; do
        case "${arg}" in
          NVM_DIR=*) nvm_dir="${arg#NVM_DIR=}" ;;
          bash) ;;
          /*|*.sh) script="${arg}" ;;
        esac
      done
      [[ -n "${script}" && -f "${script}" ]] || return 1
      env HOME="${home}" NVM_DIR="${nvm_dir}" bash "${script}"
      return $?
    fi
    if [[ "${1:-}" == "bash" && "${2:-}" == "-c" ]]; then
      hm_site_node_mock_bash "${home}" "${3:-}"
      return 0
    fi
    return 0
  fi
  if ! declare -F hm_node_run_as_user >/dev/null 2>&1; then
    hm_err "Brak hm_node_run_as_user."
    return 1
  fi
  hm_node_run_as_user "${user}" "${home}" "$@"
}

hm_site_node_mock_bash() {
  local home="$1" script="$2" ver dir bin
  while IFS= read -r ver; do
    [[ -n "${ver}" ]] || continue
    [[ "${ver}" == v* ]] || ver="v${ver}"
    dir="${home}/.nvm/versions/node/${ver}/bin"
    mkdir -p "${dir}"
    bin="${dir}/node"
    printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "${ver}" > "${bin}"
    chmod 755 "${bin}"
    printf '#!/bin/sh\nprintf "pm2\\n"\n' > "${dir}/pm2"
    chmod 755 "${dir}/pm2"
    printf '#!/bin/sh\nexit 0\n' > "${dir}/npm"
    chmod 755 "${dir}/npm"
  done < <(printf '%s\n' "${script}" | grep -Eo 'nvm install v?[0-9]+\.[0-9]+\.[0-9]+' | awk '{print $3}')
  ver="$(printf '%s\n' "${script}" | grep -Eo 'nvm alias default v?[0-9]+\.[0-9]+\.[0-9]+' | awk '{print $4}' | head -1)"
  if [[ -n "${ver}" ]]; then
    [[ "${ver}" == v* ]] || ver="v${ver}"
    mkdir -p "${home}/.nvm/alias"
    printf '%s\n' "${ver}" > "${home}/.nvm/alias/default"
  fi
}

hm_site_node_install_nvm() {
  local domain="$1" home user url tmp sum
  home="$(hm_site_home "${domain}")"
  user="$(hm_site_unix_user "${domain}")"
  mkdir -p "${home}"
  url="$(hm_site_node_nvm_url)"
  tmp="$(mktemp "${TMPDIR:-/tmp}/hm-nvm.XXXXXX")"
  if ! hm_site_node_fetch "${url}" "${tmp}"; then
    rm -f "${tmp}"
    return 1
  fi
  if ! grep -q 'NVM_DIR' "${tmp}"; then
    rm -f "${tmp}"
    hm_err "Instalator nvm nie zawiera NVM_DIR."
    return 1
  fi
  sum="$(hm_site_node_sha256 "${tmp}")" || { rm -f "${tmp}"; return 1; }
  if [[ "${sum}" != "${HM_NODE_NVM_PIN_SHA256}" ]]; then
    rm -f "${tmp}"
    hm_err "Suma SHA-256 instalatora nvm nie zgadza się z pinowaną wersją ${HM_NODE_NVM_PIN_VER}."
    return 1
  fi
  chmod 700 "${tmp}"
  if ! hm_site_node_as_user "${user}" "${home}" env "NVM_DIR=${home}/.nvm" "HOME=${home}" bash "${tmp}"; then
    rm -f "${tmp}"
    hm_err "Instalacja nvm nieudana."
    return 1
  fi
  rm -f "${tmp}"
  [[ -f "${home}/.nvm/nvm.sh" ]] || { hm_err "Brak ${home}/.nvm/nvm.sh po instalacji."; return 1; }
}

hm_site_node_index_file() {
  if [[ -n "${HM_NODE_INDEX_FILE:-}" && -f "${HM_NODE_INDEX_FILE}" ]]; then
    printf '%s' "${HM_NODE_INDEX_FILE}"
    return 0
  fi
  local dest="${TMPDIR:-/tmp}/hm-node-index.json"
  if [[ "${HM_NODE_FETCH_MOCK:-}" == "1" ]]; then
    hm_err "Brak HM_NODE_INDEX_FILE."
    return 1
  fi
  hm_have_cmd curl || { hm_err "Brak curl — nie pobieram listy Node."; return 1; }
  curl -fsSL --max-time 60 -o "${dest}" "https://nodejs.org/dist/index.json" || return 1
  printf '%s' "${dest}"
}

# stdout: version \t lts \t security  (najnowszy patch każdej linii, bez prerelease)
hm_site_node_majors() {
  local file="$1" line ver lts sec major seen="|"
  [[ -f "${file}" ]] || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    ver="$(printf '%s' "${line}" | sed -n 's/.*"version":"\(v[0-9][^"]*\)".*/\1/p')"
    [[ -n "${ver}" ]] || continue
    [[ "${ver}" == *-* ]] && continue
    major="${ver#v}"
    major="${major%%.*}"
    [[ "${seen}" == *"|${major}|"* ]] && continue
    seen="${seen}${major}|"
    lts="$(printf '%s' "${line}" | sed -n 's/.*"lts":\([^,}]*\).*/\1/p')"
    lts="${lts//\"/}"
    lts="${lts// /}"
    sec="$(printf '%s' "${line}" | sed -n 's/.*"security":\(true\|false\).*/\1/p')"
    [[ -n "${sec}" ]] || sec="false"
    printf '%s\t%s\t%s\n' "${ver}" "${lts}" "${sec}"
  done < "${file}"
}

hm_site_node_classify() {
  local file="$1"
  HM_SITE_NODE_ACTIVE=""
  HM_SITE_NODE_CURRENT=""
  HM_SITE_NODE_MAINT=""
  local -a lts_majors=()
  local ver lts sec major first_non="" line
  while IFS=$'\t' read -r ver lts sec; do
    [[ -n "${ver}" ]] || continue
    major="${ver#v}"
    major="${major%%.*}"
    if [[ "${lts}" != "false" && -n "${lts}" ]]; then
      lts_majors+=("${major}")
      if [[ -z "${HM_SITE_NODE_ACTIVE}" ]]; then
        HM_SITE_NODE_ACTIVE="${ver}"
      elif [[ -z "${HM_SITE_NODE_MAINT}" ]]; then
        HM_SITE_NODE_MAINT="${ver}"
      fi
    elif [[ -z "${first_non}" ]]; then
      first_non="${ver}"
    fi
  done < <(hm_site_node_majors "${file}")
  if [[ -n "${first_non}" && -n "${HM_SITE_NODE_ACTIVE}" ]]; then
    local cm am
    cm="${first_non#v}"; cm="${cm%%.*}"
    am="${HM_SITE_NODE_ACTIVE#v}"; am="${am%%.*}"
    if [[ "${cm}" -gt "${am}" ]]; then
      HM_SITE_NODE_CURRENT="${first_non}"
    fi
  elif [[ -n "${first_non}" ]]; then
    HM_SITE_NODE_CURRENT="${first_non}"
  fi
  [[ -n "${HM_SITE_NODE_ACTIVE}" ]] || return 1
}

hm_site_node_print_catalog() {
  local file="$1" ver lts sec kind
  hm_site_node_classify "${file}" || return 1
  while IFS=$'\t' read -r ver lts sec; do
    [[ -n "${ver}" ]] || continue
    if [[ "${ver}" == "${HM_SITE_NODE_CURRENT}" ]]; then
      kind="Current"
    elif [[ "${ver}" == "${HM_SITE_NODE_ACTIVE}" ]]; then
      kind="Active LTS"
    elif [[ "${ver}" == "${HM_SITE_NODE_MAINT}" ]]; then
      kind="Maintenance LTS"
    elif [[ "${lts}" != "false" && -n "${lts}" ]]; then
      kind="EOL"
    else
      kind="EOL"
    fi
    printf '%s\t%s\tlts=%s\tsecurity=%s\n' "${kind}" "${ver}" "${lts}" "${sec}"
  done < <(hm_site_node_majors "${file}")
}

hm_site_node_resolve_ver() {
  local file="$1" spec="$2" ver major
  spec="${spec#v}"
  if [[ "${spec}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'v%s' "${spec}"
    return 0
  fi
  [[ "${spec}" =~ ^[0-9]+$ ]] || { hm_err "Nieprawidłowa wersja Node: ${spec}"; return 1; }
  while IFS=$'\t' read -r ver _ _; do
    major="${ver#v}"
    major="${major%%.*}"
    if [[ "${major}" == "${spec}" ]]; then
      printf '%s' "${ver}"
      return 0
    fi
  done < <(hm_site_node_majors "${file}")
  hm_err "Brak Node ${spec} w index.json."
  return 1
}

hm_site_node_install_versions() {
  local domain="$1" def="$2"
  shift 2 || return 1
  local home user ver list=""
  home="$(hm_site_home "${domain}")"
  user="$(hm_site_unix_user "${domain}")"
  for ver in "$@"; do
    [[ "${ver}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { hm_err "Zła wersja: ${ver}"; return 1; }
    list+=" nvm install ${ver} &&"
  done
  list+=" nvm alias default ${def}"
  hm_site_node_as_user "${user}" "${home}" bash -c \
    "export NVM_DIR=\"${home}/.nvm\"; . \"\$NVM_DIR/nvm.sh\" &&${list}" || return 1
  local app="${home}/app"
  mkdir -p "${app}"
  printf '%s\n' "${def}" > "${app}/.nvmrc"
}

hm_site_node_start_ok() {
  local s="${1:-}" ok
  [[ -n "${s}" ]] || return 1
  case "${s}" in
    *'`'*|*'$( '*|*'$('*|*';'*|*'|'*|*'>'*|*'<'*|*'&'*|*'\'*) return 1 ;;
  esac
  ok="$(printf '%s' "${s}" | grep -E '^[A-Za-z0-9_./:=@+ -]+$' || true)"
  [[ "${ok}" == "${s}" ]]
}

hm_site_node_preset_start() {
  case "${1:-}" in
    next) printf '%s' "next start -H 127.0.0.1" ;;
    nuxt) printf '%s' "node .output/server/index.mjs" ;;
    nest|express) printf '%s' "node dist/main.js" ;;
    static) printf '%s' "" ;;
    "") printf '%s' "node dist/main.js" ;;
    *) hm_err "Nieznany preset: ${1}"; return 1 ;;
  esac
}

hm_site_node_pkg() {
  local domain="$1" pkg="$2" home user nodebin app
  home="$(hm_site_home "${domain}")"
  user="$(hm_site_unix_user "${domain}")"
  app="${home}/app"
  mkdir -p "${app}"
  case "${pkg}" in
    npm|"") pkg="npm" ;;
    pnpm|yarn|bun) ;;
    *) hm_err "Nieznany menedżer: ${pkg}"; return 1 ;;
  esac
  nodebin="$(hm_site_node_default_bin "${home}")" || return 1
  if [[ "${pkg}" == "pnpm" || "${pkg}" == "yarn" ]]; then
    local pin="${HM_SITE_PNPM_PIN}"
    [[ "${pkg}" == "yarn" ]] && pin="${HM_SITE_YARN_PIN}"
    hm_site_node_as_user "${user}" "${home}" bash -c \
      "export NVM_DIR=\"${home}/.nvm\"; . \"\$NVM_DIR/nvm.sh\" && corepack enable && corepack prepare ${pkg}@${pin} --activate" \
      || return 1
    hm_site_node_package_manager_field "${app}" "${pkg}@${pin}"
  elif [[ "${pkg}" == "bun" ]]; then
    hm_site_node_as_user "${user}" "${home}" bash -c \
      "export NVM_DIR=\"${home}/.nvm\"; . \"\$NVM_DIR/nvm.sh\" && npm install -g bun@${HM_SITE_BUN_PIN}" \
      || return 1
    hm_site_node_package_manager_field "${app}" "bun@${HM_SITE_BUN_PIN}"
  fi
  hm_site_node_write_deploy "${app}" "${pkg}"
  printf '%s' "${nodebin}"
}

hm_site_node_default_bin() {
  local home="$1" ver bin
  [[ -f "${home}/.nvm/alias/default" ]] || return 1
  ver="$(tr -d '[:space:]' < "${home}/.nvm/alias/default")"
  [[ "${ver}" == v* ]] || ver="v${ver}"
  bin="${home}/.nvm/versions/node/${ver}/bin/node"
  [[ -x "${bin}" ]] || return 1
  printf '%s' "${bin}"
}

hm_site_node_package_manager_field() {
  local app="$1" spec="$2" pkgjson="${1}/package.json"
  if [[ -f "${pkgjson}" ]]; then
    if grep -q '"packageManager"' "${pkgjson}"; then
      return 0
    fi
    return 0
  fi
  printf '{"name":"app","private":true,"packageManager":"%s"}\n' "${spec}" > "${pkgjson}"
}

hm_site_node_write_deploy() {
  local app="$1" pkg="$2" marker="${1}/.hmtools-deploy"
  case "${pkg}" in
    pnpm)
      printf '%s\n' 'build=pnpm install --frozen-lockfile' 'build=pnpm run build' > "${marker}"
      ;;
    yarn)
      printf '%s\n' 'build=yarn install --frozen-lockfile' 'build=yarn build' > "${marker}"
      ;;
    bun)
      printf '%s\n' 'build=bun install --frozen-lockfile' 'build=bun run build' > "${marker}"
      ;;
    *)
      printf '%s\n' 'build=npm ci' 'build=npm run build' > "${marker}"
      ;;
  esac
}

hm_site_port_reserve() {
  local domain="$1" want="${2:-auto}" file p
  if declare -F hm_site_web_reserve_port >/dev/null 2>&1; then
    hm_site_web_reserve_port "${domain}" "${want}"
    return $?
  fi
  file="${HM_SITE_PORT_FILE:-}"
  if [[ -z "${file}" ]]; then
    file="${HM_SITE_HOME_BASE:-/var/tmp}/hmtools-ports.ndjson"
  fi
  mkdir -p "$(dirname "${file}")" || return 1
  [[ -f "${file}" ]] || : > "${file}"
  if [[ "${want}" != "auto" && -n "${want}" ]]; then
    [[ "${want}" =~ ^[0-9]+$ ]] || { hm_err "Zły port: ${want}"; return 1; }
    p="${want}"
  else
    p=3000
    while awk -F '\t' -v p="${p}" '$2 == p { found = 1 } END { exit !found }' "${file}"; do
      p=$((p + 1))
      [[ "${p}" -lt 65535 ]] || { hm_err "Brak wolnego portu."; return 1; }
    done
  fi
  local tmp
  tmp="$(mktemp "${file}.XXXXXX")"
  awk -F '\t' -v d="${domain}" '$1 != d' "${file}" > "${tmp}" || true
  printf '%s\t%s\n' "${domain}" "${p}" >> "${tmp}"
  mv -f "${tmp}" "${file}"
  printf '%s' "${p}"
}

hm_site_node_write_proxy() {
  local domain="$1" port="$2" mode="$3" home
  home="$(hm_site_home "${domain}")"
  mkdir -p "${home}/.hmtools"
  printf 'mode=%s\nupstream=127.0.0.1:%s\n' "${mode}" "${port}" > "${home}/.hmtools/proxy.snippet"
  if declare -F hm_site_web_apply_proxy >/dev/null 2>&1; then
    hm_site_web_apply_proxy "${domain}" "${port}" "${mode}" || return 1
  fi
}

hm_site_node_json_escape() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "${s}"
}

hm_site_node_write_pm2() {
  local domain="$1" home="$2" start="$3" port="$4" instances="$5" memory="$6"
  local eco="${home}/shared/ecosystem.config.cjs" name script args
  mkdir -p "${home}/shared" "${home}/logs"
  name="$(hm_site_node_json_escape "${domain}")"
  start="$(hm_site_node_json_escape "${start}")"
  if [[ "${start}" == node\ * ]]; then
    script="$(hm_site_node_default_bin "${home}")" || return 1
    args="${start#node }"
  else
    script="/bin/bash"
    args="-c exec ${start}"
  fi
  script="$(hm_site_node_json_escape "${script}")"
  args="$(hm_site_node_json_escape "${args}")"
  cat > "${eco}" <<EOF
module.exports = {
  apps: [{
    name: "${name}",
    cwd: "${home}/app",
    script: "${script}",
    args: "${args}",
    instances: ${instances},
    exec_mode: "fork",
    max_memory_restart: "${memory}",
    error_file: "${home}/logs/pm2-error.log",
    out_file: "${home}/logs/pm2-out.log",
    env_file: "${home}/shared/.env",
    env: { HOST: "127.0.0.1", PORT: "${port}" }
  }]
};
EOF
  printf '%s' "${eco}"
}

hm_site_node_unit_name() {
  local safe="${1//./-}"
  safe="$(printf '%s' "${safe}" | tr -cd 'A-Za-z0-9-')"
  printf 'hm-app-%s.service' "${safe}"
}

hm_site_node_write_systemd() {
  local domain="$1" home="$2" user="$3" start="$4" port="$5"
  local name dest dir nodebin pathbin
  name="$(hm_site_node_unit_name "${domain}")"
  dir="${HM_SYSTEMD_UNIT_DIR:-}"
  if [[ -z "${dir}" ]]; then
    if [[ "$(id -u)" -eq 0 ]]; then
      dir="/etc/systemd/system"
    else
      dir="${home}/.hmtools"
    fi
  fi
  mkdir -p "${dir}" "${home}/logs" "${home}/app"
  dest="${dir}/${name}"
  nodebin="$(hm_site_node_default_bin "${home}")" || return 1
  pathbin="$(dirname "${nodebin}")"
  local execstart
  if [[ "${start}" == node\ * ]]; then
    execstart="${nodebin} ${start#node }"
  else
    execstart="/bin/bash -c 'exec ${start}'"
  fi
  cat > "${dest}" <<EOF
[Unit]
Description=hmtools ${domain}
After=network.target

[Service]
User=${user}
WorkingDirectory=${home}/app
EnvironmentFile=-${home}/shared/.env
Environment=HOST=127.0.0.1
Environment=PORT=${port}
Environment=PATH=${pathbin}:/usr/bin
ExecStart=${execstart}
Restart=on-failure
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=${home}

[Install]
WantedBy=multi-user.target
EOF
  if [[ "${HM_SITE_NODE_MOCK:-}" == "1" || "$(id -u)" -eq 0 ]]; then
    if [[ -n "${HM_SITE_NODE_LOG:-}" && "${HM_SITE_NODE_MOCK:-}" == "1" ]]; then
      printf 'systemctl daemon-reload\nsystemctl enable %s\n' "${name}" >> "${HM_SITE_NODE_LOG}"
    elif [[ "$(id -u)" -eq 0 ]] && hm_have_cmd systemctl; then
      systemctl daemon-reload || return 1
      systemctl enable "${name}" || return 1
    fi
  fi
  printf '%s' "${dest}"
}

hm_site_node_pm2_startup() {
  local domain="$1" home user eco
  home="$(hm_site_home "${domain}")"
  user="$(hm_site_unix_user "${domain}")"
  eco="${home}/shared/ecosystem.config.cjs"
  hm_site_node_as_user "${user}" "${home}" bash -c \
    "export NVM_DIR=\"${home}/.nvm\"; . \"\$NVM_DIR/nvm.sh\" && npm install -g pm2 && pm2 startup systemd -u ${user} --hp ${home} && pm2 start ${eco} && pm2 save" \
    || return 1
}

hm_site_node_provision() {
  local domain="$1" spec="$2" def_spec="$3" pkg="$4" process="$5" start="$6" port_want="$7" preset="$8" instances="${9:-1}" memory="${10:-300M}"
  local home user file ver def="" port mode="proxy"
  local -a vers=()
  [[ "${instances}" =~ ^[0-9]+$ ]] || { hm_err "Złe instances."; return 1; }
  [[ "${memory}" =~ ^[0-9]+[KMG]?$ ]] || { hm_err "Zły limit pamięci."; return 1; }
  case "${preset}" in
    ""|next|nuxt|express|nest) ;;
    static) mode="static"; [[ -n "${process}" ]] || process="none" ;;
    *) hm_err "Nieznany preset: ${preset}"; return 1 ;;
  esac
  [[ -n "${process}" ]] || process="pm2"
  case "${process}" in
    pm2|systemd|none) ;;
    *) hm_err "Nieznany menedżer procesów: ${process}"; return 1 ;;
  esac
  [[ -n "${pkg}" ]] || pkg="npm"
  [[ -n "${start}" ]] || start="$(hm_site_node_preset_start "${preset}")" || return 1
  if [[ "${mode}" != "static" ]]; then
    hm_site_node_start_ok "${start}" || { hm_err "Niedozwolone polecenie startu."; return 1; }
  fi
  file="$(hm_site_node_index_file)" || return 1
  hm_site_node_classify "${file}" || return 1
  if [[ -z "${spec}" ]]; then
    spec="${HM_SITE_NODE_ACTIVE#v}"
    spec="${spec%%.*}"
  fi
  local part
  while IFS= read -r part; do
    part="${part// /}"
    [[ -n "${part}" ]] || continue
    ver="$(hm_site_node_resolve_ver "${file}" "${part}")" || return 1
    vers+=("${ver}")
  done < <(printf '%s\n' "${spec}" | tr ',' '\n')
  [[ "${#vers[@]}" -gt 0 ]] || { hm_err "Brak wersji Node."; return 1; }
  if [[ -n "${def_spec}" ]]; then
    def="$(hm_site_node_resolve_ver "${file}" "${def_spec}")" || return 1
  else
    def="${vers[0]}"
  fi
  local ok=0 v
  for v in "${vers[@]}"; do
    [[ "${v}" == "${def}" ]] && ok=1
  done
  [[ "${ok}" -eq 1 ]] || { hm_err "Wersja domyślna nie jest na liście instalacji."; return 1; }

  hm_site_node_install_nvm "${domain}" || return 1
  hm_site_node_install_versions "${domain}" "${def}" "${vers[@]}" || return 1
  hm_site_node_pkg "${domain}" "${pkg}" >/dev/null || return 1

  home="$(hm_site_home "${domain}")"
  user="$(hm_site_unix_user "${domain}")"
  if [[ "${mode}" == "static" ]]; then
    port="0"
    process="none"
  else
    port="$(hm_site_port_reserve "${domain}" "${port_want:-auto}")" || return 1
    hm_site_env_upsert "${domain}" "PORT" "${port}" || return 1
    hm_site_env_upsert "${domain}" "HOST" "127.0.0.1" || return 1
  fi
  hm_site_node_write_proxy "${domain}" "${port}" "${mode}" || return 1

  case "${process}" in
    pm2)
      hm_site_node_write_pm2 "${domain}" "${home}" "${start}" "${port}" "${instances}" "${memory}" >/dev/null || return 1
      hm_site_node_pm2_startup "${domain}" || return 1
      ;;
    systemd)
      hm_site_node_write_systemd "${domain}" "${home}" "${user}" "${start}" "${port}" >/dev/null || return 1
      ;;
    none) ;;
  esac
  hm_ok "Node ${def} dla ${domain} (proces: ${process}, nasłuch 127.0.0.1:${port})."
}
