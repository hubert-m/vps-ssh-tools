# Changelog

Proste, punktowe notatki wersji.  
Szczegółowe pliki używane przez CLI (`version`, `update-hmtools`, instalator): katalog [`changelogs/`](changelogs/).

Format: [Keep a Changelog](https://keepachangelog.com/pl/1.1.0/) · [SemVer](https://semver.org/lang/pl/).

## [Unreleased]

_(brak)_

## [v0.1.0] — 2026-10-27

- Interaktywny shell kontekstowy (`webs` → `use` → `exit`)
- Auto-detekcja CyberPanel / OpenLiteSpeed / MariaDB–MySQL
- Lista i szczegóły stron (`info`, `size`, `dbs`, `ssl`, `php`, `logs`)
- Backupy streamingowe na Google Drive (rclone) — strona i cały serwer
- Oszczędność dysku: stream + chunki, próg wolnego miejsca
- Narzędzia: `disk`, `ols`, `ssl`, `mysql`, `health`, `clean`, `detect`
- Instalacja/aktualizacja jednym `curl | bash` (porównanie po git tagach)
- Logi pracy w `/hm-tools/logs` (`applog`)
- Komendy: `update-hmtools`, `version` (+ wypis changelogu)
- Powitanie po pierwszej instalacji (curl)
- Odinstalowanie: `uninstall-hmtools [--yes]`

[Unreleased]: https://github.com/hubert-m/vps-ssh-tools/compare/v0.1.0...HEAD
[v0.1.0]: https://github.com/hubert-m/vps-ssh-tools/releases/tag/v0.1.0
