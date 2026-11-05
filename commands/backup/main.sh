#!/usr/bin/env bash
# Moduł: backup (logika w core/list/restore/prune/schedule/archive)


_hm_cmd_help backup <<'EOF'
Użycie:
  backup setup              Instalacja/konfiguracja rclone + Google Drive
  backup config             Ustaw katalog root na Drive (jednorazowo)
  backup show               Pokaż aktualny root i strukturę
  backup targets            Lista celów (gdrive / s3 / sftp / local)
  backup target add …       Dodaj cel (sekrety tylko w rclone.conf 0600)
  backup full [--yes] [--targets a,b]
                            Pełna kopia → full/<stamp>/ (multi-cel: 1× backup + replikacja)
  backup site <domena> [--target n|--targets a,b]
                            Kopia strony → <domena>/<stamp>/
  backup local <domena> [--keep N]
                            Szybka kopia lokalna (/backup/hmtools/…) — ten sam format co Drive
  backup inc init|site|list|restore|forget
                            Inkrementalne (restic + rclone backend; hasło w restic.pass 0600)
  backup archive <domena> [--force-nested]
                            Archiwum (type=archive) → weryfikacja → usunięcie z VPS
  backup list [domena|full] Snapshoty + manifest (w kontekście: bieżąca domena)
  backup restore <domena> [stamp] [--files-only|--db-only]
                            [--overwrite-db] [--overwrite-files] [--adopt-existing-user]
                            [--target n]  Odtwórz z dowolnego celu / lokalnego root
  backup restore-full [stamp] [--system]
  backup prune [--days N] [--dry-run] [--yes]
  backup schedule [enable|disable|status]
  backup test               Test połączenia rclone / lokalnego root

Struktura (root = RCLONE_REMOTE lub cel):
  <root>/full/<stamp>/           — pełne kopie serwera
  <root>/<domena>/<stamp>/       — kopie poszczególnych stron
  <root>/db-dumps/               — jednorazowe mysql dump

W kontekście strony samo 'backup' = kopia tej strony.
EOF

_hm_cmd_help archive-site <<'EOF'
Użycie:
  webs archive <numer|domena> [--force-nested]
  backup archive <numer|domena> [--force-nested]
  archive-site <numer|domena> [--force-nested]
  (w kontekście) archive [--force-nested]

