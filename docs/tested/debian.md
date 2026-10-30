# Debian — checklista testów hmtools

Checklist ręcznych testów hmtools na **debian**. Zaznaczaj `- [x]` po weryfikacji.

| | |
|--|--|
| **OS_ID** | `debian` |
| **Rodzina** | debian |
| **Pakiety** | apt / apt-get |
| **Mapa komend** | [commands.md](../commands.md) |
| **Indeks testów** | [README.md](README.md) |

## Specyfika Debian

- [ ] `detect` pokazuje `OS_ID=debian`, `OS_FAMILY=debian`, `PKG_MANAGER=apt`
- [ ] `php --refresh` używa `apt-get update`
- [ ] Apache (jeśli obecny): unit `apache2`, log `/var/log/apache2/error.log`
- [ ] Nginx (jeśli obecny): unit `nginx`, log `/var/log/nginx/error.log`

---

## Środowisko testowe

- [ ] Czysta / reprezentatywna instalacja OS
- [ ] hmtools zainstalowane (`install.sh` / tag)
- [ ] Dostęp root (SSH)
- [ ] (opcjonalnie) rclone + Google Drive skonfigurowane
- [ ] (opcjonalnie) OpenLiteSpeed / CyberPanel na hoście
- [ ] (opcjonalnie) co najmniej jedna domena testowa

## Start i detekcja

- [ ] `hmtools` — start REPL bez crasha
- [ ] Banner „Wykryty stos” (OS / panel / www / db)
- [ ] `detect` / `env` — pełna karta stosu
- [ ] `OS_FAMILY` i `PKG_MANAGER` zgodne z dystrybucją
- [ ] `version` — wersja lokalna (+ remote jeśli sieć)
- [ ] `help` / `help detect`
- [ ] `exit` / `quit` — wyjście z REPL
- [ ] `hmtools -c "version"` — tryb one-shot
- [ ] `hmtools -c "detect"` — one-shot z jedną komendą
- [ ] Tab-complete podstawowych komend

## Instalacja / self

- [ ] `update-hmtools` (dry / sprawdzenie wersji)
- [ ] `update-hmtools --force` (jeśli zamierzone)
- [ ] `applog` / `applog 20`
- [ ] `uninstall-hmtools` — anulowanie (nie-yes)
- [ ] `uninstall-hmtools --yes` — tylko na VPS do wyrzucenia

## Dyski i health

- [ ] `disk` — df / inody / top home
- [ ] `health` / `status` — load, RAM, dysk, usługi, certy

## Security

- [ ] `security` / `security help`
- [ ] `security ports`
- [ ] `security ssh`
- [ ] `security ban` / status Fail2Ban (jeśli zainstalowany)
- [ ] `security unban` (jeśli dotyczy)
- [ ] `security scan` / `security scan <domena>`

## Weby (globalnie)

- [ ] `webs` / `webs --quick` — lista serwisów
- [ ] Suma SIZE pod listą (jeśli wiele stron)
- [ ] `use <numer>` — wejście w kontekst
- [ ] `use <domena>` — wejście po nazwie
- [ ] Tab przy `use ` — podpowiedź domen
- [ ] `webs delete <domena>` — anulowanie planu (nie-yes / zła nazwa)
- [ ] `delete-site <domena>` — alias
- [ ] `webs archive <domena>` — anulowanie planu
- [ ] `archive-site <domena>` — alias

## Kontekst strony (`use`)

- [ ] `info`
- [ ] `size`
- [ ] `dbs` — lista baz
- [ ] `ssl` — status certu
- [ ] `renew-ssl` — anulowanie / przebieg (ostrożnie na prod)
- [ ] `logs` / `logs 50`
- [ ] `logs errors` / `logs stats`
- [ ] `logs follow` — przerwanie Ctrl+C
- [ ] `clean` — podgląd + anulowanie
- [ ] `clean --lscache` (przy OLS/LSCache)
- [ ] `htaccess` / `htaccess check`
- [ ] `htaccess enable` — anulowanie planu
- [ ] `proxy` / `proxy status`
- [ ] `proxy set-port <port>` (w kontekście)
- [ ] `perms` / `perms check`
- [ ] `perms fix` — anulowanie planu
- [ ] `cron` (w kontekście strony)
- [ ] `pm2` (w kontekście)
- [ ] `backup` (w kontekście) — anulowanie / przebieg testowy
- [ ] `delete-site` (w kontekście) — anulowanie
- [ ] `archive` (w kontekście) — anulowanie
- [ ] `exit` — powrót do `hmtools>`

## OpenLiteSpeed (`ols`)

> Pomiń lub oznacz N/A, jeśli na hoście nie ma OLS.

