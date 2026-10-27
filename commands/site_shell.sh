#!/usr/bin/env bash
# Komendy dostępne w kontekście strony

cmd_site_info() {
  hm_print_site_info "${HM_SITE_DOMAIN}"
}

cmd_site_size() {
  [[ -n "${HM_SITE_DOMAIN}" ]] || { hm_err "Brak kontekstu."; return 1; }
  local root="${HM_SITE_ROOT:-${HM_SITE_DOCROOT}}"
  if [[ -z "${root}" || ! -d "${root}" ]]; then
    hm_err "Brak katalogu strony."
    return 1
  fi
  echo "Środowisko: ${root}"
  echo "Całość: $(hm_format_size_from_path "${root}")"
  if [[ -d "${root}/public_html" ]]; then
    echo "public_html: $(hm_format_size_from_path "${root}/public_html")"
  fi
  if [[ -d "${root}/logs" ]]; then
    echo "logs: $(hm_format_size_from_path "${root}/logs")"
  fi
  if [[ -d "${root}/mail" ]]; then
    echo "mail: $(hm_format_size_from_path "${root}/mail")"
  fi
  echo
  echo "Top katalogi:"
  du -h --max-depth=1 "${root}" 2>/dev/null | sort -hr | head -20
}

cmd_site_dbs() {
  [[ -n "${HM_SITE_DOMAIN}" ]] || { hm_err "Brak kontekstu."; return 1; }
  hm_print_dbs_for_site "${HM_SITE_DOMAIN}" "${HM_SITE_DOCROOT}"
}

cmd_site_ssl() {
  hm_print_site_ssl "${HM_SITE_DOMAIN}"
}

cmd_site_php() {
  [[ -n "${HM_SITE_DOMAIN}" ]] || { hm_err "Brak kontekstu."; return 1; }
  echo "PHP strony: ${HM_SITE_PHP:--}"
  echo
  echo "${C_BOLD}Dostępne LSPHP${C_RESET} ${C_DIM}(+ porównanie z php.net)${C_RESET}"
  echo
  hm_list_available_php
}

cmd_site_logs() {
  local n="${1:-40}"
  hm_print_site_logs "${HM_SITE_DOMAIN}" "${n}"
}

cmd_site_backup() {
  hm_backup_site "${HM_SITE_DOMAIN}"
}

cmd_site_clean() {
  [[ -n "${HM_SITE_DOMAIN}" ]] || { hm_err "Brak kontekstu."; return 1; }
  local doc="${HM_SITE_DOCROOT}"
  [[ -n "${doc}" && -d "${doc}" ]] || { hm_err "Brak docroot."; return 1; }

  hm_warn "Bezpieczne czyszczenie cache/tmp dla ${HM_SITE_DOMAIN}"
  local targets=()
  [[ -d "${doc}/wp-content/cache" ]] && targets+=("${doc}/wp-content/cache")
  [[ -d "${doc}/wp-content/uploads/cache" ]] && targets+=("${doc}/wp-content/uploads/cache")
  [[ -d "${doc}/cache" ]] && targets+=("${doc}/cache")
  [[ -d "${doc}/tmp" ]] && targets+=("${doc}/tmp")
  [[ -d "${doc}/storage/framework/cache" ]] && targets+=("${doc}/storage/framework/cache")
  [[ -d "${doc}/storage/framework/views" ]] && targets+=("${doc}/storage/framework/views")

  if [[ "${#targets[@]}" -eq 0 ]]; then
    hm_info "Nie znaleziono typowych katalogów cache."
    return 0
  fi

  local t
  for t in "${targets[@]}"; do
    echo "  - ${t} ($(hm_format_size_from_path "${t}"))"
  done
  if ! hm_confirm "Usunąć zawartość powyższych katalogów?"; then
    hm_info "Anulowano."
    return 0
  fi
  for t in "${targets[@]}"; do
    find "${t}" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    hm_ok "Wyczyszczono: ${t}"
  done
}

cmd_site_help() {
  cat <<'EOF'
Komendy w kontekście strony:
  info      Pełne informacje o środowisku
  size      Rozmiary katalogów
  dbs       Bazy danych przypisane / wykryte
  ssl       Certyfikat SSL (wygasły → czerwony alert)
  renew-ssl Odnów Let's Encrypt (z potwierdzeniem)
  php       Wersja PHP + dostępne LSPHP
  logs [N]  Ostatnie N linii logów (domyślnie 40)
  cron      Crony użytkownika strony (+ heurystyka w /etc)
  pm2       Procesy PM2/Node powiązane ze stroną + porty proxy
  backup    Pełna kopia (pliki + DB) → Google Drive
  clean     Bezpieczne czyszczenie cache/tmp
  help [cmd] Pomoc (lista lub help <polecenie>)
  exit      Wyjście z kontekstu strony
EOF
}
