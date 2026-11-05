#!/usr/bin/env bash
# mail diag — kolejka Postfix, logi, DKIM/SPF/DMARC, DNSBL, TLS

# --- helpers -----------------------------------------------------------------

hm_mail_have_postfix() {
  hm_have_cmd postqueue && hm_have_cmd postsuper
}

hm_mail_warn_no_postfix() {
  hm_warn "Brak postqueue/postsuper — zainstaluj Postfix (lub użyj panelu)."
}

hm_mail_public_ipv4() {
  local ip=""
  if hm_have_cmd dig; then
    ip="$(hm_run_timeout 5 dig +short -4 myip.opendns.com @resolver1.opendns.com 2>/dev/null | head -1 | tr -d '[:space:]')"
  fi
  if [[ -z "${ip}" ]] && hm_have_cmd curl; then
    ip="$(hm_run_timeout 5 curl -4 -fsS https://ifconfig.me/ip 2>/dev/null | tr -d '[:space:]')"
  fi
  if [[ -z "${ip}" ]] && hm_have_cmd curl; then
    ip="$(hm_run_timeout 5 curl -4 -fsS https://api.ipify.org 2>/dev/null | tr -d '[:space:]')"
  fi
  if [[ -z "${ip}" ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  printf '%s' "${ip}"
}

hm_mail_reverse_octets() {
  local ip="$1"
  local a b c d
  IFS=. read -r a b c d <<<"${ip}"
  printf '%s.%s.%s.%s' "${d}" "${c}" "${b}" "${a}"
}

hm_mail_dig_txt() {
  local name="$1"
  if ! hm_have_cmd dig; then
    return 1
  fi
  hm_run_timeout 8 dig +short TXT "${name}" 2>/dev/null | tr -d '"' | tr '\n' ' '
}

hm_mail_dig_mx() {
  local name="$1"
  hm_have_cmd dig || return 1
  hm_run_timeout 8 dig +short MX "${name}" 2>/dev/null
}

hm_mail_dig_ptr() {
  local ip="$1"
  hm_have_cmd dig || return 1
  hm_run_timeout 8 dig +short -x "${ip}" 2>/dev/null | head -1 | sed 's/\.$//'
}

hm_mail_helo_hostname() {
  if hm_have_cmd postconf; then
    postconf -h myhostname 2>/dev/null | head -1
  else
    hostname -f 2>/dev/null || hostname 2>/dev/null || true
  fi
}

hm_mail_opendkim_txt_file() {
  local domain="$1"
  local f
  for f in \
    "/etc/opendkim/keys/${domain}/default.txt" \
    "/etc/opendkim/keys/${domain}/default" \
    "/etc/dkimkeys/${domain}/default.txt"
  do
    [[ -f "${f}" ]] && { printf '%s' "${f}"; return 0; }
  done
  return 1
}

hm_mail_extract_p_from_txtfile() {
  # z pliku default.txt wyciągnij p=... (base64 klucza)
  local f="$1"
  [[ -f "${f}" ]] || return 1
  tr -d '\n\r" ' < "${f}" | sed -n 's/.*p=\([A-Za-z0-9+/=]*\).*/\1/p' | head -1
}

hm_mail_log_file() {
  local f
  if declare -F hm_logs_system_find_files >/dev/null 2>&1; then
    f="$(hm_logs_system_find_files mail 2>/dev/null | head -1 || true)"
    [[ -n "${f}" ]] && { printf '%s' "${f}"; return 0; }
  fi
  for f in /var/log/mail.log /var/log/maillog; do
    [[ -f "${f}" && -r "${f}" ]] && { printf '%s' "${f}"; return 0; }
  done
  return 1
}

# --- queue -------------------------------------------------------------------

hm_mail_queue_raw_json() {
  if postqueue -j >/dev/null 2>&1; then
    postqueue -j 2>/dev/null
    return 0
  fi
  return 1
}

# TSV: qid|sender|recipient|reason|size
hm_mail_queue_parse() {
  local line qid sender recip reason size
  if hm_mail_queue_raw_json >/dev/null 2>&1; then
    # JSON lines (Postfix ≥3.1) — bez jq: proste sed/awk
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ -n "${line}" ]] || continue
      qid="$(printf '%s' "${line}" | sed -n 's/.*"queue_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
      sender="$(printf '%s' "${line}" | sed -n 's/.*"sender"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
      size="$(printf '%s' "${line}" | sed -n 's/.*"message_size"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')"
      recip="$(printf '%s' "${line}" | sed -n 's/.*"address"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
      reason="$(printf '%s' "${line}" | sed -n 's/.*"delay_reason"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
      [[ -z "${reason}" ]] && reason="$(printf '%s' "${line}" | sed -n 's/.*"why"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
      [[ -n "${qid}" ]] || continue
      printf '%s\t%s\t%s\t%s\t%s\n' "${qid}" "${sender:-?}" "${recip:-?}" "${reason:--}" "${size:-0}"
    done < <(hm_mail_queue_raw_json)
    return 0
  fi
  # fallback postqueue -p
  # format: QID   size  date  sender
  #          recip
  local cur_qid="" cur_sender="" cur_size=""
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" =~ ^-+$ || "${line}" =~ ^Mail\ queue\ is\ empty || "${line}" =~ ^-- ]]; then
      continue
    fi
    if [[ "${line}" =~ ^[A-F0-9]+[!*\ ] ]]; then
      cur_qid="$(echo "${line}" | awk '{print $1}' | tr -d '!*')"
      cur_size="$(echo "${line}" | awk '{print $2}')"
      cur_sender="$(echo "${line}" | awk '{print $NF}')"
      continue
    fi
    if [[ -n "${cur_qid}" && "${line}" =~ ^[[:space:]] ]]; then
      recip="$(echo "${line}" | awk '{print $NF}')"
      reason="$(echo "${line}" | sed 's/^[[:space:]]*//;s/[[:space:]][^[:space:]]*$//')"
      printf '%s\t%s\t%s\t%s\t%s\n' "${cur_qid}" "${cur_sender}" "${recip}" "${reason:--}" "${cur_size:-0}"
    fi
  done < <(postqueue -p 2>/dev/null || true)
}

