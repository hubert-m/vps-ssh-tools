#!/usr/bin/env bash
# Komenda: update — aktualizacje systemu i stosu (nie mylić z update-hmtools / update-php)


_hm_cmd_help update <<'EOF'
Użycie:
  update check                         Przegląd: pakiety, security, OLS, CyberPanel, reboot
  update security [--yes]              Tylko poprawki bezpieczeństwa
  update packages [--exclude GLOB…] [--yes]
                                       Upgrade pakietów (opcjonalne wykluczenia, np. mariadb*)
  update ols [--yes]                   Aktualizacja OpenLiteSpeed (oficjalny skrypt / pakiet)
  update cyberpanel [--yes]            Snapshot → oficjalny upgrade → weryfikacja
  update auto-security on|off          unattended-upgrades / dnf-automatic

Rozróżnienie:
  update-hmtools  — aktualizacja samego hmtools z GitHuba
  update-php      — instalacja/aktualizacja LSPHP
  update          — system + stos (ten moduł)

Długie operacje: preferowany systemd-run --scope (zerwanie SSH nie przerywa).
Kopie przed upgrade CyberPanel: /var/backups/hmtools/pre-update/<stamp>/
EOF

HM_UPDATE_BACKUP_ROOT="/var/backups/hmtools/pre-update"

hm_update_stamp() {
  date +%Y%m%d-%H%M%S
}

hm_update_free_space_ok() {
  local path="${1:-/}" need_mb="${2:-2048}" avail
  avail="$(df -Pm "${path}" 2>/dev/null | awk 'NR==2{print $4}')"
  [[ "${avail}" =~ ^[0-9]+$ ]] || return 0
  if [[ "${avail}" -lt "${need_mb}" ]]; then
    hm_err "Za mało miejsca na ${path}: ${avail} MB wolne (min. ${need_mb} MB)."
    return 1
  fi
  return 0
}

# Uruchom zewnętrzny binariusz w scope systemd (zerwanie SSH nie zabija procesu).
# Tylko ścieżki wykonywalne / proste argv — nie funkcje bash.
hm_update_run_durable() {
  local title="$1"
  shift
  if hm_have_cmd systemd-run; then
    hm_info "${title} — systemd-run --scope (odporne na zerwanie SSH)…"
    hm_run systemd-run --scope --collect --quiet -- "$@"
    return $?
  fi
  hm_warn "Brak systemd-run — bieżąca sesja. Zalecane: tmux/screen przed długim upgrade."
  hm_run "$@"
}

hm_update_warn_ssh() {
  hm_warn "Długa operacja: przy ryzyku zerwania SSH użyj tmux/screen (lub systemd-run dla skryptów zewnętrznych)."
}

hm_update_ols_local_version() {
  local root="${OLS_ROOT:-/usr/local/lsws}" v=""
  if [[ -x "${root}/bin/openlitespeed" ]]; then
    v="$("${root}/bin/openlitespeed" -v 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  fi
  if [[ -z "${v}" && -f "${root}/VERSION" ]]; then
    v="$(tr -d '[:space:]' < "${root}/VERSION" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)"
  fi
  printf '%s' "${v:-?}"
}

hm_update_ols_remote_version() {
  # LiteSpeed public JSON (jak CP getLatestLSWSVersion) — best-effort
  local ver=""
  if hm_have_cmd curl; then
    ver="$(curl -fsS --max-time 8 \
      'https://update.litespeedtech.com/ws/latest.php' 2>/dev/null \
      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  fi
  printf '%s' "${ver:-?}"
}

hm_update_cyberpanel_local_version() {
  local f v=""
  for f in /usr/local/CyberCP/version.txt /usr/local/cyberpanel/version.txt; do
    if [[ -f "${f}" ]]; then
      v="$(tr -d '[:space:]' < "${f}" | head -1)"
      break
    fi
  done
  if [[ -z "${v}" ]] && hm_have_cmd cyberpanel; then
    v="$(cyberpanel version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -1 || true)"
  fi
  printf '%s' "${v:-?}"
}

hm_update_reboot_required() {
  if [[ -f /var/run/reboot-required ]]; then
    printf 'yes'
    return 0
  fi
  if hm_have_cmd needs-restarting; then
    # needs-restarting -r: rc=0 = reboot NIE potrzebny; rc=1 = potrzebny
    if needs-restarting -r >/dev/null 2>&1; then
      printf 'no'
    else
      printf 'yes'
    fi
    return 0
  fi
  printf 'unknown'
}

