#!/usr/bin/env bash
# OLS vhost: show / edit / rollback + rewrite/headers presets + cache settings
# Zapis vhconf: cp -a bak + cat > (nigdy mv z mktemp) — zachowanie mode/owner.


_hm_cmd_help vhost <<'EOF'
Użycie (kontekst strony lub z domeną):
  vhost show [--section rewrite|context|extprocessor|module]
  vhost edit
  vhost rollback [<stamp>|list]

Edycja: kopia → $EDITOR → diff → potwierdzenie → zapis (z bak.hmtools.<stamp>,
retencja 10) → ols reload → sprawdzenie error.log (+ opcjonalny curl) → rollback
przy błędzie. Nie nadpisuje bloków CyberPanel bez ostrzeżenia.
EOF

_hm_cmd_help rewrite <<'EOF'
Użycie (kontekst strony):
  rewrite preset https|www|non-www|spa
  rewrite preset remove <nazwa>
  rewrite preset list

Presety jako bloki # hmtools:rewrite-<nazwa> (idempotentne).
EOF

_hm_cmd_help headers <<'EOF'
Użycie (kontekst strony):
  headers preset security [--hsts]
  headers preset remove security
  headers show

Nagłówki bezpieczeństwa w bloku # hmtools:headers-security (extraHeaders).
EOF

# --- ścieżki / backup --------------------------------------------------------

hm_ols_vhost_conf_for() {
  local domain="${1:-${HM_SITE_DOMAIN:-}}"
  local conf="${2:-${HM_SITE_VHOST:-}}"
  [[ -n "${domain}" ]] || { hm_err "Podaj domenę lub use <domena>."; return 1; }
  if [[ -z "${conf}" || ! -f "${conf}" ]]; then
    conf="$(hm_vhost_conf_path "${domain}" 2>/dev/null || true)"
  fi
  [[ -n "${conf}" && -f "${conf}" ]] || { hm_err "Brak vhconf dla ${domain}."; return 1; }
  printf '%s' "${conf}"
}

hm_ols_vhost_stamp() {
  date +%Y%m%d%H%M%S
}

hm_ols_vhost_backup_list() {
  local conf="$1"
  local d base
  d="$(dirname "${conf}")"
  base="$(basename "${conf}")"
  # shellcheck disable=SC2012
  ls -1t "${d}/${base}.hmtools."* 2>/dev/null | head -20 || true
}

hm_ols_vhost_backup_prune() {
  local conf="$1"
  local keep="${2:-10}"
  local f i=0
  while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    i=$((i + 1))
    if [[ "${i}" -gt "${keep}" ]]; then
      rm -f "${f}" 2>/dev/null || true
    fi
  done < <(hm_ols_vhost_backup_list "${conf}")
}

# Tworzy conf.hmtools.<stamp> (+ legacy .hmtools.bak). Echo ścieżki stamp.
hm_ols_vhost_backup() {
  local conf="$1"
  local stamp="${2:-$(hm_ols_vhost_stamp)}"
  local dest="${conf}.hmtools.${stamp}"
  if ! cp -a "${conf}" "${dest}"; then
    hm_err "Nie udało się utworzyć kopii ${dest}"
    return 1
  fi
  cp -a "${conf}" "${conf}.hmtools.bak" 2>/dev/null || true
  hm_ols_vhost_backup_prune "${conf}" 10
  printf '%s' "${dest}"
}

# Zapis treści z pliku src do conf — zachowuje mode/owner (cat >, nie mv).
hm_ols_vhost_write() {
  local conf="$1" src="$2"
  [[ -f "${conf}" && -f "${src}" ]] || return 1
  if ! cat "${src}" > "${conf}"; then
    hm_err "Zapis vhconf nieudany: ${conf}"
    return 1
  fi
  return 0
}