hm_mail_queue_cmd() {
  local sub="${1:-}"
  shift || true
  case "${sub}" in
    help|-h|--help)
      echo "Użycie: mail queue | mail queue flush | mail queue delete <id>|--from <email> [--yes]"
      return 0
      ;;
    flush)
      hm_mail_queue_flush "$@"
      return $?
      ;;
    delete|del|rm)
      hm_mail_queue_delete "$@"
      return $?
      ;;
    ""|status|show|list|ls)
      ;;
    *)
      hm_err "Użycie: mail queue [flush|delete …]"
      return 1
      ;;
  esac

  if ! hm_mail_have_postfix; then
    hm_mail_warn_no_postfix
    return 0
  fi

  local tmp n
  tmp="$(hm_mktemp .q)"
  hm_mail_queue_parse > "${tmp}" || true
  n="$(wc -l < "${tmp}" | tr -d ' ')"
  echo "${C_BOLD}Mail queue${C_RESET}  (${n} wpisów odbiorców)"
  if [[ "${n}" -eq 0 ]]; then
    hm_ok "Kolejka pusta."
    rm -f "${tmp}"
    return 0
  fi
  echo
  echo "${C_BOLD}Top nadawcy${C_RESET}"
  awk -F'\t' '{c[$2]++} END{for(s in c) printf "%6d  %s\n", c[s], s}' "${tmp}" | sort -nr | head -15
  echo
  echo "${C_BOLD}Top domeny odbiorców${C_RESET}"
  awk -F'\t' '{
    r=$3; sub(/^.*@/,"",r); c[r]++
  } END{for(d in c) printf "%6d  %s\n", c[d], d}' "${tmp}" | sort -nr | head -15
  echo
  echo "${C_BOLD}Top powody (delay/bounce)${C_RESET}"
  awk -F'\t' '{
    w=$4; if(length(w)>60) w=substr(w,1,57)"…"; c[w]++
  } END{for(x in c) printf "%6d  %s\n", c[x], x}' "${tmp}" | sort -nr | head -15
  echo
  echo "${C_BOLD}Próbka (max 20)${C_RESET}"
  printf '  %-12s %-28s %-28s %s\n' "QID" "FROM" "TO" "REASON"
  head -20 "${tmp}" | while IFS=$'\t' read -r q s r w sz; do
    printf '  %-12s %-28s %-28s %s\n' "${q}" "${s:0:28}" "${r:0:28}" "${w:0:40}"
  done
  rm -f "${tmp}"
}