hm_update_snapshot_pre() {
  local stamp="${1:-$(hm_update_stamp)}"
  local dest="${HM_UPDATE_BACKUP_ROOT}/${stamp}"
  local p
  hm_update_free_space_ok / 3072 || return 1
  mkdir -p "${dest}"
  chmod 700 "${HM_UPDATE_BACKUP_ROOT}" "${dest}" 2>/dev/null || true

  hm_info "Snapshot konfiguracji → ${dest}"
  for p in \
    /usr/local/lsws/conf \
    /etc/postfix \
    /etc/dovecot \
    /etc/pdns \
    /etc/powerdns
  do
    if [[ -e "${p}" ]]; then
      hm_run tar -czf "${dest}/$(echo "${p}" | tr '/' '_').tar.gz" -C / "${p#/}" 2>/dev/null \
        || hm_warn "Nie spakowano ${p}"
    fi
  done
  # CyberCP bez venv (duży) — rsync/tar z exclude
  if [[ -d /usr/local/CyberCP ]]; then
    hm_run tar -czf "${dest}/CyberCP.tar.gz" \
      --exclude='CyberCP/bin' --exclude='CyberCP/**/venv' --exclude='CyberCP/**/__pycache__' \
      -C /usr/local CyberCP 2>/dev/null \
      || hm_warn "Nie spakowano CyberCP (kontynuuję)."
  fi
  if declare -F hm_mysql_dump_local >/dev/null 2>&1; then
    hm_mysql_dump_local cyberpanel "${dest}/cyberpanel.sql.gz" 2>/dev/null \
      || hm_warn "Dump bazy cyberpanel nieudany."
  elif hm_have_cmd mysqldump; then
    mysqldump cyberpanel > "${dest}/cyberpanel.sql" 2>/dev/null \
      || hm_warn "mysqldump cyberpanel nieudany."
  fi
  # README poniżej odnosi się do .sql — jeśli mamy .gz, dopisz hint
  [[ -f "${dest}/cyberpanel.sql.gz" ]] && echo "DB dump: cyberpanel.sql.gz (gunzip -c … | mysql cyberpanel)" >> "${dest}/README.db.txt"
  printf '%s\n' "${dest}" > "${dest}/README.txt"
  cat >> "${dest}/README.txt" <<EOF
Przywracanie (ręcznie po awarii upgrade):
  tar -xzf ${dest}/_usr_local_lsws_conf.tar.gz -C /
  tar -xzf ${dest}/CyberCP.tar.gz -C /usr/local
  mysql cyberpanel < ${dest}/cyberpanel.sql
Stamp: ${stamp}
EOF
  printf '%s' "${dest}"
}

hm_update_verify_services() {
  local u
  local -a units=(lscpd lsws openlitespeed mysql mariadb postfix dovecot pdns)
  local ok=0 fail=0
  for u in "${units[@]}"; do
    if systemctl list-unit-files "${u}.service" >/dev/null 2>&1 \
      || systemctl status "${u}" >/dev/null 2>&1; then
      if systemctl is-active --quiet "${u}" 2>/dev/null; then
        hm_ok "service ${u}: active"
        ok=$((ok + 1))
      elif systemctl is-enabled --quiet "${u}" 2>/dev/null; then
        hm_warn "service ${u}: enabled ale nie active"
        fail=$((fail + 1))
      fi
    fi
  done
  # HTTP smoke: panel + do 3 domen
  if hm_have_cmd curl; then
    if curl -fsS -o /dev/null --max-time 5 -k "https://127.0.0.1:8090" 2>/dev/null \
      || curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:8090" 2>/dev/null; then
      hm_ok "HTTP panel :8090 odpowiada"
    else
      hm_warn "Panel :8090 nie odpowiada (może być OK tuż po upgrade)."
    fi
    local d n=0
    hm_discover_sites 2>/dev/null || true
    for d in "${HM_SITES_LIST[@]:-}"; do
      [[ -n "${d}" ]] || continue
      n=$((n + 1))
      [[ "${n}" -le 3 ]] || break
      if curl -fsS -o /dev/null --max-time 5 -k "https://${d}/" 2>/dev/null \
        || curl -fsS -o /dev/null --max-time 5 "http://${d}/" 2>/dev/null; then
        hm_ok "HTTP ${d} OK"
      else
        hm_warn "HTTP ${d} — brak odpowiedzi"
      fi
    done
  fi
  return 0
}

