#!/usr/bin/env bash
# mail spam / senders / quota / dmarc — odczyt logów i raportów, bez haseł.

hm_mail_spam_status() {
  local file="${HM_MAIL_SPAM_STATUS:-}" engine="brak" active="nieznany" ver="" ham="" spam="" reject=""
  if [[ -n "${file}" && -f "${file}" ]]; then
    engine="$(grep '^engine=' "${file}" | head -n 1 || true)"
    engine="${engine#engine=}"
    active="$(grep '^active=' "${file}" | head -n 1 || true)"
    active="${active#active=}"
    ver="$(grep '^version=' "${file}" | head -n 1 || true)"
    ver="${ver#version=}"
    ham="$(grep '^ham=' "${file}" | head -n 1 || true)"
    ham="${ham#ham=}"
    spam="$(grep '^spam=' "${file}" | head -n 1 || true)"
    spam="${spam#spam=}"
    reject="$(grep '^reject=' "${file}" | head -n 1 || true)"
    reject="${reject#reject=}"
  elif command -v rspamd >/dev/null 2>&1; then
    engine="rspamd"
    active="jest"
  elif command -v spamassassin >/dev/null 2>&1; then
    engine="spamassassin"
    active="jest"
  fi
  printf 'engine: %s\n' "${engine:-brak}"
  printf 'active: %s\n' "${active:-nieznany}"
  printf 'version: %s\n' "${ver:-brak}"
  printf 'ham: %s\n' "${ham:-0}"
  printf 'spam: %s\n' "${spam:-0}"
  printf 'reject: %s\n' "${reject:-0}"
}

hm_mail_senders() {
  local since="" log="${HM_MAIL_LOG:-}" max="${HM_MAIL_SENDER_MAX:-100}" dedup line user count
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --since) since="${2:-}"; shift 2 || true ;;
      *) shift ;;
    esac
  done
  [[ -n "${log}" && -f "${log}" ]] || { hm_err "Brak logu Postfixa."; return 1; }
  [[ "${max}" =~ ^[0-9]+$ ]] || max=100
  dedup="${HM_MAIL_DEDUP:-}"
  while IFS=$'\t' read -r user count; do
    [[ -n "${user}" ]] || continue
    printf '%s\t%s\n' "${user}" "${count}"
    if [[ "${count}" -gt "${max}" ]]; then
      if [[ -n "${dedup}" && -f "${dedup}" ]] && grep -qx "${user} ${count}" "${dedup}"; then
        continue
      fi
      hm_warn "Skrzynka ${user} wysłała ${count} (próg ${max}). Rozważ mail passwd albo blokadę."
      if declare -F hm_notify >/dev/null 2>&1; then
        hm_notify error "Spam sender" "${user} ${count}" "mail.sender.${user}"
      fi
      if [[ -n "${dedup}" ]]; then
        mkdir -p "$(dirname "${dedup}")"
        printf '%s %s\n' "${user}" "${count}" >> "${dedup}"
      fi
    fi
  done < <(awk '
    {
      user=""
      if (match($0, /sasl_username=[^ ,]+/)) {
        user=substr($0, RSTART+14, RLENGTH-14)
      } else if (match($0, /from=<[^>]+>/)) {
        user=substr($0, RSTART+6, RLENGTH-7)
      }
      if (user != "") n[user]++
    }
    END { for (u in n) printf "%s\t%s\n", u, n[u] }
  ' "${log}")
  if [[ -n "${since}" ]]; then
    hm_info "Okno: ${since}"
  fi
}

hm_mail_quota() {
  local domain="${1:-}" file="${HM_MAIL_QUOTA:-}" line user used limit
  [[ -n "${file}" && -f "${file}" ]] || { hm_err "Brak danych quota."; return 1; }
  while IFS=$'\t' read -r user used limit; do
    [[ -n "${user}" ]] || continue
    if [[ -n "${domain}" && "${user}" != *"@${domain}" ]]; then
      continue
    fi
    printf '%s\t%s\t%s\n' "${user}" "${used}" "${limit}"
    if [[ "${used}" =~ ^[0-9]+$ && "${limit}" =~ ^[0-9]+$ && "${limit}" -gt 0 ]]; then
      if [[ $(( used * 100 / limit )) -ge 90 ]]; then
        hm_warn "Quota ${user}: ${used}/${limit}"
      fi
    fi
  done < "${file}"
}

hm_mail_dmarc_safe() {
  local file="$1" size
  [[ -f "${file}" ]] || { hm_err "Brak raportu DMARC."; return 1; }
  size="$(wc -c < "${file}" | tr -d '[:space:]')"
  if [[ "${size}" -gt 1048576 ]]; then
    hm_err "Raport DMARC jest większy niż 1 MB."
    return 1
  fi
  if grep -q '<!DOCTYPE\|<!ENTITY' "${file}"; then
    hm_err "Raport DMARC odrzucony (DOCTYPE lub ENTITY)."
    return 1
  fi
}

hm_mail_dmarc_report() {
  local file="$1" tmp=""
  if [[ "${file}" == *.gz ]]; then
    tmp="$(mktemp)"
    gzip -dc -- "${file}" 2>/dev/null | head -c 1048576 > "${tmp}" || { rm -f "${tmp}"; hm_err "Nie udało się odczytać gzip."; return 1; }
    file="${tmp}"
  fi
  hm_mail_dmarc_safe "${file}" || { rm -f "${tmp}"; return 1; }
  awk '
    function grab(tag,   s, a, b) {
      s=$0
      a=index(s, "<" tag ">")
      b=index(s, "</" tag ">")
      if (a && b > a) return substr(s, a+length(tag)+2, b-(a+length(tag)+2))
      return ""
    }
    {
      ip=grab("source_ip"); if (ip != "") ips[++n]=ip
      d=grab("dkim"); if (d != "") dkims[++nd]=d
      s=grab("spf"); if (s != "") spfs[++ns]=s
    }
    END {
      m=n; if (nd>m) m=nd; if (ns>m) m=ns
      for (i=1; i<=m; i++) printf "%s\t%s\t%s\n", ips[i], spfs[i], dkims[i]
    }
  ' "${file}"
  rm -f "${tmp}"
}

hm_mail_spam_cmd() {
  case "${1:-status}" in
    status|"") hm_mail_spam_status ;;
    *) hm_err "Użycie: mail spam status"; return 1 ;;
  esac
}

hm_mail_dmarc_cmd() {
  local sub="${1:-report}"
  shift || true
  case "${sub}" in
    import|report)
      [[ -n "${1:-}" ]] || { hm_err "Użycie: mail dmarc report <plik>"; return 1; }
      hm_mail_dmarc_report "$1"
      ;;
    *)
      hm_err "Użycie: mail dmarc report <plik>"
      return 1
      ;;
  esac
}
