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
  hm_print_dbs_for_site "${HM_SITE_DOMAIN}" "${HM_SITE_DOCROOT}" "${HM_SITE_ROOT}" "${HM_SITE_USER}"
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

hm_clean_count_entries() {
  # liczba wpisów w katalogu (mindepth 1)
  local dir="$1"
  find "${dir}" -mindepth 1 2>/dev/null | wc -l | tr -d ' '
}

hm_clean_preview_top() {
  # do 8 pozycji z pierwszego poziomu
  local dir="$1"
  local line n=0
  while IFS= read -r line; do
    n=$((n + 1))
    [[ "${n}" -le 8 ]] || break
    if [[ -d "${line}" ]]; then
      printf '      · %s/  (%s)\n' "$(basename "${line}")" "$(hm_format_size_from_path "${line}")"
    else
      printf '      · %s  (%s)\n' "$(basename "${line}")" "$(hm_human_size "$(stat -c %s "${line}" 2>/dev/null || echo 0)")"
    fi
  done < <(find "${dir}" -mindepth 1 -maxdepth 1 2>/dev/null | sort)
  local total
  total="$(find "${dir}" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${total}" -gt 8 ]]; then
    echo "      … (+$((total - 8)) więcej na pierwszym poziomie)"
  fi
}

cmd_site_clean() {
  [[ -n "${HM_SITE_DOMAIN}" ]] || { hm_err "Brak kontekstu."; return 1; }
  local doc="${HM_SITE_DOCROOT}"
  local root="${HM_SITE_ROOT:-}"
  [[ -n "${doc}" && -d "${doc}" ]] || { hm_err "Brak docroot."; return 1; }

  # tylko typowe cache/tmp — NIE ruszamy uploads/media/node_modules
  local -a candidates=(
    "${doc}/wp-content/cache"
    "${doc}/wp-content/uploads/cache"
    "${doc}/wp-content/litespeed"
    "${doc}/cache"
    "${doc}/tmp"
    "${doc}/temp"
    "${doc}/storage/framework/cache"
    "${doc}/storage/framework/views"
    "${doc}/storage/framework/sessions"
    "${doc}/.next/cache"
    "${doc}/node_modules/.cache"
  )
  if [[ -n "${root}" && "${root}" != "${doc}" ]]; then
    candidates+=(
      "${root}/cache"
      "${root}/tmp"
      "${root}/.next/cache"
      "${root}/node_modules/.cache"
      "${root}/storage/framework/cache"
      "${root}/storage/framework/views"
    )
  fi

  local -a targets=()
  local c
  for c in "${candidates[@]}"; do
    [[ -d "${c}" ]] || continue
    # pomiń puste
    if [[ -z "$(find "${c}" -mindepth 1 -maxdepth 1 2>/dev/null | head -1)" ]]; then
      continue
    fi
    targets+=("${c}")
  done

  if [[ "${#targets[@]}" -eq 0 ]]; then
    hm_info "Nie znaleziono niepustych katalogów cache/tmp do wyczyszczenia."
    return 0
  fi

  echo "${C_BOLD}Podgląd czyszczenia — ${HM_SITE_DOMAIN}${C_RESET}"
  echo "  ${C_DIM}Zostanie usunięta TYLKO zawartość poniższych katalogów (same foldery zostaną).${C_RESET}"
  echo

  local t bytes total_bytes=0 count entries
  local -a sizes=()
  for t in "${targets[@]}"; do
    bytes="$(hm_dir_size_bytes "${t}" 2>/dev/null || echo 0)"
    [[ "${bytes}" =~ ^[0-9]+$ ]] || bytes=0
    total_bytes=$((total_bytes + bytes))
    sizes+=("${bytes}")
    entries="$(hm_clean_count_entries "${t}")"
    echo "  ${C_YELLOW}${t}${C_RESET}"
    echo "    rozmiar : $(hm_human_size "${bytes}")"
    echo "    wpisy   : ${entries} (pliki/katalogi łącznie)"
    echo "    zawartość (1. poziom):"
    hm_clean_preview_top "${t}"
    echo
  done

  echo "  ${C_BOLD}Razem do usunięcia: $(hm_human_size "${total_bytes}") w ${#targets[@]} katalogach${C_RESET}"
  echo
  hm_warn "Tej operacji nie da się cofnąć (bez backupu)."

  local reply
  printf '%s [yes/no]: ' "Na pewno wyczyścić powyższą zawartość?"
  read -r reply || return 1
  case "${reply}" in
    yes|YES|Yes|y|Y|tak|Tak|TAK|t|T) ;;
    *)
      hm_info "Anulowano — nic nie usunięto."
      return 0
      ;;
  esac

  echo
  local i=0
  for t in "${targets[@]}"; do
    find "${t}" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    hm_ok "Wyczyszczono: ${t}  (było $(hm_human_size "${sizes[$i]}"))"
    i=$((i + 1))
  done
  hm_ok "Czyszczenie zakończone."
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
  clean     Podgląd cache/tmp → potwierdzenie yes/no → czyszczenie
  help [cmd] Pomoc (lista lub help <polecenie>)
  exit      Wyjście z kontekstu strony
EOF
}