hm_mail_queue_flush() {
  local yes=0
  [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && yes=1
  hm_mail_have_postfix || { hm_mail_warn_no_postfix; return 0; }
  local n
  n="$(hm_mail_queue_parse 2>/dev/null | wc -l | tr -d ' ')"
  local -a plan=("postqueue -f (flush / ponów dostarczenie, ~${n} pozycji)")
  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "mail queue flush" "Ponowi dostarczenie całej kolejki." --yes "${plan[@]}" || return 1
  else
    hm_confirm_plan "mail queue flush" "Ponowi dostarczenie całej kolejki." "${plan[@]}" || return 1
  fi
  postqueue -f && hm_ok "Flush zlecony."
}

hm_mail_queue_delete() {
  local yes=0 from="" qid="" a
  while [[ $# -gt 0 ]]; do
    a="$1"; shift || true
    case "${a}" in
      --from) from="${1:-}"; shift || true ;;
      --from=*) from="${a#--from=}" ;;
      --yes|-y) yes=1 ;;
      help|-h|--help)
        echo "Użycie: mail queue delete <queue-id> | mail queue delete --from user@domain [--yes]"
        return 0
        ;;
      -*) hm_err "Nieznana flaga: ${a}"; return 1 ;;
      *)
        if [[ -z "${qid}" ]]; then qid="${a}"
        else hm_err "Za dużo argumentów"; return 1
        fi
        ;;
    esac
  done

  hm_mail_have_postfix || { hm_mail_warn_no_postfix; return 0; }

  local tmp
  tmp="$(hm_mktemp .qdel)"
  hm_mail_queue_parse > "${tmp}" || true

  local -a ids=()
  local line q s r
  if [[ -n "${from}" ]]; then
    # exact match nadawcy (case-insensitive)
    local from_l
    from_l="$(printf '%s' "${from}" | tr '[:upper:]' '[:lower:]')"
    while IFS=$'\t' read -r q s r _ _; do
      [[ -n "${q}" ]] || continue
      if [[ "$(printf '%s' "${s}" | tr '[:upper:]' '[:lower:]')" == "${from_l}" ]]; then
        ids+=("${q}")
      fi
    done < "${tmp}"
  elif [[ -n "${qid}" ]]; then
    ids+=("${qid}")
  else
    hm_err "Użycie: mail queue delete <id> | --from <email>"
    rm -f "${tmp}"
    return 1
  fi
  rm -f "${tmp}"

  # uniq
  local -a uniq=() seen="|"
  local id
  for id in "${ids[@]}"; do
    [[ "${seen}" == *"|${id}|"* ]] && continue
    seen+="${id}|"
    uniq+=("${id}")
  done

  local n="${#uniq[@]}"
  [[ "${n}" -gt 0 ]] || { hm_info "Brak pasujących wiadomości."; return 0; }

  local -a plan=("Usunięcie ${n} wiadomości z kolejki (postsuper -d)")
  [[ -n "${from}" ]] && plan+=("Filtr nadawcy exact: ${from}")
  [[ -n "${qid}" && -z "${from}" ]] && plan+=("QID: ${qid}")

  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan_critical "mail-queue" "mail queue delete (${n})" \
      "Nieodwracalne usunięcie z kolejki Postfix." --yes "${plan[@]}" || return 1
  else
    hm_confirm_plan_critical "mail-queue" "mail queue delete (${n})" \
      "Nieodwracalne usunięcie z kolejki Postfix." "${plan[@]}" || return 1
  fi

  local ok=0 fail=0
  for id in "${uniq[@]}"; do
    if postsuper -d "${id}" >/dev/null 2>&1; then
      ok=$((ok + 1))
    else
      fail=$((fail + 1))
      hm_warn "Nie usunięto ${id}"
    fi
  done
  hm_ok "Usunięto ${ok}/${n}${fail:+ (fail=${fail})}."
}

# --- log ---------------------------------------------------------------------

