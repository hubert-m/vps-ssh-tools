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

Po restore: uprawnienia (`perms fix`), vhost OLS, ewentualnie `ols reload`.

Setup Drive i backup: [backup.md](backup.md).

← [README](../README.md)
