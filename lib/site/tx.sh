#!/usr/bin/env bash
# Manifest serwisu i journal transakcji (rollback / resume).

if [[ -n "${HMTOOLS_SITE_TX_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_SITE_TX_LOADED=1

hm_site_manifest_dir() {
  printf '%s' "${HM_SITE_MANIFEST_DIR:-/etc/hmtools/sites}"
}

hm_site_manifest_path() {
  printf '%s/%s.json' "$(hm_site_manifest_dir)" "${1:-}"
}

hm_site_journal_dir() {
  printf '%s' "${HM_SITE_JOURNAL_DIR:-/var/lib/hmtools/journal}"
}

hm_tx_lock_path() {
  printf '%s/site-%s.lock' "${HM_SITE_LOCK_DIR:-/run/hmtools}" "${1:-}"
}

hm_site_json_escape() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "${s}"
}

hm_tx_acquire() {
  local path="$1" what="$2" pid=""
  mkdir -p "$(dirname "${path}")"
  if [[ -f "${path}" ]]; then
    pid="$(head -1 "${path}" 2>/dev/null || true)"
    if [[ "${pid}" == "$$" && "${HM_TX_LOCK:-}" == "${path}" ]]; then
      return 0
    fi
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
      hm_err "Lock: ${what} jest już w trakcie."
      return 1
    fi
  fi
  printf '%s\n' "$$" > "${path}"
  chmod 0600 "${path}" 2>/dev/null || true
  HM_TX_LOCK="${path}"
}

hm_tx_lock() {
  hm_tx_acquire "$(hm_tx_lock_path "${1}")" "site new ${1}"
}

hm_tx_pkg_lock() {
  hm_tx_acquire "${HM_SITE_LOCK_DIR:-/run/hmtools}/pkg.lock" "instalacja pakietów"
}

hm_tx_unlock() {
  [[ -n "${HM_TX_LOCK:-}" && -f "${HM_TX_LOCK}" ]] && rm -f "${HM_TX_LOCK}"
  HM_TX_LOCK=""
}

hm_tx_journal_open() {
  local domain="$1" dir stamp
  dir="$(hm_site_journal_dir)"
  mkdir -p "${dir}"
  chmod 0700 "${dir}" 2>/dev/null || true
  stamp="$(date +%Y%m%d%H%M%S)"
  HM_TX_JOURNAL="${dir}/${domain}-${stamp}.log"
  : > "${HM_TX_JOURNAL}"
  chmod 0600 "${HM_TX_JOURNAL}" 2>/dev/null || true
}

hm_tx_latest_open() {
  local domain="$1" dir f latest=""
  dir="$(hm_site_journal_dir)"
  [[ -d "${dir}" ]] || return 1
  for f in "${dir}/${domain}-"*.log; do
    [[ -f "${f}" ]] || continue
    grep -q '^COMMIT$' "${f}" && continue
    grep -q '^ROLLBACK$' "${f}" && continue
    latest="${f}"
  done
  [[ -n "${latest}" ]] || return 1
  HM_TX_JOURNAL="${latest}"
  printf '%s' "${latest}"
}

hm_tx_begin() {
  local domain="$1"
  hm_tx_lock "${domain}" || return 1
  hm_tx_journal_open "${domain}"
  printf 'BEGIN tx %s\n' "${domain}" >> "${HM_TX_JOURNAL}"
  HM_TX_DOMAIN="${domain}"
}

hm_tx_step() {
  local name="$1" undo="${2:-}"
  [[ -n "${HM_TX_JOURNAL:-}" && -f "${HM_TX_JOURNAL}" ]] || return 1
  if grep -q "^DONE ${name}$" "${HM_TX_JOURNAL}"; then
    hm_info "pomijam — już jest (${name})"
    return 0
  fi
  printf 'BEGIN %s\n' "${name}" >> "${HM_TX_JOURNAL}"
  printf 'undo=%s\n' "${undo}" >> "${HM_TX_JOURNAL}"
  return 2
}

hm_tx_done() {
  local name="$1"
  printf 'DONE %s\n' "${name}" >> "${HM_TX_JOURNAL}"
}

hm_tx_undo_ok() {
  case "${1:-}" in
    rm\ *|rmdir\ *|userdel\ *) return 0 ;;
    *) return 1 ;;
  esac
}

