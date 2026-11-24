#!/usr/bin/env bash
# Cykl życia serwisu wg manifestu: show, runtime, doctor, zasoby przy webs delete.

if [[ -n "${HMTOOLS_SITE_LIFE_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_SITE_LIFE_LOADED=1

hm_site_resources_path() {
  local domain="$1" dir
  if declare -F hm_site_manifest_dir >/dev/null 2>&1; then
    dir="$(hm_site_manifest_dir)"
  else
    dir="${HM_SITE_MANIFEST_DIR:-/etc/hmtools/sites}"
  fi
  printf '%s/%s.resources.ndjson' "${dir}" "${domain}"
}

hm_site_resource_add() {
  local domain="$1" kind="$2" path="$3" shared="${4:-0}" file flag="false"
  case "${kind}" in
    worker|timer|unit|pm2|compose|vhost|fpm|db|firewall|port|logrotate|cron) ;;
    *) hm_err "Nieznany rodzaj zasobu: ${kind}"; return 1 ;;
  esac
  [[ "${shared}" == "1" || "${shared}" == "true" ]] && flag="true"
  file="$(hm_site_resources_path "${domain}")"
  mkdir -p "$(dirname "${file}")"
  chmod 0700 "$(dirname "${file}")" 2>/dev/null || true
  if declare -F hm_site_path_has_symlink >/dev/null 2>&1 \
    && { hm_site_path_has_symlink "${file}" || hm_site_path_has_symlink "$(dirname "${file}")"; }; then
    hm_err "Odmowa zapisu listy zasobów przez symlink."
    return 1
  fi
  if [[ -f "${file}" ]] && grep -F -q "\"path\":\"${path}\"" "${file}" 2>/dev/null; then
    if grep -F "\"path\":\"${path}\"" "${file}" | grep -F -q "\"kind\":\"${kind}\""; then
      chmod 0600 "${file}" 2>/dev/null || true
      return 0
    fi
  fi
  printf '{"kind":"%s","path":"%s","shared":%s}\n' \
    "$(hm_site_json_escape "${kind}")" \
    "$(hm_site_json_escape "${path}")" \
    "${flag}" >> "${file}"
  chmod 0600 "${file}" 2>/dev/null || true
}

# Po rollbacku: wyczyść listę zasobów domeny (bez kasowania plików systemowych).
hm_site_resource_clear() {
  local domain="$1" file
  file="$(hm_site_resources_path "${domain}")"
  [[ -f "${file}" ]] || return 0
  if declare -F hm_site_path_has_symlink >/dev/null 2>&1 \
    && { hm_site_path_has_symlink "${file}" || hm_site_path_has_symlink "$(dirname "${file}")"; }; then
    hm_err "Odmowa czyszczenia resources przez symlink."
    return 1
  fi
  : > "${file}"
  chmod 0600 "${file}" 2>/dev/null || true
}

hm_site_resource_read() {
  local line="$1"
  local re_kind='"kind"[[:space:]]*:[[:space:]]*"([^"]*)"'
  local re_path='"path"[[:space:]]*:[[:space:]]*"([^"]*)"'
  local re_shared='"shared"[[:space:]]*:[[:space:]]*(true|false)'
  HM_SITE_RES_KIND=""
  HM_SITE_RES_PATH=""
  HM_SITE_RES_SHARED=0
  [[ "${line}" =~ $re_kind ]] && HM_SITE_RES_KIND="${BASH_REMATCH[1]}"
  [[ "${line}" =~ $re_path ]] && HM_SITE_RES_PATH="${BASH_REMATCH[1]}"
  if [[ "${line}" =~ $re_shared && "${BASH_REMATCH[1]}" == "true" ]]; then
    HM_SITE_RES_SHARED=1
  fi
  [[ -n "${HM_SITE_RES_KIND}" && -n "${HM_SITE_RES_PATH}" ]]
}

hm_site_runtime_version() {
  local path="$1"
  sed -n 's/.*"runtime":{"type":"[^"]*","version":"\([^"]*\)".*/\1/p' "${path}" | head -1
}

hm_site_manifest_set_version() {
  local path="$1" ver="$2" tmp
  [[ "${ver}" =~ ^[A-Za-z0-9._+-]+$ ]] || { hm_err "Zła wersja: ${ver}"; return 1; }
  if [[ -L "${path}" ]] || hm_site_path_has_symlink "$(dirname "${path}")"; then
    hm_err "Odmowa zapisu manifestu przez symlink."
    return 1
  fi
  tmp="$(mktemp)"
  sed -E 's/("runtime":\{"type":"[^"]*","version":")[^"]*/\1'"${ver}"'/' "${path}" > "${tmp}"
  mv -f "${tmp}" "${path}"
}

