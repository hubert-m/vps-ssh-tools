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

Repozytorium: [github.com/hubert-m/vps-ssh-tools](https://github.com/hubert-m/vps-ssh-tools) (branch `develop`).

Na serwerze jako **root** — **to samo polecenie** instaluje i aktualizuje:

```bash
curl -fsSL https://raw.githubusercontent.com/hubert-m/vps-ssh-tools/develop/install.sh | bash
```

Alternatywa (GitHub przekierowuje na raw):

```bash
curl -fsSL https://github.com/hubert-m/vps-ssh-tools/raw/develop/install.sh | bash
```

Z poziomu już zainstalowanego hmtools:

```text
hmtools> version
hmtools> update-hmtools
hmtools> update-hmtools --force    # reinstalacja tej samej wersji
```

### Wersjonowanie (git tags)

Instalator porównuje:

- **remote:** najnowszy [git tag](https://github.com/hubert-m/vps-ssh-tools/tags) repozytorium (sortowanie semver),
- **local:** plik `/hm-tools/VERSION`.

Jeśli wersje są równe — **nic nie pobiera i nie nadpisuje**.  
Gdy nie ma jeszcze żadnego taga, używany jest fallback `develop@<sha>`.

Po wydaniu nowej wersji:

1. Uzupełnij `VERSION` (np. `v0.2.0`)
2. Dodaj `changelogs/v0.2.0.txt` (proste punkty — to widzi `version` / update)
3. Dopisz wpis w `CHANGELOG.md`
4. Utwórz tag:

```bash
git tag v0.1.0
git push origin v0.1.0
```

Co robi instalator:

1. Sprawdza najnowszy tag na GitHubie vs `/hm-tools/VERSION`
2. Gdy trzeba — pobiera tarball **tego taga** (nie „ślepo” cały branch)
3. Wgrywa pliki do `/hm-tools` (nadpisuje bin/lib/commands/scripts)
4. **Nie nadpisuje** istniejącego `/hm-tools/config/hmtools.conf`
5. Zapisuje `VERSION` + symlink `/usr/local/bin/hmtools`

Zmienne opcjonalne (przed `| bash`):

```bash
# konkretny tag / wymuszenie / inny katalog
HMTOOLS_VERSION=v0.1.0 curl -fsSL https://raw.githubusercontent.com/hubert-m/vps-ssh-tools/develop/install.sh | bash
HMTOOLS_FORCE=1 curl -fsSL ... | bash
HMTOOLS_DEST=/opt/hm-tools curl -fsSL ... | bash
```

Uruchomienie:

```bash
hmtools
```

Jednorazowa komenda bez REPL:

```bash
hmtools webs --quick
hmtools health
hmtools version
hmtools update-hmtools
hmtools uninstall-hmtools          # z potwierdzeniem
hmtools uninstall-hmtools --yes    # bez pytania
```

### Odinstalowanie

```text
hmtools> uninstall-hmtools
```

Usuwa katalog `/hm-tools` (w tym conf i logi) oraz symlink `/usr/local/bin/hmtools`.  
**Nie** usuwa rclone ani backupów na Google Drive.

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
- `use <numer|domena>` — wejście w kontekst strony
- `exit` w kontekście — powrót do `hmtools>`
- `exit` na poziomie głównym — wyjście do SSH

---

## Mapa komend

### Globalne (`hmtools>`)

| Komenda | Opis |
|---------|------|
| `webs [--quick]` | Lista usług webowych |
| `use <n\|domena>` | Wejście w kontekst strony |
| `backup setup` | Instalacja/konfiguracja rclone + Google Drive |
| `backup full` | Pełna kopia serwera → Drive |
| `backup site <domena>` | Kopia jednej strony |
| `backup test` | Test połączenia rclone |
| `update-hmtools [--force]` | Update z GitHuba + wypis „co nowego” |
| `version` | Wersja lokalna/remote + changelog tej wersji |
| `uninstall-hmtools [--yes]` | Usuwa `/hm-tools` i symlink (z potwierdzeniem) |
| `applog [N]` | Ostatnie N linii logu hmtools (domyślnie 50) |
| `disk` | `df`, inody, top `/home` |
| `ols [status\|reload\|restart\|log]` | OpenLiteSpeed |
| `ssl` | Certyfikaty SSL wszystkich stron |
| `mysql` / `dbs` | Lista baz (lub w kontekście: powiązane) |
| `mysql dump <db>` | Jedna baza streamem na Drive |
| `php` | Dostępne LSPHP |
| `health` | Load, RAM, dysk, OLS/MySQL, certy &lt;14 dni |
| `detect` | Wypisz wykryty panel / webserver / DB |
| `help` | Pomoc |
| `exit` | Wyjście |

### W kontekście strony (`[domena]>`)

| Komenda | Opis |
|---------|------|
| `info` | Pełne info: ścieżki, rozmiar, DB, SSL, PHP |
| `size` | Rozmiary katalogów + top `du` |
| `dbs` | Bazy (CyberPanel confirmed + heurystyka) |
| `ssl` | Certyfikat i data wygaśnięcia |
| `php` | PHP strony + lista LSPHP |
| `logs [N]` | Ostatnie N linii logów |
| `backup` | Pełna kopia środowiska (pliki + DB) → Drive |
| `clean` | Bezpieczne czyszczenie cache/tmp (z potwierdzeniem) |
| `exit` | Wyjście z kontekstu |

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
RCLONE_REMOTE="gdrive:vps-backups"
MIN_FREE_PERCENT=5
CHUNK_SIZE_MB=512
CHUNK_THRESHOLD_MB=2048
TMP_DIR="/tmp/hmtools-backup"
BACKUP_EXCLUDES="cache node_modules .git *.log tmp temp wp-content/cache"

LOG_ENABLED=1
LOG_DIR="/hm-tools/logs"
LOG_RETENTION_DAYS=30
LOG_LEVEL="INFO"
```

---

## Logi pracy hmtools

Każda sesja i komenda trafiają do plików dziennych:

```text
/hm-tools/logs/hmtools-2026-10-27.log
```

Przykładowa linia:

```text
2026-10-27 14:35:01 [INFO] site=example.com CMD: backup
2026-10-27 14:35:02 [INFO] site=example.com Backup strony example.com
```

Podgląd z REPL:

```text
hmtools> applog
hmtools> applog 200
```

Wyłączenie / zmiana poziomu — w `hmtools.conf` (`LOG_ENABLED=0`, `LOG_LEVEL=WARN`).

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

### 3. Wpis w hmtools.conf

`backup setup` zapisze np.:

```bash
RCLONE_REMOTE="gdrive:vps-backups"
```

Ręcznie:

```bash
nano /hm-tools/config/hmtools.conf
```

### 4. Test

```bash
hmtools> backup test
# lub
rclone lsd gdrive:
rclone mkdir gdrive:vps-backups
```

### 5. Backup

```text
[example.com]> backup          # pliki + DB strony
hmtools> backup full           # konfigi + wszystkie DB + wszystkie strony
hmtools> mysql dump nazwa_db   # jedna baza
```

Struktura na Drive (przykład):

```text
vps-backups/
  <hostname>/
    sites/example.com/20260327-143000/
      files.tar.gz          # lub files.chunks/ przy dużych tree
      db/nazwa.sql.gz
      vhost.conf
      manifest.json
    full/20260327-150000/
      system-configs.tar.gz
      databases/*.sql.gz
      sites/<domena>/...
      manifest.json
```

### Jak działają backupi (miejsce na dysku)

1. **Sprawdzenie wolnego %** — poniżej `MIN_FREE_PERCENT` → abort.  
2. **DB:** `mysqldump | gzip | rclone rcat` — bez pliku lokalnego.  
3. **Pliki (mniejsze):** `tar | gzip | rclone rcat`.  
4. **Pliki (duże, &gt; `CHUNK_THRESHOLD_MB`):** `tar | gzip | split` → upload chunka → **usuń lokalnie** (w `TMP_DIR` zostaje tylko bieżący kawałek).  
5. Na końcu `manifest.json` z metadanymi.

---

## Przywracanie (high-level)

```bash
# Lista
rclone ls gdrive:vps-backups/<host>/sites/example.com/

# Pobierz pliki (na maszynę z miejscem — niekoniecznie ten sam pełny VPS)
rclone copy gdrive:vps-backups/<host>/sites/example.com/<stamp>/ ./restore/

# Rozpakuj pliki
mkdir -p /home/example.com
tar -xzf restore/files.tar.gz -C /home/example.com

# Chunki: połącz i rozpakuj
cat restore/files.chunks/files.tar.gz.part_* > files.tar.gz
tar -xzf files.tar.gz -C /home/example.com

# Baza
gunzip -c restore/db/nazwa.sql.gz | mysql nazwa
```

Po restore sprawdź uprawnienia użytkownika strony, vhost OLS i ewentualnie `ols reload`.

---

## Troubleshooting

| Objaw | Co sprawdzić |
|-------|----------------|
| Pusta lista `webs` | `detect` — czy OLS/CyberPanel widoczne; czy istnieją `/home/*/public_html` |
| `backup` pada na rclone | `backup test`, `rclone config`, poprawne `RCLONE_REMOTE` |
| Abort przez dysk | Zwolnij miejsce lub tymczasowo obniż `MIN_FREE_PERCENT` (ostrożnie) |
| Brak baz przy stronie | Heurystyka vs CyberPanel DB; sprawdź `wp-config.php` / uprawnienia MySQL jako root |
| `ols reload` nie działa | `/usr/local/lsws/bin/lswsctrl`, czy proces `lshttpd` żyje |
| Autoryzacja Drive na headless | `rclone authorize "drive"` lokalnie + wklejenie tokena |

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
├── VERSION                 # np. v0.1.0
├── changelogs/v0.1.0.txt   # punktowy changelog (CLI + instalator)
├── install.sh
├── bin/hmtools
├── lib/           # common, logging, detect, sites, db, size, backup, rclone
├── commands/      # webs, site_shell, backup, disk, ols, ssl, mysql, health
├── config/hmtools.conf.example
└── scripts/setup-rclone.sh
```



---

## Licencja / użycie

Narzędzia przeznaczone do administracji **własnym** VPS jako root. Backupy zawierają dane produkcyjne — chroń dostęp do remote Google Drive i tokenów rclone (`~/.config/rclone/rclone.conf`).
