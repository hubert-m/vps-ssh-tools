# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/pl/1.1.0/) · [Semantic Versioning](https://semver.org/lang/pl/).

Pliki punktowe dla CLI (`version`, `update-hmtools`): ten katalog (`changelogs/*.txt`).

**Instalator** (`install.sh` z brancha `develop`) domyślnie instaluje **najnowszy git tag**.  
Konkretną wersję wymuszasz zmienną `HMTOOLS_VERSION`.

```bash
# zawsze najnowszy tag
curl -fsSL https://raw.githubusercontent.com/hubert-m/vps-ssh-tools/develop/install.sh | bash
```

---

## [Unreleased] / [v0.1.9]

- Fix: `hm_ols_remove_domain_from_conf` — usuwa też `# hmtools restore — <domena>` (bez kumulacji po archive→restore)
- Fix: polszczyzna „1 dzień temu” (wiek indeksu apt/rpm; cert SSL) zamiast „1 dni temu”
- Feat: `access` — zarządzanie SSH (passwd/shell/keys) i FTP (CyberPanel/pure-pw) per strona (`HM_SITE_USER`)
- Fix: `backup site` / `backup full` — błąd mysqldump → `status: partial`, NIEKOMPLETNY, rc≠0 (nie cichy sukces)
- Fix: `security ban` / ufw — `prepend deny` (v4+v6), DETEKCJA tylko DENY/REJECT; rc≠0 przy całkowitej porażce
- Fix: `chrome version` — zachowanie rc timeoutu (124), bez `if ! …; then $?` (fałszywe rc=0)
- Feat: `redis` — detekcja, status/memory/dbs/clients/slowlog/sites, config/flush/restart/client kill
- Fix: zapis `httpd_config.conf` przez `cat >` (nie `mv` z mktemp 0600); bez narastających pustych linii przy archive/restore
- Fix: `security ban` — pełny ban ufw tylko przy DENY `Anywhere`/`Anywhere (v6)` (nie DENY na pojedynczy port)
- Fix: `access ftp` (pure-pw) — passwd/delete tylko dla kont należących do strony; `ftp add` respektuje ścieżkę w root
- Fix: `access … <domena>` — `hm_access_resolve_site` bez subshella `$(…)` (HM_SITE_*); `access status` → rc≠0 przy błędzie
- Fix: `access ssh keys` — odmowa symlinków `~/.ssh`/`authorized_keys` (bez zapisu/chown do plików poza home)

## [v0.1.8]