hm_site_show_table() {
  local domain="$1" path="$2" runtime ver web env line st
  runtime="$(sed -n 's/.*"runtime":{"type":"\([^"]*\)".*/\1/p' "${path}" | head -1)"
  ver="$(hm_site_runtime_version "${path}")"
  web="$(sed -n 's/.*"webserver":"\([^"]*\)".*/\1/p' "${path}" | head -1)"
  env="$(sed -n 's/.*"env_file":"\([^"]*\)".*/\1/p' "${path}" | head -1)"
  if declare -F hm_table_begin >/dev/null 2>&1; then
    hm_table_begin
    hm_table_row "pole" "wartość"
    hm_table_row "domena" "${domain}"
    hm_table_row "runtime" "${runtime:-brak}"
    hm_table_row "wersja" "${ver:-brak}"
    hm_table_row "webserver" "${web:-brak}"
    hm_table_row "env" "${env:-brak}"
    if [[ -f "$(hm_site_resources_path "${domain}")" ]]; then
      while IFS= read -r line || [[ -n "${line}" ]]; do
        hm_site_resource_read "${line}" || continue
        if [[ "${HM_SITE_RES_SHARED}" -eq 1 ]]; then
          st="współdzielone"
        elif [[ -e "${HM_SITE_RES_PATH}" ]]; then
          st="ok"
        else
          st="brak"
        fi
        hm_table_row "${HM_SITE_RES_KIND}" "${st} ${HM_SITE_RES_PATH}"
      done < "$(hm_site_resources_path "${domain}")"
    fi
    hm_table_print
    return 0
  fi
  printf 'domena\t%s\n' "${domain}"
  printf 'runtime\t%s\n' "${runtime:-brak}"
  printf 'wersja\t%s\n' "${ver:-brak}"
}

hm_site_runtime_restore() {
  local src="$1" dest="$2"
  if [[ ! -f "${src}" || -L "${src}" || -L "${dest}" ]]; then
    rm -f "${src}"
    return 0
  fi
  mv -f "${src}" "${dest}"
}

hm_site_runtime_php() {
  local domain="$1" ver="$2" path old home pool runtime user line old_pool="" new_pool=""
  path="$(hm_site_manifest_path "${domain}")"
  [[ -f "${path}" ]] || { hm_err "Brak manifestu."; return 1; }
  runtime="$(sed -n 's/.*"runtime":{"type":"\([^"]*\)".*/\1/p' "${path}" | head -1)"
  [[ "${runtime}" == "php" ]] || { hm_err "site runtime php: serwis nie jest PHP (${runtime:-brak})."; return 1; }
  old="$(hm_site_runtime_version "${path}")"
  home="$(hm_site_home "${domain}")"
  user="$(hm_site_unix_user "${domain}" 2>/dev/null || true)"
  [[ -n "${user}" ]] || user="$(stat -c '%U' "${home}" 2>/dev/null || echo root)"
  pool="${HM_SITE_FPM_POOL:-$(hm_site_state_dir "${domain}")/fpm.conf}"
  mkdir -p "$(dirname "${pool}")" "$(dirname "${path}")"
  if [[ -L "${pool}" || -L "${path}" ]]; then
    hm_err "Odmowa zmiany PHP przez symlink (pula/manifest)."
    return 1
  fi
  [[ -f "${pool}" && ! -L "${pool}" ]] && cp -f "${pool}" "${pool}.hmbak"
  [[ ! -L "${path}" ]] && cp -f "${path}" "${path}.hmbak"
  if [[ -f "$(hm_site_resources_path "${domain}")" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      hm_site_resource_read "${line}" || continue
      [[ "${HM_SITE_RES_KIND}" == "fpm" && "${HM_SITE_RES_SHARED}" != "1" ]] || continue
      old_pool="${HM_SITE_RES_PATH}"
      break
    done < "$(hm_site_resources_path "${domain}")"
  fi
  if [[ "${HM_SITE_RUNTIME_FAIL:-}" == "1" ]]; then
    rm -f "${pool}.hmbak" "${path}.hmbak"
    hm_err "PHP ${ver} nie przeszedł testu — zostaje ${old:-dotychczasowa}."
    return 1
  fi
  if [[ "${HMTOOLS_TEST:-}" != "1" ]] && declare -F hm_site_php_write_pool >/dev/null 2>&1; then
    if declare -F hm_site_php_ensure_repo >/dev/null 2>&1; then
      hm_site_php_ensure_repo "${ver}" 1 || {
        hm_site_runtime_restore "${path}.hmbak" "${path}"
        hm_site_runtime_restore "${pool}.hmbak" "${pool}"
        hm_err "Nie zainstalowano PHP ${ver} — zostaje ${old:-dotychczasowa}."
        return 1
      }
    fi
    if declare -F hm_site_php_install_exts >/dev/null 2>&1; then
      hm_site_php_install_exts "${ver}" fpm || true
    fi
    new_pool="$(hm_site_php_write_pool "${domain}" "${ver}" "${user}" "${home}" fpm)" || {
      hm_site_runtime_restore "${path}.hmbak" "${path}"
      hm_site_runtime_restore "${pool}.hmbak" "${pool}"
      hm_err "Pula FPM ${ver} nieudana — zostaje ${old:-dotychczasowa}."
      return 1
    }
    if [[ -n "${old_pool}" && "${old_pool}" != "${new_pool}" && -f "${old_pool}" && ! -L "${old_pool}" ]]; then
      if hm_site_delete_path_allowed "${old_pool}" fpm "${domain}"; then
        rm -f -- "${old_pool}"
      fi
    fi
    printf 'php=%s\npool=%s\n' "${ver}" "${new_pool}" | hm_site_write_nofollow "${pool}" || true
  else
    printf 'php=%s\nlisten=127.0.0.1\n' "${ver}" | hm_site_write_nofollow "${pool}" || {
      hm_site_runtime_restore "${path}.hmbak" "${path}"
      hm_site_runtime_restore "${pool}.hmbak" "${pool}"
      return 1
    }
  fi
  hm_site_manifest_set_version "${path}" "${ver}" || {
    hm_site_runtime_restore "${path}.hmbak" "${path}"
    hm_site_runtime_restore "${pool}.hmbak" "${pool}"
    return 1
  }
  if [[ "${WEBSERVER:-}" == "ols" ]] && declare -F hm_php_set_site >/dev/null 2>&1; then
    if ! hm_php_set_site "${ver}"; then
      hm_site_runtime_restore "${path}.hmbak" "${path}"
      hm_site_runtime_restore "${pool}.hmbak" "${pool}"
      hm_err "OLS nie przełączył PHP — przywrócono ${old:-poprzednią}."
      return 1
    fi
  fi
  if [[ "${HMTOOLS_TEST:-}" != "1" ]] && declare -F hm_site_php_fpm_reload >/dev/null 2>&1; then
    [[ -n "${old}" ]] && hm_site_php_fpm_reload "${old}" 2>/dev/null || true
    hm_site_php_fpm_reload "${ver}" 2>/dev/null || true
  fi
  HM_SITE_RUNTIME_VERSION="${ver}"
  rm -f "${pool}.hmbak" "${path}.hmbak"
  hm_ok "PHP ${domain} → ${ver}"
}

hm_site_runtime_node() {
  local domain="$1" ver="$2" path old home nvmrc unit line runtime tmp
  path="$(hm_site_manifest_path "${domain}")"
  [[ -f "${path}" ]] || { hm_err "Brak manifestu."; return 1; }
  runtime="$(sed -n 's/.*"runtime":{"type":"\([^"]*\)".*/\1/p' "${path}" | head -1)"
  [[ "${runtime}" == "node" ]] || { hm_err "site runtime node: serwis nie jest Node (${runtime:-brak})."; return 1; }
  old="$(hm_site_runtime_version "${path}")"
  home="$(hm_site_home "${domain}")"
  nvmrc="${home}/.nvmrc"
  mkdir -p "${home}"
  if [[ -L "${path}" ]] || { declare -F hm_site_path_has_symlink >/dev/null 2>&1 && hm_site_path_has_symlink "${path}"; }; then
    hm_err "Odmowa zmiany Node przez symlink (manifest)."
    return 1
  fi
  if [[ -L "${nvmrc}" ]] || { declare -F hm_site_path_has_symlink >/dev/null 2>&1 && hm_site_path_has_symlink "${nvmrc}"; }; then
    hm_err "Odmowa zmiany Node przez symlink (.nvmrc)."
    return 1
  fi
  # write_nofollow i tak odmówi, gdy katalog HOME ma symlink w ścieżce
  [[ -f "${nvmrc}" && ! -L "${nvmrc}" ]] && cp -f "${nvmrc}" "${nvmrc}.hmbak"
  cp -f "${path}" "${path}.hmbak"
  unit=""
  if [[ -f "$(hm_site_resources_path "${domain}")" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      hm_site_resource_read "${line}" || continue
      [[ "${HM_SITE_RES_KIND}" == "unit" ]] || continue
      unit="${HM_SITE_RES_PATH}"
      break
    done < "$(hm_site_resources_path "${domain}")"
  fi
  if [[ -n "${unit}" ]]; then
    if [[ -L "${unit}" ]]; then
      hm_err "Odmowa zapisu unitu przez symlink: ${unit}"
      rm -f "${nvmrc}.hmbak" "${path}.hmbak"
      return 1
    fi
    [[ -f "${unit}" ]] && cp -f "${unit}" "${unit}.hmbak"
  fi
  if [[ "${HM_SITE_RUNTIME_FAIL:-}" == "1" ]]; then
    rm -f "${nvmrc}.hmbak" "${path}.hmbak" "${unit}.hmbak"
    hm_err "Node ${ver} nie wstał — zostaje ${old:-dotychczasowa}."
    return 1
  fi
  if [[ "${HMTOOLS_TEST:-}" != "1" ]] && declare -F hm_site_node_install_versions >/dev/null 2>&1; then
    hm_site_node_install_nvm "${domain}" 2>/dev/null || true
    hm_site_node_install_versions "${domain}" "${ver}" "${ver}" || {
      hm_site_runtime_restore "${path}.hmbak" "${path}"
      hm_site_runtime_restore "${nvmrc}.hmbak" "${nvmrc}"
      [[ -n "${unit}" ]] && hm_site_runtime_restore "${unit}.hmbak" "${unit}"
      hm_err "nvm install ${ver} nieudany — zostaje ${old:-dotychczasowa}."
      return 1
    }
  fi
  printf '%s\n' "${ver}" | hm_site_write_nofollow "${nvmrc}" || {
    hm_site_runtime_restore "${nvmrc}.hmbak" "${nvmrc}"
    hm_site_runtime_restore "${path}.hmbak" "${path}"
    hm_site_runtime_restore "${unit}.hmbak" "${unit}"
    return 1
  }
  if [[ -n "${unit}" && -f "${unit}" && -n "${old}" ]]; then
    tmp="$(mktemp)"
    # Tylko ścieżki nvm/node/vN — nie podmieniaj przypadkowych podciągów wersji.
    sed -E \
      -e "s#(versions/node/v)${old}([/\"[:space:]])#\\1${ver}\\2#g" \
      -e "s#(node/v)${old}([/\"[:space:]])#\\1${ver}\\2#g" \
      -e "s#(/v)${old}(/bin/node)#\\1${ver}\\2#g" \
      "${unit}" > "${tmp}"
    if ! hm_site_write_nofollow "${unit}" < "${tmp}"; then
      rm -f "${tmp}"
      hm_site_runtime_restore "${path}.hmbak" "${path}"
      hm_site_runtime_restore "${nvmrc}.hmbak" "${nvmrc}"
      hm_site_runtime_restore "${unit}.hmbak" "${unit}"
      return 1
    fi
    rm -f "${tmp}"
  fi
  hm_site_manifest_set_version "${path}" "${ver}" || {
    hm_site_runtime_restore "${path}.hmbak" "${path}"
    hm_site_runtime_restore "${nvmrc}.hmbak" "${nvmrc}"
    [[ -n "${unit}" ]] && hm_site_runtime_restore "${unit}.hmbak" "${unit}"
    return 1
  }
  if [[ "${HMTOOLS_TEST:-}" != "1" && -n "${unit}" ]] \
    && declare -F hm_have_cmd >/dev/null 2>&1 && hm_have_cmd systemctl; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl restart "$(basename -- "${unit}")" >/dev/null 2>&1 || true
  fi
  HM_SITE_RUNTIME_VERSION="${ver}"
  rm -f "${nvmrc}.hmbak" "${path}.hmbak" "${unit}.hmbak"
  hm_ok "Node ${domain} → ${ver}"
}

hm_site_runtime_beside() {
  local domain="$1" ver="$2" prefix="$3" path old home link dest
  path="$(hm_site_manifest_path "${domain}")"
  [[ -f "${path}" ]] || { hm_err "Brak manifestu."; return 1; }
  old="$(hm_site_runtime_version "${path}")"
  home="$(hm_site_state_dir "${domain}")"
  link="${home}/${prefix}"
  dest="${home}/${prefix}-${ver}"
  mkdir -p "${home}"
  cp -f "${path}" "${path}.hmbak"
  if [[ "${HM_SITE_RUNTIME_FAIL:-}" == "1" ]]; then
    rm -f "${path}.hmbak"
    hm_err "${prefix} ${ver} nie wstał — zostaje ${old:-dotychczasowa}."
    return 1
  fi
  if [[ -e "${link}" || -L "${link}" ]]; then
    local cur line
    line="$(ls -ld "${link}" 2>/dev/null || true)"
    if [[ "${line}" == *"->"* ]]; then
      printf '%s\n' "${line##*-> }" > "${link}.hmbak"
    elif [[ -f "${link}" ]]; then
      cp -f "${link}" "${link}.hmbak"
    fi
  fi
  mkdir -p "${dest}"
  rm -rf "${link}"
  ln -sfn "${prefix}-${ver}" "${link}" 2>/dev/null || true
  if ! ls -ld "${link}" 2>/dev/null | grep -F -q -- '->'; then
    rm -rf "${link}"
    printf '%s\n' "${prefix}-${ver}" > "${link}"
  fi
  hm_site_manifest_set_version "${path}" "${ver}" || {
    hm_site_runtime_restore "${path}.hmbak" "${path}"
    if [[ -f "${link}.hmbak" ]]; then
      local prev
      prev="$(tr -d '[:space:]' < "${link}.hmbak")"
      rm -rf "${link}"
      ln -sfn "${prev}" "${link}" 2>/dev/null || true
      if ! ls -ld "${link}" 2>/dev/null | grep -F -q -- '->'; then
        rm -rf "${link}"
        printf '%s\n' "${prev}" > "${link}"
      fi
      rm -f "${link}.hmbak"
    fi
    return 1
  }
  rm -f "${path}.hmbak" "${link}.hmbak"
  hm_ok "${prefix} ${domain} → ${ver}"
}

cmd_site_runtime() {
  local kind="" ver="" domain="" a
  while [[ $# -gt 0 ]]; do
    a="$1"
    shift || true
    case "${a}" in
      --yes|-y) ;;
      php|node|python|dotnet)
        kind="${a}"
        ver="${1:-}"
        shift || true
        ;;
      -*)
        hm_err "Nieznana flaga: ${a}"
        return 1
        ;;
      *)
        if [[ -z "${domain}" ]]; then
          domain="${a}"
        else
          hm_err "Za dużo argumentów: ${a}"
          return 1
        fi
        ;;
    esac
  done
  [[ -n "${kind}" && -n "${ver}" ]] || { hm_err "Użycie: site runtime php|node|python|dotnet <wersja> [domena]"; return 1; }
  [[ -n "${domain}" ]] || domain="${HM_SITE_DOMAIN:-}"
  [[ -n "${domain}" ]] || { hm_err "Brak domeny."; return 1; }
  case "${kind}" in
    php) hm_site_runtime_php "${domain}" "${ver}" ;;
    node) hm_site_runtime_node "${domain}" "${ver}" ;;
    python) hm_site_runtime_beside "${domain}" "${ver}" "venv" ;;
    dotnet) hm_site_runtime_beside "${domain}" "${ver}" "dotnet" ;;
  esac
}

cmd_site_doctor() {
  local domain="" line drift=0 st
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) shift ;;
      -*) hm_err "Nieznana flaga: $1"; return 1 ;;
      *) domain="$1"; shift ;;
    esac
  done
  [[ -n "${domain}" ]] || domain="${HM_SITE_DOMAIN:-}"
  [[ -n "${domain}" ]] || { hm_err "Użycie: site doctor <domena>"; return 1; }
  [[ -f "$(hm_site_manifest_path "${domain}")" ]] || { hm_err "Brak manifestu."; return 1; }
  if declare -F hm_site_path_has_symlink >/dev/null 2>&1 \
    && hm_site_path_has_symlink "$(hm_site_resources_path "${domain}")"; then
    hm_err "Lista zasobów jest symlinkiem."
    return 1
  fi
  if [[ ! -f "$(hm_site_resources_path "${domain}")" ]]; then
    printf 'OK\tbrak listy zasobów\n'
    return 0
  fi
  while IFS= read -r line || [[ -n "${line}" ]]; do
    hm_site_resource_read "${line}" || continue
    [[ "${HM_SITE_RES_SHARED}" -eq 1 ]] && continue
    if ! hm_site_doctor_readable "${HM_SITE_RES_PATH}" "${HM_SITE_RES_KIND}" "${domain}"; then
      printf 'DRYF\todmowa %s %s\n' "${HM_SITE_RES_KIND}" "${HM_SITE_RES_PATH}"
      drift=1
      continue
    fi
    if [[ ! -e "${HM_SITE_RES_PATH}" ]]; then
      printf 'DRYF\tbrak %s %s\n' "${HM_SITE_RES_KIND}" "${HM_SITE_RES_PATH}"
      drift=1
      continue
    fi
    if [[ "${HM_SITE_RES_KIND}" == "vhost" ]] && ! grep -F -q "${domain}" "${HM_SITE_RES_PATH}"; then
      printf 'DRYF\tvhost bez domeny %s\n' "${HM_SITE_RES_PATH}"
      drift=1
      continue
    fi
    if [[ "${HM_SITE_RES_KIND}" == "port" && -n "${HM_SITE_DOCTOR_LISTEN:-}" ]]; then
      st="$(tr -d '[:space:]' < "${HM_SITE_RES_PATH}")"
      if [[ "${st}" != "${HM_SITE_DOCTOR_LISTEN}" ]]; then
        printf 'DRYF\tport %s != %s\n' "${st}" "${HM_SITE_DOCTOR_LISTEN}"
        drift=1
        continue
      fi
    fi
    printf 'OK\t%s %s\n' "${HM_SITE_RES_KIND}" "${HM_SITE_RES_PATH}"
  done < "$(hm_site_resources_path "${domain}")"
  [[ "${drift}" -eq 0 ]]
}

hm_site_lifecycle_collect_delete() {
  local domain="${HM_DEL_DOMAIN:-}" file line
  HM_DEL_WIZARD=()
  [[ -n "${domain}" ]] || return 0
  declare -F hm_site_resources_path >/dev/null 2>&1 || return 0
  file="$(hm_site_resources_path "${domain}")"
  [[ -f "${file}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    hm_site_resource_read "${line}" || continue
    HM_DEL_WIZARD+=("${HM_SITE_RES_KIND}"$'\t'"${HM_SITE_RES_PATH}"$'\t'"${HM_SITE_RES_SHARED}")
  done < "${file}"
}

# Manifest / .dbs / stan / resources — sprzątanie niezależne od resources.ndjson.
hm_site_lifecycle_has_meta() {
  local domain="${1:-${HM_DEL_DOMAIN:-}}" man res state dbfile
  [[ -n "${domain}" ]] || return 1
  man="$(hm_site_manifest_path "${domain}" 2>/dev/null || true)"
  res="$(hm_site_resources_path "${domain}" 2>/dev/null || true)"
  state="$(hm_site_state_dir "${domain}" 2>/dev/null || true)"
  dbfile="$(hm_site_manifest_dir)/.${domain}.dbs"
  [[ -n "${man}" && -f "${man}" && ! -L "${man}" ]] && return 0
  [[ -n "${res}" && -f "${res}" && ! -L "${res}" ]] && return 0
  [[ -f "${dbfile}" && ! -L "${dbfile}" ]] && return 0
  [[ -n "${state}" && -d "${state}" && ! -L "${state}" ]] && return 0
  return 1
}

hm_site_lifecycle_plan_delete() {
  local line kind path shared
  if [[ "${#HM_DEL_WIZARD[@]}" -gt 0 ]]; then
    for line in "${HM_DEL_WIZARD[@]}"; do
      kind="${line%%$'\t'*}"
      path="${line#*$'\t'}"
      shared="${path##*$'\t'}"
      path="${path%$'\t'*}"
      if [[ "${shared}" == "1" ]]; then
        HM_DEL_PLAN_STEPS+=("Zostawiam współdzielone (${kind}): ${path}")
      else
        HM_DEL_PLAN_STEPS+=("Zasób kreatora (${kind}): ${path}")
      fi
    done
    HM_DEL_PLAN_KEYS+=("wizard")
    return 0
  fi
  # site new bez vhosta/unitów nie tworzy resources.ndjson — i tak sprzątaj meta + bazy z .dbs
  if hm_site_lifecycle_has_meta; then
    HM_DEL_PLAN_STEPS+=("Sprzątanie metadanych kreatora (manifest, .dbs, stan) i baz z manifestu")
    HM_DEL_PLAN_KEYS+=("meta")
  fi
}

hm_site_doctor_readable() {
  local path="$1" kind="$2" domain="$3" home
  hm_site_delete_path_allowed "${path}" "${kind}" "${domain}" || return 1
  home="$(hm_site_home "${domain}" 2>/dev/null || true)"
  [[ -n "${home}" && "${home}" != "/" && "${path}" == "${home}/"* ]] && return 1
  return 0
}

# Kanoniczna ścieżka (także gdy plik jeszcze nie istnieje).
hm_site_canon_path() {
  local p="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath -m -- "${p}" 2>/dev/null && return 0
  fi
  printf '%s' "${p}"
}

# Basename unitu systemd należący do domeny (dokładny slug, bez cudzych hm-*).
hm_site_unit_basename_ok() {
  local base="$1" domain="$2" safe="$3" d s
  [[ "${base}" != *..* && "${base}" == hm-* ]] || return 1
  d="${domain//./\\.}"
  s="${safe//./\\.}"
  [[ "${base}" =~ ^hm-(app-|worker-|cron-|celery-)?(${d}|${s})((@[A-Za-z0-9._-]+)|(-(worker|cron|beat|schedule)(-[A-Za-z0-9._-]+)*))?(\.(service|timer))?$ ]]
}

# Vhost: dokładna nazwa pliku = domena lub domena.conf (bez prefiksu ${domain}*).
hm_site_vhost_path_ok() {
  local path="$1" domain="$2" base
  base="$(basename -- "${path}")"
  [[ "${base}" == "${domain}" || "${base}" == "${domain}.conf" ]] || return 1
  case "${path}" in
    /etc/nginx/sites-available/"${base}"|/etc/nginx/sites-enabled/"${base}")
      return 0 ;;
    /etc/apache2/sites-available/"${base}"|/etc/apache2/sites-enabled/"${base}")
      return 0 ;;
    /etc/httpd/conf.d/"${base}")
      return 0 ;;
  esac
  [[ -n "${HM_SITE_VHOST_DIR:-}" && "${path}" == "${HM_SITE_VHOST_DIR}/${base}" ]] && return 0
  [[ -n "${HM_SITE_VHOST_ENABLED_DIR:-}" && "${path}" == "${HM_SITE_VHOST_ENABLED_DIR}/${base}" ]] && return 0
  return 1
}

hm_site_delete_path_allowed() {
  local path="$1" kind="$2" domain="${3:-${HM_DEL_DOMAIN:-}}" safe="" state="" home="" real="" realhome="" canon="" base="" dir=""
  local vhost_link=0
  [[ "${path}" == /* && "${path}" != "/" ]] || return 1
  [[ -n "${domain}" ]] || return 1
  safe="${domain//[^A-Za-z0-9._-]/_}"
  state="$(hm_site_state_dir "${domain}")"
  canon="$(hm_site_canon_path "${path}")"
  [[ -n "${canon}" && "${canon}" == /* && "${canon}" != "/" ]] || return 1

  # sites-enabled: symlink vhosta wolno skasować jako link (bez podążania).
  if [[ -L "${path}" ]]; then
    if [[ "${kind}" == "vhost" ]] && hm_site_vhost_path_ok "${path}" "${domain}"; then
      case "${path}" in
        /etc/nginx/sites-enabled/*|/etc/apache2/sites-enabled/*)
          vhost_link=1
          ;;
        *)
          if [[ -n "${HM_SITE_VHOST_ENABLED_DIR:-}" && "${path}" == "${HM_SITE_VHOST_ENABLED_DIR}/"* ]]; then
            vhost_link=1
          else
            return 1
          fi
          ;;
      esac
    else
      return 1
    fi
  fi

  if [[ "${vhost_link}" -eq 0 ]]; then
    if declare -F hm_site_path_has_symlink >/dev/null 2>&1 && hm_site_path_has_symlink "${path}"; then
      return 1
    fi
    if [[ -e "${path}" && ! -L "${path}" ]]; then
      real="$(readlink -f -- "${path}" 2>/dev/null || true)"
      [[ -n "${real}" && "${real}" == "${path}" ]] || return 1
    fi
  fi

  case "${kind}" in
    worker|timer|unit|cron|pm2)
      base="$(basename -- "${canon}")"
      dir="$(dirname -- "${canon}")"
      hm_site_unit_basename_ok "${base}" "${domain}" "${safe}" || return 1
      [[ "${dir}" == /etc/systemd/system ]] && return 0
      [[ -n "${HM_SITE_SYSTEMD_DIR:-}" && "${dir}" == "${HM_SITE_SYSTEMD_DIR}" ]] && return 0
      return 1
      ;;
    logrotate)
      [[ "${canon}" == "/etc/logrotate.d/hm-${safe}" || "${canon}" == "/etc/logrotate.d/hm-${safe}.conf" ]] && return 0
      [[ -n "${HM_SITE_LOGROTATE_DIR:-}" && ( "${canon}" == "${HM_SITE_LOGROTATE_DIR}/hm-${safe}" || "${canon}" == "${HM_SITE_LOGROTATE_DIR}/hm-${safe}.conf" ) ]] && return 0
      return 1
      ;;
    firewall)
      [[ "${canon}" == "/etc/hmtools/firewall/hm-${safe}.rules" ]] && return 0
      [[ -n "${HM_SITE_FW_DIR:-}" && "${canon}" == "${HM_SITE_FW_DIR}/hm-${safe}.rules" ]] && return 0
      return 1
      ;;
    vhost)
      if [[ "${vhost_link}" -eq 1 ]]; then
        return 0
      fi
      hm_site_vhost_path_ok "${canon}" "${domain}" && return 0
      return 1
      ;;
    fpm|db|port|compose)
      [[ "${canon}" == "${state}/"* ]] && return 0
      [[ "${canon}" == /etc/php/*/fpm/pool.d/"${domain}".conf ]] && return 0
      return 1
      ;;
  esac
  home="$(hm_site_home "${domain}")"
  [[ -n "${home}" && "${home}" != "/" && "${canon}" == "${home}/"* ]] || return 1
  [[ -L "${home}" ]] && return 1
  if [[ -e "${path}" && ! -L "${path}" ]]; then
    realhome="$(readlink -f -- "${home}" 2>/dev/null || true)"
    real="$(readlink -f -- "${path}" 2>/dev/null || true)"
    [[ -n "${real}" && -n "${realhome}" && "${real}" == "${realhome}/"* ]] || return 1
  fi
  return 0
}

hm_site_lifecycle_disable_unit() {
  local path="$1" base
  base="$(basename -- "${path}")"
  [[ "${base}" == hm-*.service || "${base}" == hm-*.timer || "${base}" == hm-*@*.service ]] || return 0
  if [[ -n "${HM_SITE_LIFECYCLE_LOG:-}" ]]; then
    printf 'disable\t%s\n' "${base}" >> "${HM_SITE_LIFECYCLE_LOG}"
  fi
  [[ "${HMTOOLS_TEST:-}" == "1" ]] && return 0
  if declare -F hm_have_cmd >/dev/null 2>&1 && hm_have_cmd systemctl; then
    systemctl disable --now "${base}" >/dev/null 2>&1 || true
  fi
}

hm_site_lifecycle_remove_path() {
  local path="$1" kind="$2" port_line port_spec
  [[ -n "${path}" && "${path}" != "/" ]] || return 1
  if ! hm_site_delete_path_allowed "${path}" "${kind}"; then
    hm_warn "Odmowa usunięcia ścieżki spoza allowlisty: ${path}"
    return 1
  fi
  case "${kind}" in
    worker|timer|unit|cron|pm2)
      hm_site_lifecycle_disable_unit "${path}"
      ;;
  esac
  if [[ "${kind}" == "firewall" && -f "${path}" && ! -L "${path}" ]]; then
    port_line="$(head -1 "${path}" 2>/dev/null || true)"
    port_spec="${port_line%%#*}"
    port_spec="${port_spec%%[[:space:]]*}"
    if [[ -n "${port_spec}" && "${HMTOOLS_TEST:-}" != "1" ]] \
      && declare -F hm_os_firewall_remove >/dev/null 2>&1; then
      hm_os_firewall_remove "${port_spec}" 2>/dev/null || \
        hm_warn "Nie usunięto reguły firewalla ${port_spec} (snippet i tak kasowany)."
    fi
  fi
  # Najpierw link sites-enabled (gdy kasujemy sites-available) — bez wiszących symlinków.
  if [[ "${kind}" == "vhost" ]]; then
    local en base_v
    case "${path}" in
      */sites-available/*)
        base_v="$(basename -- "${path}")"
        en="$(dirname -- "${path}")"
        en="${en%/sites-available}/sites-enabled/${base_v}"
        if [[ -L "${en}" || -e "${en}" ]] && hm_site_delete_path_allowed "${en}" vhost; then
          rm -f -- "${en}"
          if [[ -n "${HM_SITE_LIFECYCLE_LOG:-}" ]]; then
            printf 'vhost\t%s\n' "${en}" >> "${HM_SITE_LIFECYCLE_LOG}"
          fi
          hm_ok "Usunięto vhost link: ${en}"
        fi
        ;;
    esac
  fi
  if [[ -L "${path}" ]]; then
    rm -f -- "${path}"
  elif [[ -e "${path}" ]]; then
    rm -rf -- "${path}"
  fi
  if [[ -n "${HM_SITE_LIFECYCLE_LOG:-}" ]]; then
    printf '%s\t%s\n' "${kind}" "${path}" >> "${HM_SITE_LIFECYCLE_LOG}"
  fi
  hm_ok "Usunięto ${kind}: ${path}"
}

# Czy baza z .{domena}.dbs jest w planie usunięcia (HM_DEL_DBS)?
hm_site_lifecycle_db_in_plan() {
  local name="$1" dline n_dbs=0 n_skip=0
  [[ -n "${name}" ]] || return 1
  n_dbs="${#HM_DEL_DBS[@]}"
  n_skip="${#HM_DEL_SKIP_DBS[@]}"
  # Brak inwentaryzacji (np. sam lifecycle) → pozwól (dalej guard współdzielenia).
  if [[ "${n_dbs}" -eq 0 && "${n_skip}" -eq 0 ]]; then
    return 0
  fi
  for dline in "${HM_DEL_DBS[@]+"${HM_DEL_DBS[@]}"}"; do
    [[ -n "${dline}" ]] || continue
    [[ "${dline%%|*}" == "${name}" ]] && return 0
  done
  return 1
}

# Usuń bazy/userów z .{domena}.dbs — tylko wyłączne i obecne w planie (HM_DEL_DBS).
hm_site_lifecycle_drop_manifest_dbs() {
  local domain="${1:-${HM_DEL_DOMAIN:-}}" dbfile typ name dbuser host port other planned
  [[ -n "${domain}" ]] || return 0
  [[ "${HM_DEL_KEEP_DB:-0}" == "1" ]] && return 0
  dbfile="$(hm_site_manifest_dir)/.${domain}.dbs"
  [[ -f "${dbfile}" && ! -L "${dbfile}" ]] || return 0
  while IFS=$'\t' read -r typ name dbuser host port || [[ -n "${typ}" ]]; do
    [[ -n "${typ}" && -n "${name}" ]] || continue
    other=""
    if declare -F hm_site_mysql_db_owned_elsewhere >/dev/null 2>&1; then
      other="$(hm_site_mysql_db_owned_elsewhere "${domain}" "${name}" 2>/dev/null || true)"
    fi
    if [[ -n "${other}" ]]; then
      hm_warn "Pomijam DROP ${name} (manifest) — współdzielona z serwisem ${other}."
      continue
    fi
    if declare -F hm_del_db_owned_by_other >/dev/null 2>&1 \
        && hm_del_db_owned_by_other "${name}" "${domain}"; then
      hm_warn "Pomijam DROP ${name} (manifest) — współdzielona z inną domeną."
      continue
    fi
    if ! hm_site_lifecycle_db_in_plan "${name}"; then
      hm_warn "Pomijam DROP ${name} (manifest) — nie w planie usunięcia."
      continue
    fi
    case "${typ}" in
      mysql|mariadb)
        if declare -F hm_mysql_exec >/dev/null 2>&1; then
          hm_mysql_exec -e "DROP DATABASE IF EXISTS \`${name}\`;" 2>/dev/null \
            && hm_ok "DROP DATABASE ${name} (manifest)" || hm_warn "DROP ${name} nieudany"
          if [[ -n "${dbuser}" ]]; then
            hm_mysql_exec -e "DROP USER IF EXISTS '${dbuser}'@'localhost'; FLUSH PRIVILEGES;" 2>/dev/null || true
          fi
        fi
        ;;
      postgres|postgresql|pg)
        if declare -F hm_pg_exec >/dev/null 2>&1; then
          hm_pg_exec -c "DROP DATABASE IF EXISTS \"${name}\";" 2>/dev/null || true
        fi
        ;;
      redis)
        hm_info "Redis ACL ${name} — usuń ręcznie jeśli nie współdzielony."
        ;;
    esac
  done < "${dbfile}"
}

hm_site_lifecycle_cleanup_meta() {
  local domain="${1:-${HM_DEL_DOMAIN:-}}" man res state dbfile
  [[ -n "${domain}" ]] || return 0
  man="$(hm_site_manifest_path "${domain}" 2>/dev/null || true)"
  res="$(hm_site_resources_path "${domain}" 2>/dev/null || true)"
  state="$(hm_site_state_dir "${domain}" 2>/dev/null || true)"
  dbfile="$(hm_site_manifest_dir)/.${domain}.dbs"
  if declare -F hm_site_resource_clear >/dev/null 2>&1; then
    hm_site_resource_clear "${domain}" || true
  fi
  if [[ -n "${res}" && -f "${res}" && ! -L "${res}" ]]; then
    rm -f -- "${res}"
  fi
  [[ -n "${man}" && -f "${man}" && ! -L "${man}" ]] && rm -f -- "${man}"
  if [[ "${HM_DEL_KEEP_DB:-0}" != "1" && -f "${dbfile}" && ! -L "${dbfile}" ]]; then
    rm -f -- "${dbfile}"
  fi
  # --keep-db / --keep-files: nie kasuj całego stanu (mogą leżeć dump/db.sql albo lokalne pliki).
  if [[ "${HM_DEL_KEEP_DB:-0}" != "1" && "${HM_DEL_KEEP_FILES:-0}" != "1" \
        && -n "${state}" && -d "${state}" && ! -L "${state}" ]]; then
    case "${state}" in
      /var/lib/hmtools/sites/*|"${HM_SITE_STATE_BASE:-/var/lib/hmtools/sites}"/*|"${HM_SITE_STATE_DIR:-/var/lib/hmtools/sites}"/*)
        rm -rf -- "${state}"
        ;;
    esac
  fi
  if [[ -n "${HM_SITE_LIFECYCLE_LOG:-}" ]]; then
    printf 'meta\t%s\n' "${domain}" >> "${HM_SITE_LIFECYCLE_LOG}"
  fi
}

hm_site_lifecycle_delete_one() {
  local kind="$1" path="$2" shared="$3"
  if [[ "${shared}" == "1" ]]; then
    hm_info "Zostawiam współdzielone ${kind}: ${path}"
    return 0
  fi
  if [[ "${HM_DEL_KEEP_DB:-0}" == "1" && "${kind}" == "db" ]]; then
    hm_info "Zostawiam bazę (--keep-db): ${path}"
    return 0
  fi
  if [[ "${HM_DEL_KEEP_FILES:-0}" == "1" && -n "${HM_DEL_ROOT:-}" && "${path}" == "${HM_DEL_ROOT}"* ]]; then
    hm_info "Zostawiam plik (--keep-files): ${path}"
    return 0
  fi
  hm_site_lifecycle_remove_path "${path}" "${kind}"
}

hm_site_lifecycle_execute_delete() {
  local k line kind path shared did_vhost=0 did_fpm=0 did_unit=0 fpm_ver="" web
  local -a order=(worker timer unit pm2 compose vhost fpm db firewall port logrotate cron)
  hm_site_lifecycle_drop_manifest_dbs "${HM_DEL_DOMAIN:-}" || true
  for k in "${order[@]}"; do
    if [[ "${k}" == "vhost" ]]; then
      # 1) sites-enabled (linki), 2) pozostałe vhosty
      for line in "${HM_DEL_WIZARD[@]+"${HM_DEL_WIZARD[@]}"}"; do
        [[ -n "${line}" ]] || continue
        kind="${line%%$'\t'*}"
        path="${line#*$'\t'}"
        shared="${path##*$'\t'}"
        path="${path%$'\t'*}"
        [[ "${kind}" == "vhost" ]] || continue
        case "${path}" in */sites-enabled/*) ;; *) continue ;; esac
        [[ "${shared}" == "1" ]] || did_vhost=1
        hm_site_lifecycle_delete_one "${kind}" "${path}" "${shared}" || true
      done
      for line in "${HM_DEL_WIZARD[@]+"${HM_DEL_WIZARD[@]}"}"; do
        [[ -n "${line}" ]] || continue
        kind="${line%%$'\t'*}"
        path="${line#*$'\t'}"
        shared="${path##*$'\t'}"
        path="${path%$'\t'*}"
        [[ "${kind}" == "vhost" ]] || continue
        case "${path}" in */sites-enabled/*) continue ;; esac
        [[ "${shared}" == "1" ]] || did_vhost=1
        hm_site_lifecycle_delete_one "${kind}" "${path}" "${shared}" || true
      done
      continue
    fi
    for line in "${HM_DEL_WIZARD[@]+"${HM_DEL_WIZARD[@]}"}"; do
      [[ -n "${line}" ]] || continue
      kind="${line%%$'\t'*}"
      path="${line#*$'\t'}"
      shared="${path##*$'\t'}"
      path="${path%$'\t'*}"
      [[ "${kind}" == "${k}" ]] || continue
      hm_site_lifecycle_delete_one "${kind}" "${path}" "${shared}" || true
      if [[ "${kind}" == "fpm" ]]; then
        did_fpm=1
        [[ "${path}" =~ /php/([0-9]+\.[0-9]+)/ ]] && fpm_ver="${BASH_REMATCH[1]}"
      fi
      case "${kind}" in worker|timer|unit|cron) did_unit=1 ;; esac
    done
  done
  if [[ "${did_unit}" -eq 1 && "${HMTOOLS_TEST:-}" != "1" ]] \
    && declare -F hm_have_cmd >/dev/null 2>&1 && hm_have_cmd systemctl; then
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  if [[ "${did_vhost}" -eq 1 ]]; then
    web="${HM_SITE_WEBSERVER:-${WEBSERVER:-nginx}}"
    if declare -F hm_site_web_validate >/dev/null 2>&1; then
      hm_site_web_validate "${web}" 2>/dev/null || hm_warn "Walidacja ${web} po delete — sprawdź vhosty."
    fi
    if declare -F hm_site_web_reload >/dev/null 2>&1; then
      hm_site_web_reload "${web}" 2>/dev/null || true
    fi
  fi
  if [[ "${did_fpm}" -eq 1 && -n "${fpm_ver}" ]] \
    && declare -F hm_site_php_fpm_reload >/dev/null 2>&1; then
    hm_site_php_fpm_reload "${fpm_ver}" 2>/dev/null || true
  fi
  hm_site_lifecycle_cleanup_meta "${HM_DEL_DOMAIN:-}" || true
}
