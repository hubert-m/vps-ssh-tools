#!/usr/bin/env bash
# vuln — CVE pakietów, wtyczki/motywy WP i wersje EOL. Token API tylko z env albo pliku 0600.

_hm_cmd_help vuln <<'EOF'
Użycie:
  vuln [--json]              Podsumowanie: os + wp + eol
  vuln os [--json]           Poprawki security pakietów (hm_pkg_list_security)
  vuln wp [--all|domena] [--json]
                             Core, wtyczki i motywy. Bez tokenu: lokalna baza.
  vuln eol [--json]          PHP, Node, OLS, MariaDB, OS — tabela share/vuln/eol.tsv

Token WPScan: zmienna HM_VULN_WPSCAN_TOKEN albo plik 0600
  (HM_VULN_TOKEN_FILE, domyślnie /etc/hmtools/vuln-wpscan.token).
Token nie trafia do argv, applogu ani --json. --json jest pod raport tygodniowy.
Naprawa: update security, wp plugin update <nazwa>, wp theme update <nazwa>, wp core update.
EOF

hm_vuln_json_escape() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "${s}"
}

hm_vuln_norm_sev() {
  local raw
  raw="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "${raw}" in
    critical|krytyczny|krytyczne) printf 'critical' ;;
    important|high|wysoki|wysokie) printf 'high' ;;
    moderate|medium|sredni|średni) printf 'medium' ;;
    low|niski|niskie) printf 'low' ;;
    *) printf 'high' ;;
  esac
}

hm_vuln_reset() {
  HM_VULN_FINDINGS="$(mktemp "${TMPDIR:-/tmp}/hm-vuln.XXXXXX")"
}

hm_vuln_add() {
  local sev="$1" kind="$2" id="${3:-}" subject="$4" version="${5:-}" fix="$6"
  [[ -n "${HM_VULN_FINDINGS:-}" ]] || hm_vuln_reset
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${sev}" "${kind}" "${id}" "${subject}" "${version}" "${fix}" >> "${HM_VULN_FINDINGS}"
}