hm_ols_vhost_warn_cp() {
  local conf="$1"
  if grep -qE 'cyberpanel|CyberPanel|#.*?PHP|#.*?SSL' "${conf}" 2>/dev/null; then
    hm_warn "vhconf wygląda na zarządzany przez CyberPanel — zmiana PHP/SSL w panelu może nadpisać ręczne edycje."
  fi
}

# Usuwa blok # hmtools:NAME BEGIN … # hmtools:NAME END (włącznie).
hm_ols_vhost_strip_block() {
  local src="$1" name="$2" dest="$3"
  awk -v n="${name}" '
    BEGIN { skip=0; begin="# hmtools:" n " BEGIN"; end="# hmtools:" n " END" }
    index($0, begin) { skip=1; next }
    index($0, end) { skip=0; next }
    skip { next }
    { print }
  ' "${src}" > "${dest}"
}

# Wstawia blok na końcu pliku (po strip).
hm_ols_vhost_append_block() {
  local dest="$1" name="$2"
  shift 2
  {
    echo "# hmtools:${name} BEGIN"
    printf '%s\n' "$@"
    echo "# hmtools:${name} END"
  } >> "${dest}"
}

hm_ols_vhost_has_block() {
  local conf="$1" name="$2"
  grep -qF "# hmtools:${name} BEGIN" "${conf}" 2>/dev/null
}

# --- walidacja / HTTP --------------------------------------------------------

hm_ols_vhost_config_test() {
  # openlitespeed -t jeśli wspiera; inaczej 0 (brak testu składni)
  local bin="${OLS_BIN:-}"
  [[ -n "${bin}" && -x "${bin}" ]] || return 0
  if "${bin}" -t >/dev/null 2>&1; then
    return 0
  fi
  # wiele buildów OLS nie ma -t — nie traktuj jako błąd
  return 0
}

hm_ols_vhost_errorlog_tail_errors() {
  # wypisz nowe linie ERROR/CRIT z error.log po znaczniku czasu (epoch)
  local since_epoch="${1:-0}"
  local logf="${OLS_ROOT:-/usr/local/lsws}/logs/error.log"
  [[ -f "${logf}" ]] || return 0
  awk -v since="${since_epoch}" '
    BEGIN { bad=0 }
    {
      # OLS: YYYY-MM-DD HH:MM:SS.mmm ...
      if (match($0, /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
        ts=substr($0,1,19)
        gsub(/[-:]/," ",ts)
        epoch=mktime(ts " 0")
        if (epoch < since) next
      }
      if ($0 ~ /\[ERROR\]|\[CRIT\]|parse error|config error|Syntax error|Failed to/i) {
        print
        bad=1
      }
    }
    END { exit bad }
  ' "${logf}" 2>/dev/null || true
}

hm_ols_vhost_http_probe() {
  local domain="$1"
  # opcjonalnie: oczekiwany kod (np. 503 po suspend) lub "any" / puste = domyślnie błąd przy 5xx
  local expect="${2:-${HM_OLS_ACCEPT_HTTP:-}}"
  hm_have_cmd curl || return 0
  # lokalny resolve na 127.0.0.1 — nie wymaga DNS
  local code
  code="$(curl -sk --max-time 5 --resolve "${domain}:443:127.0.0.1" \
    -o /dev/null -w '%{http_code}' "https://${domain}/" 2>/dev/null || echo 000)"
  case "${code}" in
    000|5??)
      code="$(curl -sk --max-time 5 --resolve "${domain}:80:127.0.0.1" \
        -o /dev/null -w '%{http_code}' "http://${domain}/" 2>/dev/null || echo 000)"
      ;;
  esac
  if [[ -n "${expect}" && "${expect}" != "any" && "${code}" == "${expect}" ]]; then
    hm_info "HTTP probe: ${domain} → HTTP ${code} (oczekiwane)"
    return 0
  fi
  if [[ "${expect}" == "any" ]]; then
    hm_info "HTTP probe: ${domain} → HTTP ${code} (bez walidacji)"
    return 0
  fi
  case "${code}" in
    000)
      hm_warn "HTTP probe: brak odpowiedzi (curl) — nie rollback tylko z tego powodu."
      return 0
      ;;
    5??)
      hm_err "HTTP probe: ${domain} → HTTP ${code}"
      return 1
      ;;
    *)
      hm_info "HTTP probe: ${domain} → HTTP ${code}"
      return 0
      ;;
  esac
}