cmd_update_check() {
  hm_pkg_bind || {
    hm_err "Brak menedżera pakietów (apt/dnf/yum)."
    return 1
  }
  local age
  age="$(hm_pkg_cache_age_info)"
  echo "${C_BOLD}update check${C_RESET}  ${C_DIM}(indeks pakietów: ${age})${C_RESET}"
  echo

  local -a upg=() sec=()
  local name inst cand
  while IFS=$'\t' read -r name inst cand; do
    [[ -n "${name}" ]] && upg+=("${name}")
  done < <(hm_pkg_list_upgradable 2>/dev/null || true)
  while IFS=$'\t' read -r name inst cand; do
    [[ -n "${name}" ]] && sec+=("${name}")
  done < <(hm_pkg_list_security 2>/dev/null || true)

  echo "  Pakiety do aktualizacji : ${#upg[@]}"
  if [[ "${#upg[@]}" -gt 0 ]]; then
    local i=0
    for name in "${upg[@]}"; do
      i=$((i + 1))
      [[ "${i}" -le 15 ]] || { echo "    … (+$(( ${#upg[@]} - 15 )))"; break; }
      echo "    - ${name}"
    done
  fi
  echo "  Z tego security          : ${#sec[@]}"
  if [[ "${#sec[@]}" -gt 0 ]]; then
    for name in "${sec[@]}"; do
      echo "    ! ${name}"
    done | head -15
  fi
  echo

  local ols_l ols_r cp_l auto reboot
  ols_l="$(hm_update_ols_local_version)"
  ols_r="$(hm_update_ols_remote_version)"
  cp_l="$(hm_update_cyberpanel_local_version)"
  auto="$(hm_pkg_auto_security_status 2>/dev/null | tr -d '[:space:]')"
  reboot="$(hm_update_reboot_required)"

  echo "  OLS lokalna / najnowsza  : ${ols_l} / ${ols_r}"
  echo "  CyberPanel               : ${cp_l}${PANEL:+ (panel=${PANEL})}"
  echo "  auto-security            : ${auto}"
  echo "  reboot-required          : ${reboot}"
  echo
  echo "  ${C_DIM}update security | update packages | update ols | update cyberpanel${C_RESET}"
  echo "  ${C_DIM}Nie mylić z: update-hmtools, update-php${C_RESET}"
}

cmd_update_security() {
  local yes=0 a
  for a in "$@"; do
    case "${a}" in
      --yes|-y) yes=1 ;;
      -h|--help) hm_help_topic update; return 0 ;;
      *) hm_err "Nieznany argument: ${a}"; return 1 ;;
    esac
  done
  hm_pkg_bind || return 1

  local -a sec=()
  local name
  while IFS=$'\t' read -r name _ _; do
    [[ -n "${name}" ]] && sec+=("${name}")
  done < <(hm_pkg_list_security 2>/dev/null || true)

  local -a plan=(
    "Odświeżenie indeksu pakietów (opcjonalne)"
    "Aktualizacja wyłącznie poprawek bezpieczeństwa (${#sec[@]} wykrytych)"
    "Weryfikacja usług po upgrade"
  )
  if [[ "${yes}" -eq 1 ]]; then
    if ! hm_confirm_plan "update security" "Tryb --yes (nieinteraktywny)." --yes "${plan[@]}"; then
      return 1
    fi
  else
    if ! hm_confirm_plan "update security" \
      "Zostaną zainstalowane tylko poprawki security." \
      "${plan[@]}"; then
      return 1
    fi
  fi

  hm_update_free_space_ok / 1024 || return 1
  hm_pkg_refresh || hm_warn "refresh indeksu nieudany — kontynuuję."
  hm_update_warn_ssh
  hm_pkg_upgrade_security || return 1
  hm_update_verify_services
  local rb
  rb="$(hm_update_reboot_required)"
  [[ "${rb}" == "yes" ]] && hm_warn "Wymagany restart systemu (reboot-required)."
  hm_ok "update security zakończone."
}

