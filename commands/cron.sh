#!/usr/bin/env bash
# cron / crons — lista i edycja zadań cron

hm_cron_spool_dir() {
  if [[ -d /var/spool/cron/crontabs ]]; then
    echo /var/spool/cron/crontabs
  elif [[ -d /var/spool/cron ]]; then
    echo /var/spool/cron
  else
    echo ""
  fi
}

hm_cron_list_users_with_crontab() {
  local spool u
  spool="$(hm_cron_spool_dir)"
  [[ -n "${spool}" && -d "${spool}" ]] || return 0
  for u in "${spool}"/*; do
    [[ -f "${u}" ]] || continue
    basename "${u}"
  done
}

hm_cron_print_user() {
  local user="$1"
  local label="${2:-user:${user}}"
  local out
  if ! out="$(crontab -u "${user}" -l 2>/dev/null)"; then
    # pusty crontab lub brak
    if id "${user}" >/dev/null 2>&1; then
      echo "---- ${label} ----"
      echo "(brak wpisów w crontab)"
      echo
    fi
    return 0
  fi
  # odfiltruj komentarze-nagłówki samego crontaba? zostawiamy wszystko oprócz pustych-only
  echo "---- ${label} ----"
  if [[ -z "$(echo "${out}" | grep -vE '^[[:space:]]*(#|$)' || true)" ]]; then
    echo "(brak aktywnych wpisów — tylko komentarze / pusto)"
    echo "${out}" | sed 's/^/  /'
  else
    echo "${out}" | sed 's/^/  /'
  fi
  echo
}

hm_cron_print_file() {
  local file="$1"
  local label="${2:-${file}}"
  [[ -f "${file}" ]] || return 0
  echo "---- ${label} ----"
  # pomiń czysto puste
  if [[ ! -s "${file}" ]]; then
    echo "(pusty plik)"
    echo
    return 0
  fi
  sed 's/^/  /' "${file}"
  echo
}

hm_cron_list_system() {
  echo "${C_BOLD}Systemowe crony${C_RESET}"
  hm_cron_print_file /etc/crontab "/etc/crontab"
  local f
  if [[ -d /etc/cron.d ]]; then
    for f in /etc/cron.d/*; do
      [[ -f "${f}" ]] || continue
      case "$(basename "${f}")" in
        .gitignore|*.dpkg-*|*.rpmsave|*.rpmnew) continue ;;
      esac
      hm_cron_print_file "${f}" "${f}"
    done
  fi
  echo "${C_BOLD}Katalogi okresowe${C_RESET} (skrypty, nie crontab):"
  local d
  for d in /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly; do
    if [[ -d "${d}" ]]; then
      local count
      count="$(find "${d}" -maxdepth 1 -type f ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')"
      echo "  ${d}  (${count} plików)"
    fi
  done
  echo
}

hm_cron_list_all_users() {
  echo "${C_BOLD}Crontaby użytkowników${C_RESET}"
  local u any=0
  while IFS= read -r u; do
    [[ -n "${u}" ]] || continue
    # pomiń typowe systemowe bez sensu
    case "${u}" in
      ntp|systemd-network|systemd-resolve) continue ;;
    esac
    any=1
    hm_cron_print_user "${u}" "crontab -u ${u}"
  done < <(hm_cron_list_users_with_crontab)
  if [[ "${any}" -eq 0 ]]; then
    echo "(brak plików w spool cron użytkowników)"
    echo
  fi
}

hm_cron_list_site() {
  local domain="${1:-${HM_SITE_DOMAIN}}"
  [[ -n "${domain}" ]] || { hm_err "Brak domeny — use <domena> albo cron site <domena>."; return 1; }
  hm_set_site_context "${domain}"
  local user="${HM_SITE_USER}"
  echo "${C_BOLD}Cron — ${domain}${C_RESET}"
  echo "User: ${user:--}"
  echo "Site root: ${HM_SITE_ROOT:--}"
  echo
  if [[ -z "${user}" || "${user}" == "-" ]]; then
    hm_warn "Nie ustalono użytkownika strony — pokazuję wpisy zawierające domenę / ścieżkę."
  else
    hm_cron_print_user "${user}" "crontab użytkownika strony (${user})"
  fi

  # heurystyka: wpisy systemowe wspominające domenę lub docroot
  local needle="${domain}"
  local path_n="${HM_SITE_ROOT:-}"
  echo "${C_BOLD}Trafienia w /etc/crontab i /etc/cron.d (heurystyka)${C_RESET}"
  local hits=0
  local f
  for f in /etc/crontab /etc/cron.d/*; do
    [[ -f "${f}" ]] || continue
    if grep -F "${needle}" "${f}" >/dev/null 2>&1 \
      || { [[ -n "${path_n}" ]] && grep -F "${path_n}" "${f}" >/dev/null 2>&1; }; then
      hits=1
      echo "---- ${f} ----"
      if [[ -n "${path_n}" ]]; then
        grep -n -F -e "${needle}" -e "${path_n}" "${f}" 2>/dev/null | sed 's/^/  /' || true
      else
        grep -n -F -e "${needle}" "${f}" 2>/dev/null | sed 's/^/  /' || true
      fi
      echo
    fi
  done
  if [[ "${hits}" -eq 0 ]]; then
    echo "(brak dopasowań)"
    echo
  fi
}

hm_cron_edit_user() {
  local user="$1"
  [[ -n "${user}" ]] || { hm_err "Podaj użytkownika."; return 1; }
  if ! id "${user}" >/dev/null 2>&1; then
    hm_err "Użytkownik nie istnieje: ${user}"
    return 1
  fi
  export EDITOR="${EDITOR:-${VISUAL:-nano}}"
  if ! command -v "${EDITOR}" >/dev/null 2>&1; then
    if command -v nano >/dev/null 2>&1; then
      EDITOR=nano
    elif command -v vi >/dev/null 2>&1; then
      EDITOR=vi
    else
      hm_err "Brak edytora (ustaw EDITOR=nano|vi|vim)."
      return 1
    fi
  fi
  hm_info "Edycja crontab użytkownika ${user} (EDITOR=${EDITOR})"
  hm_info "Zapisz i zamknij edytor, aby zastosować zmiany."
  crontab -u "${user}" -e
}

cmd_cron() {
  local sub="${1:-list}"
  shift || true

  case "${sub}" in
    list|ls|"")
      if [[ -n "${HM_SITE_DOMAIN}" ]]; then
        hm_cron_list_site "${HM_SITE_DOMAIN}"
      else
        hm_cron_list_system
        hm_cron_list_all_users
      fi
      ;;
    all|global)
      hm_cron_list_system
      hm_cron_list_all_users
      ;;
    system)
      hm_cron_list_system
      ;;
    users)
      hm_cron_list_all_users
      ;;
    site)
      local domain="${1:-${HM_SITE_DOMAIN}}"
      [[ -n "${domain}" ]] || { hm_err "Użycie: cron site <domena>"; return 1; }
      if [[ -z "${HM_SITE_DOMAIN}" || "${HM_SITE_DOMAIN}" != "${domain}" ]]; then
        domain="$(hm_find_site_by_arg "${domain}")" || return 1
      fi
      hm_cron_list_site "${domain}"
      ;;
    user)
      local user="$1"
      [[ -n "${user}" ]] || { hm_err "Użycie: cron user <username>"; return 1; }
      hm_cron_print_user "${user}"
      ;;
    edit)
      local who="${1:-}"
      if [[ -z "${who}" ]]; then
        if [[ -n "${HM_SITE_DOMAIN}" && -n "${HM_SITE_USER}" ]]; then
          who="${HM_SITE_USER}"
        else
          hm_err "Użycie: cron edit <username>  (w kontekście strony: cron edit)"
          return 1
        fi
      fi
      # jeśli podano domenę zamiast usera
      if ! id "${who}" >/dev/null 2>&1; then
        local dom
        if dom="$(hm_find_site_by_arg "${who}" 2>/dev/null)"; then
          hm_set_site_context "${dom}"
          who="${HM_SITE_USER}"
        fi
      fi
      hm_cron_edit_user "${who}"
      ;;
    help|-h|--help)
      hm_help_topic cron
      ;;
    *)
      hm_err "Nieznane: cron ${sub}. Zobacz: help cron"
      return 1
      ;;
  esac
}

cmd_crons() {
  cmd_cron "$@"
}
