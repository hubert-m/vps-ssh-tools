# hmtools — narzędzia SSH dla VPS (OpenLiteSpeed / CyberPanel)

Zestaw narzędzi CLI instalowanych w `/hm-tools`. Po uruchomieniu `hmtools` wchodzisz w interaktywny kontekst: listujesz usługi webowe, wchodzisz w konkretną stronę (`use`), wykonujesz operacje i wracasz przez `exit`.

Panel i webserver **nie są hardcodowane** — przy starcie `detect` rozpoznaje OS oraz stos (OLS/Nginx/Apache, CyberPanel/cPanel/Plesk/Webmin, MariaDB/MySQL) i sugeruje dopasowane komendy; nadpisanie: `FORCE_*` w `hmtools.conf`.

---

## Dokumentacja

| Temat | Plik |
|-------|------|
| Instalacja, update, odinstalowanie | [docs/install.md](docs/install.md) |
| Szybki start | [docs/quickstart.md](docs/quickstart.md) |
| Mapa komend (globalne / kontekst / PM2) | [docs/commands.md](docs/commands.md) |
| Auto-detekcja panelu i stron | [docs/detection.md](docs/detection.md) |
| Wsparcie dystrybucji (apt/dnf, restricted OS) | [docs/os-support.md](docs/os-support.md) |
| Checklisty testów ręcznych (per OS) | [docs/tested/](docs/tested/) |
| Konfiguracja (`hmtools.conf`) | [docs/configuration.md](docs/configuration.md) |
| Logi sesji | [docs/logging.md](docs/logging.md) |
| Backup → Google Drive (rclone) | [docs/backup.md](docs/backup.md) |
| Przywracanie | [docs/restore.md](docs/restore.md) |
| Troubleshooting | [docs/troubleshooting.md](docs/troubleshooting.md) |
| Struktura repozytorium | [docs/structure.md](docs/structure.md) |
| Historia wersji | [CHANGELOG.md](CHANGELOG.md) |

---

## Instalacja (skrót)

```bash
curl -fsSL https://raw.githubusercontent.com/hubert-m/vps-ssh-tools/develop/install.sh | bash
hmtools
```

Szczegóły, konkretne tagi i update z REPL: [docs/install.md](docs/install.md).

---

## Szybki start (skrót)

```text
hmtools> webs
hmtools> use 1
[example.com]> info
[example.com]> exit
```

Więcej: [docs/quickstart.md](docs/quickstart.md) · pełna mapa: [docs/commands.md](docs/commands.md).

---

## Licencja / użycie

Narzędzia przeznaczone do administracji **własnym** VPS jako root. Backupy zawierają dane produkcyjne — chroń dostęp do remote Google Drive i tokenów rclone (`~/.config/rclone/rclone.conf`).
