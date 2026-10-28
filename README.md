# hmtools — narzędzia SSH dla VPS (OpenLiteSpeed / CyberPanel)

Zestaw narzędzi CLI instalowanych w `/hm-tools`. Po uruchomieniu `hmtools` wchodzisz w interaktywny kontekst: listujesz usługi webowe, wchodzisz w konkretną stronę (`use`), wykonujesz operacje i wracasz przez `exit`.

Panel i webserver **nie są hardcodowane** — skrypt wykrywa CyberPanel, OpenLiteSpeed, MariaDB/MySQL w runtime.

---

## Wymagania

- Linux VPS, dostęp **root**
- Bash 4+
- OpenLiteSpeed i/lub CyberPanel (opcjonalnie — działa też na samym OLS / skanie `/home/*/public_html`)
- Do backupów na Google Drive: **[rclone](https://rclone.org/)**
- Opcjonalnie: `openssl`, `gzip`, `tar`, klient `mysql`/`mariadb`

---

## Instalacja i aktualizacja

Repozytorium: [github.com/hubert-m/vps-ssh-tools](https://github.com/hubert-m/vps-ssh-tools).

Na serwerze jako **root** — **to samo polecenie** instaluje i aktualizuje do **najnowszego git taga**:

```bash
curl -fsSL https://raw.githubusercontent.com/hubert-m/vps-ssh-tools/develop/install.sh | bash
```

Wymagane: `curl`, `tar`, `bash`. Historia wersji i polecenia instalacji konkretnych tagów: [CHANGELOG.md](CHANGELOG.md).

### Starsza / konkretna wersja

```bash
HMTOOLS_VERSION=v0.1.0 curl -fsSL https://raw.githubusercontent.com/hubert-m/vps-ssh-tools/develop/install.sh | bash
```

### Z poziomu hmtools

```text
hmtools> version              # lokalna vs najnowszy tag + changelog
hmtools> update-hmtools       # update tylko gdy jest nowszy tag
hmtools> update-hmtools --force
```

Jeśli lokalna wersja = najnowszy tag, instalator **nic nie nadpisuje** (chyba że `HMTOOLS_FORCE=1` / `--force`).  
Istniejący `/hm-tools/config/hmtools.conf` jest zawsze zachowywany przy update.

### Uruchomienie

```bash
hmtools
```

Jednorazowo (bez REPL):

```bash
hmtools webs --quick
hmtools health
hmtools version
hmtools update-hmtools
hmtools uninstall-hmtools --yes
```

### Odinstalowanie

```text
hmtools> uninstall-hmtools
```

Usuwa `/hm-tools` oraz symlinki (`/usr/bin/hmtools`, `/usr/local/bin/hmtools`).  
Nie usuwa rclone ani backupów na Google Drive.

---

## Szybki start

```text
# hmtools
hmtools> detect
hmtools> webs
 #  DOMAIN              PHP    SSL   SIZE    STATUS
 1  example.com         8.2    yes   12.4G   active
 2  blog.example.com    8.1    yes    2.1G   active

hmtools> use 1
[example.com]> info
[example.com]> dbs
[example.com]> backup
[example.com]> exit
hmtools> backup full
hmtools> exit
```

- `webs` — lista usług (dodaj `--quick`, żeby pominąć wolne `du`)
- `use <numer|domena>` — wejście w kontekst strony (**Tab** uzupełnia domenę)
- `exit` w kontekście — powrót do `hmtools>`
- `exit` na poziomie głównym — wyjście do SSH

---

## Mapa komend

### Globalne (`hmtools>`)

| Komenda | Opis |
|---------|------|
| `webs [--quick]` | Lista usług webowych |
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
| `php` | LSPHP: lista vs repo (`--refresh` / `--phpnet`), `set`/`ext`/`ini`/`restart`/`ps` |
| `update-php <ver>` | Aktualizacja LSPHP (np. `8.4`) z potwierdzeniem |
| `health` | Load, RAM, dysk, OLS/MySQL, certy &lt;14 dni, wrażliwe porty |
| `security …` | Audyt: `ports`, `ssh`, Fail2Ban `ban`/`unban`, `scan` docroot |
| `detect` | Wypisz wykryty panel / webserver / DB |
| `help [polecenie]` | Lista komend lub pomoc do wybranej (np. `help use`) |
| `exit` | Wyjście |

### W kontekście strony (`[domena]>`)

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
| `exit` | Wyjście z kontekstu |

### PM2 / Node / Next

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

---

## Auto-detekcja

`lib/detect.sh` ustawia m.in.:

| Sygnał | Wynik |
|--------|--------|
| `/usr/local/CyberCP` lub CLI `cyberpanel` | `PANEL=cyberpanel` |
| `/usr/local/lsws` + conf OLS | `WEBSERVER=openlitespeed` |
| gniazdo MySQL + `mariadb`/`mysql` | `DB_ENGINE` |

**Discovery stron (kolejność):**

1. CyberPanel (`listWebsitesJson` / tabela `websites_website`)
2. Katalogi vhostów OLS (`/usr/local/lsws/conf/vhosts/*`)
3. Fallback: `/home/*/public_html`

Ścieżki docroot, PHP, SSL czytane z vhosta OLS i metadanych panelu — bez zakładania na sztywno layoutu CyberPanel.

Bazy danych:

- **confirmed** — z CyberPanel (`databases_databases`)
- **detected** — z `wp-config.php`, `.env`, `configuration.php`
- **prefix-match** — nazwy DB pasujące do prefiksu domeny

---

## Konfiguracja

Plik: `/hm-tools/config/hmtools.conf`  
Wzór: [`config/hmtools.conf.example`](config/hmtools.conf.example)

Ważne zmienne:

```bash
RCLONE_REMOTE="gdrive:vps-backups"   # root: full/ + <domena>/ + db-dumps/
MIN_FREE_PERCENT=5
CHUNK_SIZE_MB=512
CHUNK_THRESHOLD_MB=2048
TMP_DIR="/tmp/hmtools-backup"
BACKUP_EXCLUDES="cache node_modules .git *.log tmp temp wp-content/cache"
BACKUP_KEEP_DAYS=14          # retencja: backup prune / schedule
BACKUP_KEEP_MIN=3

LOG_ENABLED=1
LOG_DIR="/hm-tools/logs"
LOG_RETENTION_DAYS=30
LOG_LEVEL="INFO"
LOG_CAPTURE_OUTPUT=1          # cały output sesji → log
LOG_RUN_MAX_LINES=400         # limit linii z hm_run (apt, rclone, …)
```

---

## Logi pracy hmtools

Każda sesja trafia do plików dziennych:

```text
/hm-tools/logs/hmtools-2026-10-27.log
```

Rejestrowane m.in.:

| Prefiks | Znaczenie |
|---------|-----------|
| `CMD` / `CMD_END` | Komenda użytkownika + kod wyjścia i czas |
| `OUT` / `ERR` | Cały stdout/stderr sesji (tabele, komunikaty) |
| `RUN` / `RUN_OUT` / `RUN_END` | Zewnętrzne polecenia (`apt`, `rclone`, `cyberpanel`, …) |
| `CONFIRM` | Odpowiedzi yes/no / t/N |

Przykład:

```text
2026-10-27 14:35:01 [INFO] site=example.com CMD: backup
2026-10-27 14:35:01 [INFO] site=example.com RUN: rclone rcat gdrive:…/files.tar.gz
2026-10-27 14:35:40 [INFO] site=example.com CMD_END: rc=0 duration=39s
```

Podgląd z REPL: `applog` / `applog 200`.  
Wyłączenie capture outputu: `LOG_CAPTURE_OUTPUT=0` w `hmtools.conf`.

---

## Google Drive przez rclone

Backupy **nie zapisują pełnego archiwum lokalnie** — streamują do rclone (`rcat`) albo wysyłają małe chunki i od razu je usuwają. Przy ~90% zajętości dysku nadal sprawdzany jest próg `MIN_FREE_PERCENT`.

### 1. Instalacja rclone

```bash
hmtools
hmtools> backup setup
```

albo ręcznie:

```bash
curl https://rclone.org/install.sh | bash
rclone version
```

### 2. Remote Google Drive

```bash
rclone config
```

Zalecany przebieg:

1. `n` — New remote  
2. Nazwa, np. `gdrive`  
3. Storage: **Google Drive**  
4. `client_id` / `client_secret` — Enter (puste na start)  
5. Scope: Full access (lub węższy, jeśli wolisz)  
6. Autoryzacja Google  

**VPS bez przeglądarki:** na lokalnym komputerze z rclone:

```bash
rclone authorize "drive"
```

Wklej uzyskany token w `rclone config` na serwerze.

### 3. Katalog root na Drive (jednorazowo)

`backup setup` lub później:

```text
hmtools> backup config
```

Zapisze np.:

```bash
RCLONE_REMOTE="gdrive:vps-backups"
```

Ręcznie: `nano /hm-tools/config/hmtools.conf`  
Podgląd: `backup show`

### 4. Test

```bash
hmtools> backup test
# lub
rclone lsd gdrive:
rclone mkdir gdrive:vps-backups
```

### 5. Backup

```text
[example.com]> backup                 # → <root>/example.com/<stamp>/
hmtools> backup full                  # → <root>/full/<stamp>/
hmtools> backup list example.com
hmtools> backup restore example.com   # najnowszy stamp (z potwierdzeniem)
hmtools> backup prune --dry-run
hmtools> backup schedule enable
hmtools> mysql dump nazwa_db          # → <root>/db-dumps/
hmtools> mysql dump nazwa_db --local  # lokalny .sql.gz (np. ~/backups/)
```

Struktura na Drive:

```text
vps-backups/                          ← root (RCLONE_REMOTE)
  full/20261027-143000/               ← pełna kopia serwera
    system-configs.tar.gz
    databases/*.sql.gz
    sites/<domena>/...
    manifest.json
  projects.unideverse.com/20261027-150000/   ← kopia jednej strony
    files.tar.gz   (lub files.chunks/)
    db/nazwa.sql.gz
    vhost.conf
    manifest.json
  db-dumps/
    nazwa-20261027-151000.sql.gz
```

### Jak działają backupy (miejsce na dysku)

1. **Sprawdzenie wolnego %** — poniżej `MIN_FREE_PERCENT` → abort.  
2. **DB:** dump do pliku tymczasowego, potem upload (bez pustych `.sql.gz` na Drive przy błędzie).  
3. **Pliki (mniejsze):** `tar | gzip | rclone rcat` (tar kod 1 „file changed” = ostrzeżenie, nie abort).  
4. **Pliki (duże, &gt; `CHUNK_THRESHOLD_MB`):** `tar | gzip | split` → upload chunka → **usuń lokalnie** (w `TMP_DIR` zostaje tylko bieżący kawałek).  
5. Na końcu `manifest.json` z metadanymi.

---

## Przywracanie

Z poziomu hmtools (zalecane):

```text
hmtools> backup list example.com
hmtools> backup restore example.com              # najnowszy
hmtools> backup restore example.com 20261027-150000
hmtools> backup restore example.com --files-only
```

Ręcznie (rclone + tar), gdy wolisz poza hmtools:

```bash
rclone ls gdrive:vps-backups/example.com/
rclone copy gdrive:vps-backups/example.com/<stamp>/ ./restore/
mkdir -p /home/example.com
tar -xzf restore/files.tar.gz -C /home/example.com
# chunki:
cat restore/files.chunks/files.tar.gz.part_* > files.tar.gz
tar -xzf files.tar.gz -C /home/example.com
gunzip -c restore/db/nazwa.sql.gz | mysql nazwa
```

Po restore: uprawnienia (`perms fix`), vhost OLS, ewentualnie `ols reload`.

---

## Troubleshooting

| Objaw | Co sprawdzić |
|-------|----------------|
| Pusta lista `webs` | `detect` — czy OLS/CyberPanel widoczne; czy istnieją `/home/*/public_html` |
| `backup` pada na rclone | `backup test`, `rclone config`, poprawne `RCLONE_REMOTE` |
| Abort przez dysk | Zwolnij miejsce lub tymczasowo obniż `MIN_FREE_PERCENT` (ostrożnie) |
| Brak baz przy stronie | Heurystyka vs CyberPanel DB; sprawdź `wp-config.php` / uprawnienia MySQL jako root |
| `ols reload` nie działa | `/usr/local/lsws/bin/lswsctrl`, czy proces `lshttpd` żyje |
| 403 po wgraniu plików jako root | `[domena]> perms check` / `perms fix` (docroot `user:nogroup` 750) |
| `.htaccess` „nie działa” | `htaccess` — `autoLoadHtaccess` + `ols reload` |
| Autoryzacja Drive na headless | `rclone authorize "drive"` lokalnie + wklejenie tokena |
| Podejrzenie otwartego MySQL/Redis | `security ports` / `health` |

Logi / ścieżki konfiguracji:

- Narzędzia: `/hm-tools`
- Conf: `/hm-tools/config/hmtools.conf`
- Logi pracy: `/hm-tools/logs/hmtools-YYYY-MM-DD.log`
- Tmp chunków: `/tmp/hmtools-backup` (domyślnie)

---

## Struktura repo

```text
vps-ssh-tools/
├── README.md
├── CHANGELOG.md
├── VERSION                 # np. v0.1.6
├── changelogs/*.txt        # punktowy changelog (CLI + instalator)
├── install.sh
├── bin/hmtools
├── lib/           # help, logging, detect, db, size, rclone, ols (+ loadery)
│   ├── common/    # ui, config, context, self
│   ├── complete/  # helpers, tab
│   ├── backup/    # core, list, restore, prune, schedule
│   └── sites/     # vhost, ssl, discover, print, php, php_manage
├── commands/      # webs, site_shell, backup, disk, ols, ssl, mysql,
│                  # health, cron, pm2, security
├── config/hmtools.conf.example
├── .github/workflows/lint.yml   # obecnie wyłączone (workflow_dispatch + if: false)
└── scripts/setup-rclone.sh
```



---

## Licencja / użycie

Narzędzia przeznaczone do administracji **własnym** VPS jako root. Backupy zawierają dane produkcyjne — chroń dostęp do remote Google Drive i tokenów rclone (`~/.config/rclone/rclone.conf`).