# Zastosuj tmp → conf z backupem, reload, walidacja; przy failu restore stamp.
hm_ols_vhost_apply_tmp() {
  local domain="$1" conf="$2" tmp="$3"
  local title="${4:-vhost apply — ${domain}}"
  shift 4 || true
  local -a plan_steps=("$@")

  hm_ols_vhost_warn_cp "${conf}"

  if [[ "${#plan_steps[@]}" -eq 0 ]]; then
    plan_steps=(
      "Kopia ${conf}.hmtools.<stamp> (retencja 10)"
      "Zapis vhconf (zachowanie uprawnień/właściciela)"
      "ols reload + sprawdzenie error.log"
      "Probe HTTP lokalny (curl --resolve)"
    )
  fi

  if [[ "${HM_OLS_VHOST_YES:-0}" == "1" ]]; then
    if ! hm_confirm_plan "${title}" \
      "Błąd składni → automatyczny rollback z kopii." \
      --yes "${plan_steps[@]}"; then
      return 0
    fi
  else
    if ! hm_confirm_plan "${title}" \
      "Błąd składni → automatyczny rollback z kopii." \
      "${plan_steps[@]}"; then
      return 0
    fi
  fi

  local stamp bak before_epoch err_out
  stamp="$(hm_ols_vhost_stamp)"
  bak="$(hm_ols_vhost_backup "${conf}" "${stamp}")" || return 1
  hm_info "Backup: ${bak}"

  before_epoch="$(date +%s)"
  # mały bufor wstecz — logi z sekundy reload
  before_epoch=$((before_epoch - 1))

  if ! hm_ols_vhost_write "${conf}" "${tmp}"; then
    return 1
  fi

  hm_ols_vhost_config_test || true

  if ! hm_ols_reload_soft; then
    hm_err "ols reload nieudany — rollback."
    cat "${bak}" > "${conf}"
    hm_ols_reload_soft || true
    return 1
  fi
  hm_ok "OLS reload OK."

  sleep 0.3 2>/dev/null || true
  err_out="$(hm_ols_vhost_errorlog_tail_errors "${before_epoch}" 2>/dev/null || true)"
  if [[ -n "${err_out}" ]]; then
    hm_err "Wykryto błędy w error.log po reload — rollback."
    printf '%s\n' "${err_out}" | head -20
    cat "${bak}" > "${conf}"
    hm_ols_reload_soft || true
    hm_ok "Przywrócono ${bak}"
    return 1
  fi

  if ! hm_ols_vhost_http_probe "${domain}"; then
    hm_err "HTTP 5xx po zmianie — rollback."
    cat "${bak}" > "${conf}"
    hm_ols_reload_soft || true
    hm_ok "Przywrócono ${bak}"
    return 1
  fi

  hm_ok "Zastosowano zmiany vhconf (${domain})."
  return 0
}

# --- show / edit / rollback --------------------------------------------------

hm_ols_vhost_show_section() {
  local conf="$1" section="$2"
  case "${section}" in
    ""|all|full)
      cat "${conf}"
      ;;
    rewrite|context|extprocessor|module)
      awk -v sec="${section}" '
        BEGIN { depth=0; show=0 }
        {
          low=$0
          # start bloku (case-insensitive prefix)
          if (show==0) {
            if (sec=="module") {
              if ($0 ~ /^[ \t]*[Mm][Oo][Dd][Uu][Ll][Ee][ \t]/) show=1
            } else if (index(tolower($1), sec)==1 && length($1)==length(sec)) {
              show=1
            } else if (tolower($1)==sec) {
              show=1
            }
          }
          if (show) {
            print
            o = gsub(/\{/, "{")
            c = gsub(/\}/, "}")
            depth += o - c
            if (depth <= 0) { show=0; depth=0 }
          }
        }
      ' "${conf}"
      ;;
    *)
      hm_err "Nieznana sekcja: ${section} (rewrite|context|extprocessor|module)"
      return 1
      ;;
  esac
}

