# Mapa komend

## Globalne (`hmtools>`)

| Komenda | Opis |
|---------|------|
| `webs [--quick]` | Lista usług webowych |
| `webs delete <d>` / `delete-site` | Całkowite usunięcie serwisu (`yes` + nazwa domeny) |
| `webs archive <d>` / `backup archive` | Archiwum Drive → verify → usunięcie z VPS |
| `use <n\|domena>` | Wejście w kontekst (Tab uzupełnia domenę z listy) |
| `backup setup` | Instalacja/konfiguracja rclone + Google Drive |
| `backup config` | Ustaw katalog root backupów na Drive (jednorazowo) |
| `backup show` | Pokaż aktualny root i strukturę |
| `backup full` | Pełna kopia → `Drive/full/<stamp>/` |
| `backup site <domena>` | Kopia strony → `Drive/<domena>/<stamp>/` |
| `backup list [domena\|full]` | Snapshoty + manifest z Drive |
| `backup restore …` | Odtwórz pliki/DB (tar lub chunks) |
| `backup prune` / `schedule` | Retencja snapshotów / cron `/etc/cron.d/hmtools-backup` |
| `backup test` | Test połączenia rclone |
| `update-hmtools [--force]` | Update z GitHuba + wypis „co nowego” |
| `version` | Wersja lokalna/remote + changelog tej wersji |
| `uninstall-hmtools [--yes]` | Usuwa `/hm-tools` i symlink (z potwierdzeniem) |
| `applog [N]` | Ostatnie N linii logu hmtools (domyślnie 50) |
| `disk` | `df`, inody, top `/home` |
| `ols …` | OLS: `status`/`reload`/`restart`/`log`, `stats`/`top`, `htaccess`, `cache`, `proxy`, `admin` |
| `ssl` | Certyfikaty SSL (status / dni; wygasły na czerwono) |
| `renew-ssl [domena]` | Odnów Let's Encrypt (z potwierdzeniem) |
| `mysql` / `dbs` | Lista baz; `dump`/`dump-local`/`import`/`cli`/`top`/`optimize`/`create` |
| `cron` / `crons` | Crony systemowe / users / strony; `cron edit` |
| `pm2` / `node` / `apps` | PM2: lista, proxy, `restart`/`reload`/`logs`/`save` |
| `php` | LSPHP: lista vs repo + nowsze gałęzie do instalacji (`--refresh` / `--phpnet`), `set`/`ext`/`ini`/`restart`/`ps` |
| `update-php <ver>` | Aktualizacja / instalacja LSPHP (np. `8.4`, `8.6`) z potwierdzeniem |
| `health` | Load, RAM, dysk, OLS/MySQL, certy &lt;14 dni, wrażliwe porty |
| `security …` | Audyt: `ports`, `ssh`, Fail2Ban `ban`/`unban`, `scan` docroot |
| `detect` | Wypisz wykryty panel / webserver / DB |
| `help [polecenie]` | Lista komend lub pomoc do wybranej (np. `help use`) |
| `exit` | Wyjście |

## W kontekście strony (`[domena]>`)

| Komenda | Opis |
|---------|------|
| `info` | Pełne info: ścieżki, rozmiar, DB, SSL, PHP |
| `size` | Rozmiary katalogów + top `du` |
| `dbs` | Bazy (CyberPanel confirmed + heurystyka); też `dbs cli` itd. |
| `ssl` | Certyfikat; wygasły → czerwony alert |
| `renew-ssl` | Odnów Let's Encrypt dla strony |
| `php` | `set` / `ext` / `ini` / `restart` / `ps` — `php help` |
| `logs [N\|errors\|stats\|follow]` | Logi vhosta + OLS `stderr.log`; analityka / live |
| `cron` | Crony użytkownika strony (+ heurystyka w `/etc`) |
| `pm2` | Procesy strony; `restart`/`reload`/`logs` jako user strony |
| `backup` | Pełna kopia środowiska (pliki + DB) → Drive |
| `clean [--lscache]` | Podgląd cache/tmp (+ LSCache) → potwierdzenie |
| `htaccess [enable]` | Diagnostyka `.htaccess` / `autoLoadHtaccess` |
| `proxy [set-port N]` | Zdrowie reverse proxy OLS / zmiana portu |
| `perms [check\|fix]` | Uprawnienia pod OLS/CyberPanel (`nogroup` 750) |
| `delete-site […]` | Usuń bieżącą stronę (inwentaryzacja + plan critical) |
| `archive` | Archiwum Drive → verify → usunięcie tej strony |
| `exit` | Wyjście z kontekstu |

## PM2 / Node / Next

Dla aplikacji React/Node/Next uruchamianych przez PM2 (często za reverse-proxy OLS na różnych portach):

```text
hmtools> pm2              # wszystkie procesy + mapa proxy OLS → port
hmtools> pm2 ports        # nasłuchujące porty node/pm2/next (ss)
hmtools> pm2 site app.pl  # procesy powiązane ze stroną
hmtools> use app.pl
[app.pl]> pm2             # filtr: cwd / nazwa / port proxy
[app.pl]> pm2 restart all # runuser + PM2_HOME użytkownika strony
[app.pl]> pm2 logs 100
```

Aliasy: `node`, `apps`. Pomoc: `help pm2`.

← [README](../README.md) · [Szybki start](quickstart.md)