- Refactor: `lib/pkg.sh` + `pkg/apt|rpm` — adapter menedżera pakietów; PHP/`update-php`/`ext` bez `case apt|dnf|yum`
- Refactor: `lib/os_family.sh` + `os/debian|rhel` — web group, apache, firewall; override per `OS_ID`
- Feat: `FORCE_PKG_MANAGER` w conf; docs `architecture-pkg.md` + reguła Cursor distro-adapters
- Feat: `php` — sekcja nowszych gałęzi LSPHP dostępnych w repo do instalacji (kanał stable/niepewna → `update-php`)
- Docs: `CHANGELOG.md` przeniesiony do `changelogs/CHANGELOG.md`
- Docs: `docs/FAQ.md` — FAQ z sekcjami toggle; pierwsze Q: mechanizm `update-php <ver>` (pełny przebieg krok po kroku)
- Refactor: komendy jako moduły `commands/<narzędzie>/` + loader `_load.sh`
- Refactor: logika toolowa `lib/backup/*` / `lib/sites/*` → `commands/backup|php|delete-site|_shared/sites/`
- Feat: pluginowy dispatch (`_dispatch.sh`) — aliasy / restricted / site bez centralnego `case`
- Docs: `structure.md` + `architecture-commands.md` (kontrakt rejestru modułów)
- Refactor: `help <polecenie>` — treści w `commands/*/main.sh` (`_hm_cmd_help` / `HM_CMD_HELP`); brak wpisu → „Brak podpowiedzi dla tego polecenia”
- Feat: detect — Supervisor + Chrome/Chromium (headless); `FORCE_SUPERVISOR` / `FORCE_CHROME_BIN`
- Feat: komendy `supervisor` (status/ctl/logs) i `chrome` (info/which/version/test headless); skrót w `health`
- Fix: `hm_detect_chrome` — bez `--version` na starcie (timeout 3s / leniwie); `/snap/bin/chromium`; trim wersji; 1× warn FORCE
- Fix: `help` / Tab z rejestru `HM_CMD_*` (w tym chrome/supervisor + podkomendy Tab)
- Fix: `supervisor` — logs = linie (nie bajty); `all` w kontekście = tylko strona + confirm; `FORCE_SUPERVISOR=no`; detect bez false-yes na samym conf; filtr user dokładny
- Fix: `security ban/unban` — dokładny match ufw; IPv6 (firewalld/ip6tables); ban we wszystkich jailach; walidacja IP; ostrzeżenie self-ban
- Fix: rpm candidate = dokładna nazwa pakietu; walidacja FORCE_*; komunikaty update-php / wiek indeksu
- Fix: `php` / php.net — `{"error":"Unknown version"}` nie cache’owane; kanał „brak danych” zamiast false-stable (`hm_php_parse_phpnet_json`)
- Fix: `webs delete` / archive — `virtualhost` case-insensitive w httpd_config; denylista `SITES_ROOT`; bez `pkill` na współdzielonym userze; inwentarz `--keep-db`; hardening `uninstall-hmtools`
- Fix: `backup restore` z archive — odtwarza ols-vhost-dir + snippet httpd_config/map; `webs archive` czyści niepełny snapshot na Drive (`hm_archive_purge_remote`)
- Fix: `backup full --yes` (cron); anulowanie bez TTY → rc≠0; walidacja stamp; niepełne snapshoty: purge/list BAD/prune; `backup site` rc≠0 przy błędzie plików
- Fix: polish `php` (kolumny ASCII, subpakiety w statusie, nieparsowalna wersja); `ols cache` bez global cachedata per-domena; walidacja nazwy proxy przed confirm
- Fix: `help`/`use` — kontekst z perms/htaccess/proxy/archive/supervisor; `logs` bez surowego `ls -la` przy braku plików
- Fix: `mysql dump-local` — walidacja ścieżki przed mkdir, umask 077; `mysql create` — hasło przez stdin (nie `-e`); install.sh `${DEST:?}`
- Fix: TSV `hm_resolve_site_paths` / `hm_dbs_for_site` — puste pola jako `-` (`hm_tsv_field`), bez zlewania kolumn przy `IFS=tab`; test `scripts/test-tsv-fields.sh`
- Fix: drobne UX/walidacja (retest v0.1.8) — chrome FORCE etykieta + timeout version; supervisor/cache/delete/restore cancel → rc≠0; detect FORCE warn 1×; IP (0.0.0.0, IPv6); port 99999; PHP `?` poza Nowsze; pkg OS_FAMILY przed apt-get; php.net negative-cache 10 min; cache flush bez podwójnego liczenia/„Uwaga”; webs `--keep-db` banner; restore bez pustego `/home` i bez duplikatu vhconf; list bez pustej tabeli; snapshot bez files* = BAD; mysql help `${TMP_DIR}/hmtools-db`; update-check tylko semver
- Fix: `security ban` / ufw — `ufw insert 1 deny from IP` (DENY przed ALLOW 22/80/443); komunikat gdy f2b OK a firewall nie
- Fix: `pm2 list` — puste pola TSV (script/porthint) jako `-` w jq; bez przesunięcia RST→PORT; ols/db hardening; test-tsv-fields
- Fix: `backup full` — błędy plików/konfig → status `partial` + rc≠0 (nie „zakończony”); restore OLS mapy per-listener (`# listener:`) bez dublowania
- Fix: `backup restore` — po ols-vhost-dir nie dokłada zbędnego `vhconf.conf` (używa istniejącego `vhost.conf` / `hm_vhost_conf_path`; standalone → `vhost.conf`)
- Fix: polish php — gramatyka wieku indeksu (`indeks z:` / `indeks:`); RPM candidate strip `.arch` z `dnf check-update`; `hm_run` przywraca stan `set -e`; `update-php` przeżywa refresh rc≠0; gałąź z `lsphpNN` przy ver=`?`
- Fix: `help` — lista kontekstu z przecinkami+spacjami (nie sklejona); tylko kanoniczne SITE (bez aliasów databases/log/perm); bez sekcji kontekstu w restricted; jedna stopka; `help` w kontekście ma `supervisor`; blurb z opisu nie z linii użycia

## [v0.1.7]