- [ ] `ols` / `ols status`
- [ ] `ols reload`
- [ ] `ols restart` (ostrożnie)
- [ ] `ols log` / `ols log 50`
- [ ] `ols stats`
- [ ] `ols top` — wyjście `q` / Ctrl+C
- [ ] `ols htaccess` / `ols htaccess check <domena>`
- [ ] `ols htaccess enable <domena>` — anulowanie
- [ ] `ols cache status` / `ols cache status <domena>`
- [ ] `ols cache flush` bez lscache — komunikat „brak katalogów”
- [ ] `ols cache flush <domena>` / `ols cache flush all` — anulowanie
- [ ] `ols proxy` / `ols proxy <domena>`
- [ ] `ols proxy set-port <domena> <port>` (poza `use`)
- [ ] `ols admin status`
- [ ] `ols admin pass` — anulowanie (nie zmieniać hasła bez potrzeby)

## PHP / LSPHP

> Wymaga lsphp* / OLS.

- [ ] `php` — tabela ZAINSTALOWANA / W REPO (UPDATE)
- [ ] `php --refresh` / `php -r`
- [ ] `php --phpnet` (opcjonalnie, sieć)
- [ ] Kolumny poprawne przy braku Candidate (bez zlewania TSV)
- [ ] `php help` / `update-php` help
- [ ] `update-php <ver>` — anulowanie / Installed==Candidate → propozycja refresh
- [ ] W kontekście: `php set` / `php ext` / `php ini` / `php restart` / `php ps` (wg help)

## MySQL / MariaDB

- [ ] `mysql` / `dbs` — lista baz
- [ ] `mysql dump <baza>` — na Drive (rclone)
- [ ] `mysql dump nieistniejaca_baza` — czytelny błąd, brak pustego `.sql.gz`
- [ ] `mysql dump <baza> --local`
- [ ] `mysql dump <baza> --local /tmp/` (katalog ze `/`)
- [ ] `mysql dump <baza> --local /root/backups` (istniejący katalog)
- [ ] `mysql dump-local <baza>`
- [ ] `mysql import <baza> <plik.sql|.sql.gz>` — anulowanie planu
- [ ] `mysql cli` / `mysql cli <baza>`
- [ ] `mysql top` / `mysql processlist`
- [ ] `mysql optimize` / `mysql optimize <baza>` — anulowanie
- [ ] `mysql create <baza> [user]` — anulowanie / przebieg testowy

## Backup / rclone

> Wymaga skonfigurowanego `RCLONE_REMOTE`.

- [ ] `backup setup` / `backup config` / `backup show`
- [ ] `backup test`
- [ ] `backup site <domena>`
- [ ] `backup full`
- [ ] `backup list` / `backup list <domena>` / `backup list full`
- [ ] `backup restore <domena>` — anulowanie planu critical
- [ ] `backup restore` z `files.tar.gz`
- [ ] `backup restore` z `files.chunks/`
- [ ] `backup restore --files-only` / `--db-only`
- [ ] `backup prune --dry-run`
- [ ] `backup prune --yes` (ostrożnie; chroni `type=archive`)
- [ ] `backup schedule status` / `enable` / `disable`
- [ ] `backup archive <domena>` — anulowanie; potem pełny przebieg na stronie testowej
- [ ] Po archive: `backup list` pokazuje `type=archive`
- [ ] `backup prune` nie usuwa snapshotów archive
- [ ] `backup restore` domeny usuniętej z VPS (tylko Drive)

## Cron

- [ ] `cron` / `cron list`
- [ ] `cron all` / `cron system` / `cron users`
- [ ] `cron site <domena>` / `cron user <name>`
- [ ] `cron user` bez argumentu — komunikat użycia (bez unbound)
- [ ] `cron edit` (ostrożnie)

## PM2

- [ ] `pm2` / `pm2 list` / `pm2 all`
- [ ] `pm2 ports` / `pm2 proxy`
- [ ] `pm2 site <domena>`
- [ ] W kontekście: `pm2 restart` / `reload` / `stop` / `start` / `logs` / `save`
- [ ] Uruchomienie jako user strony (`runuser` / `sudo -u`), nie root

## SSL (globalnie)

- [ ] `ssl` — lista / status
- [ ] `renew-ssl` / `renew-ssl <domena>` — anulowanie

## Konfiguracja i pakiety (OS-specific)

- [ ] `hmtools.conf` — odczyt `RCLONE_REMOTE` / `FORCE_*`
- [ ] `FORCE_PANEL` / `FORCE_WEBSERVER` zmienia wynik `detect`
- [ ] Menedżer pakietów zgodny z OS (apt vs dnf/yum) przy `php --refresh` / `update-php`
- [ ] (opcjonalnie) `SITES_ROOT` — `webs delete` / `ols cache flush` akceptuje ścieżkę

## Tryb restricted (symulacja)

> Tylko jeśli celowo testujesz niewspierany OS / `OS_SUPPORTED=0`.

- [ ] Prompt `hmtools[unsupported]>`
- [ ] Blokada zwykłych komend (np. `webs` → błąd)
- [ ] Dozwolone: `uninstall-hmtools`, `help`, `version`, `detect`, `exit`
- [ ] `ALLOW_UNSUPPORTED_OS=1` przywraca pełny tryb