hm_mail_log_cmd() {
  local n=50 domain="" bounced=0 follow=0 a
  while [[ $# -gt 0 ]]; do
    a="$1"; shift || true
    case "${a}" in
      --domain) domain="${1:-}"; shift || true ;;
      --domain=*) domain="${a#--domain=}" ;;
      --bounced|--bounce) bounced=1 ;;
      --follow|-f) follow=1 ;;
      help|-h|--help)
        echo "Użycie: mail log [N] [--domain d] [--bounced] [--follow]"
        return 0
        ;;
      -*)
        hm_err "Nieznana flaga: ${a}"; return 1 ;;
      *)
        [[ "${a}" =~ ^[0-9]+$ ]] && n="${a}"
        ;;
    esac
  done
  if [[ -n "${domain}" ]] && ! hm_is_valid_domain "${domain}"; then
    hm_err "Nieprawidłowa domena: ${domain}"
    return 1
  fi

  local logfile
  if ! logfile="$(hm_mail_log_file)"; then
    hm_warn "Brak czytelnego mail.log / maillog."
    return 0
  fi

  echo "${C_BOLD}Mail log${C_RESET}  ${logfile}"
  [[ -n "${domain}" ]] && echo "  filtr: @${domain} (exact)"
  [[ "${bounced}" == "1" ]] && echo "  filtr: bounced|deferred"

  if [[ "${follow}" == "1" ]]; then
    if [[ -n "${domain}" || "${bounced}" == "1" ]]; then
      tail -F "${logfile}" 2>/dev/null | while IFS= read -r line; do
        if hm_mail_log_line_match "${line}" "${domain}" "${bounced}"; then
          printf '%s\n' "${line}"
        fi
      done
    else
      tail -F "${logfile}"
    fi
    return 0
  fi

  local tmp
  tmp="$(hm_mktemp .mlog)"
  tail -n "$((n * 40))" "${logfile}" 2>/dev/null > "${tmp}.raw" || true
  : > "${tmp}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if hm_mail_log_line_match "${line}" "${domain}" "${bounced}"; then
      printf '%s\n' "${line}" >> "${tmp}"
    fi
  done < "${tmp}.raw"
  tail -n "${n}" "${tmp}"
  rm -f "${tmp}" "${tmp}.raw"
}

hm_mail_log_line_match() {
  local line="$1" domain="$2" bounced="$3"
  local low
  low="$(printf '%s' "${line}" | tr '[:upper:]' '[:lower:]')"
  if [[ "${bounced}" == "1" ]]; then
    case "${low}" in
      *status=bounced*|*status=deferred*) ;;
      *) return 1 ;;
    esac
  fi
  if [[ -n "${domain}" ]]; then
    local dlc esc
    dlc="$(printf '%s' "${domain}" | tr '[:upper:]' '[:lower:]')"
    # exact @domena — nie substring (evil-example / sub.example)
    esc="$(printf '%s' "${dlc}" | sed 's/\./\\./g')"
    if printf '%s' "${low}" | grep -qE "@${esc}([^a-z0-9.-]|$)"; then
      return 0
    fi
    return 1
  fi
  return 0
}

# --- check -------------------------------------------------------------------

hm_mail_check_ports() {
  local host="${1:-127.0.0.1}"
  local p
  echo "${C_BOLD}Porty SMTP/IMAP${C_RESET}"
  for p in 25 465 587 993; do
    if hm_have_cmd ss; then
      if ss -lnt 2>/dev/null | grep -qE ":${p}\\s"; then
        echo "  :${p}  ${C_GREEN}LISTEN${C_RESET}"
      else
        echo "  :${p}  ${C_YELLOW}brak listen${C_RESET}"
      fi
    elif hm_have_cmd nc; then
      if hm_run_timeout 2 nc -z "${host}" "${p}" 2>/dev/null; then
        echo "  :${p}  open"
      else
        echo "  :${p}  closed/timeout"
      fi
    else
      echo "  :${p}  (brak ss/nc — pominięto)"
    fi
  done
}

