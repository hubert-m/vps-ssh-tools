# Mapa komend

## Globalne (`hmtools>`)

| Komenda | Opis |
|---------|------|
| `webs [--quick] [--suspended]` | Lista usług webowych (STATUS; filtr suspended) |
| `webs delete <d>` / `delete-site` | Całkowite usunięcie serwisu (`yes` + nazwa domeny) |
| `webs archive <d>` / `backup archive` | Archiwum Drive → verify → usunięcie z VPS |
| `site create <d> --php <ver> […]` / `site-create` / `create-site` | Nowa strona (CyberPanel CLI lub OLS); `--ssl`/`--dkim`/`--no-open-basedir` |
| `site create <child> --child-of <master> --php <ver>` | Child domain (`--path`, `--ssl`) |
| `use <n\|domena>` | Wejście w kontekst (Tab uzupełnia domenę z listy) |
| `backup setup` | Instalacja/konfiguracja rclone + Google Drive |
| `backup config` | Ustaw katalog root backupów na Drive (jednorazowo) |
| `backup show` / `targets` | Root + lista celów; `target add s3\|b2\|sftp\|local` |
| `backup full [--targets a,b]` | Pełna kopia (+ replikacja na kolejne cele) |
| `backup site <d> [--target n]` | Kopia strony (multi-cel) |
| `backup local <d> [--keep N]` | Szybka kopia lokalna (`BACKUP_LOCAL_ROOT`) |
| `backup inc …` | restic (init/site/list/restore/forget); hasło w `restic.pass` |
| `backup list [domena\|full]` | Snapshoty + manifest |
| `backup restore … [--target n]` | Odtwórz pliki/DB (rclone lub lokalnie) |
| `backup prune` / `schedule` | Retencja snapshotów / cron `/etc/cron.d/hmtools-backup` |
| `backup test` | Test połączenia rclone / lokalnego root |
| `update check` | Przegląd: pakiety / security / OLS / CyberPanel / reboot-required |
| `update security\|packages\|ols\|cyberpanel` | Aktualizacje z potwierdzeniem; kopia przed CP; weryfikacja usług |
| `update auto-security on\|off` | unattended-upgrades / dnf-automatic |
| `update-hmtools [--force]` | Update z GitHuba + wypis „co nowego” |
| `version` | Wersja lokalna/remote + changelog tej wersji |
| `uninstall-hmtools [--yes]` | Usuwa `/hm-tools` i symlink (z potwierdzeniem) |
| `applog [N]` | Ostatnie N linii logu hmtools (domyślnie 50) |
| `disk` [`--drive`] [`--inodes`] [`--home`] [`--heavy` [`--count N`] [`--deep N`]] | `df` / inody / top `/home`; `--heavy` — rekurencyjnie najcięższe pliki/katalogi od `/` (domyślnie count=3, deep=5) |
| `ols …` | OLS: `status`/`reload`/`restart`/`log`, `stats`/`top`, `htaccess`, `cache`, `proxy`, `admin`, `vhost` |
| `ssl` | Certyfikaty SSL (status / dni; wygasły na czerwono) |
| `ssl issue [domena]` | Wydaj LE (HTTP-01) z pre-check DNS/HTTP; `--with-www` / `--aliases`; `--wildcard --dns pdns\|cloudflare` |
| `ssl hostname` / `ssl mail` / `ssl self-signed` / `ssl diagnose` | Hostname panelu, poczta, awaryjny self-signed, diagnoza ACME |
| `renew-ssl [domena]` | Odnów Let's Encrypt (z potwierdzeniem) |
| `mysql` / `dbs` | Lista baz; `heavy [--min-size X]` (bazy/tabele ≥ X, domyślnie 1G); `dump`/`dump-local`/`import`/`cli`/`top`/`optimize`/`create` |
| `cron` / `crons` | Crony systemowe / users / strony; `cron edit` |
| `pm2` / `node` / `apps` | PM2: lista, proxy, `restart`/`reload`/`logs`/`save` |
| `php` | LSPHP: lista vs repo + nowsze gałęzie do instalacji (`--refresh` / `--phpnet`), `set`/`ext`/`ini`/`restart`/`ps` |
| `update-php <ver>` | Aktualizacja / instalacja LSPHP (np. `8.4`, `8.6`) z potwierdzeniem |
| `health` [`--ram`] [`--cpu`] [`--count N`] [`--live`] [`--interval N`] | Przegląd; top RAM/CPU; `--live` (min. 2 s, q/Ctrl+C) |
| `health --check` / `health watch` | Alert dysk/SSL/usługi (+ `--notify`); cron co 15 min |
| `notify …` | Powiadomienia e-mail/webhook (`setup`/`test`/`status`); dedup 24h |
| `services …` | Status/restart/enable usług stosu (lsws, MariaDB, Postfix, …); failed na czerwono |
| `logs system …` | Logi mail/ftp/auth/cyberpanel/modsec/lsws/mysql (`--grep`/`--follow`/`--since`); `logs clean` |
| `limits …` | Zużycie/limity per strona (cgroup CPU/RAM/IO, quota dysku); `check`/`set`/`clear` |
| `firewall …` | Porty/reguły (ufw/firewalld/CSF): `allow`/`deny`/`remove`/`whitelist` |
| `security …` | Audyt: `ports`, `ssh` (+ `set`/`confirm`), Fail2Ban `ban`/`unban`, `scan` |
| `access …` | SSH/FTP strony: `ssh` (passwd/shell/keys), `ftp` (list/add/passwd/delete) |
| `redis …` | Redis: status/memory/dbs/clients/slowlog/sites; `config`/`flush*`/`restart`/`client kill` |
| `docker …` | Kontenery: lista (+ domena OLS proxy), logs, start/stop/restart, compose ls/pull/up, prune (domyślnie dry-run) |
| `git` / `deploy` | (w `use`) status/attach/klucz deploy; deploy pull+build+reload / rollback |
| `detect` | Wypisz wykryty panel / webserver / DB |
| `help [polecenie]` | Lista komend lub pomoc do wybranej (np. `help use`) |
| `exit` | Na głównej: wyjście z hmtools; w `[domena]>`: powrót do `hmtools>` |

