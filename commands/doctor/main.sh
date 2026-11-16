#!/usr/bin/env bash
# Moduł: doctor — autodiagnoza instalacji hmtools (tylko raport, bez zmian).

_hm_cmd_help doctor <<'EOF'
Użycie:
  doctor [--json]

Raport diagnostyczny instalacji hmtools: wersja, narzędzia, uprawnienia,
locale, TMP, symlinki. Nie zmienia systemu — tylko status i podpowiedzi.
EOF

hm_doctor_json_escape() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "${s}"
}

hm_doctor_check_tool() {
  local name="$1"
  if command -v "${name}" >/dev/null 2>&1; then
    printf 'ok'
  else
    printf 'missing'
  fi
}

hm_doctor_perm_ok() {
  local path="$1" want="$2" mode
  [[ -e "${path}" ]] || {
    printf 'missing'
    return 0
  }
  mode="$(stat -c '%a' "${path}" 2>/dev/null || stat -f '%OLp' "${path}" 2>/dev/null || echo '?')"
  mode="${mode##0}"
  [[ "${mode}" == "${want}" || "${mode}" == "0${want}" ]] && printf 'ok' || printf 'bad:%s' "${mode}"
}

hm_doctor_owner_root() {
  local path="$1" uid
  [[ -e "${path}" ]] || {
    printf 'missing'
    return 0
  }
  uid="$(stat -c '%u' "${path}" 2>/dev/null || stat -f '%u' "${path}" 2>/dev/null || echo '?')"
  [[ "${uid}" == "0" ]] && printf 'ok' || printf 'uid:%s' "${uid}"
}

