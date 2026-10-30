#!/usr/bin/env bash
# Sites: SSL helpers

hm_ssl_paths_for_domain() {
  local domain="$1"
  local candidates=(
    "/etc/letsencrypt/live/${domain}/fullchain.pem"
    "${OLS_ROOT}/conf/vhosts/${domain}/ssl/fullchain.pem"
    "/home/${domain}/ssl/fullchain.pem"
    "/etc/ssl/${domain}/fullchain.pem"
  )
  local p
  for p in "${candidates[@]}"; do
    if [[ -f "${p}" ]]; then
      echo "${p}"
      return 0
    fi
  done
  # certFile w vhost (OLS: keyFile / certFile; ścieżki często z $VH_ROOT / $SERVER_ROOT)
  local conf cert
  conf="$(hm_vhost_conf_path "${domain}" 2>/dev/null || true)"
  if [[ -n "${conf}" ]]; then
    cert="$(awk 'tolower($1)=="certfile"{gsub(/\r/,"",$2); print $2; exit}' "${conf}" 2>/dev/null || true)"
    if [[ -n "${cert}" ]]; then
      if [[ -n "${OLS_ROOT:-}" ]]; then
        cert="${cert//\$SERVER_ROOT/${OLS_ROOT}}"
      fi
      cert="$(hm_expand_ols_vars "${cert}" "${domain}")"
      if [[ -f "${cert}" ]]; then
        echo "${cert}"
        return 0
      fi
    fi
  fi
  return 1
}

hm_ssl_expiry() {
  local cert="$1"
  [[ -f "${cert}" ]] || { echo "-"; return; }
  openssl x509 -enddate -noout -in "${cert}" 2>/dev/null | sed 's/notAfter=//' || echo "-"
}

hm_ssl_expiry_epoch() {
  local cert="$1" end
  [[ -f "${cert}" ]] || return 1
  end="$(openssl x509 -enddate -noout -in "${cert}" 2>/dev/null | sed 's/notAfter=//')"
  [[ -n "${end}" ]] || return 1
  date -d "${end}" +%s 2>/dev/null || return 1
}

hm_ssl_days_left() {
  # dni do wygaśnięcia (ujemne = wygasł)
  local cert="$1" exp now
  exp="$(hm_ssl_expiry_epoch "${cert}" 2>/dev/null || true)"
  [[ -n "${exp}" ]] || { echo ""; return 1; }
  now="$(date +%s)"
  echo $(( (exp - now) / 86400 ))
}

hm_ssl_status() {
  # stdout: ok | soon | expired | missing | unknown
  local cert="${1:-}"
  local days warn_days="${2:-14}"
  if [[ -z "${cert}" || ! -f "${cert}" ]]; then
    echo "missing"
    return 0
  fi
  days="$(hm_ssl_days_left "${cert}" 2>/dev/null || true)"
  if [[ -z "${days}" ]]; then
    echo "unknown"
    return 0
  fi
  if [[ "${days}" -lt 0 ]]; then
    echo "expired"
  elif [[ "${days}" -le "${warn_days}" ]]; then
    echo "soon"
  else
    echo "ok"
  fi
}

hm_ssl_has() {
  local domain="$1"
  if hm_ssl_paths_for_domain "${domain}" >/dev/null 2>&1; then
    echo "yes"
  else
    echo "no"
  fi
}
