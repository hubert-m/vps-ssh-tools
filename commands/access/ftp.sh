#!/usr/bin/env bash
# access — FTP: detekcja daemona + list/add/passwd/delete

hm_access_ftp_detect() {
  # stdout: cyberpanel | pure-ftpd | vsftpd | none
  if [[ "${PANEL:-}" == "cyberpanel" ]] || hm_have_cmd cyberpanel; then
    if hm_access_cp_ftp_table_ok 2>/dev/null || hm_have_cmd cyberpanel; then
      printf 'cyberpanel'
      return 0
    fi
  fi
  if hm_have_cmd pure-pw || pgrep -x pure-ftpd >/dev/null 2>&1 \
    || systemctl is-active --quiet pure-ftpd 2>/dev/null \
    || systemctl is-active --quiet pure-ftpd-mysql 2>/dev/null; then
    printf 'pure-ftpd'
    return 0
  fi
  if hm_have_cmd vsftpd || systemctl is-active --quiet vsftpd 2>/dev/null; then
    printf 'vsftpd'
    return 0
  fi
  printf 'none'
}

hm_access_ftp_backend_ok() {
  local b
  b="$(hm_access_ftp_detect)"
  case "${b}" in
    cyberpanel|pure-ftpd) return 0 ;;
    vsftpd)
      hm_err "Wykryto vsftpd — v1 obsługuje konta FTP przez CyberPanel / Pure-FTPd (pure-pw)."
      hm_info "Zainstaluj/skonfiguruj Pure-FTPd lub użyj panelu CyberPanel."
      return 1
      ;;
    *)
      hm_err "Brak obsługiwanego serwera FTP (CyberPanel Pure-FTPd / pure-pw)."
      hm_info "Na VPS z CyberPanel FTP jest zwykle już dostępne."
      return 1
      ;;
  esac
}

hm_access_is_valid_ftp_user() {
  local u="${1:-}"
  # CyberPanel: często user = nazwa bez domeny lub user@domain — dopuszczamy [a-z0-9._-]
  [[ "${u}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._@-]{0,62}$ ]]
}

hm_access_ftp_list() {
  local domain backend
  domain="$(hm_access_resolve_site "${1:-}")" || return 1
  backend="$(hm_access_ftp_detect)"

  echo "${C_BOLD}FTP — ${domain}${C_RESET} ${C_DIM}(backend: ${backend})${C_RESET}"
  echo

  case "${backend}" in
    cyberpanel)
      local line user path any=0
      while IFS=$'\t' read -r user path; do
        [[ -n "${user}" ]] || continue
        any=1
        printf '  %-28s %s\n' "${user}" "${path:--}"
      done < <(hm_access_cp_ftp_list "${domain}")
      if [[ "${any}" -eq 0 ]]; then
        echo "  (brak kont FTP w CyberPanel dla tej domeny)"
      fi
      ;;
    pure-ftpd)
      if ! hm_have_cmd pure-pw; then
        hm_warn "pure-pw niedostępne — nie mogę wylistować wirtualnych kont."
        return 0
      fi
      # filtr heurystyczny: wpisy zawierające domenę lub site root
      local root="${HM_SITE_ROOT:-}"
      echo "  ${C_DIM}pure-pw list (filtr: ${domain}${root:+ / ${root}})${C_RESET}"
      pure-pw list 2>/dev/null | awk -v d="${domain}" -v r="${root}" '
        BEGIN { n=0 }
        $0 ~ d || (r != "" && index($0, r) > 0) { print "  " $0; n++ }
        END { if (n==0) print "  (brak dopasowanych wpisów pure-pw)" }
      '
      ;;
    *)
      hm_access_ftp_backend_ok
      return $?
      ;;
  esac
}