hm_mail_check_tls() {
  local host="$1" port="${2:-587}"
  echo "${C_BOLD}TLS SMTP ${host}:${port}${C_RESET}"
  if ! hm_have_cmd openssl; then
    hm_warn "Brak openssl — pomijam TLS."
    return 0
  fi
  local out end days
  out="$(hm_mktemp .tls)"
  if [[ "${port}" == "465" ]]; then
    echo | hm_run_timeout 8 openssl s_client -connect "${host}:${port}" -servername "${host}" 2>/dev/null > "${out}" || true
  else
    echo | hm_run_timeout 8 openssl s_client -starttls smtp -connect "${host}:${port}" -servername "${host}" 2>/dev/null > "${out}" || true
  fi
  if ! grep -q "BEGIN CERTIFICATE" "${out}" 2>/dev/null; then
    hm_warn "Brak certyfikatu / timeout na ${host}:${port}"
    rm -f "${out}"
    return 0
  fi
  end="$(openssl x509 -noout -enddate -in "${out}" 2>/dev/null | cut -d= -f2 || true)"
  if [[ -n "${end}" ]]; then
    local end_epoch now
    end_epoch="$(date -d "${end}" +%s 2>/dev/null || true)"
    now="$(date +%s)"
    if [[ -n "${end_epoch}" ]]; then
      days=$(( (end_epoch - now) / 86400 ))
      echo "  notAfter: ${end}  (${days} dni)"
    else
      echo "  notAfter: ${end}"
    fi
  fi
  rm -f "${out}"
}

hm_mail_check_cmd() {
  local domain="${1:-${HM_SITE_DOMAIN:-}}"
  shift || true
  case "${1:-}" in help|-h|--help)
    echo "Użycie: mail check <domena>"
    return 0
    ;;
  esac
  [[ -n "${domain}" ]] || { hm_err "Użycie: mail check <domena>"; return 1; }
  hm_is_valid_domain "${domain}" || { hm_err "Nieprawidłowa domena: ${domain}"; return 1; }

  echo "${C_BOLD}Mail check — ${domain}${C_RESET}"
  echo

  # MX
  echo "${C_BOLD}MX${C_RESET}"
  local mx
  mx="$(hm_mail_dig_mx "${domain}" 2>/dev/null || true)"
  if [[ -z "${mx}" ]]; then
    if ! hm_have_cmd dig; then
      hm_warn "Brak dig — pomijam MX/SPF/DKIM DNS."
    else
      hm_warn "Brak rekordów MX dla ${domain}"
    fi
  else
    printf '%s\n' "${mx}" | sed 's/^/  /'
  fi
  echo

  # SPF
  echo "${C_BOLD}SPF${C_RESET}"
  local spf ip
  spf="$(hm_mail_dig_txt "${domain}" 2>/dev/null || true)"
  spf="$(printf '%s' "${spf}" | grep -oE 'v=spf1[^"]*' | head -1 || true)"
  ip="$(hm_mail_public_ipv4 2>/dev/null || true)"
  if [[ -z "${spf}" ]]; then
    hm_warn "Brak SPF (TXT v=spf1) dla ${domain}"
  else
    echo "  ${spf}"
    if [[ -n "${ip}" ]]; then
      if [[ "${spf}" == *"ip4:${ip}"* ]]; then
        hm_ok "SPF zawiera ip4:${ip}"
      elif [[ "${spf}" == *include:* || "${spf}" =~ (^|[[:space:]])a([[:space:]]|/|:|$) || "${spf}" =~ (^|[[:space:]])mx([[:space:]]|/|:|$) ]]; then
        hm_info "SPF ma a/mx/include — zweryfikuj czy obejmuje ${ip}"
      else
        hm_warn "SPF bez ip4:${ip} (IP VPS) — możliwe odrzucenia"
      fi
    else
      hm_warn "Nie ustalono publicznego IPv4 — pomijam porównanie SPF."
    fi
  fi
  echo

  # DKIM
  echo "${C_BOLD}DKIM (default._domainkey)${C_RESET}"
  local dns_dkim local_f local_p dns_p
  dns_dkim="$(hm_mail_dig_txt "default._domainkey.${domain}" 2>/dev/null || true)"
  if [[ -z "${dns_dkim}" ]]; then
    hm_warn "Brak TXT default._domainkey.${domain}"
  else
    echo "  DNS: ${dns_dkim:0:80}…"
  fi
  if local_f="$(hm_mail_opendkim_txt_file "${domain}" 2>/dev/null)"; then
    echo "  lokalny: ${local_f}"
    local_p="$(hm_mail_extract_p_from_txtfile "${local_f}")"
    dns_p="$(printf '%s' "${dns_dkim}" | sed -n 's/.*p=\([A-Za-z0-9+/=]*\).*/\1/p')"
    if [[ -n "${local_p}" && -n "${dns_p}" ]]; then
      if [[ "${local_p}" == "${dns_p}" ]]; then
        hm_ok "DKIM lokalny = DNS"
      else
        hm_warn "DKIM rozbieżność: klucz lokalny ≠ TXT w DNS"
      fi
    elif [[ -z "${dns_p}" && -n "${local_p}" ]]; then
      hm_warn "Klucz lokalny jest, brak p= w DNS"
    fi
  else
    hm_warn "Brak lokalnego klucza OpenDKIM dla ${domain} (/etc/opendkim/keys/…)"
  fi
  echo

  # DMARC
  echo "${C_BOLD}DMARC${C_RESET}"
  local dmarc
  dmarc="$(hm_mail_dig_txt "_dmarc.${domain}" 2>/dev/null || true)"
  dmarc="$(printf '%s' "${dmarc}" | grep -oE 'v=DMARC1[^"]*' | head -1 || true)"
  if [[ -z "${dmarc}" ]]; then
    hm_warn "Brak DMARC (_dmarc.${domain})"
  else
    hm_ok "${dmarc}"
  fi
  echo

  # PTR / HELO
  echo "${C_BOLD}PTR / HELO${C_RESET}"
  local helo ptr
  helo="$(hm_mail_helo_hostname)"
  echo "  myhostname/HELO: ${helo:--}"
  if [[ -n "${ip}" ]]; then
    echo "  public IP: ${ip}"
    ptr="$(hm_mail_dig_ptr "${ip}" 2>/dev/null || true)"
    echo "  PTR: ${ptr:--}"
    if [[ -n "${ptr}" && -n "${helo}" ]]; then
      local ptr_l helo_l
      ptr_l="$(printf '%s' "${ptr}" | tr '[:upper:]' '[:lower:]')"
      helo_l="$(printf '%s' "${helo}" | tr '[:upper:]' '[:lower:]')"
      if [[ "${ptr_l}" == "${helo_l}" ]]; then
        hm_ok "PTR = hostname"
      else
        hm_warn "PTR (${ptr}) ≠ hostname (${helo})"
      fi
    elif [[ -z "${ptr}" ]]; then
      hm_warn "Brak PTR dla ${ip}"
    fi
  fi
  echo

  hm_mail_check_ports
  echo
  local mailhost="mail.${domain}"
  hm_mail_check_tls "${mailhost}" 587
  hm_mail_check_tls "${mailhost}" 465

  # limity (informacyjnie)
  echo
  echo "${C_BOLD}Limity Postfix (fragment)${C_RESET}"
  if hm_have_cmd postconf; then
    postconf -h message_size_limit maximal_queue_lifetime 2>/dev/null | paste - - 2>/dev/null \
      || postconf message_size_limit maximal_queue_lifetime 2>/dev/null | head -5
  else
    hm_warn "Brak postconf."
  fi
}