cmd_vhost() {
  local sub="${1:-show}"
  shift || true
  local domain="${HM_SITE_DOMAIN:-}"
  local conf=""

  # opcjonalna domena jako 1. arg gdy nie w kontekście
  if [[ -n "${1:-}" ]] && hm_is_valid_domain "${1}" 2>/dev/null; then
    domain="${1}"
    shift || true
  fi

  case "${sub}" in
    show|cat|print)
      local section=""
      while [[ $# -gt 0 ]]; do
        case "${1}" in
          --section|-s) section="${2:-}"; shift 2 || true ;;
          --section=*) section="${1#*=}"; shift ;;
          rewrite|context|extprocessor|module) section="${1}"; shift ;;
          *)
            if hm_is_valid_domain "${1}" 2>/dev/null; then
              domain="${1}"; shift
            else
              hm_err "Nieznany argument: ${1}"; return 1
            fi
            ;;
        esac
      done
      conf="$(hm_ols_vhost_conf_for "${domain}")" || return 1
      echo "${C_BOLD}vhconf — ${domain}${C_RESET}  ${C_DIM}${conf}${C_RESET}"
      hm_ols_vhost_show_section "${conf}" "${section}"
      ;;
    edit|e)
      if [[ -n "${1:-}" ]] && hm_is_valid_domain "${1}" 2>/dev/null; then
        domain="${1}"
      fi
      conf="$(hm_ols_vhost_conf_for "${domain}")" || return 1
      local editor="${EDITOR:-${VISUAL:-}}"
      if [[ -z "${editor}" ]]; then
        if hm_have_cmd nano; then editor=nano
        elif hm_have_cmd vi; then editor=vi
        else
          hm_err "Brak EDITOR/VISUAL/nano/vi."
          return 1
        fi
      fi
      local tmp mode_before
      tmp="$(hm_mktemp .vhconf)"
      cp -a "${conf}" "${tmp}"
      mode_before="$(stat -c '%a' "${conf}" 2>/dev/null || echo "")"
      hm_info "Edycja kopii: ${tmp}"
      # shellcheck disable=SC2086
      if ! hm_run_on_tty ${editor} "${tmp}"; then
        hm_warn "Edytor zakończył się kodem ≠0 — kontynuuję jeśli plik zmieniony."
      fi
      if cmp -s "${conf}" "${tmp}"; then
        hm_info "Brak zmian — anulowano."
        rm -f "${tmp}"
        return 0
      fi
      echo "${C_BOLD}Diff:${C_RESET}"
      diff -u "${conf}" "${tmp}" | head -200 || true
      if ! hm_ols_vhost_apply_tmp "${domain}" "${conf}" "${tmp}" "vhost edit — ${domain}"; then
        rm -f "${tmp}"
        return 1
      fi
      if [[ -n "${mode_before}" ]]; then
        local mode_after
        mode_after="$(stat -c '%a' "${conf}" 2>/dev/null || echo "")"
        if [[ -n "${mode_after}" && "${mode_after}" != "${mode_before}" ]]; then
          hm_err "Regresja uprawnień: mode ${mode_before} → ${mode_after}"
          rm -f "${tmp}"
          return 1
        fi
      fi
      rm -f "${tmp}"
      ;;
    rollback|restore)
      local stamp="${1:-}"
      if [[ -n "${1:-}" ]] && hm_is_valid_domain "${1}" 2>/dev/null; then
        domain="${1}"
        stamp="${2:-}"
      fi
      conf="$(hm_ols_vhost_conf_for "${domain}")" || return 1
      if [[ "${stamp}" == "list" || "${stamp}" == "ls" || -z "${stamp}" ]]; then
        echo "${C_BOLD}Kopie vhconf — ${domain}${C_RESET}"
        local f
        local any=0
        while IFS= read -r f; do
          [[ -n "${f}" ]] || continue
          any=1
          printf '  %s\n' "$(basename "${f}")"
        done < <(hm_ols_vhost_backup_list "${conf}")
        if [[ "${any}" -eq 0 ]]; then
          if [[ -f "${conf}.hmtools.bak" ]]; then
            echo "  $(basename "${conf}.hmtools.bak")  (legacy)"
          else
            hm_info "Brak kopii .hmtools.*"
          fi
        fi
        [[ -z "${stamp}" ]] && hm_info "Użycie: vhost rollback <stamp>"
        [[ "${stamp}" == "list" || "${stamp}" == "ls" || -z "${stamp}" ]] && return 0
      fi
      local src=""
      if [[ -f "${conf}.hmtools.${stamp}" ]]; then
        src="${conf}.hmtools.${stamp}"
      elif [[ "${stamp}" == "bak" && -f "${conf}.hmtools.bak" ]]; then
        src="${conf}.hmtools.bak"
      elif [[ -f "${stamp}" ]]; then
        src="${stamp}"
      else
        # najnowsza
        src="$(hm_ols_vhost_backup_list "${conf}" | head -1)"
        if [[ -z "${src}" && -f "${conf}.hmtools.bak" ]]; then
          src="${conf}.hmtools.bak"
        fi
      fi
      [[ -n "${src}" && -f "${src}" ]] || { hm_err "Brak kopii do rollback."; return 1; }
      if ! hm_confirm_plan "vhost rollback — ${domain}" \
        "Przywrócenie poprzedniej konfiguracji vhost." \
        "Źródło: ${src}" \
        "Zapis do ${conf} (zachowanie uprawnień)" \
        "ols reload"; then
        return 0
      fi
      # najpierw backup stanu bieżącego
      hm_ols_vhost_backup "${conf}" >/dev/null || true
      if ! cat "${src}" > "${conf}"; then
        hm_err "Rollback zapisu nieudany."
        return 1
      fi
      hm_ols_reload_soft && hm_ok "OLS reload OK." || hm_warn "ols reload nieudany"
      hm_ok "Przywrócono z $(basename "${src}")"
      ;;
    help|-h|--help)
      hm_help_topic vhost
      ;;
    *)
      hm_err "Nieznane: ${sub}. vhost help"
      return 1
      ;;
  esac
}