- `webs`: pod listą — suma rozmiarów wszystkich serwisów (kolumna SIZE)
- Docs: README → `docs/*.md` (install, commands, backup, …) + linki w README
- Fix: `hmtools -c "cmd args"` — rozbijanie zacytowanej komendy (cron `backup`/`prune`)
- Fix: `PIPESTATUS` — snapshot tablicy po potoku (`mysqldump`/`tar`; `set -u`)
- Fix: `backup restore` — bez podwójnego `gunzip`; walidacja nazw baz (`hm_is_valid_db_name`)
- Fix: `ols cache flush` — pusta lista LSCache; whitelist `/var/www`; `proxy set-port [domena]`
- Fix: `mysql dump --local <katalog>` — zapis `${db}-stamp.sql.gz` w podanym katalogu
- Fix: `php` — puste pola TSV (`cand_clean`/`branch`) nie zlewają kolumn przy `IFS=tab`
- Fix: `webs archive` — stdout trybu plików (`>&2`); puste `archive_dbs` bez fałszywej iteracji
- Fix: `webs delete` — puste tablice bez `[@]:-`; whitelist `SITES_ROOT`
- Feat: `detect` — karta stosu (OS/panel/WWW/DB), hinty narzędzi, `FORCE_*` w conf
- Feat: wsparcie OS (Ubuntu/Debian/Alma/Rocky/CentOS) + tryb restricted → `uninstall-hmtools`
- Docs: `docs/tested/` — checklisty testów ręcznych per OS (checkboxy)

## [v0.1.6]

- Docs: README — mapa komend (`ols`/`mysql`/`pm2`/`security`/`backup`/`perms`), restore, troubleshooting
- UX: `hm_progress_bar` / `hm_status_line` na TTY (fd 3 przy tee logów) — bez śmieci w logach
- UX: `hm_run` — spinner + czas + ostatnia linia podczas apt/acme/certbot/…
- UX: postęp w `webs`/`php`/`info`/`size`/`clean`/`perms`/`disk`/`ssl`/`health`/`mysql`/`backup`/`security`/`logs`/`pm2`
- `php`: Candidate z `apt-cache`/`dnf` (nie php.net); flagi `--refresh` / `--phpnet`; `update-php` spójny z repo
- UX: `hm_confirm_plan` / `hm_confirm_plan_critical` — plan kroków + wpisanie `yes` przed ciężkimi operacjami
- `webs delete` / `delete-site` — całkowite usunięcie serwisu (inwentaryzacja + plan critical)
- `webs archive` / `backup archive` — Drive + Atomic Guard + usunięcie; `prune` chroni `type=archive`

## [v0.1.5]