hm_access_ftp_add() {
  local domain_arg="" ftp_user="" path="/"
  local a pos=0
  for a in "$@"; do
    pos=$((pos + 1))
    if [[ "${pos}" -eq 1 ]] && [[ "${a}" == *"/"* || "${a}" =~ \.[a-zA-Z]{2,} ]]; then
      # może być domena
      if [[ -z "${domain_arg}" ]] && { [[ -n "${HM_SITE_DOMAIN:-}" && "${a}" == "${HM_SITE_DOMAIN}" ]] || hm_find_site_by_arg "${a}" >/dev/null 2>&1; }; then
        domain_arg="${a}"
        continue
      fi
    fi
    if [[ -z "${ftp_user}" ]]; then
      ftp_user="${a}"
    elif [[ "${a}" == /* || "${a}" == "." ]]; then
      path="${a}"
    fi
  done

  local domain backend pass home_path
  domain="$(hm_access_resolve_site "${domain_arg}")" || return 1
  hm_access_require_site_user "${domain}" >/dev/null || return 1
  backend="$(hm_access_ftp_detect)"
  hm_access_ftp_backend_ok || return 1

  [[ -n "${ftp_user}" ]] || {
    hm_err "Użycie: access ftp add [domena] <ftp_user> [ścieżka=/]"
    return 1
  }
  hm_access_is_valid_ftp_user "${ftp_user}" || {
    hm_err "Nieprawidłowa nazwa użytkownika FTP: ${ftp_user}"
    return 1
  }

  home_path="${HM_SITE_ROOT:-${HM_SITE_DOCROOT:-}}"
  [[ -n "${home_path}" && -d "${home_path}" ]] || {
    hm_err "Brak HM_SITE_ROOT/docroot — nie ustalę katalogu chroot."
    return 1
  }
  # path w CP to względna od home strony (np. / lub /public_html)
  [[ "${path}" == "." ]] && path="/"

  pass="$(hm_gen_password)"
  [[ -n "${pass}" && ${#pass} -ge 12 ]] || { hm_err "Nie udało się wygenerować hasła."; return 1; }

  if ! hm_confirm_plan "access ftp add — ${domain}" \
    "Hasło FTP zostanie wypisane po utworzeniu." \
    "Backend: ${backend}" \
    "Utworzenie konta FTP '${ftp_user}' (path=${path})" \
    "Katalog strony (chroot/home): ${home_path}"; then
    return 1
  fi

  case "${backend}" in
    cyberpanel)
      if hm_access_cp_ftp_exists "${ftp_user}"; then
        hm_err "Konto FTP już istnieje: ${ftp_user}"
        return 1
      fi
      hm_access_cp_ftp_create "${domain}" "${ftp_user}" "${pass}" "${path}" || {
        hm_err "Nie udało się utworzyć konta FTP."
        return 1
      }
      ;;
    pure-ftpd)
      if ! hm_have_cmd pure-pw; then
        hm_err "Brak pure-pw."
        return 1
      fi
      local pdb="/etc/pure-ftpd/pureftpd.passwd"
      [[ -f "${pdb}" ]] || pdb="/etc/pureftpd.passwd"
      # pure-pw useradd USER -u UID -g GID -d DIR
      local uid gid
      uid="$(id -u "${HM_SITE_USER}")"
      gid="$(id -g "${HM_SITE_USER}")"
      if ! printf '%s\n%s\n' "${pass}" "${pass}" | pure-pw useradd "${ftp_user}" \
        -u "${uid}" -g "${gid}" -d "${home_path}" -m; then
        hm_err "pure-pw useradd nieudany."
        return 1
      fi
      ;;
  esac

  hm_ok "Konto FTP utworzone: ${ftp_user}"
  echo
  echo "  ${C_BOLD}FTP user:${C_RESET} ${ftp_user}"
  echo "  ${C_BOLD}Hasło:${C_RESET}    ${pass}"
  echo "  ${C_BOLD}Path:${C_RESET}     ${path} (root strony: ${home_path})"
  echo "  ${C_DIM}Zapisz hasło — nie będzie ponownie pokazane.${C_RESET}"
}

hm_access_ftp_passwd() {
  local domain_arg="" ftp_user=""
  if [[ -n "${2:-}" ]]; then
    domain_arg="${1:-}"
    ftp_user="${2:-}"
  else
    ftp_user="${1:-}"
  fi

  local domain backend pass
  domain="$(hm_access_resolve_site "${domain_arg}")" || return 1
  hm_access_ftp_backend_ok || return 1
  backend="$(hm_access_ftp_detect)"

  [[ -n "${ftp_user}" ]] || {
    hm_err "Użycie: access ftp passwd [domena] <ftp_user>"
    return 1
  }

  case "${backend}" in
    cyberpanel)
      hm_access_cp_ftp_belongs_to_domain "${ftp_user}" "${domain}" || {
        hm_err "Konto FTP '${ftp_user}' nie należy do ${domain} (lub nie istnieje)."
        return 1
      }
      ;;
    pure-ftpd)
      pure-pw show "${ftp_user}" >/dev/null 2>&1 || {
        hm_err "Brak konta pure-pw: ${ftp_user}"
        return 1
      }
      ;;
  esac

  pass="$(hm_gen_password)"
  [[ -n "${pass}" && ${#pass} -ge 12 ]] || { hm_err "Nie udało się wygenerować hasła."; return 1; }

  if ! hm_confirm_plan "access ftp passwd — ${ftp_user}" \
    "Hasło FTP zostanie zmienione i wypisane na ekranie." \
    "Zmiana hasła konta FTP '${ftp_user}' (domena ${domain})"; then
    return 1
  fi

  case "${backend}" in
    cyberpanel)
      hm_access_cp_ftp_set_password "${ftp_user}" "${pass}" || {
        hm_err "Zmiana hasła FTP nieudana."
        return 1
      }
      ;;
    pure-ftpd)
      if ! printf '%s\n%s\n' "${pass}" "${pass}" | pure-pw passwd "${ftp_user}" -m; then
        hm_err "pure-pw passwd nieudany."
        return 1
      fi
      ;;
  esac

  hm_ok "Hasło FTP ustawione: ${ftp_user}"
  echo
  echo "  ${C_BOLD}FTP user:${C_RESET} ${ftp_user}"
  echo "  ${C_BOLD}Hasło:${C_RESET}    ${pass}"
}

hm_access_ftp_delete() {
  local domain_arg="" ftp_user=""
  if [[ -n "${2:-}" ]]; then
    domain_arg="${1:-}"
    ftp_user="${2:-}"
  else
    ftp_user="${1:-}"
  fi

  local domain backend
  domain="$(hm_access_resolve_site "${domain_arg}")" || return 1
  hm_access_ftp_backend_ok || return 1
  backend="$(hm_access_ftp_detect)"

  [[ -n "${ftp_user}" ]] || {
    hm_err "Użycie: access ftp delete [domena] <ftp_user>"
    return 1
  }

  case "${backend}" in
    cyberpanel)
      hm_access_cp_ftp_belongs_to_domain "${ftp_user}" "${domain}" || {
        hm_err "Konto FTP '${ftp_user}' nie należy do ${domain} (lub nie istnieje)."
        return 1
      }
      ;;
    pure-ftpd)
      pure-pw show "${ftp_user}" >/dev/null 2>&1 || {
        hm_err "Brak konta pure-pw: ${ftp_user}"
        return 1
      }
      ;;
  esac

  if ! hm_confirm_plan_critical "${domain}" \
    "access ftp delete — ${ftp_user}" \
    "Konto FTP zostanie trwale usunięte." \
    "Usunięcie konta FTP '${ftp_user}' (backend ${backend})"; then
    return 1
  fi

  case "${backend}" in
    cyberpanel)
      hm_access_cp_ftp_delete "${ftp_user}" || {
        hm_err "Usuwanie FTP nieudane."
        return 1
      }
      ;;
    pure-ftpd)
      pure-pw userdel "${ftp_user}" -m || {
        hm_err "pure-pw userdel nieudany."
        return 1
      }
      ;;
  esac
  hm_ok "Usunięto konto FTP: ${ftp_user}"
}

hm_access_ftp_dispatch() {
  local sub="${1:-list}"
  shift || true
  case "${sub}" in
    list|ls|"")
      hm_access_ftp_list "$@"
      ;;
    add|create|new)
      hm_access_ftp_add "$@"
      ;;
    passwd|password|pass)
      hm_access_ftp_passwd "$@"
      ;;
    delete|del|rm|remove)
      hm_access_ftp_delete "$@"
      ;;
    help|-h|--help)
      hm_help_topic access
      ;;
    *)
      hm_err "Nieznane: access ftp ${sub}. access help"
      return 1
      ;;
  esac
}
