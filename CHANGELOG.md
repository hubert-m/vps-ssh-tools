# Changelog

Wszystkie istotne zmiany w [hmtools](https://github.com/hubert-m/vps-ssh-tools) są dokumentowane w tym pliku.

Format oparty o [Keep a Changelog](https://keepachangelog.com/pl/1.1.0/),
wersjonowanie zgodne z [Semantic Versioning](https://semver.org/lang/pl/).

## [Unreleased]

_(brak)_

## [v0.1.0] — 2026-10-27

Pierwsza publiczna wersja **hmtools** — zestaw narzędzi CLI do zarządzania VPS
(OpenLiteSpeed / CyberPanel) z kontekstowym shellem SSH i backupami na Google Drive.

### Dodane

#### Instalacja i aktualizacja
- Instalator `install.sh` działający lokalnie oraz przez `curl | bash`
- To samo polecenie instaluje **i** aktualizuje narzędzia w `/hm-tools`
- Porównywanie wersji: najnowszy **git tag** na GitHubie ↔ `/hm-tools/VERSION`
- Pomijanie update, gdy lokalna wersja jest już aktualna
- Wymuszenie reinstalacji: `HMTOOLS_FORCE=1` / `update-hmtools --force`
- Zachowanie istniejącego `config/hmtools.conf` przy aktualizacji
- Symlink `/usr/local/bin/hmtools`
- Komendy REPL: `update-hmtools`, `version`

#### Logowanie
- Zapis pracy narzędzi do `/hm-tools/logs/hmtools-YYYY-MM-DD.log`
- Poziomy: DEBUG / INFO / WARN / ERROR (`LOG_LEVEL`)
- Logowanie komend (`CMD:`), komunikatów info/ok/warn/error oraz startu/końca sesji
- Retencja starych plików (`LOG_RETENTION_DAYS`, domyślnie 30)
- Komenda `applog [N]` — podgląd ostatnich linii logu
- Katalog `logs/` chroniony przy aktualizacji (nie jest kasowany przez instalator)

#### Shell kontekstowy
- Interaktywny REPL `hmtools` (komunikaty po polsku)
- `webs [--quick]` — lista usług webowych (domena, PHP, SSL, rozmiar, status)
- `use <numer|domena>` — wejście w kontekst strony; `exit` — powrót
- Tryb jednorazowy: `hmtools <komenda> …`

#### Auto-detekcja środowiska
- Wykrywanie panelu (CyberPanel, aaPanel, DirectAdmin, cPanel → lub `unknown`)
- Wykrywanie OpenLiteSpeed / LiteSpeed oraz MariaDB/MySQL
- Discovery stron: CyberPanel → vhosty OLS → fallback `/home/*/public_html`
- Powiązanie baz: CyberPanel DB, heurystyka (`wp-config.php`, `.env`, Joomla) oraz prefix domeny

#### Kontekst strony
- `info` — ścieżki, rozmiar środowiska, DB, SSL, PHP, wolne miejsce
- `size`, `dbs`, `ssl`, `php`, `logs [N]`
- `backup` — pełna kopia środowiska (pliki + bazy) → Drive
- `clean` — bezpieczne czyszczenie typowych cache/tmp (z potwierdzeniem)

#### Backupy (rclone / Google Drive)
- Streaming bez pełnego archiwum lokalnego (`mysqldump|gzip|rclone rcat`, `tar|gzip|rclone rcat`)
- Tryb chunków dla dużych drzew (`CHUNK_THRESHOLD_MB` / `CHUNK_SIZE_MB`)
- Abort przy zbyt małej ilości wolnego miejsca (`MIN_FREE_PERCENT`)
- `backup full` — konfigi systemowe + wszystkie DB + wszystkie strony
- `backup setup` / `scripts/setup-rclone.sh` — guided konfiguracja Drive
- `mysql dump <db>` — zrzut jednej bazy na Drive
- `manifest.json` w każdym backupie

#### Narzędzia serwerowe
- `disk` — `df`, inody, top `/home`
- `ols [status|reload|restart|log]`
- `ssl` — certyfikaty wszystkich stron
- `mysql` / `dbs` — lista baz (globalnie lub w kontekście)
- `php` — dostępne LSPHP
- `health` — load, RAM, dysk, OLS/MySQL, certy wygasające &lt;14 dni
- `detect` — wypis wykrytego środowiska

#### Dokumentacja i konfiguracja
- `README.md` (instalacja, komendy, rclone, restore, troubleshooting)
- `config/hmtools.conf.example`
- Ten plik `CHANGELOG.md`

### Uwagi wydania

- Docelowy branch roboczy: `develop`; instalator bootstrapuje się z raw `install.sh` tego brancha, a paczkę narzędzi bierze z **najnowszego taga**.
- Do działania wersjonowanych update’ów wymagane są tagi na GitHubie (ten release: `v0.1.0`).

[Unreleased]: https://github.com/hubert-m/vps-ssh-tools/compare/v0.1.0...HEAD
[v0.1.0]: https://github.com/hubert-m/vps-ssh-tools/releases/tag/v0.1.0
