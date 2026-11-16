#!/usr/bin/env bash
# mail spam / senders / quota / dmarc — odczyt logów i raportów, bez haseł.

hm_mail_paths_init() {
  local base="${HM_MAIL_DIR:-/var/lib/hmtools/mail}"
  HM_MAIL_DEDUP="${HM_MAIL_DEDUP:-${base}/senders.dedup}"
  mkdir -p "$(dirname "${HM_MAIL_DEDUP}")" 2>/dev/null || true
}

hm_mail_spam_status() {
  local file="${HM_MAIL_SPAM_STATUS:-}" engine="brak" active="nieznany" ver="" ham="" spam="" reject=""
  local have_stats=0
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
    have_stats=1
  elif command -v rspamc >/dev/null 2>&1 || command -v rspamd >/dev/null 2>&1; then
    engine="rspamd"
    active="jest"
    if command -v rspamc >/dev/null 2>&1; then
      ver="$(rspamc stat 2>/dev/null | awk -F': ' '/^Rspamd version/{print $2; exit}')"
    fi
  elif command -v spamassassin >/dev/null 2>&1; then
    engine="spamassassin"
    active="jest"
    ver="$(spamassassin -V 2>/dev/null | head -n 1 | awk '{print $NF}')"
  fi
  printf 'engine: %s\n' "${engine:-brak}"
  printf 'active: %s\n' "${active:-nieznany}"
  printf 'version: %s\n' "${ver:-brak}"
  if [[ "${have_stats}" -eq 1 ]]; then
    printf 'ham: %s\n' "${ham:-0}"
    printf 'spam: %s\n' "${spam:-0}"
    printf 'reject: %s\n' "${reject:-0}"
  else
    printf 'ham: brak danych\n'
    printf 'spam: brak danych\n'
    printf 'reject: brak danych\n'
  fi
}

hm_mail_find_log() {
  local f
  if [[ -n "${HM_MAIL_LOG:-}" ]]; then
    printf '%s\n' "${HM_MAIL_LOG}"
    return 0
  fi
  for f in /var/log/mail.log /var/log/maillog /var/log/mail/mail.log; do
    if [[ -f "${f}" ]]; then
      printf '%s\n' "${f}"
      return 0
    fi
  done
  return 1
}

hm_mail_senders() {
  local since="" log="" max="${HM_MAIL_SENDER_MAX:-100}" dedup user count day key
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --since) since="${2:-}"; shift 2 || true ;;
      *) shift ;;
    esac
  done
  hm_mail_paths_init
  log="$(hm_mail_find_log)" || { hm_err "Brak logu Postfixa."; return 1; }
  [[ -f "${log}" ]] || { hm_err "Brak logu Postfixa."; return 1; }
  [[ "${max}" =~ ^[0-9]+$ ]] || max=100
  dedup="${HM_MAIL_DEDUP}"
  day="$(date +%Y-%m-%d 2>/dev/null || echo unknown)"
  while IFS=$'\t' read -r user count; do
    [[ -n "${user}" ]] || continue
    printf '%s\t%s\n' "${user}" "${count}"
    if [[ "${count}" -gt "${max}" ]]; then
      # Klucz: user + dzień (nie count — inaczej każdy przyrost omija dedup)
      key="${user} ${day}"
      if [[ -n "${dedup}" && -f "${dedup}" ]] && grep -Fxq -- "${key}" "${dedup}"; then
        continue
      fi
      hm_warn "Skrzynka ${user} wysłała ${count} (próg ${max}). Rozważ mail passwd albo blokadę."
      if declare -F hm_notify >/dev/null 2>&1; then
        hm_notify error "Spam sender" "${user} ${count}" "mail.sender.${user}"
      fi
      if [[ -n "${dedup}" ]]; then
        mkdir -p "$(dirname "${dedup}")"
        printf '%s\n' "${key}" >> "${dedup}"
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

hm_mail_quota_from_doveadm() {
  local domain="${1:-}" out user used limit
  command -v doveadm >/dev/null 2>&1 || return 1
  out="$(doveadm quota get -A 2>/dev/null || true)"
  [[ -n "${out}" ]] || return 1
  printf '%s\n' "${out}" | awk -v domain="${domain}" '
    # user STORAGE used limit %
    $2 == "STORAGE" {
      u=$1; used=$3+0; limit=$4+0
      if (domain != "" && index(u, "@" domain) == 0) next
      printf "%s\t%s\t%s\n", u, used, limit
    }
  '
}

hm_mail_quota() {
  local domain="${1:-}" file="${HM_MAIL_QUOTA:-}" line user used limit src
  if [[ -n "${file}" && -f "${file}" ]]; then
    src="${file}"
  else
    src="$(mktemp "${TMP_DIR:-${TMPDIR:-/tmp}}/hm-quota.XXXXXX")" || {
      hm_err "Brak danych quota."
      return 1
    }
    if ! hm_mail_quota_from_doveadm "${domain}" > "${src}" || [[ ! -s "${src}" ]]; then
      rm -f "${src}"
      hm_err "Brak danych quota."
      return 1
    fi
    domain=""
  fi
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
  done < "${src}"
  if [[ "${src}" != "${file}" ]]; then
    rm -f "${src}"
  fi
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
    tmp="$(mktemp "${TMP_DIR:-${TMPDIR:-/tmp}}/hm-dmarc.XXXXXX")"
    gzip -dc -- "${file}" 2>/dev/null | head -c 1048576 > "${tmp}" || {
      rm -f "${tmp}"
      hm_err "Nie udało się odczytać gzip."
      return 1
    }
    # jeśli gzip był większy niż limit — head uciął; odrzuć gdy wejście nadal „pełne” 1MB i gzip ma więcej
    if [[ "$(wc -c < "${tmp}" | tr -d '[:space:]')" -ge 1048576 ]]; then
      rm -f "${tmp}"
      hm_err "Raport DMARC jest większy niż 1 MB."
      return 1
    fi
    file="${tmp}"
  fi
  hm_mail_dmarc_safe "${file}" || { rm -f "${tmp}"; return 1; }
  # Cały dokument (≤1 MB): rekordy po <source_ip>, SPF/DKIM z tego samego wycinka (minified OK).
  awk '
    function tagval(s, tag,   a, b, op, cl) {
      op = "<" tag ">"
      cl = "</" tag ">"
      a = index(s, op)
      if (!a) return ""
      b = index(substr(s, a), cl)
      if (!b) return ""
      return substr(s, a + length(op), b - length(op) - 1)
    }
    {
      data = data $0
    }
    END {
      while (match(data, /<source_ip>[^<]*<\/source_ip>/)) {
        ip = substr(data, RSTART + 11, RLENGTH - 23)
        rest = substr(data, RSTART + RLENGTH)
        # wycinek do następnego source_ip
        cut = index(rest, "<source_ip>")
        if (cut) chunk = substr(rest, 1, cut - 1)
        else chunk = rest
        spf = tagval(chunk, "spf")
        dkim = tagval(chunk, "dkim")
        # czasem wynik w <result> wewnątrz spf/dkim
        if (spf ~ /<result>/) spf = tagval(spf, "result")
        if (dkim ~ /<result>/) dkim = tagval(dkim, "result")
        printf "%s\t%s\t%s\n", ip, spf, dkim
        data = rest
      }
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