# --- rewrite presets ---------------------------------------------------------

hm_ols_rewrite_preset_body() {
  local name="$1"
  case "${name}" in
    https)
      cat <<'RULES'
rewrite  {
  enable                  1
  rules                   <<<END_hmtools_https
# hmtools rewrite-https
RewriteCond %{HTTPS} !=on
RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [L,R=301]
  END_hmtools_https
}
RULES
      ;;
    www)
      cat <<'RULES'
rewrite  {
  enable                  1
  rules                   <<<END_hmtools_www
# hmtools rewrite-www
RewriteCond %{HTTP_HOST} !^www\. [NC]
RewriteRule ^ https://www.%{HTTP_HOST}%{REQUEST_URI} [L,R=301]
  END_hmtools_www
}
RULES
      ;;
    non-www)
      cat <<'RULES'
rewrite  {
  enable                  1
  rules                   <<<END_hmtools_nonwww
# hmtools rewrite-non-www
RewriteCond %{HTTP_HOST} ^www\.(.+)$ [NC]
RewriteRule ^ https://%1%{REQUEST_URI} [L,R=301]
  END_hmtools_nonwww
}
RULES
      ;;
    spa)
      cat <<'RULES'
rewrite  {
  enable                  1
  rules                   <<<END_hmtools_spa
# hmtools rewrite-spa
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule ^ index.html [L]
  END_hmtools_spa
}
RULES
      ;;
    *)
      return 1
      ;;
  esac
}

