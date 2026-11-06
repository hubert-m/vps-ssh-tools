#!/usr/bin/env bash
# security waf — ModSecurity (OWASP CRS / Comodo) na OLS

_hm_cmd_help waf <<'EOF'
Użycie (globalnie):
  security waf                         Status: moduł, SecRuleEngine, OWASP/Comodo, blokady 24h
  security waf log [N] [--domain d] [--ip IP]   Agregacja audit logu
  security waf mode on|detect|off [--yes]
  security waf rules [owasp|comodo]    Pliki reguł + stan
  security waf rule-file disable|enable <plik.conf> [--yes]

Użycie (kontekst [domena]>):
  waf                                  Blokady tej strony (z audit logu)
  waf whitelist <ruleId> [--uri /path] [--yes]
  waf whitelist list
  waf whitelist remove <ruleId> [--yes]

Whitelist: blok # hmtools:waf w vhconf + SecRule SERVER_NAME w
conf/modsec/hmtools-exclusions.conf (OLS nie honoruje SecRuleRemoveById w .htaccess).
EOF

hm_waf_ols_root() {
  printf '%s' "${OLS_ROOT:-/usr/local/lsws}"
}

hm_waf_httpd_conf() {
  printf '%s' "${OLS_CONF:-$(hm_waf_ols_root)/conf/httpd_config.conf}"
}

hm_waf_modsec_conf() {
  local r
  r="$(hm_waf_ols_root)"
  local f
  for f in \
    "${r}/conf/modsec.conf" \
    "${r}/conf/modsec/main.conf" \
    "${r}/modsec/main.conf"
  do
    [[ -f "${f}" ]] && { printf '%s' "${f}"; return 0; }
  done
  return 1
}

hm_waf_audit_log() {
  local r f
  r="$(hm_waf_ols_root)"
  for f in \
    "${r}/logs/auditmodsec.log" \
    "${r}/logs/modsec_audit.log" \
    "${r}/logs/modsec.log" \
    /var/log/modsec_audit.log
  do
    [[ -f "${f}" ]] && { printf '%s' "${f}"; return 0; }
  done
  # SecAuditLog w conf
  local mc
  mc="$(hm_waf_modsec_conf 2>/dev/null || true)"
  if [[ -n "${mc}" ]]; then
    f="$(grep -E '^[[:space:]]*SecAuditLog[[:space:]]+' "${mc}" 2>/dev/null | awk '{print $2; exit}' | tr -d '"' || true)"
    [[ -n "${f}" && -f "${f}" ]] && { printf '%s' "${f}"; return 0; }
  fi
  printf '%s' "${r}/logs/auditmodsec.log"
}

hm_waf_exclusions_file() {
  printf '%s/conf/modsec/hmtools-exclusions.conf' "$(hm_waf_ols_root)"
}

hm_waf_owasp_dir() {
  local r d
  r="$(hm_waf_ols_root)"
  for d in \
    "${r}/conf/modsec/owasp-modsecurity-crs" \
    "${r}/conf/owasp/owasp-modsecurity-crs" \
    "${r}/conf/modsec/owasp-modsecurity-crs-3.0.0" \
    "${r}/conf/modsec/owasp-modsecurity-crs-3.3.0" \
    "${r}/conf/modsec/owasp-modsecurity-crs-3.3.2" \
    "${r}/conf/modsec/owasp-modsecurity-crs-3.3.4" \
    "${r}/conf/modsec/owasp-modsecurity-crs-3.3.5"
  do
    [[ -d "${d}" ]] && { printf '%s' "${d}"; return 0; }
  done
  # glob
  for d in "${r}/conf/modsec"/owasp-modsecurity-crs* "${r}/conf/owasp"/owasp-modsecurity-crs*; do
    [[ -d "${d}" ]] && { printf '%s' "${d}"; return 0; }
  done
  return 1
}

hm_waf_comodo_dir() {
  local r d
  r="$(hm_waf_ols_root)"
  for d in \
    "${r}/conf/comodo_litespeed" \
    "${r}/conf/modsec/comodo" \
    "${r}/modsec/comodo"
  do
    [[ -d "${d}" ]] && { printf '%s' "${d}"; return 0; }
  done
  return 1
}

hm_waf_module_loaded() {
  local conf so
  conf="$(hm_waf_httpd_conf)"
  so="$(hm_waf_ols_root)/modules/mod_security.so"
  [[ -f "${so}" ]] || return 1
  [[ -f "${conf}" ]] || return 1
  grep -qiE 'module[[:space:]]+mod_security' "${conf}" 2>/dev/null
}

hm_waf_engine_mode() {
  # On | DetectionOnly | Off | unknown
  local conf mc line
  conf="$(hm_waf_httpd_conf)"
  mc="$(hm_waf_modsec_conf 2>/dev/null || true)"
  for f in "${conf}" "${mc}"; do
    [[ -n "${f}" && -f "${f}" ]] || continue
    line="$(grep -E 'SecRuleEngine[[:space:]]+' "${f}" 2>/dev/null | tail -1 || true)"
    if [[ "${line}" =~ SecRuleEngine[[:space:]]+([A-Za-z]+) ]]; then
      printf '%s' "${BASH_REMATCH[1]}"
      return 0
    fi
  done
  printf 'unknown'
}

