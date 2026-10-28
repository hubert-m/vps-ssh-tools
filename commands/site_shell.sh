#!/usr/bin/env bash
# Komendy dostępne w kontekście strony

cmd_site_info() {
  hm_print_site_info "${HM_SITE_DOMAIN}"
}

cmd_site_size() {
  [[ -n "${HM_SITE_DOMAIN}" ]] || { hm_err "Brak kontekstu."; return 1; }
  local root="${HM_SITE_ROOT:-${HM_SITE_DOCROOT}}"
  local doc="${HM_SITE_DOCROOT:-}"
  if [[ -z "${root}" || ! -d "${root}" ]]; then
    hm_err "Brak katalogu strony."
    return 1
  fi
  [[ -z "${doc}" || ! -d "${doc}" ]] && doc=""
  if [[ -z "${doc}" && -d "${root}/public_html" ]]; then
    doc="${root}/public_html"
  fi

  echo "${C_BOLD}Rozmiary — ${HM_SITE_DOMAIN}${C_RESET}"
  hm_status_line "Liczenie rozmiaru środowiska..."
  echo "  Środowisko : ${root}"
  echo "  Całość     : $(hm_format_size_from_path "${root}")"
  if [[ -n "${doc}" ]]; then
    hm_status_line "Liczenie rozmiaru docroot..."
    echo "  Docroot    : ${doc}  ($(hm_format_size_from_path "${doc}"))"
  fi
  if [[ -d "${root}/logs" ]]; then
    echo "  logs       : $(hm_format_size_from_path "${root}/logs")"
  fi
  if [[ -d "${root}/mail" ]]; then
    echo "  mail       : $(hm_format_size_from_path "${root}/mail")"
  fi
  hm_status_clear

  echo
  echo "${C_BOLD}Top katalogi (środowisko)${C_RESET} ${C_DIM}— max-depth 1${C_RESET}"
  hm_status_line "Analiza top katalogów w root..."
  du -h --max-depth=1 "${root}" 2>/dev/null | sort -hr | head -20 | sed 's/^/  /'
  hm_status_clear

  # drugi poziom: wnętrze docroot / public_html
  if [[ -n "${doc}" && -d "${doc}" ]]; then
    echo
    echo "${C_BOLD}Top w $(basename "${doc}")${C_RESET} ${C_DIM}— ${doc}${C_RESET}"
    hm_status_line "Analiza top w docroot..."
    du -h --max-depth=1 "${doc}" 2>/dev/null | sort -hr | head -25 | sed 's/^/  /'
    hm_status_clear
  fi

  # jeśli największe katalogi poza docroot zasługują na 2. poziom (.npm, .nvm, .cache…)
  local sub
  for sub in .npm .nvm .cache .pm2 node_modules; do
    if [[ -d "${root}/${sub}" ]]; then
      local sz
      sz="$(hm_dir_size_bytes "${root}/${sub}" 2>/dev/null || echo 0)"
      # pokaż rozbicie tylko gdy > ~50MB
      if [[ "${sz}" =~ ^[0-9]+$ ]] && [[ "${sz}" -ge 52428800 ]]; then
        echo
        echo "${C_BOLD}Top w ${sub}${C_RESET} ${C_DIM}— ${root}/${sub}${C_RESET}"
        du -h --max-depth=1 "${root}/${sub}" 2>/dev/null | sort -hr | head -15 | sed 's/^/  /'
      fi
    fi
  done
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
  echo "${C_BOLD}PHP strony: ${HM_SITE_PHP:--}${C_RESET}  (${HM_SITE_DOMAIN})"
  echo "  set / ext / ini / restart / ps — zobacz: php help"
  echo
  echo "${C_BOLD}Dostępne LSPHP${C_RESET} ${C_DIM}(+ porównanie z repozytorium)${C_RESET}"
  echo
  hm_list_available_php
}

