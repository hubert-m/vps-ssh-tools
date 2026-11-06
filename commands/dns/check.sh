#!/usr/bin/env bash
# dns check — diagnostyka DNS domeny vs IP VPS

hm_dns_vps_ips() {
  local ip
  if hm_have_cmd hostname; then
    while IFS= read -r ip; do
      [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && printf '%s\n' "${ip}"
      [[ "${ip}" == *:* ]] && printf '%s\n' "${ip}"
    done < <(hostname -I 2>/dev/null | tr ' ' '\n')
  fi
  if hm_have_cmd ip; then
    ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1
    ip -o -6 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1
  fi
}

hm_dns_dig() {
  # hm_dns_dig <type> <name> [server]
  local typ="$1" name="$2" server="${3:-}"
  if hm_have_cmd dig; then
    if [[ -n "${server}" ]]; then
      hm_run_timeout 8 dig +short @"${server}" "${typ}" "${name}" 2>/dev/null
    else
      hm_run_timeout 8 dig +short "${typ}" "${name}" 2>/dev/null
    fi
    return 0
  fi
  if hm_have_cmd host; then
    case "${typ}" in
      A|AAAA) host -t "${typ}" "${name}" 2>/dev/null | awk '/has address|has IPv6/{print $NF}' ;;
      MX) host -t MX "${name}" 2>/dev/null | awk '/mail is handled/{print $(NF-1), $NF}' ;;
      TXT) host -t TXT "${name}" 2>/dev/null | sed -n 's/.*descriptive text "\(.*\)"/\1/p' ;;
      NS) host -t NS "${name}" 2>/dev/null | awk '/name server/{print $NF}' ;;
      *) return 1 ;;
    esac
    return 0
  fi
  return 1
}

hm_dns_check_status_line() {
  local status="$1" label="$2" detail="$3"
  case "${status}" in
    OK) printf '  %s%-5s%s  %-18s %s\n' "${C_GREEN}" "OK" "${C_RESET}" "${label}" "${detail}" ;;
    WARN) printf '  %s%-5s%s  %-18s %s\n' "${C_YELLOW}" "WARN" "${C_RESET}" "${label}" "${detail}" ;;
    ERR) printf '  %s%-5s%s  %-18s %s\n' "${C_RED}" "ERR" "${C_RESET}" "${label}" "${detail}" ;;
    *) printf '  %-5s  %-18s %s\n' "${status}" "${label}" "${detail}" ;;
  esac
}

