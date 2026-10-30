# Auto-detekcja stosu VPS

`lib/detect.sh` przy starcie (`hm_detect_all`) oraz komendą `detect` / `env` rozpoznaje środowisko **bez skanowania całego dysku** — tylko wybrane ścieżki, CLI i (dla paneli) sygnały API.

## Co jest wykrywane

| Warstwa | Sygnały (kolejność) | Wynik |
|---------|---------------------|--------|
| **OS** | `/etc/os-release` (`ID`, `VERSION_ID`, `PRETTY_NAME`) | `OS_*` |
| **Panel** | cPanel (`/usr/local/cpanel` + `uapi`/`whmapi1`), Plesk (`/usr/local/psa` + `plesk`), CyberPanel, DirectAdmin, aaPanel, Webmin | `PANEL`, `PANEL_SOURCE` |
| **WWW** | OLS (`/usr/local/lsws`), Nginx (`/etc/nginx`), Apache (`/etc/apache2`\|`/etc/httpd`), potem proces/systemd | `WEBSERVER`, `WEBSERVER_SOURCE`; dodatkowe w `STACK_EXTRA` |
| **DB** | socket MySQL + `mariadb`/`mysql` / unit systemd | `DB_ENGINE`, `MYSQL_SOCKET` |

cPanel / Plesk: preferowany sygnał to obecność narzędzi API/CLI (UAPI, `plesk`), nie samo zgadywanie po layoutcie plików.

## Karta i sugestie narzędzi

- Start REPL: `hm_detect_banner` (OS · panel · www · db + sugerowane komendy).
- Pełna karta: `hmtools> detect` — ścieżki, źródło detekcji, hinty pod stos.

Przykłady hintów:

- CyberPanel + OLS → `webs`, `ols`, `php`, `backup`, `perms`, …
- sam Nginx/Apache → głównie `mysql` / `backup` / `health` (bez natywnego OLS)
- cPanel/Plesk → ograniczone wsparcie vhostów; backup/mysql nadal użyteczne

## Ręczne nadpisanie

W `/hm-tools/config/hmtools.conf` (patrz `config/hmtools.conf.example`):

```bash
FORCE_PANEL="cyberpanel"
FORCE_WEBSERVER="openlitespeed"
FORCE_DB_ENGINE="mariadb"
```

Ustawiane **po** auto-detekcji (`hm_detect_apply_overrides`).

## Discovery stron (kolejność)

1. CyberPanel (`listWebsitesJson` / tabela `websites_website`)
2. Katalogi vhostów OLS (`/usr/local/lsws/conf/vhosts/*`)
3. Fallback: `/home/*/public_html`

Ścieżki docroot, PHP, SSL czytane z vhosta OLS i metadanych panelu.

## Bazy danych

- **confirmed** — z CyberPanel (`databases_databases`)
- **detected** — z `wp-config.php`, `.env`, `configuration.php`
- **prefix-match** — nazwy DB pasujące do prefiksu domeny

← [README](../README.md) · [Struktura repo](structure.md)
