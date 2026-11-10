#!/usr/bin/env bash
# Silnik kreatora: kroki, wstecz, anulowanie, podsumowanie, dry-run, tryb bez TTY.

if [[ -n "${HMTOOLS_WIZARD_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_WIZARD_LOADED=1

hm_wiz_reset() {
  HM_WIZ_ORDER=()
  HM_WIZ_VISIBLE=()
  HM_WIZ_PLAN=()
  HM_WIZ_NAV=""
  HM_WIZ_LINE=""
  HM_WIZ_JUMP=0
  HM_WIZ_APPLY=""
  declare -gA HM_WIZ=()
  declare -gA HM_WIZ_TITLE=()
  declare -gA HM_WIZ_ASK=()
  declare -gA HM_WIZ_VALID=()
  declare -gA HM_WIZ_WHEN=()
  declare -gA HM_WIZ_FLAG=()
  declare -gA HM_WIZ_HELP=()
  declare -gA HM_WIZ_SECRET=()
  declare -gA HM_WIZ_REQ=()
  declare -gA HM_WIZ_OPTIONS=()
}

hm_wiz_step() {
  local id="$1" title="$2" ask="$3" valid="${4:-}" when="${5:-}"
  HM_WIZ_ORDER+=("${id}")
  HM_WIZ_TITLE["${id}"]="${title}"
  HM_WIZ_ASK["${id}"]="${ask}"
  HM_WIZ_VALID["${id}"]="${valid}"
  HM_WIZ_WHEN["${id}"]="${when}"
  HM_WIZ_FLAG["${id}"]="--${id}"
  HM_WIZ_REQ["${id}"]=1
}

hm_wiz_flag() {
  local id="$1" flag="$2" req="${3:-1}"
  HM_WIZ_FLAG["${id}"]="${flag}"
  HM_WIZ_REQ["${id}"]="${req}"
}

hm_wiz_help() { HM_WIZ_HELP["${1}"]="${2}"; }
hm_wiz_options() { HM_WIZ_OPTIONS["${1}"]="${2}"; }
hm_wiz_set() { HM_WIZ["${1}"]="${2}"; }
hm_wiz_mark_secret() { HM_WIZ_SECRET["${1}"]=1; }

hm_wiz_is_batch() {
  [[ "${HM_WIZ_FORCE_PROMPT:-}" == "1" ]] && return 1
  [[ "${HM_WIZ_NONINTERACTIVE:-}" == "1" || "${HM_WIZ_YES:-}" == "1" ]] && return 0
  [[ "${HMTOOLS_TEST_NO_TTY:-}" == "1" ]] && return 0
  [[ -t 0 ]] && return 1
  return 0
}

hm_wiz_visible_ids() {
  local id fn
  HM_WIZ_VISIBLE=()
  [[ "${#HM_WIZ_ORDER[@]}" -eq 0 ]] && return 0
  for id in "${HM_WIZ_ORDER[@]}"; do
    fn="${HM_WIZ_WHEN[${id}]:-}"
    if [[ -z "${fn}" ]] || "${fn}"; then
      HM_WIZ_VISIBLE+=("${id}")
    fi
  done
}

hm_wiz_cleanup() {
  local dir="${HM_WIZ_TMP:-}"
  if [[ -n "${dir}" && -d "${dir}" ]]; then
    rm -rf "${dir}"
  fi
  HM_WIZ_TMP=""
  trap - INT
}

hm_wiz_cancel() {
  hm_wiz_cleanup
  HM_WIZ_CANCELLED=1
}

hm_wiz_begin() {
  local base="${HM_WIZ_TMP_DIR:-/var/lib/hmtools/tmp}"
  HM_WIZ_TMP="${base}/wiz-$$"
  mkdir -p "${HM_WIZ_TMP}"
  trap 'hm_wiz_cancel; exit 130' INT
}

hm_wiz_progress() {
  local n="$1" total="$2" title="$3"
  if declare -F hm_status_line >/dev/null 2>&1; then
    hm_status_line "Krok ${n}/${total} — ${title}" || true
  fi
  printf 'Krok %s/%s — %s\n' "${n}" "${total}" "${title}"
}

hm_wiz_read() {
  local line=""
  if ! IFS= read -r line; then
    HM_WIZ_NAV=cancel
    return 0
  fi
  case "${line}" in
    "<"|wstecz) HM_WIZ_NAV=back ;;
    "?") HM_WIZ_NAV=help ;;
    "!") HM_WIZ_NAV=state ;;
    q|Q) HM_WIZ_NAV=cancel ;;
    *) HM_WIZ_NAV=value; HM_WIZ_LINE="${line}" ;;
  esac
}

