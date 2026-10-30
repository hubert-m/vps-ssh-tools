# Struktura repo

```text
vps-ssh-tools/
├── README.md
├── VERSION                 # np. v0.1.8
├── changelogs/
│   ├── CHANGELOG.md        # pełna historia wersji
│   └── *.txt               # punktowy changelog (CLI + instalator)
├── docs/                   # dokumentacja (ten katalog)
├── install.sh
├── bin/hmtools             # REPL + cienki hm_dispatch (plugin)
├── lib/                    # infrastruktura (nie narzędzia REPL)
│   ├── pkg.sh + pkg/       # adapter menedżera pakietów (apt|rpm)
│   ├── os_family.sh + os/  # adapter rodziny OS (debian|rhel)
│   ├── common/             # ui, config, context, self
│   ├── complete/           # helpers, tab
│   ├── db.sh, ols.sh, detect.sh, help.sh, size.sh, rclone_drive.sh, …
├── commands/               # narzędzia REPL — katalog = komenda
│   ├── _load.sh            # rejestr aliasów + source */main.sh
│   ├── _dispatch.sh        # resolve / restricted / site / invoke
│   ├── _shared/sites/      # wspólne helpery discovery/vhost (wiele narzędzi)
│   ├── backup/             # main + core/list/restore/prune/schedule/archive
│   ├── webs/, use/, site/, php/, ssl/, ols/, mysql/, …
│   └── help/, version/, update-hmtools/, delete-site/, …
├── config/hmtools.conf.example
├── .github/workflows/lint.yml
└── scripts/setup-rclone.sh
```

Komendy jako moduły: [architecture-commands.md](architecture-commands.md).  
Auto-detekcja: [detection.md](detection.md).  
Pakiety / OS: [architecture-pkg.md](architecture-pkg.md).

← [README](../README.md)