# --- dkim --------------------------------------------------------------------

hm_mail_dkim_cmd() {
  local domain="${1:-}" action="${2:-show}"
  shift 2 2>/dev/null || true
  case "${domain}" in
    help|-h|--help|"")
      echo "Użycie: mail dkim <domena> [generate] [--yes]"
      return 0
      ;;
  esac
  hm_is_valid_domain "${domain}" || { hm_err "Nieprawidłowa domena: ${domain}"; return 1; }

  if [[ "${action}" == "generate" || "${action}" == "gen" || "${action}" == "create" ]]; then
    hm_mail_dkim_generate "${domain}" "$@"
    return $?
  fi

  echo "${C_BOLD}DKIM — ${domain}${C_RESET}"
  local f dns
  if f="$(hm_mail_opendkim_txt_file "${domain}" 2>/dev/null)"; then
    echo "Lokalny plik: ${f}"
    echo "----- rekord do DNS (TXT default._domainkey.${domain}) -----"
    cat "${f}"
    echo "-------------------------------------------------------------"
  else
    hm_warn "Brak lokalnego klucza — wygeneruj: mail dkim ${domain} generate"
  fi
  dns="$(hm_mail_dig_txt "default._domainkey.${domain}" 2>/dev/null || true)"
  echo "DNS obecnie: ${dns:-"(brak / brak dig)"}"
}