cmd_rewrite() {
  local sub="${1:-}"
  shift || true
  local domain="${HM_SITE_DOMAIN:-}"
  case "${sub}" in
    preset)
      local action="${1:-}"
      shift || true
      [[ -n "${action}" ]] || { hm_err "Użycie: rewrite preset https|www|non-www|spa | remove <n> | list"; return 1; }
      local conf
      conf="$(hm_ols_vhost_conf_for "${domain}")" || return 1
      case "${action}" in
        list|ls)
          echo "${C_BOLD}Presety rewrite (hmtools) — ${domain}${C_RESET}"
          local n
          for n in https www non-www spa; do
            if hm_ols_vhost_has_block "${conf}" "rewrite-${n}"; then
              echo "  [x] rewrite-${n}"
            else
              echo "  [ ] rewrite-${n}"
            fi
          done
          ;;
        remove|rm|off)
          local name="${1:-}"
          [[ -n "${name}" ]] || { hm_err "Użycie: rewrite preset remove <https|www|non-www|spa>"; return 1; }
          name="${name#rewrite-}"
          if ! hm_ols_vhost_has_block "${conf}" "rewrite-${name}"; then
            hm_info "Brak bloku rewrite-${name}."
            return 0
          fi
          local tmp
          tmp="$(hm_mktemp .vhconf)"
          hm_ols_vhost_strip_block "${conf}" "rewrite-${name}" "${tmp}"
          hm_ols_vhost_apply_tmp "${domain}" "${conf}" "${tmp}" \
            "rewrite preset remove ${name} — ${domain}" \
            "Usunięcie bloku # hmtools:rewrite-${name}" \
            "ols reload + walidacja"
          local rc=$?
          rm -f "${tmp}"
          return "${rc}"
          ;;
        https|www|non-www|spa)
          local name="${action}"
          local body tmp
          body="$(hm_ols_rewrite_preset_body "${name}")" || { hm_err "Nieznany preset."; return 1; }
          tmp="$(hm_mktemp .vhconf)"
          hm_ols_vhost_strip_block "${conf}" "rewrite-${name}" "${tmp}"
          {
            cat "${tmp}"
            echo "# hmtools:rewrite-${name} BEGIN"
            printf '%s\n' "${body}"
            echo "# hmtools:rewrite-${name} END"
          } > "${tmp}.new"
          mv "${tmp}.new" "${tmp}"
          hm_ols_vhost_apply_tmp "${domain}" "${conf}" "${tmp}" \
            "rewrite preset ${name} — ${domain}" \
            "Idempotentny blok # hmtools:rewrite-${name}" \
            "ols reload + walidacja"
          local rc=$?
          rm -f "${tmp}"
          return "${rc}"
          ;;
        *)
          hm_err "Nieznany preset: ${action}"
          return 1
          ;;
      esac
      ;;
    help|-h|--help|"")
      hm_help_topic rewrite
      ;;
    *)
      hm_err "Nieznane: ${sub}. rewrite help"
      return 1
      ;;
  esac
}

# --- headers presets ---------------------------------------------------------

hm_ols_headers_security_body() {
  local with_hsts="${1:-0}"
  echo "extraHeaders              <<<END_hmtools_headers"
  echo "X-Frame-Options SAMEORIGIN"
  echo "X-Content-Type-Options nosniff"
  echo "Referrer-Policy strict-origin-when-cross-origin"
  echo "Permissions-Policy geolocation=(), microphone=(), camera=()"
  if [[ "${with_hsts}" == "1" ]]; then
    echo "Strict-Transport-Security max-age=31536000; includeSubDomains"
  fi
  echo "  END_hmtools_headers"
}

