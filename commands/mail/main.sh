#!/usr/bin/env bash
# mail — skrzynki/przekierowania CyberPanel + diagnostyka (kolejka, DKIM, DNSBL)


_hm_cmd_help mail <<'EOF'
Użycie (globalnie):
  mail                               Domeny pocztowe + top skrzynek (rozmiar)
  mail queue | queue flush | queue delete …
  mail log [N] [--domain d] [--bounced] [--follow]
  mail check <domena>
  mail dkim <domena> [generate]
  mail blacklist [IPv4]
  mail spam status
  mail senders [--since 24h]
  mail quota [domena]
  mail dmarc report <plik>

Użycie (kontekst [domena]>):
  mail                               Skrzynki + rozmiar Maildir + forward/catchall
  mail add <local> [--password-gen] [--yes]
  mail passwd <local> [--yes]
  mail delete <local> [--keep-maildir|--purge] [--yes]
  mail forward list|add <src> <dst>|remove <src> <dst>
  mail catchall [set <email> | off]

Konta/hasła: wyłącznie cyberpanel CLI (hasło redagowane w applog).
Przekierowania/catch-all: e_forwardings / e_catchall + postfix reload.
EOF

_HM_MAIL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=diag.sh
source "${_HM_MAIL_DIR}/diag.sh"
# shellcheck source=accounts.sh
source "${_HM_MAIL_DIR}/accounts.sh"
# shellcheck source=forward.sh
source "${_HM_MAIL_DIR}/forward.sh"
# shellcheck source=spam.sh
source "${_HM_MAIL_DIR}/spam.sh"

cmd_mail() {
  local sub="${1:-}"
  shift || true

  case "${sub}" in
    queue|q|mailq)
      hm_mail_queue_cmd "$@"
      return $?
      ;;
    log|logs)
      hm_mail_log_cmd "$@"
      return $?
      ;;
    check|diag|diagnose)
      hm_mail_check_cmd "$@"
      return $?
      ;;
    dkim)
      hm_mail_dkim_cmd "$@"
      return $?
      ;;
    blacklist|dnsbl|rbl)
      hm_mail_blacklist_cmd "$@"
      return $?
      ;;
    spam)
      hm_mail_spam_cmd "$@"
      return $?
      ;;
    senders)
      hm_mail_senders "$@"
      return $?
      ;;
    quota)
      hm_mail_quota "$@"
      return $?
      ;;
    dmarc)
      hm_mail_dmarc_cmd "$@"
      return $?
      ;;
    help|-h|--help)
      hm_help_topic mail
      return 0
      ;;
  esac

  # Kontekst strony — konta / forward
  if [[ -n "${HM_SITE_DOMAIN:-}" ]]; then
    case "${sub}" in
      ""|list|ls|status|show)
        hm_mail_accounts_list "${HM_SITE_DOMAIN}"
        ;;
      add|create|new)
        hm_mail_account_add "$@"
        ;;
      passwd|password|pass)
        hm_mail_account_passwd "$@"
        ;;
      delete|del|rm|remove)
        hm_mail_account_delete "$@"
        ;;
      forward|fwd|forwards)
        hm_mail_forward_cmd "$@"
        ;;
      catchall|catch-all|catch)
        hm_mail_catchall_cmd "$@"
        ;;
      *)
        hm_err "Nieznane: mail ${sub}.  help: mail help"
        return 1
        ;;
    esac
    return $?
  fi

  # Globalnie bez sub → przegląd domen; nieznany sub → błąd
  case "${sub}" in
    "")
      hm_mail_accounts_global
      ;;
    *)
      hm_err "Nieznane: mail ${sub}.  W kontekście strony: add/passwd/delete/forward/catchall.  help: mail help"
      return 1
      ;;
  esac
}

_hm_cmd_register mail cmd_mail 0
_hm_cmd_register_site mail cmd_mail
