#!/usr/bin/env bash
# mail — diagnostyka poczty (kolejka, logi, DKIM/SPF/DMARC, DNSBL)


_hm_cmd_help mail <<'EOF'
Użycie:
  mail queue                              Kolejka Postfix (agregacja nadawca/domena/błąd)
  mail queue flush [--yes]
  mail queue delete <queue-id> [--yes]
  mail queue delete --from user@domena [--yes]
  mail log [N] [--domain d] [--bounced] [--follow]
  mail check <domena>                    MX, SPF, DKIM, DMARC, PTR/HELO, TLS, porty
  mail dkim <domena> [generate] [--yes]
  mail blacklist [IPv4]                  DNSBL (spamhaus, spamcop, barracuda, …)

Bez Postfix/opendkim/dig: WARN zamiast twardego błędu (poza mutate delete/generate).
EOF

_HM_MAIL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=diag.sh
source "${_HM_MAIL_DIR}/diag.sh"

cmd_mail() {
  local sub="${1:-}"
  shift || true
  case "${sub}" in
    queue|q|mailq)
      hm_mail_queue_cmd "$@"
      ;;
    log|logs)
      hm_mail_log_cmd "$@"
      ;;
    check|diag|diagnose)
      hm_mail_check_cmd "$@"
      ;;
    dkim)
      hm_mail_dkim_cmd "$@"
      ;;
    blacklist|dnsbl|rbl)
      hm_mail_blacklist_cmd "$@"
      ;;
    help|-h|--help|"")
      hm_help_topic mail
      ;;
    *)
      hm_err "Nieznane: mail ${sub}.  help: mail help"
      return 1
      ;;
  esac
}

_hm_cmd_register mail cmd_mail 0