hm_wiz_show_state() {
  local id show
  for id in "${HM_WIZ_VISIBLE[@]}"; do
    show="${HM_WIZ[${id}]:-}"
    [[ "${HM_WIZ_SECRET[${id}]:-}" == "1" ]] && show="****"
    printf '  %s = %s\n' "${id}" "${show}"
  done
}

hm_wiz_input_text() {
  local id="$1" label="$2" default="${3:-}"
  printf '%s [%s]: ' "${label}" "${default}"
  hm_wiz_read
  [[ "${HM_WIZ_NAV}" == "value" ]] || return 0
  [[ -z "${HM_WIZ_LINE}" ]] && HM_WIZ_LINE="${default}"
  HM_WIZ["${id}"]="${HM_WIZ_LINE}"
}

hm_wiz_input_secret() {
  local id="$1" line=""
  printf '%s: ' "Sekret"
  if ! IFS= read -r -s line; then
    HM_WIZ_NAV=cancel
    return 0
  fi
  printf '\n'
  HM_WIZ_NAV=value
  HM_WIZ["${id}"]="${line}"
  HM_WIZ_SECRET["${id}"]=1
}

hm_wiz_option_list() {
  local id="$1" line label n=0 def=1 mark
  HM_WIZ_OPT_LABELS=()
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    n=$((n + 1))
    mark=" "
    label="${line}"
    if [[ "${line}" == \** ]]; then
      def="${n}"
      label="${line#\*}"
      mark="*"
    fi
    HM_WIZ_OPT_LABELS+=("${label}")
    if [[ "${mark}" == "*" ]]; then
      printf '  %s) %s *\n' "${n}" "${label}"
    else
      printf '  %s) %s\n' "${n}" "${label}"
    fi
  done <<< "${HM_WIZ_OPTIONS[${id}]:-}"
  HM_WIZ_OPT_DEFAULT="${def}"
  HM_WIZ_OPT_COUNT="${n}"
}

hm_wiz_input_choice() {
  local id="$1" pick
  hm_wiz_option_list "${id}"
  printf 'Wybór [%s]: ' "${HM_WIZ_OPT_DEFAULT}"
  hm_wiz_read
  [[ "${HM_WIZ_NAV}" == "value" ]] || return 0
  pick="${HM_WIZ_LINE:-${HM_WIZ_OPT_DEFAULT}}"
  [[ -z "${pick}" ]] && pick="${HM_WIZ_OPT_DEFAULT}"
  if [[ ! "${pick}" =~ ^[0-9]+$ ]] || [[ "${pick}" -lt 1 || "${pick}" -gt "${HM_WIZ_OPT_COUNT}" ]]; then
    HM_WIZ_NAV=invalid
    return 0
  fi
  HM_WIZ["${id}"]="${HM_WIZ_OPT_LABELS[$((pick - 1))]}"
}

hm_wiz_expand_picks() {
  local spec="$1" part start end i
  HM_WIZ_PICKS=()
  local IFS=','
  # shellcheck disable=SC2086
  for part in ${spec}; do
    if [[ "${part}" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      start="${BASH_REMATCH[1]}"
      end="${BASH_REMATCH[2]}"
      for ((i = start; i <= end; i++)); do
        HM_WIZ_PICKS+=("${i}")
      done
    elif [[ "${part}" =~ ^[0-9]+$ ]]; then
      HM_WIZ_PICKS+=("${part}")
    else
      return 1
    fi
  done
}

hm_wiz_input_multi() {
  local id="$1" pick joined="" 
  hm_wiz_option_list "${id}"
  printf 'Wybór (np. 1,3 lub 1-3): '
  hm_wiz_read
  [[ "${HM_WIZ_NAV}" == "value" ]] || return 0
  hm_wiz_expand_picks "${HM_WIZ_LINE}" || { HM_WIZ_NAV=invalid; return 0; }
  for pick in "${HM_WIZ_PICKS[@]}"; do
    if [[ "${pick}" -lt 1 || "${pick}" -gt "${HM_WIZ_OPT_COUNT}" ]]; then
      HM_WIZ_NAV=invalid
      return 0
    fi
    [[ -n "${joined}" ]] && joined+=","
    joined+="${HM_WIZ_OPT_LABELS[$((pick - 1))]}"
  done
  HM_WIZ["${id}"]="${joined}"
}

hm_wiz_input_yesno() {
  local id="$1" default="${2:-T}"
  printf '[%s/n]: ' "${default}"
  hm_wiz_read
  [[ "${HM_WIZ_NAV}" == "value" ]] || return 0
  local ans="${HM_WIZ_LINE:-${default}}"
  case "${ans}" in
    T|t|y|Y|yes|tak|"") HM_WIZ["${id}"]=tak ;;
    n|N|nie|no) HM_WIZ["${id}"]=nie ;;
    *) HM_WIZ_NAV=invalid ;;
  esac
}