- Fix: `pm2` w kontekście `use` — bin/PM2_HOME ze strony (nie cudzy nvm z `/home/*`)
- Fix: Tab przy wielu dopasowaniach nie wywala hmtools (`set -e` + `bind -x`)
- `php`: porównanie zainstalowanych LSPHP z najnowszymi wersjami z php.net
- `update-php` / `php update <ver>` — aktualizacja `lsphp*` z potwierdzeniem + reload OLS
- `ssl`: wyraźny czerwony alert przy wygasłym certyfikacie
- `renew-ssl` / `ssl renew` — odnowienie Let's Encrypt (cyberpanel / acme / certbot)
- Fix: `dbs` w kontekście strony — poprawny schemat CyberPanel + heurystyki
- `dbs` globalnie: sortowanie malejąco po rozmiarze
- `clean`: szczegółowy podgląd (ścieżki/rozmiary/zawartość) + potwierdzenie yes/no
- `size` (kontekst strony): dodatkowy poziom — top w `public_html` / dużych katalogach
- `backup config`: katalog root na Drive; struktura `full/` + `<domena>/`
- Logi: pełny capture stdout/stderr sesji, `CMD_END`, `hm_run`, `CONFIRM`
- Fix: crash `local` poza funkcją w `bin/hmtools` (oneshot + REPL)
- Fix: unbound `$1` przy `use` / `mysql dump` / `cron user` bez argumentu (`set -u`)
- `backup list [domena|full]` — snapshoty + manifest z Drive
- `backup restore` — odtwarzanie `files.tar.gz` / `files.chunks` + baz (+ vhost/chown/ols)
- `backup prune [--days N] [--dry-run] [--yes]` + `BACKUP_KEEP_DAYS` / `BACKUP_KEEP_MIN`
- `backup schedule [enable|disable|status]` → `/etc/cron.d/hmtools-backup`
- Refactor: `lib/backup.sh` → `lib/backup/{core,list,restore,prune,schedule}.sh`
- Refactor: `lib/sites.sh` → `lib/sites/{vhost,ssl,discover,print,php}.sh`
- Refactor: `lib/common.sh` → `lib/common/{ui,config,context,self}.sh`
- Refactor: `lib/complete.sh` → `lib/complete/{helpers,tab}.sh`
- `php set <ver>` — przełączanie LSPHP strony (vhost / CyberPanel + reload)
- `php ext` / `php ext install` — moduły `php -m` + instalacja `lsphpXX-*`
- `php ini` / `php ini set` — limity `php.ini` + nadpisania vhost / `.user.ini`
- `php restart` / `php ps` — kill workerów Detached Mode + podgląd procesów
- Refactor: `setup-rclone` → `hm_rclone_save_remote_conf` (bez `.bak`)
- Refactor: wspólny `hm_ols_reload_soft` (`detect`) w `ols` / `ssl` / health / php
- Refactor: health SSL przez `hm_ssl_status` / `hm_ssl_days_left`
- Fix: martwe warunki vhroot/docroot; `clean` → `hm_confirm`; ssl acme/certbot → `hm_run`
- CI: `.github/workflows/lint.yml` (`bash -n` + shellcheck)
- Fix: REPL/`-c` — bez rozwijania globów (`set -f`, `"$@"`) przy `?` / `*`
- Fix: log capture — TTY fd 3/4, detach przy prompcie; `hm_run_on_tty` dla `cron edit` / `rclone config`
- Fix: `hm_discover_sites` zawsze skanuje vhosty OLS (także przy CyberPanelu)
- Fix: `hm_ssl_paths_for_domain` — `certFile` + `$VH_ROOT` / `$SERVER_ROOT`
- Fix: `renew-ssl` poza `use` — webroot z `hm_resolve_site_paths`
- Fix: Tab w kontekście strony podpowiada `info` / `size` / `logs` / `clean` / `back`
- CI: lint — tylko `workflow_dispatch` + `if: false` (zero uruchomień przy push/PR)
- Security: walidacja nazw DB / domen przed SQL i `mysqldump`
- Security: walidacja `RCLONE_REMOTE` przed zapisem do `hmtools.conf`
- Security: `pm2` tylko systemowy bin + `runuser` na właścicielu `PM2_HOME`
- Security: `clean` — bez symlinków poza katalogiem strony
- Security: `LOG_DIR` / `TMP_DIR` `0700`, pliki logów `0600`
- Fix: tar kod 1 (file changed) nie przerywa `backup site`/`full`; stderr widoczny
- Fix: `mysqldump` → lokalny tmp, potem upload (bez pustych `.sql.gz` na Drive)
- Fix: brak duplikatu `/etc/crontab` w backup system configs
- `ols stats` / `top` — live `.rtreport` (RPS, vhosty, WAITQUE LSAPI)
- `ols htaccess` / `htaccess enable` — `autoLoadHtaccess` + mtime vs OLS
- `ols cache status|flush` + `clean --lscache`
- `ols proxy` / `proxy set-port` — zdrowie backendów reverse proxy
- `ols admin status|pass` — port WebAdmin, tunel SSH, `admpass.sh`
- `mysql`: `dump --local` / `dump-local`, `import`, `cli`, `top`, `optimize`, `create`
- `pm2`: `restart`/`reload`/`stop`/`start`/`logs`/`save` jako właściciel `PM2_HOME`
- `perms [check|fix]` — uprawnienia OLS/CyberPanel (`docroot` nogroup `750`)
- `logs`: `stderr.log` OLS, `errors`, `stats`/`top` (HTTP/IP/URL), `follow`
- `security`: `ports`, `status`, `ssh`, `fail2ban`/`ban`/`unban`, `scan` docroot
- `health`: skrócone ostrzeżenia o publicznych portach wrażliwych

---

## [v0.1.4] — 2026-10-27

### Instalacja tej wersji

```bash
curl -fsSL https://raw.githubusercontent.com/hubert-m/vps-ssh-tools/develop/install.sh | bash

HMTOOLS_VERSION=v0.1.4 curl -fsSL https://raw.githubusercontent.com/hubert-m/vps-ssh-tools/develop/install.sh | bash
```

### Zmiany

- Fix: prompt `hmtools>` / `[domena]>` nie znika przy pisaniu / Tab
- Prompt w `read -e -p` (readline); Tab bez zbędnego outputu
- Wczesny cache domen; lista kandydatów dopiero przy 2. Tab (gdy brak postępu)
- Ekran powitalny: żółte powiadomienie o nowszej wersji + komenda curl|bash
- `pm2`: czytelniejsza tabela, sortowanie po porcie ↑, skan PM2_HOME użytkowników
- Fix: resolucja `$VH_ROOT` / usera strony (`cron` w `use`, info, ścieżki)
- `cron` w kontekście: skan crontabów użytkowników; kompletna lista komend po `use`