1) Pełna kopia archiwalna na Google Drive:
   - bazy MySQL (db/*.sql.gz)
   - konta MySQL exclusive (db-accounts.sql — CREATE + GRANT tylko na bazy snapshotu; bez shared)
   - konto Unix SSH 1:1 (tylko exclusive; shared/protected pomijane)
   - pliki (child/shared → wyłącznie docroot; nie cały HOME mastera), OLS, SSL, cron, PM2, manifest.json
2) Twarda weryfikacja plików na Drive (Atomic Guard)
3) Dopiero potem usunięcie z VPS (child→docroot; cron nie przy shared user; master z childami → odmowa / --force-nested)

Snapshot ma type=archive (chroniony przed backup prune).
Przywrócenie: backup restore <domena> [stamp] [--overwrite-db|--overwrite-files|--adopt-existing-user]
EOF

_hm_cmd_help archive <<'EOF'
Użycie:
  webs archive <numer|domena> [--force-nested]
  backup archive <numer|domena> [--force-nested]
  archive-site <numer|domena> [--force-nested]
  (w kontekście) archive [--force-nested]

1) Pełna kopia archiwalna na Google Drive:
   - bazy MySQL (db/*.sql.gz)
   - konta MySQL exclusive (db-accounts.sql — CREATE + GRANT tylko na bazy snapshotu; bez shared)
   - konto Unix SSH 1:1 (tylko exclusive; shared/protected pomijane)
   - pliki (child/shared → wyłącznie docroot; nie cały HOME mastera), OLS, SSL, cron, PM2, manifest.json
2) Twarda weryfikacja plików na Drive (Atomic Guard)
3) Dopiero potem usunięcie z VPS (child→docroot; cron nie przy shared user; master z childami → odmowa / --force-nested)

Snapshot ma type=archive (chroniony przed backup prune).
Przywrócenie: backup restore <domena> [stamp] [--overwrite-db|--overwrite-files|--adopt-existing-user]
EOF

_HM_BACKUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=core.sh
source "${_HM_BACKUP_DIR}/core.sh"
# shellcheck source=list.sh
source "${_HM_BACKUP_DIR}/list.sh"
# shellcheck source=restore.sh
source "${_HM_BACKUP_DIR}/restore.sh"
# shellcheck source=prune.sh
source "${_HM_BACKUP_DIR}/prune.sh"
# shellcheck source=schedule.sh
source "${_HM_BACKUP_DIR}/schedule.sh"
# shellcheck source=archive.sh
source "${_HM_BACKUP_DIR}/archive.sh"
# shellcheck source=targets.sh
source "${_HM_BACKUP_DIR}/targets.sh"
# shellcheck source=local.sh
source "${_HM_BACKUP_DIR}/local.sh"
# shellcheck source=inc.sh
source "${_HM_BACKUP_DIR}/inc.sh"

cmd_archive_site() {
  hm_backup_archive_site "$@"
}

cmd_backup() {
  local sub="${1:-}"
  shift || true
  case "${sub}" in
    setup)
      local script="${HMTOOLS_ROOT}/scripts/setup-rclone.sh"
      if [[ -x "${script}" ]]; then
        bash "${script}"
      else
        hm_err "Brak ${script}"
        return 1
      fi
      ;;
    config|path|root)
      # jednorazowe wskazanie katalogu root na Google Drive
      hm_backup_config_root
      ;;
    show|status)
      hm_load_config
      echo "${C_BOLD}Backup — cele / root${C_RESET}"
      echo "  RCLONE_REMOTE : ${RCLONE_REMOTE:-brak}"
      echo "  BACKUP_LOCAL_ROOT=${BACKUP_LOCAL_ROOT:-/backup/hmtools}"
      echo "  BACKUP_KEEP_DAYS=${BACKUP_KEEP_DAYS:-14}  BACKUP_KEEP_MIN=${BACKUP_KEEP_MIN:-3}"
      echo "  Struktura:"
      echo "    ${RCLONE_REMOTE}/full/<stamp>/     — pełne kopie"
      echo "    ${RCLONE_REMOTE}/<domena>/<stamp>/ — kopie stron"
      echo "    ${RCLONE_REMOTE}/db-dumps/         — zrzuty mysql dump"
      hm_backup_targets_list 2>/dev/null || true
      if hm_rclone_root_is_local 2>/dev/null; then
        echo
        hm_info "Zawartość root (lokalnie):"
        ls -la "$(hm_rclone_root_fs 2>/dev/null || echo "${RCLONE_REMOTE}")" 2>/dev/null | head -20 | sed 's/^/  /' || true
      elif hm_have_cmd rclone && [[ -n "${RCLONE_REMOTE:-}" ]]; then
        echo
        hm_info "Zawartość root:"
        rclone lsd "${RCLONE_REMOTE}" 2>/dev/null | sed 's/^/  /' || hm_warn "Brak listingu (sprawdź połączenie)."
      fi
      ;;
    targets)
      cmd_backup_targets "$@"
      ;;
    target)
      if [[ "${1:-}" == "add" ]]; then
        shift || true
        hm_backup_target_add "$@"
      else
        cmd_backup_targets "$@"
      fi
      ;;
    local)
      hm_backup_local_site "$@"
      ;;
    inc|incremental|restic)
      cmd_backup_inc "$@"
      ;;
    list|ls)
      hm_backup_list "${1:-}"
      ;;
    restore)
      # opcjonalnie --target przed domeną
      HM_BACKUP_ARGS_REST=()
      hm_backup_parse_target_args "$@"
      set -- "${HM_BACKUP_ARGS_REST[@]}"
      if [[ -n "${HM_BACKUP_TARGETS_SELECTED:-}" && "${HM_BACKUP_TARGETS_SELECTED}" != "$(hm_backup_default_target_name)" ]]; then
        local _t0="${HM_BACKUP_TARGETS_SELECTED%%,*}"
        hm_backup_use_target "${_t0}" || return 1
      fi
      hm_backup_restore "$@"
      ;;
    restore-full|restore_full)
      hm_backup_restore_full "$@"
      ;;
    prune|cleanup|rotate)
      hm_backup_prune "$@"
      ;;
    schedule|cron)
      hm_backup_schedule "${1:-status}"
      ;;
    full|server)
      local full_yes=0
      HM_BACKUP_ARGS_REST=()
      hm_backup_parse_target_args "$@"
      set -- "${HM_BACKUP_ARGS_REST[@]}"
      local a
      for a in "$@"; do
        case "${a}" in
          --yes|-y) full_yes=1 ;;
          --help|-h)
            cat <<'EOF'
Użycie: backup full [--yes|-y] [--targets a,b]

Pełna kopia serwera → <root>/full/<stamp>/.
--targets: pierwszy cel = pełny backup, kolejne = replikacja + weryfikacja.
--yes pomija potwierdzenie (wymagane w cronie: backup schedule).
EOF
            return 0
            ;;
          -*)
            hm_err "Nieznana flaga: ${a} (backup full [--yes] [--targets …])"
            return 1
            ;;
        esac
      done
      hm_load_config
      echo "Cele: ${HM_BACKUP_TARGETS_SELECTED:-$(hm_backup_default_target_name)}"
      if [[ "${full_yes}" -eq 1 ]]; then
        hm_info "(--yes: pomijam potwierdzenie backup full)"
      else
        if [[ ! -t 0 ]]; then
          hm_err "Brak TTY — odmowa backup full bez --yes (cron: użyj „backup full --yes”)."
          return 1
        fi
        if ! hm_confirm "Uruchomić pełny backup serwera"; then
          hm_info "Anulowano."
          return 1
        fi
      fi
      local _bk_rc=0
      hm_backup_run_on_targets full || _bk_rc=$?
      if declare -F hm_notify >/dev/null 2>&1; then
        local _logf="${LOG_DIR:-/hm-tools/logs}/backup-cron.log"
        local _tail=""
        [[ -f "${_logf}" ]] && _tail="$(tail -n 40 "${_logf}" 2>/dev/null || true)"
        if [[ "${_bk_rc}" -ne 0 ]]; then
          hm_notify error "Backup full nieudany" \
            "host=$(hostname -f 2>/dev/null || hostname)
rc=${_bk_rc}
Ostatnie linie logu (${_logf}):
${_tail:-"(brak logu cron)"}" \
            "backup.full"
        elif [[ "${BACKUP_NOTIFY_SUCCESS:-0}" == "1" ]]; then
          hm_notify ok "Backup full OK" \
            "host=$(hostname -f 2>/dev/null || hostname)
Pełny backup zakończony pomyślnie." \
            "backup.full"
        fi
      fi
      return "${_bk_rc}"
      ;;
    site)
      HM_BACKUP_ARGS_REST=()
      hm_backup_parse_target_args "$@"
      set -- "${HM_BACKUP_ARGS_REST[@]}"
      local domain="${1:-${HM_SITE_DOMAIN}}"
      if [[ -z "${domain}" ]]; then
        hm_err "Użycie: backup site <domena> [--target n]  (lub wejdź w kontekst)"
        return 1
      fi
      if [[ -z "${HM_SITE_DOMAIN}" || "${HM_SITE_DOMAIN}" != "${domain}" ]]; then
        domain="$(hm_find_site_by_arg "${domain}")" || return 1
      fi
      hm_load_config
      echo "Cele: ${HM_BACKUP_TARGETS_SELECTED:-$(hm_backup_default_target_name)}"
      hm_backup_run_on_targets site "${domain}"
      ;;
    archive)
      local domain="${1:-${HM_SITE_DOMAIN}}"
      if [[ -z "${domain}" ]]; then
        hm_err "Użycie: backup archive <domena> [--force-nested]  (lub wejdź w kontekst: archive)"
        return 1
      fi
      shift || true
      hm_backup_archive_site "${domain}" "$@"
      ;;
    test)
      hm_load_config
      hm_rclone_test
      ;;
    ""|help|-h|--help)
      hm_help_topic backup
      ;;
    *)
      if [[ -n "${HM_SITE_DOMAIN}" && -z "${sub}" ]]; then
        hm_backup_site "${HM_SITE_DOMAIN}"
      else
        hm_err "Nieznana podkomenda: ${sub}. Zobacz: backup help"
        return 1
      fi
      ;;
  esac
}

_hm_cmd_register backup cmd_backup 0
_hm_cmd_register archive-site cmd_archive_site 0