cmd_headers() {
  local sub="${1:-show}"
  shift || true
  local domain="${HM_SITE_DOMAIN:-}"
  local conf
  case "${sub}" in
    show|status|"")
      conf="$(hm_ols_vhost_conf_for "${domain}")" || return 1
      echo "${C_BOLD}headers (hmtools) — ${domain}${C_RESET}"
      if hm_ols_vhost_has_block "${conf}" "headers-security"; then
        awk '
          /# hmtools:headers-security BEGIN/{p=1;next}
          /# hmtools:headers-security END/{p=0;next}
          p{print}
        ' "${conf}"
      else
        hm_info "Brak presetu headers-security."
      fi
      ;;
    preset)
      local action="${1:-}"
      shift || true
      conf="$(hm_ols_vhost_conf_for "${domain}")" || return 1
      case "${action}" in
        security)
          local hsts=0
          local a
          for a in "$@"; do
            case "${a}" in
              --hsts|hsts) hsts=1 ;;
            esac
          done
          local tmp body
          tmp="$(hm_mktemp .vhconf)"
          hm_ols_vhost_strip_block "${conf}" "headers-security" "${tmp}"
          body="$(hm_ols_headers_security_body "${hsts}")"
          {
            cat "${tmp}"
            echo "# hmtools:headers-security BEGIN"
            printf '%s\n' "${body}"
            echo "# hmtools:headers-security END"
          } > "${tmp}.new"
          mv "${tmp}.new" "${tmp}"
          hm_ols_vhost_apply_tmp "${domain}" "${conf}" "${tmp}" \
            "headers preset security — ${domain}" \
            "Blok # hmtools:headers-security (XFO, XCTO, Referrer-Policy${hsts:+, HSTS})" \
            "ols reload + walidacja"
          local rc=$?
          rm -f "${tmp}"
          return "${rc}"
          ;;
        remove|rm)
          local name="${1:-security}"
          name="${name#headers-}"
          [[ "${name}" == "security" ]] || { hm_err "Obsługiwane: remove security"; return 1; }
          if ! hm_ols_vhost_has_block "${conf}" "headers-security"; then
            hm_info "Brak bloku headers-security."
            return 0
          fi
          local tmp
          tmp="$(hm_mktemp .vhconf)"
          hm_ols_vhost_strip_block "${conf}" "headers-security" "${tmp}"
          hm_ols_vhost_apply_tmp "${domain}" "${conf}" "${tmp}" \
            "headers preset remove security — ${domain}" \
            "Usunięcie bloku # hmtools:headers-security" \
            "ols reload + walidacja"
          local rc=$?
          rm -f "${tmp}"
          return "${rc}"
          ;;
        *)
          hm_err "Użycie: headers preset security [--hsts] | remove security"
          return 1
          ;;
      esac
      ;;
    help|-h|--help)
      hm_help_topic headers
      ;;
    *)
      hm_err "Nieznane: ${sub}. headers help"
      return 1
      ;;
  esac
}

# --- cache settings ----------------------------------------------------------