---

## [v0.1.3] — 2026-10-27

### Instalacja tej wersji

```bash
# najnowsza (gdy v0.1.3 jest aktualnym tagiem) — bez HMTOOLS_VERSION
curl -fsSL https://raw.githubusercontent.com/hubert-m/vps-ssh-tools/develop/install.sh | bash

# na sztywno v0.1.3
HMTOOLS_VERSION=v0.1.3 curl -fsSL https://raw.githubusercontent.com/hubert-m/vps-ssh-tools/develop/install.sh | bash
```

### Zmiany

- Fix: `pm2.sh` — błąd składni `[[ =~ ]]` (klasa `[= ]`) blokujący start hmtools

---

## [v0.1.2] — 2026-10-27

### Instalacja tej wersji

```bash
# najnowsza (gdy v0.1.2 jest aktualnym tagiem) — bez HMTOOLS_VERSION
curl -fsSL https://raw.githubusercontent.com/hubert-m/vps-ssh-tools/develop/install.sh | bash

# na sztywno v0.1.2
HMTOOLS_VERSION=v0.1.2 curl -fsSL https://raw.githubusercontent.com/hubert-m/vps-ssh-tools/develop/install.sh | bash
```

### Zmiany

- Tab-complete w REPL: `use <domena>` (oraz komendy / `backup` / `ols`)
- Dopasowanie domen także po zamianie `-`/`_` na kropki
- `help <polecenie>` — szczegółowa pomoc do konkretnej komendy
- `cron` / `crons` — lista i edycja CRON (system, users, kontekst strony)
- `pm2` / `node` / `apps` — procesy PM2/Node (porty, status, proxy OLS, filtr strony)

---

## [v0.1.1] — 2026-10-27

### Instalacja tej wersji

```bash
HMTOOLS_VERSION=v0.1.1 curl -fsSL https://raw.githubusercontent.com/hubert-m/vps-ssh-tools/develop/install.sh | bash
```

### Zmiany

- Stabilniejsza instalacja `curl | bash` (kopiowanie przez `/bin/cp`, bez `rsync`)
- Poprawne rozpakowywanie archiwum z GitHuba (bez `find|head` / `pipefail`)
- Obsługa skryptów bez bitu `+x` w repozytorium (`chmod` po extract)
- Fallback do brancha `develop`, gdy tarball taga się nie uda
- Symlink komendy w `/usr/bin/hmtools` (oraz `/usr/local/bin`) — działa gdy `/usr/local/bin` nie jest w `PATH`
- [`.gitattributes`](.gitattributes) — LF dla skryptów
- Czytelniejsze logi postępu instalacji (stderr)

---

## [v0.1.0] — 2026-10-27

### Instalacja tej wersji

```bash
HMTOOLS_VERSION=v0.1.0 curl -fsSL https://raw.githubusercontent.com/hubert-m/vps-ssh-tools/develop/install.sh | bash
```

### Zmiany

- Interaktywny shell kontekstowy (`webs` → `use` → `exit`)
- Auto-detekcja CyberPanel / OpenLiteSpeed / MariaDB–MySQL
- Lista i szczegóły stron (`info`, `size`, `dbs`, `ssl`, `php`, `logs`)
- Backupy streamingowe na Google Drive (rclone) — strona i cały serwer
- Oszczędność dysku: stream + chunki, próg wolnego miejsca
- Narzędzia: `disk`, `ols`, `ssl`, `mysql`, `health`, `clean`, `detect`
- Instalacja/aktualizacja jednym `curl | bash` (porównanie po git tagach)
- Logi pracy w `/hm-tools/logs` (`applog`)
- Komendy: `update-hmtools`, `version` (+ wypis changelogu)
- Powitanie po pierwszej instalacji
- Odinstalowanie: `uninstall-hmtools [--yes]`

---

[Unreleased]: https://github.com/hubert-m/vps-ssh-tools/compare/v0.1.2...HEAD
[v0.1.2]: https://github.com/hubert-m/vps-ssh-tools/releases/tag/v0.1.2
[v0.1.1]: https://github.com/hubert-m/vps-ssh-tools/releases/tag/v0.1.1
[v0.1.0]: https://github.com/hubert-m/vps-ssh-tools/releases/tag/v0.1.0
