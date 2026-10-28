# Google Drive przez rclone

Backupy **nie zapisują pełnego archiwum lokalnie** — streamują do rclone (`rcat`) albo wysyłają małe chunki i od razu je usuwają. Przy ~90% zajętości dysku nadal sprawdzany jest próg `MIN_FREE_PERCENT`.

## 1. Instalacja rclone

```bash
hmtools
hmtools> backup setup
```

albo ręcznie:

```bash
curl https://rclone.org/install.sh | bash
rclone version
```

## 2. Remote Google Drive

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

## 3. Katalog root na Drive (jednorazowo)

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

## 4. Test

```bash
hmtools> backup test
# lub
rclone lsd gdrive:
rclone mkdir gdrive:vps-backups
```

## 5. Backup

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

### Struktura na Drive

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

## Jak działają backupy (miejsce na dysku)

1. **Sprawdzenie wolnego %** — poniżej `MIN_FREE_PERCENT` → abort.  
2. **DB:** dump do pliku tymczasowego, potem upload (bez pustych `.sql.gz` na Drive przy błędzie).  
3. **Pliki (mniejsze):** `tar | gzip | rclone rcat` (tar kod 1 „file changed” = ostrzeżenie, nie abort).  
4. **Pliki (duże, &gt; `CHUNK_THRESHOLD_MB`):** `tar | gzip | split` → upload chunka → **usuń lokalnie** (w `TMP_DIR` zostaje tylko bieżący kawałek).  
5. Na końcu `manifest.json` z metadanymi.

Przywracanie: [restore.md](restore.md). Konfiguracja: [configuration.md](configuration.md).

← [README](../README.md)
