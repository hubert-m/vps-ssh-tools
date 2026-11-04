#!/usr/bin/env bash
# Moduł: backup (logika w core/list/restore/prune/schedule/archive)


_hm_cmd_help backup <<'EOF'
Użycie:
  backup setup              Instalacja/konfiguracja rclone + Google Drive
  backup config             Ustaw katalog root na Drive (jednorazowo)
  backup show               Pokaż aktualny root i strukturę
  backup full [--yes]       Pełna kopia serwera → Drive/full/<stamp>/ (--yes = cron)
  backup site <domena>      Kopia strony → Drive/<domena>/<stamp>/
  backup archive <domena> [--force-nested]
                            Archiwum (type=archive) → weryfikacja Drive → usunięcie z VPS
                            (child→docroot; master z childami → odmowa bez --force-nested)
  backup list [domena|full] Snapshoty + manifest (w kontekście: bieżąca domena)
  backup restore <domena> [stamp] [--files-only|--db-only]
                            [--overwrite-db] [--overwrite-files] [--adopt-existing-user]
                            Odtwórz pliki (tar lub chunks) + bazy; bez stamp = najnowszy
                            (działa też dla domen tylko na Drive po webs archive)
                            --overwrite-db: świadome nadpisanie niepustej bazy
                            --overwrite-files: świadome nadpisanie niepustego katalogu docelowego
                            --adopt-existing-user: świadome przejęcie istniejącego konta Unix (hasło/klucze/home)
  backup restore-full [stamp] [--system]
                            Odtwórz snapshot full/ (bazy + db-accounts; --system = system-configs)
  backup prune [--days N] [--dry-run] [--yes]
                            Usuń stare snapshoty (BACKUP_KEEP_DAYS / BACKUP_KEEP_MIN)
                            Snapshoty type=archive chronione; świeże orphan < BACKUP_ORPHAN_GRACE_HOURS pomijane
  backup schedule [enable|disable|status]
                            Cron: /etc/cron.d/hmtools-backup + log backup-cron.log
  backup test               Test połączenia rclone

Struktura na Google Drive (root = RCLONE_REMOTE):
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
      echo "${C_BOLD}Backup — Google Drive${C_RESET}"
      echo "  RCLONE_REMOTE : ${RCLONE_REMOTE:-brak}"
      echo "  BACKUP_KEEP_DAYS=${BACKUP_KEEP_DAYS:-14}  BACKUP_KEEP_MIN=${BACKUP_KEEP_MIN:-3}"
      echo "  Struktura:"
      echo "    ${RCLONE_REMOTE}/full/<stamp>/     — pełne kopie"
      echo "    ${RCLONE_REMOTE}/<domena>/<stamp>/ — kopie stron"
      echo "    ${RCLONE_REMOTE}/db-dumps/         — zrzuty mysql dump"
      if hm_have_cmd rclone && [[ -n "${RCLONE_REMOTE:-}" ]]; then
        echo
        hm_info "Zawartość root:"
        rclone lsd "${RCLONE_REMOTE}" 2>/dev/null | sed 's/^/  /' || hm_warn "Brak listingu (sprawdź połączenie)."
      fi
      ;;
    list|ls)
      hm_backup_list "${1:-}"
      ;;
    restore)
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
      local full_yes=0 a
      for a in "$@"; do
        case "${a}" in
          --yes|-y) full_yes=1 ;;
          --help|-h)
            cat <<'EOF'
Użycie: backup full [--yes|-y]

Pełna kopia serwera → Drive/full/<stamp>/.
--yes pomija potwierdzenie (wymagane w cronie: backup schedule).
EOF
            return 0
            ;;
          -*)
            hm_err "Nieznana flaga: ${a} (backup full [--yes])"
            return 1
            ;;
        esac
      done
      hm_load_config
      echo "Root Drive: ${RCLONE_REMOTE}"
      echo "Cel:       ${RCLONE_REMOTE}/full/<stamp>/"
      if [[ "${full_yes}" -eq 1 ]]; then
        hm_info "(--yes: pomijam potwierdzenie backup full)"
      else
        if [[ ! -t 0 ]]; then
          hm_err "Brak TTY — odmowa backup full bez --yes (cron: użyj „backup full --yes”)."
          return 1
        fi
        if ! hm_confirm "Uruchomić pełny backup serwera na Google Drive"; then
          hm_info "Anulowano."
          return 1
        fi
      fi
      hm_backup_full
      ;;
    site)
      local domain="${1:-${HM_SITE_DOMAIN}}"
      if [[ -z "${domain}" ]]; then
        hm_err "Użycie: backup site <domena>  (lub wejdź w kontekst)"
        return 1
      fi
      if [[ -z "${HM_SITE_DOMAIN}" || "${HM_SITE_DOMAIN}" != "${domain}" ]]; then
        domain="$(hm_find_site_by_arg "${domain}")" || return 1
      fi
      hm_load_config
      echo "Root Drive: ${RCLONE_REMOTE}"
      echo "Cel:       ${RCLONE_REMOTE}/${domain}/<stamp>/"
      hm_backup_site "${domain}"
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