hm_dns_check_cmd() {
  local domain="${1:-${HM_SITE_DOMAIN:-}}"
  shift || true
  case "${1:-}" in help|-h|--help)
    echo "Użycie: dns check <domena>"
    return 0
    ;;
  esac
  [[ -n "${domain}" ]] || { hm_err "Użycie: dns check <domena>"; return 1; }
  hm_is_valid_domain "${domain}" || { hm_err "Nieprawidłowa domena: ${domain}"; return 1; }

  if ! hm_have_cmd dig && ! hm_have_cmd host; then
    hm_warn "Brak dig/host — ograniczona diagnostyka."
  fi

  echo "${C_BOLD}DNS check — ${domain}${C_RESET}"
  echo

  local -a vps=()
  local ip
  while IFS= read -r ip; do
    [[ -n "${ip}" ]] || continue
    local seen=0 v
    for v in "${vps[@]:-}"; do [[ "${v}" == "${ip}" ]] && seen=1 && break; done
    [[ "${seen}" -eq 0 ]] && vps+=("${ip}")
  done < <(hm_dns_vps_ips)

  # A / AAAA
  local -a a_rec=() aaaa_rec=()
  while IFS= read -r ip; do
    [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && a_rec+=("${ip}")
  done < <(hm_dns_dig A "${domain}" 2>/dev/null || true)
  while IFS= read -r ip; do
    [[ "${ip}" == *:* ]] && aaaa_rec+=("${ip}")
  done < <(hm_dns_dig AAAA "${domain}" 2>/dev/null || true)

  local hit=0
  for ip in "${a_rec[@]:-}" "${aaaa_rec[@]:-}"; do
    [[ -n "${ip}" ]] || continue
    for v in "${vps[@]:-}"; do
      [[ "${ip}" == "${v}" ]] && hit=1 && break
    done
  done

  if [[ "${#a_rec[@]}" -eq 0 && "${#aaaa_rec[@]}" -eq 0 ]]; then
    hm_dns_check_status_line ERR "A/AAAA" "brak rekordu"
  elif [[ "${#vps[@]}" -eq 0 ]]; then
    hm_dns_check_status_line WARN "A/AAAA" "${a_rec[*]:-} ${aaaa_rec[*]:-} (nie ustalono IP VPS)"
  elif [[ "${hit}" -eq 1 ]]; then
    hm_dns_check_status_line OK "A/AAAA" "${a_rec[*]:-} ${aaaa_rec[*]:-} ↔ VPS"
  else
    hm_dns_check_status_line ERR "A/AAAA" "${a_rec[*]:-} ${aaaa_rec[*]:-} ≠ VPS (${vps[*]})"
  fi

  # NS
  local ns
  ns="$(hm_dns_dig NS "${domain}" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
  if [[ -n "${ns}" ]]; then
    hm_dns_check_status_line OK "NS" "${ns}"
  else
    hm_dns_check_status_line WARN "NS" "brak / nieodczytane"
  fi

  # MX
  local mx
  mx="$(hm_dns_dig MX "${domain}" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
  if [[ -n "${mx}" ]]; then
    hm_dns_check_status_line OK "MX" "${mx}"
  else
    hm_dns_check_status_line WARN "MX" "brak"
  fi

  # SPF
  local txt spf
  txt="$(hm_dns_dig TXT "${domain}" 2>/dev/null | tr -d '"' | tr '\n' ' ')"
  spf="$(printf '%s' "${txt}" | grep -oE 'v=spf1[^"]*' | head -1 || true)"
  if [[ -n "${spf}" ]]; then
    hm_dns_check_status_line OK "SPF" "${spf:0:70}"
  else
    hm_dns_check_status_line WARN "SPF" "brak v=spf1"
  fi

  # DKIM
  local dkim
  dkim="$(hm_dns_dig TXT "default._domainkey.${domain}" 2>/dev/null | tr -d '"' | tr '\n' ' ')"
  if [[ -n "${dkim}" && "${dkim}" == *v=DKIM1* && "${dkim}" == *p=* ]]; then
    hm_dns_check_status_line OK "DKIM" "default._domainkey (v=DKIM1 + p=)"
  elif [[ -n "${dkim}" ]]; then
    hm_dns_check_status_line WARN "DKIM" "TXT bez v=DKIM1/p= — ${dkim:0:50}"
  else
    hm_dns_check_status_line WARN "DKIM" "brak default._domainkey"
  fi

  # DMARC
  local dmarc
  dmarc="$(hm_dns_dig TXT "_dmarc.${domain}" 2>/dev/null | tr -d '"' | tr '\n' ' ')"
  dmarc="$(printf '%s' "${dmarc}" | grep -oE 'v=DMARC1[^"]*' | head -1 || true)"
  if [[ -n "${dmarc}" ]]; then
    hm_dns_check_status_line OK "DMARC" "${dmarc:0:70}"
  else
    hm_dns_check_status_line WARN "DMARC" "brak _dmarc"
  fi

  # CAA
  local caa
  caa="$(hm_dns_dig CAA "${domain}" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
  if [[ -n "${caa}" ]]; then
    hm_dns_check_status_line OK "CAA" "${caa}"
  else
    hm_dns_check_status_line WARN "CAA" "brak (opcjonalne)"
  fi

  # Propagacja: lokalny pdns vs 1.1.1.1 / 8.8.8.8
  echo
  echo "${C_BOLD}Propagacja A (porównanie resolverów)${C_RESET}"
  local r pub1 pub8 loc
  pub1="$(hm_dns_dig A "${domain}" 1.1.1.1 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
  pub8="$(hm_dns_dig A "${domain}" 8.8.8.8 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
  loc="$(hm_dns_dig A "${domain}" 127.0.0.1 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
  echo "  1.1.1.1    : ${pub1:--}"
  echo "  8.8.8.8    : ${pub8:--}"
  echo "  127.0.0.1  : ${loc:--}"
  if [[ -n "${pub1}" && -n "${pub8}" && "${pub1}" != "${pub8}" ]]; then
    hm_warn "Rozbieżność 1.1.1.1 vs 8.8.8.8 — propagacja w toku?"
  fi
  if [[ -n "${loc}" && -n "${pub1}" && "${loc}" != "${pub1}" ]]; then
    hm_warn "Lokalny pdns ≠ 1.1.1.1 — sprawdź czy strefa jest autorytatywna / glue NS."
  fi
  if [[ -z "${loc}" ]]; then
    hm_info "Brak odpowiedzi @127.0.0.1 — strefa może być zewnętrzna (OK dla dns check)."
  fi
}