hm_mail_dkim_generate() {
  local domain="$1" yes=0
  shift || true
  [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && yes=1

  local -a plan=(
    "Generacja klucza DKIM dla ${domain}"
    "Reload opendkim (jeśli dostępny)"
    "Wypisanie rekordu TXT do wklejenia w DNS"
  )
  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "mail dkim generate — ${domain}" \
      "Nowy klucz unieważnia stary TXT w DNS do czasu aktualizacji." --yes "${plan[@]}" || return 1
  else
    hm_confirm_plan "mail dkim generate — ${domain}" \
      "Nowy klucz unieważnia stary TXT w DNS do czasu aktualizacji." "${plan[@]}" || return 1
  fi

  local py="/usr/local/CyberCP/bin/python"
  local util="/usr/local/CyberCP/plogical/mailUtilities.py"
  if [[ -x "${py}" && -f "${util}" ]]; then
    hm_info "CyberPanel mailUtilities…"
    # typowe wywołania CP — best-effort
    if ! hm_run_timeout 120 "${py}" "${util}" --function generateKeys --domain "${domain}" 2>/dev/null \
      && ! hm_run_timeout 120 "${py}" -c "from plogical.mailUtilities import mailUtilities; mailUtilities.generateKeys('${domain}')" 2>/dev/null; then
      hm_warn "CyberPanel generateKeys nieudane — próbuję opendkim-genkey."
    fi
  fi

  if ! hm_mail_opendkim_txt_file "${domain}" >/dev/null 2>&1; then
    if hm_have_cmd opendkim-genkey; then
      local dir="/etc/opendkim/keys/${domain}"
      mkdir -p "${dir}"
      opendkim-genkey -D "${dir}" -d "${domain}" -s default || {
        hm_err "opendkim-genkey nieudany."
        return 1
      }
      chown -R opendkim:opendkim "${dir}" 2>/dev/null || true
      chmod 640 "${dir}/default.private" 2>/dev/null || true
    else
      hm_err "Brak CyberPanel mailUtilities i opendkim-genkey."
      return 1
    fi
  fi

  if hm_have_cmd systemctl && systemctl is-active opendkim >/dev/null 2>&1; then
    systemctl reload opendkim 2>/dev/null || systemctl restart opendkim 2>/dev/null || true
  fi

  hm_mail_dkim_cmd "${domain}" show
  hm_ok "DKIM gotowy — dodaj TXT w DNS (lub pdns), potem: mail check ${domain}"
}

# --- blacklist ---------------------------------------------------------------

hm_mail_dnsbl_zones() {
  cat <<'EOF'
zen.spamhaus.org
bl.spamcop.net
b.barracudacentral.org
dnsbl.sorbs.net
spam.dnsbl.sorbs.net
psbl.surriel.com
bl.spameatingmonkey.net
EOF
}

hm_mail_blacklist_cmd() {
  local ip="${1:-}"
  case "${ip}" in
    help|-h|--help)
      echo "Użycie: mail blacklist [IPv4]"
      return 0
      ;;
  esac
  if [[ -z "${ip}" ]]; then
    ip="$(hm_mail_public_ipv4 2>/dev/null || true)"
  fi
  [[ -n "${ip}" ]] || { hm_err "Nie ustalono IP — podaj: mail blacklist 1.2.3.4"; return 1; }
  [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    hm_err "Oczekiwano IPv4: ${ip}"; return 1
  }
  if ! hm_have_cmd dig; then
    hm_warn "Brak dig — nie sprawdzę DNSBL."
    return 0
  fi

  local rev zone listed=0
  rev="$(hm_mail_reverse_octets "${ip}")"
  echo "${C_BOLD}DNSBL — ${ip}${C_RESET}  (rev ${rev})"
  while IFS= read -r zone; do
    [[ -n "${zone}" ]] || continue
    local ans
    ans="$(hm_run_timeout 5 dig +short "${rev}.${zone}" A 2>/dev/null | head -3 | tr '\n' ' ')"
    if [[ -n "${ans}" && "${ans}" =~ ^127\. ]]; then
      echo "  ${C_RED}LISTED${C_RESET}  ${zone}  → ${ans}"
      listed=$((listed + 1))
    else
      echo "  ok      ${zone}"
    fi
  done < <(hm_mail_dnsbl_zones)

  if [[ "${listed}" -eq 0 ]]; then
    hm_ok "Brak trafień na sprawdzonych listach."
  else
    hm_warn "Trafienia: ${listed} — sprawdź delisting u operatora listy."
  fi
}