cmd_update_packages() {
  local yes=0
  local -a excludes=()
  local a expect_ex=0
  for a in "$@"; do
    if [[ "${expect_ex}" -eq 1 ]]; then
      excludes+=("${a}")
      expect_ex=0
      continue
    fi
    case "${a}" in
      --yes|-y) yes=1 ;;
      --exclude) expect_ex=1 ;;
      --exclude=*) excludes+=("${a#--exclude=}") ;;
      -h|--help) hm_help_topic update; return 0 ;;
      *)
        hm_err "Nieznany argument: ${a}"
        hm_info "Użycie: update packages [--exclude mariadb*] [--yes]"
        return 1
        ;;
    esac
  done
  [[ "${expect_ex}" -eq 0 ]] || { hm_err "--exclude wymaga wartości"; return 1; }
  hm_pkg_bind || return 1

  local -a plan=(
    "Odświeżenie indeksu pakietów"
    "apt/dnf upgrade${excludes[*]:+ (exclude: ${excludes[*]})}"
    "Weryfikacja usług"
  )
  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "update packages" "Tryb --yes." --yes "${plan[@]}" || return 1
  else
    hm_confirm_plan "update packages" \
      "Aktualizacja pakietów systemowych (może zająć długo)." \
      "${plan[@]}" || return 1
  fi

  hm_update_free_space_ok / 2048 || return 1
  hm_pkg_refresh || hm_warn "refresh nieudany."
  hm_update_warn_ssh
  hm_pkg_upgrade_all "${excludes[@]:-}" || return 1
  hm_update_verify_services
  [[ "$(hm_update_reboot_required)" == "yes" ]] && hm_warn "Wymagany restart systemu."
  hm_ok "update packages zakończone."
}

cmd_update_ols() {
  local yes=0 a
  for a in "$@"; do
    case "${a}" in
      --yes|-y) yes=1 ;;
      -h|--help) hm_help_topic update; return 0 ;;
      *) hm_err "Nieznany argument: ${a}"; return 1 ;;
    esac
  done

  local local_v remote_v
  local_v="$(hm_update_ols_local_version)"
  remote_v="$(hm_update_ols_remote_version)"
  if [[ "${local_v}" == "?" ]]; then
    hm_err "OLS nie wykryty (brak ${OLS_ROOT:-/usr/local/lsws})."
    return 1
  fi

  local -a plan=(
    "Snapshot conf OLS → ${HM_UPDATE_BACKUP_ROOT}/…"
    "Aktualizacja OLS ${local_v} → ${remote_v} (skrypt LiteSpeed / pakiet)"
    "ols reload + weryfikacja lshttpd"
  )
  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "update ols" "Tryb --yes." --yes "${plan[@]}" || return 1
  else
    hm_confirm_plan "update ols" \
      "Aktualizacja OpenLiteSpeed." \
      "${plan[@]}" || return 1
  fi

  local snap
  snap="$(hm_update_snapshot_pre)" || return 1
  hm_ok "Kopia conf: ${snap}"

  local ok=0
  if [[ -x /usr/local/lsws/admin/misc/lsup.sh ]]; then
    if hm_update_run_durable "OLS lsup" /usr/local/lsws/admin/misc/lsup.sh -f; then
      ok=1
    else
      hm_warn "lsup.sh zakończył się błędem."
    fi
  elif hm_pkg_candidate openlitespeed 2>/dev/null | grep -vq '^-'; then
    hm_pkg_upgrade openlitespeed && ok=1
  else
    hm_warn "Brak lsup.sh i pakietu openlitespeed — zaktualizuj OLS z panelu / LiteSpeed."
  fi
  if [[ "${ok}" -eq 0 ]]; then
    hm_err "Nie udało się zaktualizować OLS. Kopia conf: ${snap}"
    return 1
  fi

  hm_ols_reload_soft || hm_warn "ols reload nieudany"
  if pgrep -x lshttpd >/dev/null 2>&1 || pgrep -x openlitespeed >/dev/null 2>&1; then
    hm_ok "lshttpd działa (wersja lokalna: $(hm_update_ols_local_version))"
  else
    hm_err "lshttpd nie działa po upgrade — przywróć conf z ${snap}"
    return 1
  fi
  hm_ok "update ols zakończone."
}