cmd_doctor() {
  local json=0 a
  for a in "$@"; do
    case "${a}" in
      --json) json=1 ;;
      help|-h|--help)
        hm_help_topic doctor 2>/dev/null || true
        return 0
        ;;
      -*)
        hm_err "Nieznana flaga: ${a}"
        return 1
        ;;
    esac
  done

  local root="${HMTOOLS_ROOT:-}"
  local conf="${HMTOOLS_CONF:-${root}/config/hmtools.conf}"
  local logs="${HMTOOLS_LOG_DIR:-${root}/logs}"
  local tmp_dir="${TMP_DIR:-${TMPDIR:-/tmp}}"
  local cur latest
  cur="$(hm_installed_version 2>/dev/null || true)"
  [[ -n "${cur}" ]] || cur="?"
  latest="$(hm_latest_remote_version 2>/dev/null || true)"

  local -a tools=(rclone curl python3 timeout stdbuf)
  local -A tool_st=()
  local t
  for t in "${tools[@]}"; do
    tool_st["${t}"]="$(hm_doctor_check_tool "${t}")"
  done

  local symlink_st="missing"
  if [[ -L /usr/bin/hmtools ]]; then
    local target
    target="$(readlink -f /usr/bin/hmtools 2>/dev/null || readlink /usr/bin/hmtools 2>/dev/null || true)"
    if [[ -n "${target}" && -x "${target}" ]]; then
      symlink_st="ok"
    else
      symlink_st="broken"
    fi
  elif [[ -x /usr/bin/hmtools ]]; then
    symlink_st="ok"
  fi

  local conf_mode conf_owner logs_mode root_mode locale_st tmp_free tmp_st
  conf_mode="$(hm_doctor_perm_ok "${conf}" "600")"
  conf_owner="$(hm_doctor_owner_root "${conf}")"
  logs_mode="$(hm_doctor_perm_ok "${logs}" "700")"
  if [[ -d "${logs}" ]]; then
    local f badf=0
    while IFS= read -r f; do
      [[ -f "${f}" ]] || continue
      local fm
      fm="$(hm_doctor_perm_ok "${f}" "600")"
      [[ "${fm}" == "ok" ]] || badf=1
    done < <(find "${logs}" -maxdepth 1 -type f 2>/dev/null | head -20)
    [[ "${badf}" -eq 0 ]] || logs_mode="files-not-0600"
  fi
  root_mode="ok"
  if [[ -d "${root}" ]]; then
    [[ -r "${root}" && -x "${root}" ]] || root_mode="bad"
  else
    root_mode="missing"
  fi

  locale_st="ok"
  if ! locale 2>/dev/null | grep -qi 'UTF-8\|utf8'; then
    locale_st="warn-no-utf8"
  fi

  tmp_free="$(df -Pk "${tmp_dir}" 2>/dev/null | awk 'NR==2{print $4}')"
  tmp_st="ok"
  if [[ "${tmp_free}" =~ ^[0-9]+$ ]]; then
    # < 50 MiB
    if [[ "${tmp_free}" -lt 51200 ]]; then
      tmp_st="low:${tmp_free}k"
    fi
  else
    tmp_st="unknown"
  fi

  local ver_st="ok"
  if [[ -n "${latest}" && -n "${cur}" && "${cur}" != "?" ]] && declare -F hm_version_is_newer >/dev/null 2>&1; then
    if hm_version_is_newer "${cur}" "${latest}"; then
      ver_st="outdated"
    fi
  elif [[ -z "${latest}" ]]; then
    ver_st="unknown-remote"
  fi

  local rc=0
  for t in "${tools[@]}"; do
    [[ "${tool_st[${t}]}" == "ok" ]] || rc=1
  done
  [[ "${conf_mode}" == "ok" || "${conf_mode}" == "missing" ]] || rc=1
  [[ "${symlink_st}" == "ok" || "${symlink_st}" == "missing" ]] || rc=1
  [[ "${tmp_st}" == "ok" || "${tmp_st}" == "unknown" ]] || rc=1

  if [[ "${json}" -eq 1 ]]; then
    printf '{'
    printf '"version":"%s","latest":"%s","version_status":"%s",' \
      "$(hm_doctor_json_escape "${cur}")" \
      "$(hm_doctor_json_escape "${latest}")" \
      "$(hm_doctor_json_escape "${ver_st}")"
    printf '"tools":{'
    local first=1
    for t in "${tools[@]}"; do
      [[ "${first}" -eq 1 ]] || printf ','
      first=0
      printf '"%s":"%s"' "${t}" "$(hm_doctor_json_escape "${tool_st[${t}]}")"
    done
    printf '},'
    printf '"hmtools_root":"%s","root_status":"%s",' \
      "$(hm_doctor_json_escape "${root}")" "$(hm_doctor_json_escape "${root_mode}")"
    printf '"conf":"%s","conf_mode":"%s","conf_owner":"%s",' \
      "$(hm_doctor_json_escape "${conf}")" "$(hm_doctor_json_escape "${conf_mode}")" \
      "$(hm_doctor_json_escape "${conf_owner}")"
    printf '"logs":"%s","logs_mode":"%s",' \
      "$(hm_doctor_json_escape "${logs}")" "$(hm_doctor_json_escape "${logs_mode}")"
    printf '"symlink_usr_bin":"%s","locale":"%s","tmp":"%s","tmp_free_kb":"%s"' \
      "$(hm_doctor_json_escape "${symlink_st}")" \
      "$(hm_doctor_json_escape "${locale_st}")" \
      "$(hm_doctor_json_escape "${tmp_st}")" \
      "$(hm_doctor_json_escape "${tmp_free:-}")"
    printf '}\n'
    return "${rc}"
  fi

  echo "${C_BOLD}hmtools doctor${C_RESET}"
  printf '  wersja     : %s' "${cur}"
  [[ -n "${latest}" ]] && printf ' (najnowsza: %s)' "${latest}"
  printf ' [%s]\n' "${ver_st}"
  printf '  root       : %s [%s]\n' "${root:-?}" "${root_mode}"
  printf '  conf       : %s [mode=%s owner=%s]\n' "${conf}" "${conf_mode}" "${conf_owner}"
  printf '  logs       : %s [%s]\n' "${logs}" "${logs_mode}"
  printf '  /usr/bin/hmtools symlink: %s\n' "${symlink_st}"
  printf '  locale     : %s\n' "${locale_st}"
  printf '  TMP (%s)   : %s\n' "${tmp_dir}" "${tmp_st}"
  echo "  narzędzia:"
  for t in "${tools[@]}"; do
    printf '    %-8s %s\n' "${t}" "${tool_st[${t}]}"
  done
  if [[ "${rc}" -ne 0 ]]; then
    hm_warn "Doctor: są problemy — zobacz statusy powyżej (podpowiedź: zainstaluj brakujące narzędzia / chmod 0600 conf)."
  else
    hm_ok "Doctor: brak blokujących problemów."
  fi
  return "${rc}"
}

_hm_cmd_register doctor cmd_doctor 1
