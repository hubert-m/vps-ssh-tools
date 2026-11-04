# Przywracanie

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

### Snapshot `archive` (po `webs archive`)

Gdy w snapshocie są artefakty kont:

1. **unix-account.meta** (+ opcjonalnie `unix-authorized_keys`) — `useradd` / `chpasswd -e` / klucze SSH  
2. pliki + vhost OLS  
3. import baz  
4. **db-accounts.sql** — te same konta MySQL i GRANT-y co przed archiwizacją  

Starsze snapshoty bez tych plików działają jak wcześniej (same pliki + DB; konto Unix musi istnieć lokalnie pod `site_user`).

Po restore: uprawnienia (`perms fix`), vhost OLS, ewentualnie `ols reload`.

Setup Drive i backup: [backup.md](backup.md).

← [README](../README.md)