hm_wiz_port_busy() {
  local port="$1"
  if [[ -n "${HM_WIZ_SS_FILE:-}" && -f "${HM_WIZ_SS_FILE}" ]]; then
    grep -q ":${port} " "${HM_WIZ_SS_FILE}"
    return $?
  fi
  if declare -F hm_have_cmd >/dev/null 2>&1 && hm_have_cmd ss; then
    ss -ltn | grep -q ":${port} "
    return $?
  fi
  return 1
}

hm_wiz_input_port() {
  local id="$1" port
  printf 'Port: '
  hm_wiz_read
  [[ "${HM_WIZ_NAV}" == "value" ]] || return 0
  port="${HM_WIZ_LINE}"
  if [[ ! "${port}" =~ ^[0-9]+$ ]] || [[ "${port}" -lt 1 || "${port}" -gt 65535 ]]; then
    HM_WIZ_NAV=invalid
    return 0
  fi
  if hm_wiz_port_busy "${port}"; then
    hm_err "Port ${port} jest zajęty."
    HM_WIZ_NAV=invalid
    return 0
  fi
  HM_WIZ["${id}"]="${port}"
}

hm_wiz_require() {
  local id="$1" flag val
  flag="${HM_WIZ_FLAG[${id}]:---${id}}"
  val="${HM_WIZ[${id}]:-}"
  if [[ -z "${val}" && "${HM_WIZ_REQ[${id}]:-1}" == "1" ]]; then
    hm_err "Brak ${flag} (wymagane w trybie nieinteraktywnym)"
    return 1
  fi
}

hm_wiz_summary() {
  local id show
  if declare -F hm_table_begin >/dev/null 2>&1; then
    hm_table_begin LL
    hm_table_row "Krok" "Wartość"
    for id in "${HM_WIZ_VISIBLE[@]}"; do
      show="${HM_WIZ[${id}]:-}"
      [[ "${HM_WIZ_SECRET[${id}]:-}" == "1" ]] && show="****"
      hm_table_row "${HM_WIZ_TITLE[${id}]}" "${show}"
    done
    hm_table_print
  fi
  local step
  if [[ "${#HM_WIZ_PLAN[@]}" -gt 0 ]]; then
    for step in "${HM_WIZ_PLAN[@]}"; do
      printf 'plan: %s\n' "${step}"
    done
  fi
  if [[ "${HM_WIZ_DRY:-}" == "1" ]]; then
    hm_info "dry-run: brak zmian w systemie"
    return 0
  fi
  if hm_wiz_is_batch; then
    if declare -F hm_confirm_plan >/dev/null 2>&1; then
      if [[ "${#HM_WIZ_PLAN[@]}" -gt 0 ]]; then
        hm_confirm_plan "Kreator" "" --yes "${HM_WIZ_PLAN[@]}" || return 1
      else
        hm_confirm_plan "Kreator" "" --yes "kroki kreatora" || return 1
      fi
    fi
    [[ -n "${HM_WIZ_APPLY:-}" ]] && "${HM_WIZ_APPLY}"
    return 0
  fi
  local reply=""
  printf 'Podsumowanie → [yes] wykonaj  [N] wróć do kroku  [q] anuluj\n'
  if ! IFS= read -r reply; then
    return 1
  fi
  case "${reply}" in
    yes|YES)
      [[ -n "${HM_WIZ_APPLY:-}" ]] && "${HM_WIZ_APPLY}"
      return 0
      ;;
    q|Q) return 1 ;;
    ''|*[!0-9]*) return 1 ;;
    *)
      if [[ "${reply}" -ge 1 && "${reply}" -le "${#HM_WIZ_VISIBLE[@]}" ]]; then
        HM_WIZ_JUMP=$((reply - 1))
        return 2
      fi
      return 1
      ;;
  esac
}

hm_wiz_serialize() {
  local dest="$1" id val first=1
  [[ "${#HM_WIZ_ORDER[@]}" -eq 0 ]] && { printf '{}\n' > "${dest}"; return 0; }
  {
    printf '{'
    for id in "${HM_WIZ_ORDER[@]}"; do
      [[ "${HM_WIZ_SECRET[${id}]:-}" == "1" ]] && continue
      [[ -z "${HM_WIZ[${id}]:-}" ]] && continue
      val="${HM_WIZ[${id}]}"
      val="${val//\\/\\\\}"
      val="${val//\"/\\\"}"
      [[ "${first}" -eq 0 ]] && printf ','
      first=0
      printf '"%s":"%s"' "${id}" "${val}"
    done
    printf '}\n'
  } > "${dest}"
}