hm_tx_rollback() {
  local domain="$1" journal line undo
  journal="$(hm_tx_latest_open "${domain}" || true)"
  [[ -n "${journal}" && -f "${journal}" ]] || { hm_err "Brak otwartego journala dla ${domain}."; return 1; }
  local -a undos=()
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" == undo=* ]] || continue
    undo="${line#undo=}"
    [[ -n "${undo}" ]] && undos+=("${undo}")
  done < "${journal}"
  local i
  for ((i = ${#undos[@]} - 1; i >= 0; i--)); do
    undo="${undos[$i]}"
    hm_tx_undo_ok "${undo}" || { hm_err "Odrzucono undo: ${undo}"; return 1; }
    # shellcheck disable=SC2086
    bash -c "${undo}" || hm_warn "undo nieudane: ${undo}"
  done
  printf 'ROLLBACK\n' >> "${journal}"
  hm_tx_unlock
  hm_ok "Cofnięto niedokończone wdrożenie ${domain}."
}

hm_tx_resume() {
  local domain="$1"
  hm_tx_lock "${domain}" || return 1
  hm_tx_latest_open "${domain}" >/dev/null || { hm_tx_unlock; hm_err "Brak czego wznawiać."; return 1; }
  HM_TX_DOMAIN="${domain}"
  hm_info "Wznawiam ${domain} od ostatniego DONE."
}

hm_site_manifest_record_db() {
  local domain="$1" typ="$2" name="$3" user="$4" host="$5" port="$6" extra="${7:-}"
  case "${extra}" in
    *password*|*secret*|*token*) hm_err "Manifest nie przyjmuje sekretów."; return 1 ;;
  esac
  local file
  file="$(hm_site_manifest_dir)/.${domain}.dbs"
  mkdir -p "$(hm_site_manifest_dir)"
  printf '%s\t%s\t%s\t%s\t%s\n' "${typ}" "${name}" "${user}" "${host}" "${port}" >> "${file}"
}

hm_site_manifest_write() {
  local domain="$1" user="$2" runtime="$3" web="${4:-}" envpath="$5" aliases="${6:-www}"
  local dir path tmp dbs="[]" line typ name dbuser host port first=1 ver
  dir="$(hm_site_manifest_dir)"
  mkdir -p "${dir}"
  chmod 0700 "${dir}" 2>/dev/null || true
  path="$(hm_site_manifest_path "${domain}")"
  local dbfile="${dir}/.${domain}.dbs"
  if [[ -f "${dbfile}" ]]; then
    dbs="["
    while IFS=$'\t' read -r typ name dbuser host port; do
      [[ -n "${typ}" ]] || continue
      [[ "${first}" -eq 0 ]] && dbs+=","
      first=0
      dbs+="$(printf '{"type":"%s","name":"%s","user":"%s","host":"%s","port":"%s"}' \
        "$(hm_site_json_escape "${typ}")" "$(hm_site_json_escape "${name}")" \
        "$(hm_site_json_escape "${dbuser}")" "$(hm_site_json_escape "${host}")" \
        "$(hm_site_json_escape "${port}")")"
    done < "${dbfile}"
    dbs+="]"
  fi
  ver="v0.1.12"
  [[ -f "${HMTOOLS_ROOT:-}/VERSION" ]] && ver="$(tr -d '[:space:]' < "${HMTOOLS_ROOT}/VERSION")"
  tmp="$(mktemp "${dir}/.${domain}.XXXXXX")"
  chmod 0600 "${tmp}" 2>/dev/null || true
  cat > "${tmp}" <<EOF
{"schema":1,"domain":"$(hm_site_json_escape "${domain}")","aliases":["$(hm_site_json_escape "${aliases}")"],"user":"$(hm_site_json_escape "${user}")","webserver":"$(hm_site_json_escape "${web}")","runtime":{"type":"$(hm_site_json_escape "${runtime}")","version":"","manager":""},"databases":${dbs},"env_file":"$(hm_site_json_escape "${envpath}")","ssl":false,"created_by":"site new","created_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","hmtools_version":"${ver}"}
EOF
  if hm_have_cmd jq; then
    jq -e . "${tmp}" >/dev/null || { rm -f "${tmp}"; hm_err "Manifest nie jest JSON."; return 1; }
  fi
  mv -f "${tmp}" "${path}"
  chmod 0600 "${path}" 2>/dev/null || true
  printf '%s' "${path}"
}

hm_tx_commit() {
  local domain="$1" user="$2" runtime="$3" web="${4:-}" envpath="$5"
  [[ -n "${HM_TX_JOURNAL:-}" ]] || return 1
  printf 'COMMIT\n' >> "${HM_TX_JOURNAL}"
  hm_site_manifest_write "${domain}" "${user}" "${runtime}" "${web}" "${envpath}" "${HM_SITE_ALIASES:-www}" >/dev/null
  hm_tx_unlock
}

hm_site_profile_get() {
  local file="$1" key="$2"
  sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "${file}" | head -1
}

hm_site_profile_load() {
  local file="$1"
  [[ -f "${file}" ]] || { hm_err "Brak profilu: ${file}"; return 1; }
  case "${file}" in
    *.yml|*.yaml)
      if [[ "${HM_SITE_YAML_FORCE:-}" == "missing" ]]; then
        hm_err "Profil YAML wymaga yq albo python3 z modułem yaml."
        return 1
      fi
      if ! hm_have_cmd yq && { ! hm_have_cmd python3 || ! python3 -c 'import yaml' >/dev/null 2>&1; }; then
        hm_err "Profil YAML wymaga yq albo python3 z modułem yaml."
        return 1
      fi
      if hm_have_cmd yq; then
        HM_SITE_PROFILE_PRESET="$(yq -r '.preset // ""' "${file}")"
        HM_SITE_PROFILE_RUNTIME="$(yq -r '.runtime // ""' "${file}")"
        HM_SITE_PROFILE_DB="$(yq -r '.db // ""' "${file}")"
        HM_SITE_PROFILE_WEB="$(yq -r '.webserver // ""' "${file}")"
        HM_SITE_PROFILE_PHP="$(yq -r '.php // ""' "${file}")"
        HM_SITE_PROFILE_DOMAIN="$(yq -r '.domain // ""' "${file}")"
        return 0
      fi
      local line key val
      while IFS= read -r line; do
        key="${line%%=*}"
        val="${line#*=}"
        case "${key}" in
          preset) HM_SITE_PROFILE_PRESET="${val}" ;;
          runtime) HM_SITE_PROFILE_RUNTIME="${val}" ;;
          db) HM_SITE_PROFILE_DB="${val}" ;;
          webserver) HM_SITE_PROFILE_WEB="${val}" ;;
          php) HM_SITE_PROFILE_PHP="${val}" ;;
          domain) HM_SITE_PROFILE_DOMAIN="${val}" ;;
        esac
      done < <(python3 - "${file}" <<'PY'
import sys
try:
    import yaml
except ImportError:
    sys.exit(2)
with open(sys.argv[1], encoding="utf-8") as fh:
    data = yaml.safe_load(fh) or {}
for key in ("preset", "runtime", "db", "webserver", "php", "domain"):
    value = data.get(key, "")
    if value is None:
        value = ""
    print(f"{key}={value}")
PY
)
      return 0
      ;;
  esac
  HM_SITE_PROFILE_PRESET="$(hm_site_profile_get "${file}" preset)"
  HM_SITE_PROFILE_RUNTIME="$(hm_site_profile_get "${file}" runtime)"
  HM_SITE_PROFILE_DB="$(hm_site_profile_get "${file}" db)"
  HM_SITE_PROFILE_WEB="$(hm_site_profile_get "${file}" webserver)"
  HM_SITE_PROFILE_PHP="$(hm_site_profile_get "${file}" php)"
  HM_SITE_PROFILE_DOMAIN="$(hm_site_profile_get "${file}" domain)"
}

hm_site_profile_save() {
  local dest="$1" domain="$2" preset="$3" runtime="$4" db="$5" web="$6"
  case "${preset}${runtime}${db}${web}" in
    *password*|*secret*|*token*) hm_err "Profil nie może zawierać sekretu."; return 1 ;;
  esac
  cat > "${dest}" <<EOF
{"preset":"$(hm_site_json_escape "${preset}")","runtime":"$(hm_site_json_escape "${runtime}")","db":"$(hm_site_json_escape "${db}")","webserver":"$(hm_site_json_escape "${web}")","domain":"$(hm_site_json_escape "${domain}")"}
EOF
  hm_ok "Profil zapisany: ${dest}"
}

cmd_site_manifest() {
  local domain="${1:-${HM_SITE_BASE_DOMAIN:-${HM_SITE_DOMAIN:-}}}" path
  [[ -n "${domain}" ]] || { hm_err "Użycie: site manifest <domena>"; return 1; }
  path="$(hm_site_manifest_path "${domain}")"
  [[ -f "${path}" ]] || { hm_err "Brak manifestu ${path}"; return 1; }
  sed -E 's/(password|secret|token)":"[^"]*"/\1":"****"/g' "${path}"
  printf '\n'
}
