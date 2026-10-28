# Troubleshooting

| Objaw | Co sprawdzić |
|-------|----------------|
| Pusta lista `webs` | `detect` — czy OLS/CyberPanel widoczne; czy istnieją `/home/*/public_html` |
| `backup` pada na rclone | `backup test`, `rclone config`, poprawne `RCLONE_REMOTE` |
| Abort przez dysk | Zwolnij miejsce lub tymczasowo obniż `MIN_FREE_PERCENT` (ostrożnie) |
| Brak baz przy stronie | Heurystyka vs CyberPanel DB; sprawdź `wp-config.php` / uprawnienia MySQL jako root |
| `ols reload` nie działa | `/usr/local/lsws/bin/lswsctrl`, czy proces `lshttpd` żyje |
| 403 po wgraniu plików jako root | `[domena]> perms check` / `perms fix` (docroot `user:nogroup` 750) |
| `.htaccess` „nie działa” | `htaccess` — `autoLoadHtaccess` + `ols reload` |
| Autoryzacja Drive na headless | `rclone authorize "drive"` lokalnie + wklejenie tokena |
| Podejrzenie otwartego MySQL/Redis | `security ports` / `health` |

## Logi / ścieżki konfiguracji

- Narzędzia: `/hm-tools`
- Conf: `/hm-tools/config/hmtools.conf`
- Logi pracy: `/hm-tools/logs/hmtools-YYYY-MM-DD.log`
- Tmp chunków: `/tmp/hmtools-backup` (domyślnie)

Zobacz też: [logging.md](logging.md), [configuration.md](configuration.md), [backup.md](backup.md).

← [README](../README.md)
