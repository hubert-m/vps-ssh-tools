# Przywracanie

Z poziomu hmtools (zalecane):

```text
hmtools> backup list example.com
hmtools> backup restore example.com              # najnowszy
hmtools> backup restore example.com 20261027-150000
hmtools> backup restore example.com --files-only
hmtools> backup restore example.com --overwrite-db        # niepusta DB
hmtools> backup restore example.com --overwrite-files     # niepusty katalog docelowy
hmtools> backup restore example.com --adopt-existing-user # przejęcie istniejącego Unix
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

### Snapshot `archive` (po `webs archive`)

Gdy w snapshocie są artefakty kont:

1. **unix-account.meta** (+ opcjonalnie `unix-authorized_keys`) — `useradd` / `chpasswd -e` / klucze SSH. Jeśli konto **już istnieje**: domyślna **odmowa** (`KOLIZJA Unix`); świadome przejęcie: `--adopt-existing-user`. Przy `shared=1`/`protected=1` — **bez** mutacji hasła/kluczy/home; pliki tylko do `docroot` z manifestu; crontab pominięty.  
2. pliki + vhost OLS — jeśli katalog docelowy **niepusty**, odmowa bez `--overwrite-files`  
3. import baz — jeśli baza o tej nazwie **już istnieje i nie jest pusta**, restore **odmawia** (plan pokazuje `KOLIZJA`); dopiero `--overwrite-db` nadpisuje  
4. **db-accounts.sql** — tylko konta exclusive z archiwum; GRANT-y ograniczone do baz snapshotu. Jeśli user MySQL już istnieje → **bez** `DROP`/`CREATE` (hasło i obce GRANT-y zostają); stosowane są GRANT-y z pliku na bazy snapshotu  

Starsze snapshoty bez tych plików działają jak wcześniej (same pliki + DB; konto Unix musi istnieć lokalnie pod `site_user`).

Po restore: uprawnienia (`perms fix`), vhost OLS, ewentualnie `ols reload`.

Setup Drive i backup: [backup.md](backup.md).

← [README](../README.md)
