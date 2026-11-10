#!/usr/bin/env bash
# Cykl życia serwisu wg manifestu: show, runtime, doctor, zasoby przy webs delete.

if [[ -n "${HMTOOLS_SITE_LIFE_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_SITE_LIFE_LOADED=1

hm_site_resources_path() {
  local domain="$1" man
  man="$(hm_site_manifest_path "${domain}")"
  printf '%s/%s.resources.ndjson' "$(dirname "${man}")" "${domain}"
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
  printf '{"kind":"%s","path":"%s","shared":%s}\n' \
    "$(hm_site_json_escape "${kind}")" \
    "$(hm_site_json_escape "${path}")" \
    "${flag}" >> "${file}"
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
  tmp="$(mktemp)"
  sed -E 's/("runtime":\{"type":"[^"]*","version":")[^"]*/\1'"${ver}"'/' "${path}" > "${tmp}"
  cat "${tmp}" > "${path}"
  rm -f "${tmp}"
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
  if [[ -f "${src}" ]]; then
    cat "${src}" > "${dest}"
    rm -f "${src}"
  fi
}

hm_site_runtime_php() {
  local domain="$1" ver="$2" path old home pool
  path="$(hm_site_manifest_path "${domain}")"
  [[ -f "${path}" ]] || { hm_err "Brak manifestu."; return 1; }
  old="$(hm_site_runtime_version "${path}")"
  home="$(hm_site_home "${domain}")"
  pool="${HM_SITE_FPM_POOL:-${home}/.hmtools/fpm.conf}"
  mkdir -p "$(dirname "${pool}")" "$(dirname "${path}")"
  [[ -f "${pool}" ]] && cp -f "${pool}" "${pool}.hmbak"
  cp -f "${path}" "${path}.hmbak"
  if [[ "${HM_SITE_RUNTIME_FAIL:-}" == "1" ]]; then
    rm -f "${pool}.hmbak" "${path}.hmbak"
    hm_err "PHP ${ver} nie przeszedł testu — zostaje ${old:-dotychczasowa}."
    return 1
  fi
  printf 'php=%s\nlisten=127.0.0.1\n' "${ver}" > "${pool}"
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
  rm -f "${pool}.hmbak" "${path}.hmbak"
  hm_ok "PHP ${domain} → ${ver}"
}

hm_site_runtime_node() {
  local domain="$1" ver="$2" path old home nvmrc unit line
  path="$(hm_site_manifest_path "${domain}")"
  [[ -f "${path}" ]] || { hm_err "Brak manifestu."; return 1; }
  old="$(hm_site_runtime_version "${path}")"
  home="$(hm_site_home "${domain}")"
  nvmrc="${home}/.nvmrc"
  mkdir -p "${home}"
  [[ -f "${nvmrc}" ]] && cp -f "${nvmrc}" "${nvmrc}.hmbak"
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
  [[ -n "${unit}" && -f "${unit}" ]] && cp -f "${unit}" "${unit}.hmbak"
  if [[ "${HM_SITE_RUNTIME_FAIL:-}" == "1" ]]; then
    rm -f "${nvmrc}.hmbak" "${path}.hmbak" "${unit}.hmbak"
    hm_err "Node ${ver} nie wstał — zostaje ${old:-dotychczasowa}."
    return 1
  fi
  printf '%s\n' "${ver}" > "${nvmrc}"
  if [[ -n "${unit}" && -f "${unit}" && -n "${old}" ]]; then
    sed "s/${old}/${ver}/g" "${unit}" > "${unit}.new"
    cat "${unit}.new" > "${unit}"
    rm -f "${unit}.new"
  fi
  hm_site_manifest_set_version "${path}" "${ver}" || {
    hm_site_runtime_restore "${path}.hmbak" "${path}"
    hm_site_runtime_restore "${nvmrc}.hmbak" "${nvmrc}"
    [[ -n "${unit}" ]] && hm_site_runtime_restore "${unit}.hmbak" "${unit}"
    return 1
  }
  rm -f "${nvmrc}.hmbak" "${path}.hmbak" "${unit}.hmbak"
  hm_ok "Node ${domain} → ${ver}"
}

hm_site_runtime_beside() {
  local domain="$1" ver="$2" prefix="$3" path old home link dest
  path="$(hm_site_manifest_path "${domain}")"
  [[ -f "${path}" ]] || { hm_err "Brak manifestu."; return 1; }
  old="$(hm_site_runtime_version "${path}")"
  home="$(hm_site_home "${domain}")"
  link="${home}/.hmtools/${prefix}"
  dest="${home}/.hmtools/${prefix}-${ver}"
  mkdir -p "${home}/.hmtools"
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
  if [[ ! -f "$(hm_site_resources_path "${domain}")" ]]; then
    printf 'OK\tbrak listy zasobów\n'
    return 0
  fi
  while IFS= read -r line || [[ -n "${line}" ]]; do
    hm_site_resource_read "${line}" || continue
    [[ "${HM_SITE_RES_SHARED}" -eq 1 ]] && continue
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

hm_site_lifecycle_plan_delete() {
  local line kind path shared
  [[ "${#HM_DEL_WIZARD[@]}" -gt 0 ]] || return 0
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
}

hm_site_lifecycle_remove_path() {
  local path="$1" kind="$2"
  [[ -n "${path}" && "${path}" != "/" ]] || return 0
  case "${path}" in
    /usr/*|/bin/*|/sbin/*|/lib/*|/lib64/*)
      hm_warn "Odmowa usunięcia ścieżki systemowej: ${path}"
      return 0
      ;;
  esac
  if [[ -e "${path}" || -L "${path}" ]]; then
    rm -rf -- "${path}"
  fi
  if [[ -n "${HM_SITE_LIFECYCLE_LOG:-}" ]]; then
    printf '%s\t%s\n' "${kind}" "${path}" >> "${HM_SITE_LIFECYCLE_LOG}"
  fi
  hm_ok "Usunięto ${kind}: ${path}"
}

hm_site_lifecycle_execute_delete() {
  local k line kind path shared
  local -a order=(worker timer unit pm2 compose vhost fpm db firewall port logrotate cron)
  for k in "${order[@]}"; do
    for line in "${HM_DEL_WIZARD[@]+"${HM_DEL_WIZARD[@]}"}"; do
      [[ -n "${line}" ]] || continue
      kind="${line%%$'\t'*}"
      path="${line#*$'\t'}"
      shared="${path##*$'\t'}"
      path="${path%$'\t'*}"
      [[ "${kind}" == "${k}" ]] || continue
      if [[ "${shared}" == "1" ]]; then
        hm_info "Zostawiam współdzielone ${kind}: ${path}"
        continue
      fi
      if [[ "${HM_DEL_KEEP_DB:-0}" == "1" && "${kind}" == "db" ]]; then
        hm_info "Zostawiam bazę (--keep-db): ${path}"
        continue
      fi
      if [[ "${HM_DEL_KEEP_FILES:-0}" == "1" && -n "${HM_DEL_ROOT:-}" && "${path}" == "${HM_DEL_ROOT}"* ]]; then
        hm_info "Zostawiam plik (--keep-files): ${path}"
        continue
      fi
      hm_site_lifecycle_remove_path "${path}" "${kind}"
    done
  done
}