hm_wiz_run() {
  local i=0 id ask valid src=0 n total
  HM_WIZ_CANCELLED=0
  hm_wiz_begin
  while true; do
    hm_wiz_visible_ids
    total="${#HM_WIZ_VISIBLE[@]}"
    if [[ "${total}" -eq 0 || "${i}" -ge "${total}" ]]; then
      hm_wiz_summary || src=$?
      if [[ "${src}" -eq 2 ]]; then
        i="${HM_WIZ_JUMP}"
        continue
      fi
      if [[ "${src}" -ne 0 ]]; then
        hm_wiz_cleanup
        hm_err "Anulowano."
        return 1
      fi
      if [[ -n "${HM_WIZ_STATE_FILE:-}" ]]; then
        hm_wiz_serialize "${HM_WIZ_STATE_FILE}"
      fi
      hm_wiz_cleanup
      return 0
    fi
    id="${HM_WIZ_VISIBLE[${i}]}"
    n=$((i + 1))
    hm_wiz_progress "${n}" "${total}" "${HM_WIZ_TITLE[${id}]}"
    if hm_wiz_is_batch; then
      hm_wiz_require "${id}" || { hm_wiz_cleanup; return 1; }
      i=$((i + 1))
      continue
    fi
    ask="${HM_WIZ_ASK[${id}]}"
    HM_WIZ_NAV=""
    "${ask}" "${id}" || { hm_wiz_cleanup; return 1; }
    case "${HM_WIZ_NAV}" in
      back)
        i=$((i - 1))
        [[ "${i}" -lt 0 ]] && i=0
        continue
        ;;
      cancel)
        hm_wiz_cleanup
        hm_err "Anulowano."
        return 1
        ;;
      help)
        printf '%s\n' "${HM_WIZ_HELP[${id}]:-Brak pomocy dla tego kroku.}"
        continue
        ;;
      state)
        hm_wiz_show_state
        continue
        ;;
      invalid)
        hm_err "Nieprawidłowa wartość."
        continue
        ;;
      value)
        valid="${HM_WIZ_VALID[${id}]:-}"
        if [[ -n "${valid}" ]] && ! "${valid}" "${id}"; then
          hm_err "Nieprawidłowa wartość."
          continue
        fi
        i=$((i + 1))
        ;;
      *)
        hm_err "Nieprawidłowa wartość."
        ;;
    esac
  done
}

hm_wiz_ask_domain() { hm_wiz_input_text "$1" "Domena" ""; }
hm_wiz_valid_domain() { [[ "${HM_WIZ[${1}]:-}" == *.* ]]; }
hm_wiz_ask_runtime() { hm_wiz_input_choice "$1"; }
hm_wiz_ask_php() { hm_wiz_input_choice "$1"; }
hm_wiz_when_php() { [[ "${HM_WIZ[runtime]:-}" == "PHP" ]]; }

hm_wiz_site_apply() {
  local runtime="node" php=""
  case "${HM_WIZ[runtime]:-}" in
    PHP) runtime="php"; php="${HM_WIZ[php]:-}" ;;
    Node.js) runtime="node" ;;
    *) runtime="static" ;;
  esac
  if [[ -n "${php}" ]]; then
    cmd_site_new "${HM_WIZ[domain]}" --runtime "${runtime}" --php "${php}" --db none --yes
  else
    cmd_site_new "${HM_WIZ[domain]}" --runtime "${runtime}" --db none --yes
  fi
}

hm_wiz_site_new() {
  hm_wiz_reset
  hm_wiz_step domain "Domena" hm_wiz_ask_domain hm_wiz_valid_domain
  hm_wiz_flag domain --domain 1
  hm_wiz_help domain "Podaj FQDN serwisu."
  hm_wiz_step runtime "Runtime" hm_wiz_ask_runtime
  hm_wiz_flag runtime --runtime 1
  hm_wiz_options runtime $'PHP\nNode.js\nPython\n.NET\nStatyczna/SPA\nDocker'
  hm_wiz_step php "Wersja PHP" hm_wiz_ask_php "" hm_wiz_when_php
  hm_wiz_flag php --php 1
  hm_wiz_options php $'*8.4\n8.3\n8.2'
  HM_WIZ_PLAN=("katalog serwisu" "runtime" "manifest")
  HM_WIZ_APPLY=hm_wiz_site_apply
  hm_wiz_run
}

hm_wiz_reset
