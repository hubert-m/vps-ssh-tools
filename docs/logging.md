# Logi pracy hmtools

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
Wyłączenie capture outputu: `LOG_CAPTURE_OUTPUT=0` w `hmtools.conf` — zobacz [configuration.md](configuration.md).

← [README](../README.md)
