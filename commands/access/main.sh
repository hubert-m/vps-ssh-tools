#!/usr/bin/env bash
# Komenda: access — SSH (Unix) + FTP per strona


_hm_cmd_help access <<'EOF'
Użycie:
  access status [domena]     SSH shell/klucze + konta FTP (skrót)
  access ssh status [domena]
  access ssh passwd [domena]          Nowe hasło Unix (HM_SITE_USER)
  access ssh shell enable|disable [domena]
  access ssh keys list [domena]
  access ssh keys add [domena] <linia-klucza>
  access ssh keys remove [domena] <numer>
  access ftp list [domena]
  access ftp add [domena] <ftp_user> [/path]
  access ftp passwd [domena] <ftp_user>
  access ftp delete [domena] <ftp_user>

Zarządzanie dostępem do istniejącego użytkownika strony (HM_SITE_USER) oraz
kontami FTP (CyberPanel / Pure-FTPd). Bez zmiany globalnego sshd_config
(zob. security ssh — audyt).

W kontekście use <domena> argument domeny jest opcjonalny.
Operacje passwd / shell / keys remove / ftp delete wymagają potwierdzenia.
EOF

_HM_ACCESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ssh.sh
source "${_HM_ACCESS_DIR}/ssh.sh"
# shellcheck source=cyberpanel.sh
source "${_HM_ACCESS_DIR}/cyberpanel.sh"
# shellcheck source=ftp.sh
source "${_HM_ACCESS_DIR}/ftp.sh"

hm_access_status() {
  local domain rc=0
  hm_access_resolve_site "${1:-}" || return 1
  domain="${HM_SITE_DOMAIN}"
  hm_access_ssh_status || rc=$?
  echo
  hm_access_ftp_list || rc=$?
  return "${rc}"
}

cmd_access() {
  local sub="${1:-status}"
  shift || true
  hm_detect_all

  # resolve_site ustawia HM_SITE_* na czas komendy — nie zostawiaj use <domena> w REPL
  hm_site_context_push
  local rc=0
  case "${sub}" in
    status|stat|info|"")
      hm_access_status "$@" || rc=$?
      ;;
    ssh)
      hm_access_ssh_dispatch "$@" || rc=$?
      ;;
    ftp)
      hm_access_ftp_dispatch "$@" || rc=$?
      ;;
    help|-h|--help)
      hm_help_topic access || rc=$?
      ;;
    *)
      hm_err "Nieznane: ${sub}. access help"
      rc=1
      ;;
  esac
  hm_site_context_pop
  return "${rc}"
}

_hm_cmd_register access cmd_access 0