## W kontekście strony (`[domena]>`)

| Komenda | Opis |
|---------|------|
| `info` | Pełne info: ścieżki, rozmiar, DB, SSL, PHP |
| `size` | Rozmiary katalogów + top `du` |
| `dbs` | Bazy (CyberPanel confirmed + heurystyka); też `dbs cli` itd. |
| `ssl` | Certyfikat; wygasły → czerwony alert |
| `ssl issue` / `diagnose` | Wydanie LE / diagnostyka ACME |
| `renew-ssl` | Odnów Let's Encrypt dla strony |
| `php` | `set` / `ext` / `ini` / `restart` / `ps` — `php help` |
| `logs [N\|errors\|stats\|follow]` | Logi vhosta + OLS `stderr.log`; analityka / live |
| `logs system …` / `logs clean …` | Logi systemowe (jak globalnie) |
| `cron` | Crony użytkownika strony (+ heurystyka w `/etc`) |
| `pm2` | Procesy strony; `restart`/`reload`/`logs` jako user strony |
| `limits …` | Limity CPU/RAM/IO (slice) / dysk (quota); `set`/`clear`/`check` |
| `suspend` / `unsuspend` | Zawieszenie 503 (+ maintenance/`--allow-ip`); odwieszenie |
| `openbasedir status\|on\|off` | `php_admin_value open_basedir` w vhconf (blok hmtools) |
| `alias list\|add\|remove` | Aliasy (parked) — mapa OLS / CyberPanel `createAlias` |
| `child list` | Domeny podrzędne mastera |
| `git` / `deploy` | Status repo, klucz deploy, attach, pull+build+reload, rollback |
| `backup` | Pełna kopia środowiska (pliki + DB) → Drive |
| `clean [--lscache]` | Podgląd cache/tmp (+ LSCache) → potwierdzenie |
| `vhost show\|edit\|rollback` | Podgląd/edycja vhconf (diff, bak.hmtools.\<stamp\>, reload, rollback) |
| `rewrite preset …` | Presety HTTPS / www / non-www / SPA (`# hmtools:…`) |
| `headers preset security [--hsts]` | Nagłówki bezpieczeństwa (XFO, XCTO, RP, opcjonalnie HSTS) |
| `cache settings [--ttl N] [--exclude PATH]` | LSCache w vhconf (TTL / exclude) |
| `htaccess [enable]` | Diagnostyka `.htaccess` / `autoLoadHtaccess` |
| `proxy [set-port N]` | Zdrowie reverse proxy OLS / zmiana portu |
| `perms [check\|fix]` | Uprawnienia pod OLS/CyberPanel (`nogroup` 750) |
| `delete-site […]` | Usuń bieżącą stronę (inwentaryzacja + plan critical) |
| `archive` | Archiwum Drive → verify → usunięcie tej strony |
| `access …` | SSH/FTP bieżącej strony (`status` / `ssh` / `ftp`) |
| `redis …` | Status/memory/sites (filtr domeny); mutacje jak globalnie |
| `docker …` | Kontenery powiązane z portami proxy tej strony |
| `exit` | Wyjście z kontekstu |

## Docker

```text
hmtools> docker                 # lista + OLS proxy domain
hmtools> docker logs n8n 100
hmtools> docker compose ls
hmtools> docker prune --dry-run # nigdy volume bez --volumes + critical
[app.example.pl]> docker        # filtr pod proxy strony
```

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
