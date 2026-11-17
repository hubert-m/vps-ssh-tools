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

# 24h / 7d / … → epoch; 0 = bez filtra.
hm_mail_since_epoch() {
  local since="${1:-}" now n u sec=0
  now="$(date +%s)"
  [[ -n "${since}" ]] || { printf '%s' 0; return 0; }
  if [[ "${since}" =~ ^([0-9]+)([smhd])$ ]]; then
    n="${BASH_REMATCH[1]}"
    u="${BASH_REMATCH[2]}"
    case "${u}" in
      s) sec="${n}" ;;
      m) sec=$((n * 60)) ;;
      h) sec=$((n * 3600)) ;;
      d) sec=$((n * 86400)) ;;
    esac
    printf '%s' "$((now - sec))"
    return 0
  fi
  if date -d "${since}" +%s >/dev/null 2>&1; then
    date -d "${since}" +%s
    return 0
  fi
  printf '%s' 0
}

hm_mail_epoch_cmp() {
  local ep="${1:-0}"
  [[ "${ep}" =~ ^[0-9]+$ && "${ep}" -gt 0 ]] || { printf '%s' 0; return 0; }
  if date -d "@${ep}" +%Y%m%d%H%M%S >/dev/null 2>&1; then
    date -d "@${ep}" +%Y%m%d%H%M%S
    return 0
  fi
  if date -r "${ep}" +%Y%m%d%H%M%S >/dev/null 2>&1; then
    date -r "${ep}" +%Y%m%d%H%M%S
    return 0
  fi
  printf '%s' 0
}

hm_mail_senders() {
  local since="" log="" max="${HM_MAIL_SENDER_MAX:-100}" dedup user count day key
  local since_ep=0 since_cmp=0 year
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
  year="$(date +%Y 2>/dev/null || echo 2026)"
  since_ep="$(hm_mail_since_epoch "${since}")"
  since_cmp="$(hm_mail_epoch_cmp "${since_ep}")"
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
  done < <(awk -v since_cmp="${since_cmp}" -v year="${year}" '
    BEGIN {
      split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", _m, " ")
      for (i = 1; i <= 12; i++) mon[_m[i]] = sprintf("%02d", i)
    }
    # Syslog: "Mon DD HH:MM:SS …" → YYYYMMDDHHMMSS; bez daty → "" (nie filtruj).
    function syslog_cmp(s,   a, mo, dd, t, hh, mi, ss) {
      if (!match(s, /^[A-Z][a-z][a-z][ \t]+[0-9]+[ \t]+[0-9]{2}:[0-9]{2}:[0-9]{2}/)) return ""
      a = substr(s, RSTART, RLENGTH)
      mo = substr(a, 1, 3)
      if (!(mo in mon)) return ""
      if (match(a, /[0-9]+[ \t]+[0-9]{2}:[0-9]{2}:[0-9]{2}/) == 0) return ""
      dd = substr(a, RSTART, RLENGTH)
      if (match(dd, /^[0-9]+/) == 0) return ""
      dd = sprintf("%02d", substr(dd, RSTART, RLENGTH) + 0)
      if (match(a, /[0-9]{2}:[0-9]{2}:[0-9]{2}/) == 0) return ""
      t = substr(a, RSTART, 8)
      hh = substr(t, 1, 2); mi = substr(t, 4, 2); ss = substr(t, 7, 2)
      return year mon[mo] dd hh mi ss
    }
    function qid_of(s,   m) {
      if (match(s, /: [0-9A-Fa-f]{5,}: /)) {
        m = substr(s, RSTART + 2, RLENGTH - 4)
        return m
      }
      return ""
    }
    function sasl_of(s,   u) {
      if (match(s, /sasl_username=[^ ,]+/)) {
        u = substr(s, RSTART + 14, RLENGTH - 14)
        sub(/password=.*/, "", u)
        return u
      }
      return ""
    }
    function from_of(s,   u) {
      if (match(s, /from=<[^>]*>/)) {
        u = substr(s, RSTART + 6, RLENGTH - 7)
        if (u == "" || u == "<>") return ""
        return u
      }
      return ""
    }
    {
      if (since_cmp != "0") {
        ts = syslog_cmp($0)
        if (ts != "" && ts < since_cmp) next
      }
      qid = qid_of($0)
      sasl = sasl_of($0)
      if (sasl != "") {
        if (qid != "") auth_user[qid] = sasl
        else n[sasl]++
        next
      }
      # Lokalne: postfix/pickup (nie qmgr/smtpd z zewnętrznym from=)
      if ($0 ~ /postfix\/pickup/ && (u = from_of($0)) != "") {
        if (qid != "") auth_user[qid] = u
        else n[u]++
        next
      }
      # z zewnętrznego from=/qmgr bez SASL — pomijamy (poczta przychodząca)
    }
    END {
      for (q in auth_user) n[auth_user[q]]++
      for (u in n) printf "%s\t%s\n", u, n[u]
    }
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