hm_waf_set_engine_mode() {
  local mode="$1" # On|DetectionOnly|Off
  local conf mc
  conf="$(hm_waf_httpd_conf)"
  [[ -f "${conf}" ]] || { hm_err "Brak ${conf}"; return 1; }
  cp -a "${conf}" "${conf}.hmtools.bak" 2>/dev/null || true
  if grep -qE 'SecRuleEngine[[:space:]]+' "${conf}"; then
    local tmp
    tmp="$(hm_mktemp .waf)"
    sed -E "s/SecRuleEngine[[:space:]]+[A-Za-z]+/SecRuleEngine ${mode}/g" "${conf}" > "${tmp}" \
      || { rm -f "${tmp}"; return 1; }
    cat "${tmp}" > "${conf}" || { rm -f "${tmp}"; return 1; }
    rm -f "${tmp}"
  else
    # wstaw w bloku mod_security jeśli jest
    if grep -qiE 'module[[:space:]]+mod_security' "${conf}"; then
      local tmp
      tmp="$(hm_mktemp .waf)"
      awk -v m="${mode}" '
        BEGIN { done=0 }
        tolower($1)=="module" && tolower($2)~/^mod_security/ { inb=1 }
        inb && !done && /modsecurity_rules[[:space:]]*`/ {
          print
          print "SecRuleEngine " m
          done=1
          next
        }
        { print }
        END {
          if (!done) print "# hmtools: SecRuleEngine not injected — add manually"
        }
      ' "${conf}" > "${tmp}"
      cat "${tmp}" > "${conf}"
      rm -f "${tmp}"
    else
      hm_err "Brak bloku module mod_security — zainstaluj WAF (CyberPanel / ols-modsecurity)."
      return 1
    fi
  fi
  mc="$(hm_waf_modsec_conf 2>/dev/null || true)"
  if [[ -n "${mc}" && -f "${mc}" ]] && grep -qE 'SecRuleEngine[[:space:]]+' "${mc}"; then
    local tmp
    tmp="$(hm_mktemp .waf)"
    sed -E "s/SecRuleEngine[[:space:]]+[A-Za-z]+/SecRuleEngine ${mode}/g" "${mc}" > "${tmp}"
    cat "${tmp}" > "${mc}"
    rm -f "${tmp}"
  fi
  return 0
}

hm_waf_blocks_24h() {
  local log n
  log="$(hm_waf_audit_log)"
  [[ -f "${log}" ]] || { printf '0'; return 0; }
  # licznik linii z id "…" w ostatnich ~24h (heurystyka: plik mtime / grep)
  n="$(grep -cE '\[id[[:space:]]+"[0-9]+"\]' "${log}" 2>/dev/null || echo 0)"
  [[ "${n}" =~ ^[0-9]+$ ]] || n=0
  printf '%s' "${n}"
}

hm_waf_status() {
  echo "${C_BOLD}WAF / ModSecurity${C_RESET}"
  local so eng owasp comodo log blocks
  so="$(hm_waf_ols_root)/modules/mod_security.so"
  if [[ -f "${so}" ]]; then
    echo "  mod_security.so : ${C_GREEN}obecny${C_RESET} (${so})"
  else
    hm_warn "mod_security.so brak — zainstaluj ols-modsecurity / CyberPanel ModSecurity"
  fi
  if hm_waf_module_loaded; then
    echo "  httpd module    : ${C_GREEN}załadowany${C_RESET}"
  else
    echo "  httpd module    : ${C_YELLOW}nie znaleziono bloku module mod_security${C_RESET}"
  fi
  eng="$(hm_waf_engine_mode)"
  case "${eng}" in
    On|on) echo "  SecRuleEngine   : ${C_GREEN}${eng}${C_RESET}" ;;
    DetectionOnly) echo "  SecRuleEngine   : ${C_YELLOW}${eng}${C_RESET}" ;;
    Off|off) echo "  SecRuleEngine   : ${C_RED}${eng}${C_RESET}  (brak ochrony)" ;;
    *) echo "  SecRuleEngine   : ${eng}" ;;
  esac
  if owasp="$(hm_waf_owasp_dir 2>/dev/null)"; then
    echo "  OWASP CRS       : ${C_GREEN}tak${C_RESET} (${owasp})"
  else
    echo "  OWASP CRS       : nie wykryto"
  fi
  if comodo="$(hm_waf_comodo_dir 2>/dev/null)"; then
    echo "  Comodo          : ${C_GREEN}tak${C_RESET} (${comodo})"
  else
    echo "  Comodo          : nie wykryto"
  fi
  log="$(hm_waf_audit_log)"
  blocks="$(hm_waf_blocks_24h)"
  echo "  Audit log       : ${log}$([[ -f "${log}" ]] && echo '' || echo ' (brak pliku)')"
  echo "  Trafienia (log) : ${blocks}  (linie z [id \"…\"] — przybliżenie)"
}

# Parsuj audit log → TSV: rule_id|msg|host|uri|ip|ts
hm_waf_parse_audit() {
  local log="${1:-}"
  [[ -f "${log}" ]] || return 0
  awk '
    BEGIN { sect=""; id=""; msg=""; host=""; uri=""; ip=""; ts="" }
    /^--+[0-9a-zA-Z_-]+-A--$/ {
      if (id != "") print id "\t" msg "\t" host "\t" uri "\t" ip "\t" ts
      sect="A"; id=""; msg=""; host=""; uri=""; ip=""; ts=""; next
    }
    /^--+[0-9a-zA-Z_-]+-B--$/ { sect="B"; next }
    /^--+[0-9a-zA-Z_-]+-H--$/ { sect="H"; next }
    /^--+[0-9a-zA-Z_-]+-[A-Z]--$/ { sect=""; next }
    sect=="A" {
      if (match($0, /\[[^]]+\]/)) ts=substr($0, RSTART+1, RLENGTH-2)
      if (match($0, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) ip=substr($0, RSTART, RLENGTH)
      next
    }
    sect=="B" {
      if ($0 ~ /^(GET|POST|PUT|DELETE|HEAD|OPTIONS|PATCH) /) {
        split($0, a, " ")
        uri=a[2]
      }
      if ($0 ~ /^[Hh][Oo][Ss][Tt]:/) {
        host=$0; sub(/^[Hh][Oo][Ss][Tt]:[[:space:]]*/, "", host)
        gsub(/\r/, "", host)
      }
      next
    }
    sect=="H" {
      if (index($0, "[id \"") > 0) {
        line=$0
        sub(/.*\[id "/, "", line)
        sub(/".*/, "", line)
        if (line ~ /^[0-9]+$/) id=line
      }
      if (index($0, "[msg \"") > 0) {
        line=$0
        sub(/.*\[msg "/, "", line)
        sub(/".*/, "", line)
        msg=line
      }
      next
    }
    END { if (id != "") print id "\t" msg "\t" host "\t" uri "\t" ip "\t" ts }
  ' "${log}" 2>/dev/null
}

hm_waf_log_cmd() {
  local n=50 domain="" ip="" a
  while [[ $# -gt 0 ]]; do
    a="$1"; shift || true
    case "${a}" in
      --domain|--host) domain="${1:-}"; shift || true ;;
      --domain=*) domain="${a#--domain=}" ;;
      --ip) ip="${1:-}"; shift || true ;;
      --ip=*) ip="${a#--ip=}" ;;
      help|-h|--help)
        echo "Użycie: security waf log [N] [--domain d] [--ip IP]"
        return 0
        ;;
      -*)
        hm_err "Nieznana flaga: ${a}"; return 1 ;;
      *)
        [[ "${a}" =~ ^[0-9]+$ ]] && n="${a}"
        ;;
    esac
  done
  [[ -n "${domain}" ]] && ! hm_is_valid_domain "${domain}" && {
    hm_err "Nieprawidłowa domena: ${domain}"; return 1
  }

  local log
  log="$(hm_waf_audit_log)"
  if [[ ! -f "${log}" ]]; then
    hm_warn "Brak audit logu (${log})."
    return 0
  fi

  echo "${C_BOLD}WAF audit — top reguł${C_RESET}  log=${log}"
  [[ -n "${domain}" ]] && echo "  filtr host: ${domain} (exact)"
  [[ -n "${ip}" ]] && echo "  filtr IP: ${ip}"
  echo

  local tmp
  tmp="$(hm_mktemp .waflog)"
  hm_waf_parse_audit "${log}" > "${tmp}.all"
  awk -F'\t' -v dom="${domain}" -v ipf="${ip}" '
    {
      id=$1; msg=$2; host=$3; uri=$4; ip=$5
      if (dom != "") {
        h=tolower(host); d=tolower(dom)
        # exact match (+ opcjonalny www.) — nigdy substring
        if (h != d && h != ("www." d)) next
      }
      if (ipf != "" && ip != ipf) next
      cnt[id]++
      if (!(id in sample_msg)) sample_msg[id]=msg
      if (!(id in sample_uri)) sample_uri[id]=uri
    }
    END {
      for (i in cnt) printf "%d\t%s\t%s\t%s\n", cnt[i], i, sample_msg[i], sample_uri[i]
    }
  ' "${tmp}.all" | sort -t$'\t' -k1,1nr | head -n "${n}" | {
    printf '  %-6s %-10s %-40s %s\n' "COUNT" "RULE" "MSG" "URI (przykład)"
    while IFS=$'\t' read -r c id msg uri; do
      [[ -n "${id}" ]] || continue
      printf '  %-6s %-10s %-40s %s\n' "${c}" "${id}" "${msg:0:40}" "${uri:0:40}"
    done
  }
  rm -f "${tmp}" "${tmp}.all"
}

hm_waf_mode_cmd() {
  local mode="${1:-}" yes=0
  shift || true
  [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && yes=1
  case "${mode}" in
    on|On) mode="On" ;;
    detect|detection|DetectionOnly|detectiononly) mode="DetectionOnly" ;;
    off|Off) mode="Off" ;;
    help|-h|--help|"")
      echo "Użycie: security waf mode on|detect|off [--yes]"
      return 0
      ;;
    *)
      hm_err "Użycie: security waf mode on|detect|off"
      return 1
      ;;
  esac

  local warn=""
  [[ "${mode}" == "Off" ]] && warn="WYŁĄCZENIE WAF — brak ochrony ModSecurity dla całego serwera."

  local -a plan=("Ustawienie SecRuleEngine ${mode} w httpd_config / modsec.conf" "ols soft-reload")
  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "security waf mode ${mode}" "${warn}" --yes "${plan[@]}" || return 1
  else
    hm_confirm_plan "security waf mode ${mode}" "${warn}" "${plan[@]}" || return 1
  fi

  hm_waf_set_engine_mode "${mode}" || return 1
  hm_ols_reload_soft || hm_warn "ols reload nieudany"
  hm_ok "SecRuleEngine → ${mode}"
}

hm_waf_rules_list_owasp() {
  local d f base
  if ! d="$(hm_waf_owasp_dir 2>/dev/null)"; then
    hm_warn "Brak katalogu OWASP CRS."
    return 1
  fi
  echo "${C_BOLD}OWASP rules — ${d}/rules${C_RESET}"
  shopt -s nullglob
  for f in "${d}/rules"/*.conf; do
    base="$(basename "${f}")"
    printf '  %s\n' "${base}"
  done
  for f in "${d}/rules"/*.conf.disabled; do
    base="$(basename "${f}" .disabled)"
    printf '  %s [disabled]\n' "${base}"
  done
  shopt -u nullglob
}

hm_waf_rules_list_comodo() {
  local d
  if ! d="$(hm_waf_comodo_dir 2>/dev/null)"; then
    hm_warn "Brak katalogu Comodo."
    return 1
  fi
  echo "${C_BOLD}Comodo — ${d}${C_RESET}"
  find "${d}" -maxdepth 2 -name '*.conf' 2>/dev/null | head -40 | sed 's/^/  /'
}

hm_waf_rules_list() {
  local pack="${1:-}"
  case "${pack}" in
    owasp|OWASP)
      hm_waf_rules_list_owasp
      ;;
    comodo|Comodo)
      hm_waf_rules_list_comodo
      ;;
    ""|both|all)
      hm_waf_rules_list_owasp 2>/dev/null || true
      hm_waf_rules_list_comodo 2>/dev/null || true
      ;;
    *)
      hm_err "Użycie: security waf rules [owasp|comodo]"
      return 1
      ;;
  esac
}

hm_waf_rule_file_toggle() {
  local action="$1" file="$2" yes=0
  shift 2 || true
  [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && yes=1
  [[ -n "${file}" ]] || { hm_err "Użycie: security waf rule-file disable|enable <plik.conf>"; return 1; }
  file="$(basename "${file}")"

  local d confpath
  d="$(hm_waf_owasp_dir 2>/dev/null || true)"
  [[ -n "${d}" ]] || { hm_err "Brak OWASP CRS."; return 1; }
  confpath="${d}/rules/${file}"
  [[ -f "${confpath}" || -f "${confpath}.disabled" ]] || {
    hm_err "Nie znaleziono ${confpath}"
    return 1
  }

  local -a plan=()
  case "${action}" in
    disable|off)
      plan=("Zmiana nazwy ${file} → ${file}.disabled (serwerowy scope)" "ols reload")
      ;;
    enable|on)
      plan=("Przywrócenie ${file}.disabled → ${file}" "ols reload")
      ;;
    *)
      hm_err "Użycie: rule-file disable|enable <plik>"
      return 1
      ;;
  esac
  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "waf rule-file ${action} — ${file}" \
      "Dotyczy CAŁEGO serwera (nie per strona)." --yes "${plan[@]}" || return 1
  else
    hm_confirm_plan "waf rule-file ${action} — ${file}" \
      "Dotyczy CAŁEGO serwera (nie per strona)." "${plan[@]}" || return 1
  fi

  case "${action}" in
    disable|off)
      [[ -f "${confpath}" ]] || { hm_info "Już wyłączony."; return 0; }
      mv -f -- "${confpath}" "${confpath}.disabled" || return 1
      ;;
    enable|on)
      [[ -f "${confpath}.disabled" ]] || { hm_info "Już włączony / brak .disabled."; return 0; }
      mv -f -- "${confpath}.disabled" "${confpath}" || return 1
      ;;
  esac
  hm_ols_reload_soft || hm_warn "ols reload nieudany"
  hm_ok "rule-file ${action}: ${file}"
}

# --- per-site whitelist ---

hm_waf_exclusion_id() {
  # ID użytkownika poza zakresem OWASP CRS (konwencja CRS: 1_000_000+)
  local domain="$1" rule="$2" uri="${3:-}"
  local h excl used eid n
  h="$(printf '%s:%s:%s' "${domain}" "${rule}" "${uri}" | cksum 2>/dev/null | awk '{print $1}')"
  [[ -n "${h}" ]] || h=1
  eid="$((1000000 + (h % 900000)))" # 1000000–1899999
  excl="$(hm_waf_exclusions_file)"
  used="|"
  if [[ -f "${excl}" ]]; then
    while IFS= read -r n; do
      [[ -n "${n}" ]] && used+="${n}|"
    done < <(grep -oE 'id:[0-9]+' "${excl}" 2>/dev/null | sed 's/^id://' || true)
  fi
  n=0
  while [[ "${used}" == *"|${eid}|"* && "${n}" -lt 500 ]]; do
    eid=$((eid + 1))
    [[ "${eid}" -gt 1999999 ]] && eid=1000000
    n=$((n + 1))
  done
  printf '%s' "${eid}"
}

hm_waf_ensure_exclusions_include() {
  local excl mc owasp before
  excl="$(hm_waf_exclusions_file)"
  mkdir -p "$(dirname "${excl}")"
  [[ -f "${excl}" ]] || printf '# hmtools waf exclusions — zarządzane przez: waf whitelist\n' > "${excl}"

  # dołącz do REQUEST-900 lub modsec.conf jeśli jeszcze nie
  owasp="$(hm_waf_owasp_dir 2>/dev/null || true)"
  before=""
  if [[ -n "${owasp}" && -f "${owasp}/rules/REQUEST-900-EXCLUSION-RULES-BEFORE-CRS.conf" ]]; then
    before="${owasp}/rules/REQUEST-900-EXCLUSION-RULES-BEFORE-CRS.conf"
  elif [[ -n "${owasp}" && -f "${owasp}/rules/RESPONSE-999-EXCLUSION-RULES-AFTER-CRS.conf" ]]; then
    before="${owasp}/rules/RESPONSE-999-EXCLUSION-RULES-AFTER-CRS.conf"
  fi
  if [[ -n "${before}" ]]; then
    if ! grep -qF 'hmtools-exclusions.conf' "${before}" 2>/dev/null; then
      {
        echo
        echo "# hmtools — include site exclusions"
        echo "Include ${excl}"
      } >> "${before}"
    fi
    return 0
  fi
  mc="$(hm_waf_modsec_conf 2>/dev/null || true)"
  if [[ -n "${mc}" ]] && ! grep -qF 'hmtools-exclusions.conf' "${mc}" 2>/dev/null; then
    echo "Include ${excl}" >> "${mc}"
  fi
}

hm_waf_vhconf_block_body() {
  local domain="$1"
  shift || true
  local -a rules=("$@")
  local r lines=""
  for r in "${rules[@]}"; do
    [[ -n "${r}" ]] || continue
    lines+="SecRuleRemoveById ${r}"$'\n'
  done
  cat <<EOF
module mod_security {
  modsecurity on
  modsecurity_rules \`
# hmtools waf whitelist for ${domain}
${lines}\`
}
EOF
}

hm_waf_whitelist_list_ids() {
  # Zwraca ruleId lub ruleId@uri (źródło: exclusions; fallback vhconf).
  local domain="$1" excl
  excl="$(hm_waf_exclusions_file)"
  if [[ -f "${excl}" ]]; then
    awk -v d="${domain}" '
      $0 ~ ("# --- " d " BEGIN ---") {p=1; next}
      $0 ~ ("# --- " d " END ---") {p=0; next}
      !p { next }
      /SecRule REQUEST_URI/ {
        uri=""
        if (match($0, /@beginsWith[[:space:]]+[^"]+/)) {
          uri=substr($0, RSTART, RLENGTH)
          sub(/^@beginsWith[[:space:]]+/, "", uri)
        }
        getline
        if (match($0, /ctl:ruleRemoveById=[0-9]+/)) {
          id=substr($0, RSTART, RLENGTH)
          sub(/ctl:ruleRemoveById=/, "", id)
          if (uri != "") print id "@" uri
          else print id
        }
        next
      }
      /ctl:ruleRemoveById=/ {
        line=$0
        while (match(line, /ctl:ruleRemoveById=[0-9]+/)) {
          id=substr(line, RSTART, RLENGTH)
          sub(/ctl:ruleRemoveById=/, "", id)
          print id
          line=substr(line, RSTART+RLENGTH)
        }
      }
    ' "${excl}"
    return 0
  fi
  local conf
  conf="$(hm_vhost_conf_path "${domain}" 2>/dev/null || true)"
  if [[ -n "${conf}" && -f "${conf}" ]] && hm_ols_vhost_has_block "${conf}" "waf" 2>/dev/null; then
    awk '
      /# hmtools:waf BEGIN/{p=1;next}
      /# hmtools:waf END/{p=0;next}
      p && /SecRuleRemoveById/ { print $2 }
    ' "${conf}"
  fi
}

hm_waf_whitelist_apply() {
  local domain="$1"
  shift || true
  local yes=0
  if [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]]; then
    yes=1
    shift || true
  fi
  [[ "${HMTOOLS_WAF_YES:-0}" == "1" ]] && yes=1
  local -a ids=("$@")
  local conf tmp body excl eid
  # ids may include uri tagged as id@uri
  conf="$(hm_vhost_conf_path "${domain}" 2>/dev/null || hm_ols_vhost_conf_for "${domain}" 2>/dev/null || true)"
  [[ -n "${conf}" && -f "${conf}" ]] || {
    hm_err "Brak vhconf dla ${domain}."
    return 1
  }

  local item id uri
  declare -A uri_for=()
  local -a order=()
  local seen="|"
  for item in "${ids[@]}"; do
    [[ -n "${item}" ]] || continue
    if [[ "${item}" == *@* ]]; then
      id="${item%%@*}"
      uri="${item#*@}"
    else
      id="${item}"
      uri=""
    fi
    [[ -n "${id}" ]] || continue
    if [[ "${seen}" != *"|${id}|"* ]]; then
      seen+="${id}|"
      order+=("${id}")
    fi
    # Późniejszy wpis z URI wygrywa tylko gdy podano URI; pusty nie kasuje istniejącego URI.
    if [[ -n "${uri}" ]]; then
      uri_for["${id}"]="${uri}"
    elif [[ -z "${uri_for[${id}]+x}" ]]; then
      uri_for["${id}"]=""
    fi
  done

  excl="$(hm_waf_exclusions_file)"
  mkdir -p "$(dirname "${excl}")"
  [[ -f "${excl}" ]] || printf '# hmtools waf exclusions — zarządzane przez: waf whitelist\n' > "${excl}"

  local tmp_excl new_excl
  tmp_excl="$(hm_mktemp .excl)"
  new_excl="$(hm_mktemp .exclnew)"
  awk -v d="${domain}" '
    $0 ~ ("# --- " d " BEGIN ---") {skip=1; next}
    $0 ~ ("# --- " d " END ---") {skip=0; next}
    skip { next }
    { print }
  ' "${excl}" > "${tmp_excl}"

  {
    cat "${tmp_excl}"
    echo "# --- ${domain} BEGIN ---"
    local esc_dom
    esc_dom="$(printf '%s' "${domain}" | sed 's/\./\\./g')"
    for id in "${order[@]}"; do
      uri="${uri_for[${id}]:-}"
      eid="$(hm_waf_exclusion_id "${domain}" "${id}" "${uri}")"
      if [[ -n "${uri}" ]]; then
        printf 'SecRule SERVER_NAME "@rx ^(?i)(www\\.)?%s$" \\\n' "${esc_dom}"
        printf '  "id:%s,phase:1,pass,nolog,chain"\n' "${eid}"
        printf 'SecRule REQUEST_URI "@beginsWith %s" \\\n' "${uri}"
        printf '  "ctl:ruleRemoveById=%s"\n' "${id}"
      else
        printf 'SecRule SERVER_NAME "@rx ^(?i)(www\\.)?%s$" \\\n' "${esc_dom}"
        printf '  "id:%s,phase:1,pass,nolog,ctl:ruleRemoveById=%s"\n' "${eid}" "${id}"
      fi
    done
    echo "# --- ${domain} END ---"
  } > "${new_excl}"

  # vhconf block (dokumentacja + SecRuleRemoveById)
  body="$(hm_waf_vhconf_block_body "${domain}" "${order[@]}")"
  tmp="$(hm_mktemp .vhconf)"
  hm_ols_vhost_strip_block "${conf}" "waf" "${tmp}"
  {
    cat "${tmp}"
    echo "# hmtools:waf BEGIN"
    printf '%s\n' "${body}"
    echo "# hmtools:waf END"
  } > "${tmp}.new"
  mv "${tmp}.new" "${tmp}"

  local -a plan=(
    "Kopia ${excl} + zapis SecRule SERVER_NAME / REQUEST_URI"
    "Aktualizacja # hmtools:waf w vhconf (SecRuleRemoveById)"
    "Include exclusions w CRS/modsec (jeśli brak)"
    "ols reload"
  )
  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "waf whitelist — ${domain}" \
      "Błąd → rollback vhconf i exclusions." --yes "${plan[@]}" || {
      rm -f "${tmp}" "${tmp_excl}" "${new_excl}"
      return 1
    }
  else
    hm_confirm_plan "waf whitelist — ${domain}" \
      "Błąd → rollback vhconf i exclusions." "${plan[@]}" || {
      rm -f "${tmp}" "${tmp_excl}" "${new_excl}"
      return 1
    }
  fi

  local excl_bak conf_sum_before
  excl_bak="${excl}.hmtools.bak.$$"
  cp -a "${excl}" "${excl_bak}" 2>/dev/null || true
  conf_sum_before="$(cksum "${conf}" 2>/dev/null | awk '{print $1}')"

  # 1) exclusions dopiero PO potwierdzeniu
  if ! cat "${new_excl}" > "${excl}"; then
    hm_err "Nie udało się zapisać exclusions."
    rm -f "${tmp}" "${tmp_excl}" "${new_excl}" "${excl_bak}"
    return 1
  fi
  hm_waf_ensure_exclusions_include || true

  # 2) vhconf (bez drugiego promptu)
  export HM_OLS_VHOST_YES=1
  if ! hm_ols_vhost_apply_tmp "${domain}" "${conf}" "${tmp}" \
    "waf whitelist — ${domain}" \
    "Aktualizacja # hmtools:waf w vhconf (SecRuleRemoveById)" \
    "ols reload"; then
    unset HM_OLS_VHOST_YES
    hm_warn "Rollback exclusions z kopii."
    [[ -f "${excl_bak}" ]] && cat "${excl_bak}" > "${excl}"
    rm -f "${tmp}" "${tmp_excl}" "${new_excl}" "${excl_bak}"
    return 1
  fi
  unset HM_OLS_VHOST_YES

  local conf_sum_after
  conf_sum_after="$(cksum "${conf}" 2>/dev/null | awk '{print $1}')"
  if [[ "${conf_sum_before}" == "${conf_sum_after}" ]] \
    && ! grep -qF '# hmtools:waf BEGIN' "${conf}" 2>/dev/null; then
    # apply_tmp anulowany mimo --yes? przywróć exclusions
    [[ -f "${excl_bak}" ]] && cat "${excl_bak}" > "${excl}"
    rm -f "${tmp}" "${tmp_excl}" "${new_excl}" "${excl_bak}"
    return 1
  fi

  rm -f "${tmp}" "${tmp_excl}" "${new_excl}" "${excl_bak}"
  return 0
}

hm_waf_site_status() {
  local domain="${HM_SITE_DOMAIN:-}"
  [[ -n "${domain}" ]] || { hm_err "Kontekst strony wymagany."; return 1; }
  echo "${C_BOLD}WAF — ${domain}${C_RESET}"
  echo
  echo "${C_BOLD}Whitelist (hmtools)${C_RESET}"
  local id any=0
  while IFS= read -r id; do
    [[ -n "${id}" ]] || continue
    echo "  SecRuleRemoveById / ctl: ${id}"
    any=1
  done < <(hm_waf_whitelist_list_ids "${domain}" | sort -u)
  [[ "${any}" -eq 1 ]] || echo "  (brak)"
  echo
  echo "${C_BOLD}Ostatnie blokady (audit, host exact)${C_RESET}"
  hm_waf_log_cmd 15 --domain "${domain}"
}

hm_waf_whitelist_cmd() {
  local sub="${1:-list}"
  shift || true
  local domain="${HM_SITE_DOMAIN:-}"
  [[ -n "${domain}" ]] || { hm_err "Użycie w kontekście: use <domena> → waf whitelist …"; return 1; }

  case "${sub}" in
    list|ls|"")
      echo "${C_BOLD}waf whitelist — ${domain}${C_RESET}"
      local id any=0
      while IFS= read -r id; do
        [[ -n "${id}" ]] || continue
        echo "  ${id}"
        any=1
      done < <(hm_waf_whitelist_list_ids "${domain}" | sort -u)
      [[ "${any}" -eq 1 ]] || echo "  (brak)"
      return 0
      ;;
    remove|rm|del)
      local rid="${1:-}" yes=0
      shift || true
      [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && yes=1
      [[ -n "${rid}" && "${rid}" =~ ^[0-9]+$ ]] || {
        hm_err "Użycie: waf whitelist remove <ruleId>"
        return 1
      }
      local -a keep=()
      local id base
      while IFS= read -r id; do
        [[ -n "${id}" ]] || continue
        base="${id%%@*}"
        [[ "${base}" != "${rid}" ]] && keep+=("${id}")
      done < <(hm_waf_whitelist_list_ids "${domain}" | sort -u)
      if [[ "${#keep[@]}" -eq 0 ]]; then
        local conf tmp excl new_excl excl_bak
        conf="$(hm_vhost_conf_path "${domain}" 2>/dev/null || true)"
        [[ -n "${conf}" ]] || return 1
        tmp="$(hm_mktemp .vhconf)"
        hm_ols_vhost_strip_block "${conf}" "waf" "${tmp}"
        excl="$(hm_waf_exclusions_file)"
        new_excl="$(hm_mktemp .excl)"
        if [[ -f "${excl}" ]]; then
          awk -v d="${domain}" '
            $0 ~ ("# --- " d " BEGIN ---") {skip=1; next}
            $0 ~ ("# --- " d " END ---") {skip=0; next}
            skip { next }
            { print }
          ' "${excl}" > "${new_excl}"
        else
          : > "${new_excl}"
        fi
        local -a plan=(
          "Usunięcie reguły ${rid} / pusty whitelist"
          "Aktualizacja exclusions + vhconf"
          "ols reload"
        )
        if [[ "${yes}" -eq 1 ]]; then
          hm_confirm_plan "waf whitelist remove ${rid} — ${domain}" "" --yes "${plan[@]}" || {
            rm -f "${tmp}" "${new_excl}"; return 1
          }
        else
          hm_confirm_plan "waf whitelist remove ${rid} — ${domain}" "" "${plan[@]}" || {
            rm -f "${tmp}" "${new_excl}"; return 1
          }
        fi
        excl_bak="${excl}.hmtools.bak.$$"
        [[ -f "${excl}" ]] && cp -a "${excl}" "${excl_bak}" 2>/dev/null || true
        cat "${new_excl}" > "${excl}" 2>/dev/null || true
        export HM_OLS_VHOST_YES=1
        if ! hm_ols_vhost_apply_tmp "${domain}" "${conf}" "${tmp}" \
          "waf whitelist remove ${rid} — ${domain}" \
          "Usunięcie reguły ${rid} / pusty whitelist" \
          "ols reload"; then
          unset HM_OLS_VHOST_YES
          [[ -f "${excl_bak}" ]] && cat "${excl_bak}" > "${excl}"
          rm -f "${tmp}" "${new_excl}" "${excl_bak}"
          return 1
        fi
        unset HM_OLS_VHOST_YES
        rm -f "${tmp}" "${new_excl}" "${excl_bak}"
      else
        if [[ "${yes}" -eq 1 ]]; then
          hm_waf_whitelist_apply "${domain}" --yes "${keep[@]}"
        else
          hm_waf_whitelist_apply "${domain}" "${keep[@]}"
        fi
      fi
      return $?
      ;;
    add|"")
      : ;;
  esac

  # add: waf whitelist 949110 [--uri /path]
  local rid="" uri="" yes=0 a
  if [[ "${sub}" =~ ^[0-9]+$ ]]; then
    rid="${sub}"
  else
    case "${sub}" in
      add) ;;
      *)
        hm_err "Użycie: waf whitelist <ruleId> [--uri /path] | list | remove <id>"
        return 1
        ;;
    esac
  fi
  while [[ $# -gt 0 ]]; do
    a="$1"; shift || true
    case "${a}" in
      --uri) uri="${1:-}"; shift || true ;;
      --uri=*) uri="${a#--uri=}" ;;
      --yes|-y) yes=1 ;;
      help|-h|--help)
        echo "Użycie: waf whitelist <ruleId> [--uri /path] [--yes]"
        return 0
        ;;
      *)
        if [[ -z "${rid}" && "${a}" =~ ^[0-9]+$ ]]; then rid="${a}"
        else hm_err "Nieznany argument: ${a}"; return 1
        fi
        ;;
    esac
  done
  [[ -n "${rid}" && "${rid}" =~ ^[0-9]+$ ]] || {
    hm_err "Użycie: waf whitelist <ruleId> [--uri /path]"
    return 1
  }

  local -a cur=()
  local id base existing_uri
  while IFS= read -r id; do
    [[ -n "${id}" ]] && cur+=("${id}")
  done < <(hm_waf_whitelist_list_ids "${domain}" | sort -u)
  # idempotent / aktualizacja URI dla tego samego ruleId
  local -a next=()
  local found=0
  for id in "${cur[@]:-}"; do
    base="${id%%@*}"
    if [[ "${id}" == *@* ]]; then existing_uri="${id#*@}"; else existing_uri=""; fi
    if [[ "${base}" == "${rid}" ]]; then
      found=1
      if [[ -n "${uri}" ]]; then
        if [[ "${existing_uri}" == "${uri}" ]]; then
          hm_info "Reguła ${rid} (@ ${uri}) już na whiteliście — brak zmian."
          return 0
        fi
        next+=("${rid}@${uri}")
      else
        if [[ -z "${existing_uri}" ]]; then
          hm_info "Reguła ${rid} już na whiteliście — brak zmian."
          return 0
        fi
        # bez --uri przy istniejącym @uri → zostaw (nie rozszerzaj na całą domenę)
        next+=("${id}")
        hm_info "Reguła ${rid} już z zakresem URI (${existing_uri}) — brak zmian (podaj ten sam --uri lub remove)."
        return 0
      fi
    else
      next+=("${id}")
    fi
  done
  if [[ "${found}" -eq 0 ]]; then
    if [[ -n "${uri}" ]]; then
      next+=("${rid}@${uri}")
    else
      next+=("${rid}")
    fi
  fi
  if [[ "${yes}" -eq 1 ]]; then
    hm_waf_whitelist_apply "${domain}" --yes "${next[@]}"
  else
    hm_waf_whitelist_apply "${domain}" "${next[@]}"
  fi
}

cmd_waf() {
  local sub="${1:-}"
  shift || true
  case "${sub}" in
    ""|status|show)
      hm_waf_site_status
      ;;
    whitelist|wl|allow)
      hm_waf_whitelist_cmd "$@"
      ;;
    log)
      hm_waf_log_cmd --domain "${HM_SITE_DOMAIN}" "$@"
      ;;
    help|-h|--help)
      hm_help_topic waf
      ;;
    *)
      hm_err "Użycie: waf | waf whitelist … | waf log"
      return 1
      ;;
  esac
}

hm_waf_install_cmd() {
  local yes=0
  [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && yes=1
  local py="/usr/local/CyberCP/bin/python"
  local mod="/usr/local/CyberCP/plogical/modSec.py"
  if [[ ! -x "${py}" || ! -f "${mod}" ]]; then
    hm_err "Brak CyberPanel modSec.py — zainstaluj ModSecurity z panelu (Security → ModSecurity)."
    return 1
  fi
  local -a plan=(
    "Delegacja: ${py} ${mod} (installCompatibleModSecurity / setupOWASPRules)"
    "ols soft-reload"
  )
  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "security waf install" \
      "Instalacja ModSecurity + OWASP przez CyberPanel (nie własny download)." --yes "${plan[@]}" || return 1
  else
    hm_confirm_plan "security waf install" \
      "Instalacja ModSecurity + OWASP przez CyberPanel (nie własny download)." "${plan[@]}" || return 1
  fi
  # CyberPanel API bywa funkcjami w module — wywołanie CLI jeśli istnieje
  if hm_have_cmd cyberpanel; then
    hm_run_timeout 600 cyberpanel install_modsecurity 2>/dev/null \
      || hm_warn "cyberpanel install_modsecurity niedostępne — użyj UI Security → ModSecurity"
  else
    hm_warn "Brak CLI cyberpanel — włącz ModSecurity w panelu (Security → ModSecurity → Install)."
  fi
  hm_ols_reload_soft || true
  hm_waf_status
}

cmd_security_waf() {
  local sub="${1:-}"
  shift || true
  case "${sub}" in
    ""|status|stat)
      hm_waf_status
      ;;
    log|audit)
      hm_waf_log_cmd "$@"
      ;;
    mode|engine)
      hm_waf_mode_cmd "$@"
      ;;
    rules|rule)
      hm_waf_rules_list "$@"
      ;;
    rule-file|rulefile)
      local act="${1:-}"
      shift || true
      hm_waf_rule_file_toggle "${act}" "$@"
      ;;
    install)
      hm_waf_install_cmd "$@"
      ;;
    help|-h|--help)
      hm_help_topic waf
      ;;
    *)
      hm_err "Użycie: security waf [status|log|mode|rules|rule-file|install] — help: security waf help"
      return 1
      ;;
  esac
}

_hm_cmd_register_site waf cmd_waf