cmd_update_cyberpanel() {
  local yes=0 a
  for a in "$@"; do
    case "${a}" in
      --yes|-y) yes=1 ;;
      -h|--help) hm_help_topic update; return 0 ;;
      *) hm_err "Nieznany argument: ${a}"; return 1 ;;
    esac
  done

  if [[ "${PANEL:-}" != "cyberpanel" ]] && [[ ! -d /usr/local/CyberCP ]]; then
    hm_err "CyberPanel nie wykryty — pomijam."
    return 1
  fi

  local ver
  ver="$(hm_update_cyberpanel_local_version)"
  local -a plan=(
    "Snapshot CyberCP + dump DB cyberpanel → ${HM_UPDATE_BACKUP_ROOT}/<stamp>"
    "Oficjalny upgrade (cyberpanel_upgrade.sh / upgrade.py) — wersja lokalna ${ver}"
    "Weryfikacja lscpd / panel :8090"
    "Przy awarii: instrukcja przywrócenia w README kopii"
  )
  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "update cyberpanel" "Tryb --yes." --yes "${plan[@]}" || return 1
  else
    hm_confirm_plan "update cyberpanel" \
      "Długa i wrażliwa operacja — zrób to w oknie tmux." \
      "${plan[@]}" || return 1
  fi

  local snap
  snap="$(hm_update_snapshot_pre)" || return 1
  hm_ok "Kopia przed upgrade: ${snap}"
  hm_info "Przywracanie po awarii — zobacz ${snap}/README.txt"

  local upg=""
  for upg in \
    /usr/local/cyberpanel_upgrade.sh \
    /usr/local/CyberCP/bin/upgrade.py \
    /usr/local/CyberCP/plogical/upgrade.py
  do
    [[ -e "${upg}" ]] && break
    upg=""
  done

  local rc=1
  if [[ -x /usr/local/cyberpanel_upgrade.sh ]]; then
    hm_update_run_durable "cyberpanel_upgrade" /usr/local/cyberpanel_upgrade.sh \
      || /usr/local/cyberpanel_upgrade.sh
    rc=$?
  elif [[ -f /usr/local/CyberCP/bin/upgrade.py ]]; then
    hm_update_run_durable "CyberCP upgrade.py" python3 /usr/local/CyberCP/bin/upgrade.py \
      || python3 /usr/local/CyberCP/bin/upgrade.py
    rc=$?
  elif hm_have_cmd cyberpanel; then
    hm_warn "Brak cyberpanel_upgrade.sh — próbuję 'cyberpanel upgrade' (jeśli istnieje)…"
    hm_run cyberpanel upgrade 2>/dev/null || rc=1
  else
    hm_err "Nie znaleziono skryptu upgrade CyberPanel."
    hm_info "Kopia pozostaje w ${snap}"
    return 1
  fi

  if [[ "${rc}" -ne 0 ]]; then
    hm_err "Upgrade CyberPanel zakończony kodem ${rc}."
    hm_err "Przywróć z ${snap} (README.txt)."
    return 1
  fi

  hm_update_verify_services
  hm_ok "CyberPanel po upgrade: $(hm_update_cyberpanel_local_version)"
  hm_ok "update cyberpanel zakończone. Kopia: ${snap}"
}

cmd_update_auto_security() {
  local mode="${1:-}"
  case "${mode}" in
    on|off) ;;
    -h|--help|"")
      hm_info "Użycie: update auto-security on|off"
      [[ -n "${mode}" ]] && return 0
      return 1
      ;;
    *)
      hm_err "Użycie: update auto-security on|off"
      return 1
      ;;
  esac
  hm_pkg_bind || return 1
  if ! hm_confirm_plan "update auto-security ${mode}" \
    "Zmiana automatycznych aktualizacji security." \
    "Ustawienie unattended-upgrades / dnf-automatic → ${mode}"; then
    return 1
  fi
  hm_pkg_auto_security_set "${mode}" || return 1
  hm_ok "auto-security: $(hm_pkg_auto_security_status | tr -d '[:space:]')"
}

cmd_update() {
  local sub="${1:-check}"
  case "${sub}" in
    check|status)
      shift || true
      cmd_update_check "$@"
      ;;
    security)
      shift || true
      cmd_update_security "$@"
      ;;
    packages|pkgs|package)
      shift || true
      cmd_update_packages "$@"
      ;;
    ols|lsws|openlitespeed)
      shift || true
      cmd_update_ols "$@"
      ;;
    cyberpanel|cp)
      shift || true
      cmd_update_cyberpanel "$@"
      ;;
    auto-security|autosecurity)
      shift || true
      cmd_update_auto_security "$@"
      ;;
    help|-h|--help)
      hm_help_topic update
      ;;
    hmtools|php)
      hm_err "To nie ta komenda. Użyj: update-hmtools  lub  update-php"
      return 1
      ;;
    *)
      hm_err "Nieznana podkomenda: ${sub}"
      hm_help_topic update
      return 1
      ;;
  esac
}

_hm_cmd_register update cmd_update 0
