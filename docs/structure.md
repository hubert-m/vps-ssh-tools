# Struktura repo

```text
vps-ssh-tools/
├── README.md
├── CHANGELOG.md
├── VERSION                 # np. v0.1.7
├── changelogs/*.txt        # punktowy changelog (CLI + instalator)
├── docs/                   # dokumentacja (ten katalog)
├── install.sh
├── bin/hmtools
├── lib/           # help, logging, detect, db, size, rclone, ols (+ loadery)
│   ├── common/    # ui, config, context, self
│   ├── complete/  # helpers, tab
│   ├── backup/    # core, list, restore, prune, schedule, archive
│   └── sites/     # vhost, ssl, discover, print, php, php_manage, site_delete
├── commands/      # webs, site_shell, backup, disk, ols, ssl, mysql,
│                  # health, cron, pm2, security
├── config/hmtools.conf.example
├── .github/workflows/lint.yml   # obecnie wyłączone (workflow_dispatch + if: false)
└── scripts/setup-rclone.sh
```

Auto-detekcja: [detection.md](detection.md).

← [README](../README.md)