cmd_site_logs() {
  [[ -n "${HM_SITE_DOMAIN}" ]] || { hm_err "Brak kontekstu."; return 1; }
  local sub="${1:-}"
  case "${sub}" in
    errors|error|err)
      shift || true
      local n="${1:-80}"
      [[ "${n}" =~ ^[0-9]+$ ]] || n=80
      hm_site_logs_errors "${HM_SITE_DOMAIN}" "${n}"
      ;;
    stats|stat|top)
      hm_site_logs_stats "${HM_SITE_DOMAIN}"
      ;;
    follow|live|tail|-f)
      hm_site_logs_follow "${HM_SITE_DOMAIN}"
      ;;
    help|-h|--help)
      echo "Użycie: logs [N] | errors [N] | stats|top | follow|live"
      ;;
    "")
      hm_print_site_logs "${HM_SITE_DOMAIN}" 40
      ;;
    *)
      if [[ "${sub}" =~ ^[0-9]+$ ]]; then
        hm_print_site_logs "${HM_SITE_DOMAIN}" "${sub}"
      else
        hm_err "Nieznane: logs ${sub}. logs help"
        return 1
      fi
      ;;
  esac
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
  local lscache_only=0
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --lscache|lscache|--cache) lscache_only=1 ;;
      help|-h|--help)
        echo "Użycie: clean [--lscache]"
        echo "  --lscache  tylko katalogi LSCache (jak ols cache flush)"
        return 0
        ;;
    esac
  done

  if [[ "${lscache_only}" -eq 1 ]]; then
    hm_ols_cache_flush "${HM_SITE_DOMAIN}"
    return $?
  fi

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
      "${root}/lscache"
      "${root}/.next/cache"
      "${root}/node_modules/.cache"
      "${root}/storage/framework/cache"
      "${root}/storage/framework/views"
    )
  fi
  # LSCache vhost / OLS
  local p
  while IFS= read -r p; do
    [[ -n "${p}" ]] && candidates+=("${p}")
  done < <(hm_ols_cache_paths_for_domain "${HM_SITE_DOMAIN}" "${root}" 2>/dev/null || true)

  local -a targets=()
  local c real_c real_root
  real_root="$(realpath -m "${root}" 2>/dev/null || readlink -f "${root}" 2>/dev/null || echo "${root}")"
  for c in "${candidates[@]}"; do
    [[ -d "${c}" ]] || continue
    # SECURITY: nie podążaj za symlinkami poza katalog strony
    if [[ -L "${c}" ]]; then
      hm_warn "Pominięto symlink: ${c}"
      continue
    fi
    real_c="$(realpath -m "${c}" 2>/dev/null || readlink -f "${c}" 2>/dev/null || echo "")"
    if [[ -z "${real_c}" || ( "${real_c}" != "${real_root}" && "${real_c}" != "${real_root}"/* ) ]]; then
      hm_warn "Pominięto ścieżkę poza katalogiem strony: ${c}"
      continue
    fi
    # pomiń puste
    if [[ -z "$(find -P "${c}" -mindepth 1 -maxdepth 1 2>/dev/null | head -1)" ]]; then
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
  local ci=0 ctotal="${#targets[@]}"
  for t in "${targets[@]}"; do
    ci=$((ci + 1))
    hm_progress_bar "${ci}" "${ctotal}" "Skan cache: ${t}"
    bytes="$(hm_dir_size_bytes "${t}" 2>/dev/null || echo 0)"
    [[ "${bytes}" =~ ^[0-9]+$ ]] || bytes=0
    total_bytes=$((total_bytes + bytes))
    sizes+=("${bytes}")
    entries="$(hm_clean_count_entries "${t}")"
    hm_status_clear
    echo "  ${C_YELLOW}${t}${C_RESET}"
    echo "    rozmiar : $(hm_human_size "${bytes}")"
    echo "    wpisy   : ${entries} (pliki/katalogi łącznie)"
    echo "    zawartość (1. poziom):"
    hm_clean_preview_top "${t}"
    echo
  done
  hm_progress_done

  echo "  ${C_BOLD}Razem do usunięcia: $(hm_human_size "${total_bytes}") w ${#targets[@]} katalogach${C_RESET}"

  local -a plan_steps=()
  local si=0
  for t in "${targets[@]}"; do
    plan_steps+=("Wyczyszczenie zawartości ${t} ($(hm_human_size "${sizes[$si]}"), $(hm_clean_count_entries "${t}") wpisów) — zachowanie pustego folderu")
    si=$((si + 1))
  done
  if ! hm_confirm_plan "clean — ${HM_SITE_DOMAIN}" \
    "Tej operacji nie da się cofnąć (bez backupu)." \
    "${plan_steps[@]}"; then
    return 0
  fi

  local i=0 ent
  for t in "${targets[@]}"; do
    i=$((i + 1))
    hm_progress_bar "${i}" "${#targets[@]}" "Czyszczenie: ${t}"
    # -P: nie podążaj za symlinkami; pomiń same linki na 1. poziomie
    while IFS= read -r -d '' ent; do
      [[ -L "${ent}" ]] && continue
      rm -rf -- "${ent}" 2>/dev/null || true
    done < <(find -P "${t}" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
    hm_status_clear
    hm_ok "Wyczyszczono: ${t}  (było $(hm_human_size "${sizes[$((i - 1))]}"))"
  done
  hm_progress_done "Czyszczenie zakończone."
}

hm_ols_web_group() {
  # grupa procesu lshttpd (CyberPanel/OLS: zwykle nogroup lub nobody)
  local g
  g="$(ps -o group= -C lshttpd 2>/dev/null | head -1 | tr -d ' ')"
  if [[ -z "${g}" ]]; then
    g="$(ps -o group= -C openlitespeed 2>/dev/null | head -1 | tr -d ' ')"
  fi
  if [[ -n "${g}" && "${g}" != "root" ]]; then
    printf '%s' "${g}"
    return 0
  fi
  if getent group nogroup >/dev/null 2>&1; then
    echo nogroup
    return 0
  fi
  if getent group nobody >/dev/null 2>&1; then
    echo nobody
    return 0
  fi
  echo nogroup
}

cmd_site_perms() {
  local sub="${1:-check}"
  case "${sub}" in
    check|status|"") cmd_site_perms_check ;;
    fix|repair) cmd_site_perms_fix ;;
    help|-h|--help)
      echo "Użycie: perms [check|fix]"
      echo "  check  diagnostyka właściciela/uprawnień (OLS)"
      echo "  fix    chown/chmod pod CyberPanel/OLS (z potwierdzeniem)"
      ;;
    *)
      hm_err "Nieznane: perms ${sub}. perms help"
      return 1
      ;;
  esac
}

cmd_site_perms_check() {
  [[ -n "${HM_SITE_DOMAIN}" ]] || { hm_err "Brak kontekstu."; return 1; }
  local root="${HM_SITE_ROOT:-}"
  local doc="${HM_SITE_DOCROOT:-}"
  local user="${HM_SITE_USER:-}"
  local webgrp
  webgrp="$(hm_ols_web_group)"

  echo "${C_BOLD}Uprawnienia — ${HM_SITE_DOMAIN}${C_RESET}"
  echo "  User strony : ${user:--}"
  echo "  Grupa OLS   : ${webgrp}"
  echo "  Root        : ${root:--}"
  echo "  Docroot     : ${doc:--}"
  echo

  local issues=0
  _hm_perms_stat_line() {
    local path="$1" label="$2"
    [[ -e "${path}" ]] || { echo "  ${label}: ${C_YELLOW}brak${C_RESET} (${path})"; return 0; }
    local ow og mode
    ow="$(stat -c '%U' "${path}" 2>/dev/null || echo '?')"
    og="$(stat -c '%G' "${path}" 2>/dev/null || echo '?')"
    mode="$(stat -c '%a' "${path}" 2>/dev/null || echo '?')"
    echo "  ${label}: ${ow}:${og} mode=${mode}  ${path}"
  }

  _hm_perms_stat_line "${root}" "site root"
  _hm_perms_stat_line "${doc}" "docroot"

  if [[ -n "${doc}" && -d "${doc}" ]]; then
    local dg
    dg="$(stat -c '%G' "${doc}" 2>/dev/null || true)"
    if [[ -n "${webgrp}" && "${dg}" != "${webgrp}" ]]; then
      hm_warn "Docroot ma grupę ${dg} — OLS zwykle wymaga ${webgrp} (ryzyko 403)."
      issues=$((issues + 1))
    fi
    local dm
    dm="$(stat -c '%a' "${doc}" 2>/dev/null || true)"
    if [[ "${dm}" == "755" || "${dm}" == "775" || "${dm}" == "777" ]]; then
      hm_warn "Docroot mode=${dm} (zalecane 750 dla OLS)."
      issues=$((issues + 1))
    fi
  fi

  if [[ -n "${user}" && -n "${doc}" && -d "${doc}" ]]; then
    local root_owned
    root_owned="$(find -P "${doc}" -xdev \( -user root -o -group root \) 2>/dev/null | head -20)"
    if [[ -n "${root_owned}" ]]; then
      hm_warn "Pliki/katalogi należące do root w docroot (max 20):"
      printf '%s\n' "${root_owned}" | sed 's/^/    /'
      local cnt
      cnt="$(find -P "${doc}" -xdev \( -user root -o -group root \) 2>/dev/null | wc -l | tr -d ' ')"
      echo "    … łącznie ≈ ${cnt}"
      issues=$((issues + 1))
    fi
    local wide
    wide="$(find -P "${doc}" -xdev -perm -0002 2>/dev/null | head -15)"
    if [[ -n "${wide}" ]]; then
      hm_warn "Zbyt otwarte (world-writable) — max 15:"
      printf '%s\n' "${wide}" | sed 's/^/    /'
      issues=$((issues + 1))
    fi
  fi

  local sens
  for sens in "${doc}/wp-config.php" "${doc}/.env" "${root}/.env" "${root}/wp-config.php"; do
    [[ -f "${sens}" ]] || continue
    local sm so
    sm="$(stat -c '%a' "${sens}" 2>/dev/null || echo '?')"
    so="$(stat -c '%U:%G' "${sens}" 2>/dev/null || echo '?')"
    if [[ "${sm}" != "600" && "${sm}" != "640" ]]; then
      hm_warn "Wrażliwy plik ${sens}: mode=${sm} owner=${so} (zalecane 600)."
      issues=$((issues + 1))
    else
      echo "  OK wrażliwy: ${sens} mode=${sm} ${so}"
    fi
  done

  if [[ "${issues}" -eq 0 ]]; then
    hm_ok "Brak oczywistych problemów z uprawnieniami."
  else
    hm_warn "Znaleziono ${issues} obszar(ów) do poprawy — rozważ: perms fix"
  fi
}

cmd_site_perms_fix() {
  [[ -n "${HM_SITE_DOMAIN}" ]] || { hm_err "Brak kontekstu."; return 1; }
  local root="${HM_SITE_ROOT:-}"
  local doc="${HM_SITE_DOCROOT:-}"
  local user="${HM_SITE_USER:-}"
  local webgrp
  webgrp="$(hm_ols_web_group)"

  [[ -n "${user}" ]] || { hm_err "Brak HM_SITE_USER — nie mogę ustawić właściciela."; return 1; }
  hm_is_valid_unix_user "${user}" || { hm_err "Nieprawidłowy user: ${user}"; return 1; }
  [[ -n "${doc}" && -d "${doc}" ]] || { hm_err "Brak docroot."; return 1; }

  # bezpieczeństwo: docroot musi być pod /home lub site root
  local real_doc real_root
  real_doc="$(realpath -m "${doc}" 2>/dev/null || echo "${doc}")"
  real_root="$(realpath -m "${root:-/home/${HM_SITE_DOMAIN}}" 2>/dev/null || echo "${root}")"
  case "${real_doc}" in
    /home/*) ;;
    *)
      if [[ -n "${real_root}" && "${real_doc}" != "${real_root}" && "${real_doc}" != "${real_root}"/* ]]; then
        hm_err "Docroot poza /home — odmawiam automatycznego perms fix."
        return 1
      fi
      ;;
  esac

  local -a plan_steps=(
    "Ustawienie właściciela chown -R ${user}:${user} wewnątrz ${doc}"
    "Ustawienie ${user}:${webgrp} i chmod 750 na katalogu ${doc}"
    "Ustawienie chmod 755 dla katalogów i 644 dla plików w ${doc}"
    "Zabezpieczenie chmod 600 dla wrażliwych plików (.env, wp-config.php)"
  )
  if [[ -n "${root}" && -d "${root}" && "${root}" != "${doc}" ]]; then
    plan_steps+=("Opcjonalnie root strony ${root} → ${user}:${user}")
  fi
  if ! hm_confirm_plan "perms fix — ${HM_SITE_DOMAIN}" \
    "Operacja masowa na plikach — zrób backup przy wątpliwościach." \
    "${plan_steps[@]}"; then
    return 0
  fi

  hm_progress_bar 1 4 "Właściciel plików (chown)"
  find -P "${doc}" -xdev -mindepth 1 -maxdepth 1 -print0 2>/dev/null \
    | while IFS= read -r -d '' ent; do
        [[ -L "${ent}" ]] && continue
        chown -R "${user}:${user}" -- "${ent}" 2>/dev/null || true
      done

  chown "${user}:${webgrp}" -- "${doc}" 2>/dev/null || chown "${user}:${user}" -- "${doc}"
  chmod 750 -- "${doc}" 2>/dev/null || true

  hm_progress_bar 2 4 "Katalogi (chmod 755)"
  find -P "${doc}" -xdev -type d -exec chmod 755 {} + 2>/dev/null || true
  hm_progress_bar 3 4 "Pliki (chmod 644)"
  find -P "${doc}" -xdev -type f -exec chmod 644 {} + 2>/dev/null || true

  hm_progress_bar 4 4 "Pliki wrażliwe (chmod 600)"
  local sens
  for sens in "${doc}/wp-config.php" "${doc}/.env" "${root}/.env" "${root}/wp-config.php"; do
    [[ -f "${sens}" ]] || continue
    chown "${user}:${user}" -- "${sens}" 2>/dev/null || true
    chmod 600 -- "${sens}" 2>/dev/null || true
  done
  hm_progress_done

  if [[ -n "${root}" && -d "${root}" && "${root}" != "${doc}" ]]; then
    # nie ruszaj całego /home/domena agresywnie — tylko jeśli user jest właścicielem katalogu
    local ru
    ru="$(stat -c '%U' "${root}" 2>/dev/null || true)"
    if [[ "${ru}" == "root" || "${ru}" == "${user}" ]]; then
      chown "${user}:${user}" -- "${root}" 2>/dev/null || true
    fi
  fi

  # przywróć 750 na samym docroot (find 755 nadpisał)
  chmod 750 -- "${doc}" 2>/dev/null || true
  chown "${user}:${webgrp}" -- "${doc}" 2>/dev/null || true

  hm_ok "perms fix zakończony."
  cmd_site_perms_check
}

cmd_site_help() {
  cat <<'EOF'
Komendy w kontekście strony:
  info      Pełne informacje o środowisku
  size      Rozmiary katalogów
  dbs       Bazy danych przypisane / wykryte
  ssl       Certyfikat SSL (wygasły → czerwony alert)
  renew-ssl Odnów Let's Encrypt (z potwierdzeniem)
  php       PHP strony; set/ext/ini/restart/ps — php help
  logs [N|errors|stats|follow]  Logi vhosta (+ stderr OLS)
  cron      Crony użytkownika strony (+ heurystyka w /etc)
  pm2       Procesy PM2/Node + restart/reload/logs (jako user strony)
  backup    Pełna kopia (pliki + DB) → Google Drive
  clean [--lscache]  Podgląd cache/tmp (+ LSCache) → potwierdzenie
  htaccess [enable]  Diagnostyka .htaccess / autoLoadHtaccess
  proxy [set-port N] Reverse proxy OLS — zdrowie portów / zmiana portu
  perms [check|fix] Uprawnienia plików pod OLS / CyberPanel
  help [cmd] Pomoc (lista lub help <polecenie>)
  exit      Wyjście z kontekstu strony
EOF
}
