# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/pl/1.1.0/) · [Semantic Versioning](https://semver.org/lang/pl/).

Pliki punktowe dla CLI (`version`, `update-hmtools`): katalog [`changelogs/`](changelogs/).

**Instalator** (`install.sh` z brancha `develop`) domyślnie instaluje **najnowszy git tag**.  
Konkretną wersję wymuszasz zmienną `HMTOOLS_VERSION`.

```bash
# zawsze najnowszy tag
curl -fsSL https://raw.githubusercontent.com/hubert-m/vps-ssh-tools/develop/install.sh | bash
```

---

## [Unreleased] / [v0.1.7]

- `webs`: pod listą — suma rozmiarów wszystkich serwisów (kolumna SIZE)
- Docs: README → `docs/*.md` (install, commands, backup, …) + linki w README
- Fix: `hmtools -c "cmd args"` — rozbijanie zacytowanej komendy (cron `backup`/`prune`)
- Fix: `PIPESTATUS` — snapshot tablicy po potoku (`mysqldump`/`tar`; `set -u`)

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
