# Auto-detekcja

`lib/detect.sh` ustawia m.in.:

| Sygnał | Wynik |
|--------|--------|
| `/usr/local/CyberCP` lub CLI `cyberpanel` | `PANEL=cyberpanel` |
| `/usr/local/lsws` + conf OLS | `WEBSERVER=openlitespeed` |
| gniazdo MySQL + `mariadb`/`mysql` | `DB_ENGINE` |

## Discovery stron (kolejność)

1. CyberPanel (`listWebsitesJson` / tabela `websites_website`)
2. Katalogi vhostów OLS (`/usr/local/lsws/conf/vhosts/*`)
3. Fallback: `/home/*/public_html`

Ścieżki docroot, PHP, SSL czytane z vhosta OLS i metadanych panelu — bez zakładania na sztywno layoutu CyberPanel.

## Bazy danych

- **confirmed** — z CyberPanel (`databases_databases`)
- **detected** — z `wp-config.php`, `.env`, `configuration.php`
- **prefix-match** — nazwy DB pasujące do prefiksu domeny

← [README](../README.md) · [Struktura repo](structure.md)