hm_ols_cache_settings_apply() {
  local domain="$1"
  local ttl="${2:-}"
  local exclude="${3:-}"
  local conf
  conf="$(hm_ols_vhost_conf_for "${domain}")" || return 1

  local tmp
  tmp="$(hm_mktemp .vhconf)"
  awk -v ttl="${ttl}" -v excl="${exclude}" '
    BEGIN { inmod=0; depth=0; has_ttl=0; has_excl=0; saw=0 }
    {
      if (!inmod && $0 ~ /^[ \t]*module[ \t]+cache([ \t{]|$)/) {
        inmod=1; saw=1; depth=0
        print
        line=$0; o=gsub(/{/,"&",line); c=gsub(/}/,"&",line); depth+=o-c
        next
      }
      if (inmod) {
        line=$0
        if (ttl != "" && tolower($1)=="expireinseconds") {
          print "  expireInSeconds         " ttl
          has_ttl=1
          line=$0; o=gsub(/{/,"&",line); c=gsub(/}/,"&",line); depth+=o-c
          if (depth<=0) {
            inmod=0
          }
          next
        }
        if (excl != "" && ($0 ~ /noCacheUrl/ || $0 ~ /excludes/)) {
          # zachowaj linię; osobny wpis dodamy przed zamknięciem
        }
        if ($0 ~ /^[ \t]*\}/ && depth<=1) {
          if (ttl != "" && !has_ttl) print "  expireInSeconds         " ttl
          if (excl != "" && !has_excl) print "  noCacheUrl              " excl
          print
          inmod=0; depth=0
          next
        }
        print
        line=$0; o=gsub(/{/,"&",line); c=gsub(/}/,"&",line); depth+=o-c
        next
      }
      print
    }
    END {
      if (!saw && (ttl != "" || excl != "")) {
        print "module cache {"
        print "  ls_enabled              1"
        if (ttl != "") print "  expireInSeconds         " ttl
        if (excl != "") print "  noCacheUrl              " excl
        print "}"
      }
    }
  ' "${conf}" > "${tmp}"

  local steps=()
  [[ -n "${ttl}" ]] && steps+=("Ustawienie expireInSeconds=${ttl} w module cache")
  [[ -n "${exclude}" ]] && steps+=("Dodanie noCacheUrl ${exclude}")
  steps+=("ols reload + walidacja")

  hm_ols_vhost_apply_tmp "${domain}" "${conf}" "${tmp}" \
    "cache settings — ${domain}" \
    "${steps[@]}"
  local rc=$?
  rm -f "${tmp}"
  return "${rc}"
}

cmd_site_cache() {
  local sub="${1:-status}"
  shift || true
  case "${sub}" in
    settings|set|config)
      local ttl="" exclude=""
      while [[ $# -gt 0 ]]; do
        case "${1}" in
          --ttl) ttl="${2:-}"; shift 2 || true ;;
          --ttl=*) ttl="${1#*=}"; shift ;;
          --exclude) exclude="${2:-}"; shift 2 || true ;;
          --exclude=*) exclude="${1#*=}"; shift ;;
          help|-h|--help)
            echo "Użycie: cache settings [--ttl 3600] [--exclude /ścieżka]"
            return 0
            ;;
          *)
            hm_err "Nieznany argument: ${1}"
            return 1
            ;;
        esac
      done
      if [[ -z "${ttl}" && -z "${exclude}" ]]; then
        # show current module cache snippet
        local conf
        conf="$(hm_ols_vhost_conf_for "${HM_SITE_DOMAIN}")" || return 1
        echo "${C_BOLD}cache settings — ${HM_SITE_DOMAIN}${C_RESET}"
        hm_ols_vhost_show_section "${conf}" "module" | head -80
        hm_info "Ustaw: cache settings --ttl 3600 [--exclude /koszyk]"
        return 0
      fi
      if [[ -n "${ttl}" ]] && ! [[ "${ttl}" =~ ^[0-9]+$ ]]; then
        hm_err "TTL musi być liczbą sekund."
        return 1
      fi
      hm_ols_cache_settings_apply "${HM_SITE_DOMAIN}" "${ttl}" "${exclude}"
      ;;
    status|show|flush|clear|purge)
      cmd_ols_cache "${sub}" "$@"
      ;;
    help|-h|--help)
      echo "Użycie: cache settings [--ttl N] [--exclude PATH]"
      echo "        cache status|flush   (jak ols cache)"
      ;;
    *)
      cmd_ols_cache "${sub}" "$@"
      ;;
  esac
}

_hm_cmd_register_site vhost cmd_vhost
_hm_cmd_register_site rewrite cmd_rewrite
_hm_cmd_register_site headers cmd_headers
_hm_cmd_register_site cache cmd_site_cache