hm_vuln_cve_for() {
  local pkg="$1" file="${HM_VULN_CVE_MAP:-}" name cve sev
  [[ -n "${file}" && -f "${file}" ]] || return 1
  while read -r name cve sev _; do
    [[ "${name}" == \#* || -z "${name}" ]] && continue
    if [[ "${name}" == "${pkg}" ]]; then
      printf '%s\t%s' "${cve}" "$(hm_vuln_norm_sev "${sev:-high}")"
      return 0
    fi
  done < "${file}"
  return 1
}

hm_vuln_pkg_name() {
  local raw="$1"
  raw="${raw%.x86_64}"
  raw="${raw%.aarch64}"
  raw="${raw%.noarch}"
  if [[ "${raw}" =~ ^(.+)-[0-9]+: ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "${raw}" =~ ^(.+)-[0-9] ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  printf '%s' "${raw}"
}

hm_vuln_add_os() {
  local pkg="$1" inst="${2:-}" cand="${3:-}" cve="" sev="high" pair=""
  if pair="$(hm_vuln_cve_for "${pkg}")"; then
    cve="${pair%%$'\t'*}"
    sev="${pair#*$'\t'}"
  fi
  local ver="${inst}"
  [[ -n "${cand}" ]] && ver="${inst} -> ${cand}"
  hm_vuln_add "${sev}" os "${cve}" "${pkg}" "${ver}" "update security"
}

hm_vuln_parse_apt_line() {
  local line="$1" name cand inst=""
  [[ "${line}" == *"security"* ]] || return 0
  [[ "${line}" =~ ^([A-Za-z0-9.+-]+)/[^[:space:]]+[[:space:]]+([^[:space:]]+) ]] || return 0
  name="${BASH_REMATCH[1]}"
  cand="${BASH_REMATCH[2]}"
  if [[ "${line}" =~ \[upgradable\ from:\ ([^]]+)\] ]]; then
    inst="${BASH_REMATCH[1]}"
  fi
  hm_vuln_add_os "${name}" "${inst}" "${cand}"
}

hm_vuln_parse_dnf_line() {
  local line="$1" cve="" sev="high" pkg=""
  [[ "${line}" =~ ^(CVE-[0-9]{4}-[0-9]+)[[:space:]]+([A-Za-z]+)[^[:space:]]*[[:space:]]+([^[:space:]]+)$ ]] || return 0
  cve="${BASH_REMATCH[1]}"
  sev="$(hm_vuln_norm_sev "${BASH_REMATCH[2]}")"
  pkg="$(hm_vuln_pkg_name "${BASH_REMATCH[3]}")"
  hm_vuln_add "${sev}" os "${cve}" "${pkg}" "" "update security"
}

hm_vuln_parse_os_file() {
  local file="$1" line
  [[ -f "${file}" ]] || return 1
  if grep -q 'upgradable from' "${file}"; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      hm_vuln_parse_apt_line "${line}"
    done < "${file}"
    return 0
  fi
  while IFS= read -r line || [[ -n "${line}" ]]; do
    hm_vuln_parse_dnf_line "${line}"
  done < "${file}"
}

hm_vuln_os() {
  local name inst cand
  if [[ -n "${HM_VULN_OS_FILE:-}" ]]; then
    hm_vuln_parse_os_file "${HM_VULN_OS_FILE}"
    return 0
  fi
  if ! declare -F hm_pkg_list_security >/dev/null 2>&1; then
    hm_warn "Brak listy security pakietów — pomijam vuln os."
    return 0
  fi
  while IFS=$'\t' read -r name inst cand; do
    [[ -n "${name}" ]] || continue
    hm_vuln_add_os "${name}" "${inst}" "${cand}"
  done < <(hm_pkg_list_security 2>/dev/null || true)
}

hm_vuln_ver_lt() {
  local a="$1" b="$2" first
  [[ -n "${a}" && -n "${b}" ]] || return 1
  first="$(printf '%s\n%s\n' "${a}" "${b}" | sort -V | head -1)"
  [[ "${first}" == "${a}" && "${a}" != "${b}" ]]
}

hm_vuln_wp_feed_file() {
  if [[ -n "${HM_VULN_WP_FEED:-}" ]]; then
    printf '%s' "${HM_VULN_WP_FEED}"
    return 0
  fi
  local root="${HMTOOLS_ROOT:-}"
  if [[ -z "${root}" ]]; then
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  fi
  printf '%s' "${root}/share/vuln/wp.tsv"
}

hm_vuln_token_mode_ok() {
  local file="$1" mode=""
  [[ -f "${file}" && ! -L "${file}" ]] || return 1
  mode="$(stat -c '%a' -- "${file}" 2>/dev/null || stat -f '%OLp' "${file}" 2>/dev/null || printf '644')"
  [[ "${mode: -2}" == "00" ]]
}

# Wartość tokenu tylko do podstawienia w pliku konfiguracyjnym curl, nigdy w argv.
hm_vuln_token_value() {
  local file="${HM_VULN_TOKEN_FILE:-/etc/hmtools/vuln-wpscan.token}" val=""
  if [[ -n "${HM_VULN_WPSCAN_TOKEN:-}" ]]; then
    printf '%s' "${HM_VULN_WPSCAN_TOKEN}"
    return 0
  fi
  [[ -f "${file}" ]] || return 1
  if ! hm_vuln_token_mode_ok "${file}"; then
    hm_warn "Token API odrzucony: plik musi mieć tryb 0600 (${file})."
    return 1
  fi
  val="$(tr -d '[:space:]' < "${file}")"
  [[ -n "${val}" ]] || return 1
  printf '%s' "${val}"
}

hm_vuln_fetch_api() {
  local url="$1" cfg="" token="" rc=0
  token="$(hm_vuln_token_value)" || return 1
  cfg="$(mktemp "${TMPDIR:-/tmp}/hm-vuln-curl.XXXXXX")"
  chmod 0600 "${cfg}" 2>/dev/null || true
  {
    printf '%s\n' 'silent'
    printf 'url = "%s"\n' "${url}"
    printf 'header = "Authorization: Token token=%s"\n' "${token}"
  } > "${cfg}"
  curl --config "${cfg}" || rc=$?
  rm -f "${cfg}"
  return "${rc}"
}

hm_vuln_parse_api_text() {
  local text="$1" obj kind name fixed cve sev
  while IFS= read -r obj; do
    [[ -n "${obj}" ]] || continue
    kind="$(printf '%s' "${obj}" | sed -n 's/.*"kind":"\([^"]*\)".*/\1/p')"
    name="$(printf '%s' "${obj}" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')"
    fixed="$(printf '%s' "${obj}" | sed -n 's/.*"fixed":"\([^"]*\)".*/\1/p')"
    cve="$(printf '%s' "${obj}" | sed -n 's/.*"cve":"\([^"]*\)".*/\1/p')"
    sev="$(printf '%s' "${obj}" | sed -n 's/.*"severity":"\([^"]*\)".*/\1/p')"
    [[ -n "${kind}" && -n "${name}" && -n "${fixed}" ]] || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "${kind}" "${name}" "${fixed}" "${cve}" "$(hm_vuln_norm_sev "${sev:-high}")"
  done < <(printf '%s\n' "${text}" | grep -oE '\{"kind":"[^"]*","name":"[^"]*","fixed":"[^"]*","cve":"[^"]*","severity":"[^"]*"\}' || true)
}

hm_vuln_load_feed() {
  local dest="$1" file line kind name fixed cve sev
  : > "${dest}"
  file="$(hm_vuln_wp_feed_file)"
  if [[ -f "${file}" ]]; then
    while IFS=$'\t' read -r kind name fixed cve sev _; do
      [[ -n "${kind}" && "${kind}" != \#* ]] || continue
      printf '%s\t%s\t%s\t%s\t%s\n' "${kind}" "${name}" "${fixed}" "${cve}" "$(hm_vuln_norm_sev "${sev:-high}")" >> "${dest}"
    done < "${file}"
  fi
  local raw=""
  if [[ -n "${HM_VULN_WP_API_FILE:-}" && -f "${HM_VULN_WP_API_FILE}" ]]; then
    raw="$(cat "${HM_VULN_WP_API_FILE}")"
  elif [[ -n "${HM_VULN_WP_API_URL:-}" ]]; then
    raw="$(hm_vuln_fetch_api "${HM_VULN_WP_API_URL}" || true)"
  fi
  if [[ -n "${raw}" ]]; then
    hm_vuln_parse_api_text "${raw}" >> "${dest}"
  fi
}

hm_vuln_wp_fix() {
  case "${1:-}" in
    plugin) printf 'wp plugin update %s' "${2}" ;;
    theme) printf 'wp theme update %s' "${2}" ;;
    core) printf 'wp core update' ;;
    *) printf 'aktualizacja %s %s' "${1}" "${2}" ;;
  esac
}

hm_vuln_wp_match() {
  local domain="$1" kind="$2" name="$3" ver="$4" feed="$5"
  local fkind fname fixed cve sev
  while IFS=$'\t' read -r fkind fname fixed cve sev; do
    [[ "${fkind}" == "${kind}" && "${fname}" == "${name}" ]] || continue
    if hm_vuln_ver_lt "${ver}" "${fixed}"; then
      hm_vuln_add "${sev}" wp "${cve}" "${kind} ${name}" "${ver}" "$(hm_vuln_wp_fix "${kind}" "${name}")"
    fi
  done < "${feed}"
}

hm_vuln_wp_header_version() {
  local file="$1"
  [[ -f "${file}" && ! -L "${file}" ]] || return 1
  sed -n 's/^[ \t*]*Version:[[:space:]]*//p' "${file}" | head -1 | tr -d '[:space:]'
}

hm_vuln_wp_scan_root() {
  local root="$1" feed="$2" site domain ver dir slug f
  [[ -d "${root}" ]] || return 0
  for site in "${root}"/*; do
    [[ -d "${site}" ]] || continue
    domain="$(basename "${site}")"
    if [[ -n "${HM_VULN_WP_ONLY:-}" && "${HM_VULN_WP_ONLY}" != "--all" && "${domain}" != "${HM_VULN_WP_ONLY}" ]]; then
      continue
    fi
    if [[ -f "${site}/wp-includes/version.php" ]]; then
      ver="$(sed -n "s/.*\\\$wp_version[[:space:]]*=[[:space:]]*'\\([^']*\\)'.*/\\1/p" "${site}/wp-includes/version.php" | head -1)"
      [[ -n "${ver}" ]] && hm_vuln_wp_match "${domain}" core wordpress "${ver}" "${feed}"
    fi
    for dir in "${site}/wp-content/plugins/"*; do
      [[ -d "${dir}" ]] || continue
      slug="$(basename "${dir}")"
      ver=""
      for f in "${dir}/"*.php; do
        [[ -f "${f}" ]] || continue
        ver="$(hm_vuln_wp_header_version "${f}" || true)"
        [[ -n "${ver}" ]] && break
      done
      [[ -n "${ver}" ]] && hm_vuln_wp_match "${domain}" plugin "${slug}" "${ver}" "${feed}"
    done
    for dir in "${site}/wp-content/themes/"*; do
      [[ -d "${dir}" ]] || continue
      slug="$(basename "${dir}")"
      ver="$(hm_vuln_wp_header_version "${dir}/style.css" || true)"
      [[ -n "${ver}" ]] && hm_vuln_wp_match "${domain}" theme "${slug}" "${ver}" "${feed}"
    done
  done
}

hm_vuln_wp() {
  local feed inv line domain kind name ver
  feed="$(mktemp "${TMPDIR:-/tmp}/hm-vuln-feed.XXXXXX")"
  hm_vuln_load_feed "${feed}"
  if [[ -z "${HM_VULN_WPSCAN_TOKEN:-}" && -z "${HM_VULN_WP_API_FILE:-}" && -z "${HM_VULN_WP_API_URL:-}" ]]; then
    if [[ "${HM_VULN_JSON:-0}" -eq 0 ]]; then
      hm_info "WP: tryb offline (lokalna baza, bez tokenu API)."
    fi
  fi
  if [[ -n "${HM_VULN_WP_FILE:-}" && -f "${HM_VULN_WP_FILE}" ]]; then
    while IFS=$'\t' read -r domain kind name ver _; do
      [[ -n "${kind}" && "${kind}" != \#* ]] || continue
      if [[ -n "${HM_VULN_WP_ONLY:-}" && "${HM_VULN_WP_ONLY}" != "--all" && "${domain}" != "${HM_VULN_WP_ONLY}" ]]; then
        continue
      fi
      hm_vuln_wp_match "${domain}" "${kind}" "${name}" "${ver}" "${feed}"
    done < "${HM_VULN_WP_FILE}"
  fi
  if [[ -n "${HM_VULN_WP_ROOT:-}" ]]; then
    hm_vuln_wp_scan_root "${HM_VULN_WP_ROOT}" "${feed}"
  fi
  rm -f "${feed}"
}

hm_vuln_eol_file() {
  if [[ -n "${HM_VULN_EOL_FILE:-}" ]]; then
    printf '%s' "${HM_VULN_EOL_FILE}"
    return 0
  fi
  local root="${HMTOOLS_ROOT:-}"
  if [[ -z "${root}" ]]; then
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  fi
  printf '%s' "${root}/share/vuln/eol.tsv"
}

hm_vuln_eol_lookup() {
  local kind="$1" ver="$2" file line k v st until mm
  if [[ "${kind}" == "php" ]] && declare -F hm_site_php_support_of >/dev/null 2>&1; then
    if [[ "${ver}" =~ ^([0-9]+\.[0-9]+) ]]; then
      mm="${BASH_REMATCH[1]}"
    else
      mm="${ver}"
    fi
    hm_site_php_support_of "${mm}"
    return 0
  fi
  file="$(hm_vuln_eol_file)"
  [[ -f "${file}" ]] || return 1
  if [[ "${ver}" =~ ^([0-9]+\.[0-9]+) ]]; then
    mm="${BASH_REMATCH[1]}"
  else
    mm="${ver}"
  fi
  local major="${mm%%.*}"
  while IFS=$'\t' read -r k v st until _; do
    [[ -n "${k}" && "${k}" != \#* ]] || continue
    if [[ "${k}" == "${kind}" && ( "${v}" == "${ver}" || "${v}" == "${mm}" || "${v}" == "${major}" ) ]]; then
      printf '%s\t%s' "${st}" "${until:-}"
      return 0
    fi
  done < "${file}"
  return 1
}

hm_vuln_eol_one() {
  local kind="$1" ver="$2" pair="" st="" until="" sev="" fix=""
  [[ -n "${ver}" ]] || return 0
  pair="$(hm_vuln_eol_lookup "${kind}" "${ver}" 2>/dev/null || true)"
  [[ -n "${pair}" ]] || return 0
  st="${pair%%$'\t'*}"
  until="${pair#*$'\t'}"
  [[ "${until}" == "${st}" ]] && until=""
  case "${st}" in
    eol)
      sev="high"
      fix="aktualizacja ${kind} ${ver}"
      ;;
    security)
      sev="medium"
      if [[ -n "${until}" ]]; then
        fix="wsparcie bezpieczeństwa ${kind} ${ver} do ${until}"
      else
        fix="wsparcie bezpieczeństwa ${kind} ${ver}"
      fi
      ;;
    *) return 0 ;;
  esac
  hm_vuln_add "${sev}" eol "" "${kind} ${ver}" "${ver}" "${fix}"
}

hm_vuln_each_version() {
  local raw="$1" v
  for v in ${raw}; do
    printf '%s\n' "${v}"
  done
}

hm_vuln_eol() {
  local ver
  if [[ -n "${HM_VULN_PHP_VERSIONS:-}" ]]; then
    while IFS= read -r ver; do
      hm_vuln_eol_one php "${ver}"
    done < <(hm_vuln_each_version "${HM_VULN_PHP_VERSIONS}")
  elif declare -F hm_site_php_versions >/dev/null 2>&1; then
    while IFS=$'\t' read -r ver _; do
      hm_vuln_eol_one php "${ver}"
    done < <(hm_site_php_versions || true)
  fi
  if [[ -n "${HM_VULN_NODE_VERSIONS:-}" ]]; then
    while IFS= read -r ver; do
      hm_vuln_eol_one node "${ver}"
    done < <(hm_vuln_each_version "${HM_VULN_NODE_VERSIONS}")
  fi
  if [[ -n "${HM_VULN_OLS_VERSION:-}" ]]; then
    hm_vuln_eol_one ols "${HM_VULN_OLS_VERSION}"
  fi
  if [[ -n "${HM_VULN_MARIADB_VERSION:-}" ]]; then
    hm_vuln_eol_one mariadb "${HM_VULN_MARIADB_VERSION}"
  fi
  if [[ -n "${HM_VULN_OS_KEY:-}" ]]; then
    hm_vuln_eol_one os "${HM_VULN_OS_KEY}"
  fi
}

hm_vuln_print_text() {
  local c=0 h=0 m=0 sev kind id subject version fix
  while IFS=$'\t' read -r sev kind id subject version fix; do
    case "${sev}" in
      critical) c=$((c + 1)) ;;
      high) h=$((h + 1)) ;;
      medium) m=$((m + 1)) ;;
    esac
  done < "${HM_VULN_FINDINGS}"
  echo "${C_BOLD}vuln — podatności${C_RESET}"
  echo "  krytyczne : ${c}"
  echo "  wysokie   : ${h}"
  echo "  średnie   : ${m}"
  echo
  while IFS=$'\t' read -r sev kind id subject version fix; do
    [[ -n "${sev}" ]] || continue
    printf '  [%s] %s %s %s\n' "${sev}" "${kind}" "${subject}" "${id}"
    printf '         naprawa: %s\n' "${fix}"
  done < "${HM_VULN_FINDINGS}"
}

hm_vuln_print_json() {
  local c=0 h=0 m=0 l=0 sev kind id subject version fix first=1
  while IFS=$'\t' read -r sev kind id subject version fix; do
    case "${sev}" in
      critical) c=$((c + 1)) ;;
      high) h=$((h + 1)) ;;
      medium) m=$((m + 1)) ;;
      low) l=$((l + 1)) ;;
    esac
  done < "${HM_VULN_FINDINGS}"
  printf '{"critical":%s,"high":%s,"medium":%s,"low":%s,"items":[' "${c}" "${h}" "${m}" "${l}"
  while IFS=$'\t' read -r sev kind id subject version fix; do
    [[ -n "${sev}" ]] || continue
    if [[ "${first}" -eq 0 ]]; then
      printf ','
    fi
    first=0
    printf '{"severity":"%s","kind":"%s","id":"%s","subject":"%s","version":"%s","fix":"%s"}' \
      "$(hm_vuln_json_escape "${sev}")" \
      "$(hm_vuln_json_escape "${kind}")" \
      "$(hm_vuln_json_escape "${id}")" \
      "$(hm_vuln_json_escape "${subject}")" \
      "$(hm_vuln_json_escape "${version}")" \
      "$(hm_vuln_json_escape "${fix}")"
  done < "${HM_VULN_FINDINGS}"
  printf ']}\n'
}

hm_vuln_run() {
  local which="$1" json="$2"
  HM_VULN_JSON="${json}"
  hm_vuln_reset
  case "${which}" in
    os) hm_vuln_os ;;
    wp) hm_vuln_wp ;;
    eol) hm_vuln_eol ;;
    *)
      hm_vuln_os
      hm_vuln_wp
      hm_vuln_eol
      ;;
  esac
  if [[ "${json}" -eq 1 ]]; then
    hm_vuln_print_json
  else
    hm_vuln_print_text
  fi
  rm -f "${HM_VULN_FINDINGS}"
  HM_VULN_FINDINGS=""
}

cmd_vuln() {
  local sub="" json=0 domain="" a
  HM_VULN_WP_ONLY=""
  for a in "$@"; do
    case "${a}" in
      --json) json=1 ;;
      --all) domain="--all" ;;
      os|wp|eol|summary) sub="${a}" ;;
      help|-h|--help) hm_help_topic vuln; return 0 ;;
      -*)
        hm_err "Nieznany argument: ${a}"
        return 1
        ;;
      *)
        if [[ -z "${sub}" ]]; then
          sub="${a}"
        else
          domain="${a}"
        fi
        ;;
    esac
  done
  if [[ -n "${domain}" ]]; then
    HM_VULN_WP_ONLY="${domain}"
  fi
  case "${sub}" in
    ""|summary) hm_vuln_run all "${json}" ;;
    os|wp|eol) hm_vuln_run "${sub}" "${json}" ;;
    *)
      hm_err "Nieznana podkomenda: ${sub}. Zobacz: vuln help"
      return 1
      ;;
  esac
}

_hm_cmd_register vuln cmd_vuln 0
