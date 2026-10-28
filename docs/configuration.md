# Konfiguracja

Plik: `/hm-tools/config/hmtools.conf`  
Wzór: [`config/hmtools.conf.example`](../config/hmtools.conf.example)

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

Zobacz też: [Logi](logging.md), [Backup / Google Drive](backup.md).

← [README](../README.md)
