# Instalacja i aktualizacja

## Wymagania

- Linux VPS, dostęp **root**
- Bash 4+
- OpenLiteSpeed i/lub CyberPanel (opcjonalnie — działa też na samym OLS / skanie `/home/*/public_html`)
- Do backupów na Google Drive: **[rclone](https://rclone.org/)**
- Opcjonalnie: `openssl`, `gzip`, `tar`, klient `mysql`/`mariadb`

## Instalacja

Repozytorium: [github.com/hubert-m/vps-ssh-tools](https://github.com/hubert-m/vps-ssh-tools).

Na serwerze jako **root** — **to samo polecenie** instaluje i aktualizuje do **najnowszego git taga**:

```bash
curl -fsSL https://raw.githubusercontent.com/hubert-m/vps-ssh-tools/develop/install.sh | bash
```

Wymagane: `curl`, `tar`, `bash`. Historia wersji i polecenia instalacji konkretnych tagów: [CHANGELOG.md](../changelogs/CHANGELOG.md).

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

## Uruchomienie

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

## Odinstalowanie

```text
hmtools> uninstall-hmtools
```

Usuwa `/hm-tools` oraz symlinki (`/usr/bin/hmtools`, `/usr/local/bin/hmtools`).  
Nie usuwa rclone ani backupów na Google Drive.

← [README](../README.md)
