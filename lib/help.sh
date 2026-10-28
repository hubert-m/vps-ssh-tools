#!/usr/bin/env bash
# Pomoc: help  /  help <polecenie>

if [[ -n "${HMTOOLS_HELP_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_HELP_LOADED=1

hm_help_topic() {
  local topic="${1:-}"
  topic="$(printf '%s' "${topic}" | tr '[:upper:]' '[:lower:]')"
  # aliasy
  case "${topic}" in
    sites|list) topic="webs" ;;
    enter|cd) topic="use" ;;
    df) topic="disk" ;;
    lsws) topic="ols" ;;
    db|databases) topic="mysql" ;;
    dbs) topic="mysql" ;;
    status) topic="health" ;;
    selflog|hmlog) topic="applog" ;;
    env) topic="detect" ;;
    ver) topic="version" ;;
    remove) topic="uninstall-hmtools" ;;
    upgrade) topic="update-hmtools" ;;
    log) topic="logs" ;;
    crons) topic="cron" ;;
    node|apps) topic="pm2" ;;
    php-update) topic="update-php" ;;
    ssl-renew) topic="renew-ssl" ;;
    renew-ssl) topic="ssl" ;;
    \?|h) topic="help" ;;
  esac

  case "${topic}" in
    webs)
      cat <<'EOF'
Użycie: webs [--quick|-q]

Lista usług webowych na serwerze (domena, PHP, SSL, rozmiar, status).

Opcje:
  --quick, -q   Pomiń liczenie rozmiaru (szybciej)

Następnie: use <numer|domena>
Tab uzupełnia domenę po 'use '.
EOF
      ;;
    use)
      cat <<'EOF'
Użycie: use <numer|domena>

Wejście w kontekst wybranej strony. Numer z listy 'webs' albo nazwa domeny
(dopuszczalne częściowe dopasowanie).

W kontekście prompt zmienia się na [domena]> .
Wyjście z kontekstu: exit

Tab uzupełnia dostępne domeny.
EOF
      ;;
    backup)
      cat <<'EOF'
Użycie:
  backup setup              Instalacja/konfiguracja rclone + Google Drive
  backup config             Ustaw katalog root na Drive (jednorazowo)
  backup show               Pokaż aktualny root i strukturę
  backup full               Pełna kopia serwera → Drive/full/<stamp>/
  backup site <domena>      Kopia strony → Drive/<domena>/<stamp>/
  backup list [domena|full] Snapshoty + manifest (w kontekście: bieżąca domena)
  backup restore <domena> [stamp] [--files-only|--db-only]
                            Odtwórz pliki (tar lub chunks) + bazy; bez stamp = najnowszy
  backup prune [--days N] [--dry-run] [--yes]
                            Usuń stare snapshoty (BACKUP_KEEP_DAYS / BACKUP_KEEP_MIN)
  backup schedule [enable|disable|status]
                            Cron: /etc/cron.d/hmtools-backup + log backup-cron.log
  backup test               Test połączenia rclone

Struktura na Google Drive (root = RCLONE_REMOTE):
  <root>/full/<stamp>/           — pełne kopie serwera
  <root>/<domena>/<stamp>/       — kopie poszczególnych stron
  <root>/db-dumps/               — jednorazowe mysql dump

W kontekście strony samo 'backup' = kopia tej strony.
EOF
      ;;
    disk)
      cat <<'EOF'
Użycie: disk

Pokazuje zajętość dysków (df), inody oraz największe katalogi w /home.
EOF
      ;;
    ols)
      cat <<'EOF'
Użycie: ols [status|reload|restart|log|stats|top|htaccess|cache|proxy|admin]

Zarządzanie OpenLiteSpeed:
  status              Stan / wersja / proces (domyślne)
  reload              Przeładowanie konfiguracji
  restart             Restart (z potwierdzeniem)
  log [N]             Ostatnie N linii error.log (domyślnie 50)
  stats | top         Live /tmp/lshttpd/.rtreport* (RPS, vhosty, WAITQUE LSAPI)
  htaccess [enable]   .htaccess / autoLoadHtaccess (+ reload)
  cache status|flush  LSCache (vhost / global all)
  proxy [set-port N]  Zdrowie backendów reverse proxy (503)
  admin [status|pass] WebAdmin (port, tunel SSH, admpass.sh)

W kontekście strony: htaccess, proxy, clean --lscache
EOF
      ;;
    htaccess)
      cat <<'EOF'
Użycie (kontekst strony): htaccess [enable]
       ols htaccess [check|enable] [domena]

Sprawdza .htaccess, autoLoadHtaccess, rewrite enable oraz mtime vs start OLS.
htaccess enable — dopisuje dyrektywy i robi ols reload.
EOF
      ;;
    proxy)
      cat <<'EOF'
Użycie (kontekst strony): proxy [status|set-port <port> [nazwa]]
       ols proxy [status] [domena]
       ols proxy set-port <port> [nazwa]

Weryfikuje extprocessor type proxy (ss + curl). Martwy port → ryzyko 503.
EOF
      ;;
    cache|lscache)
      cat <<'EOF'
Użycie: ols cache [status|flush [domena|all]]
        clean --lscache   (w kontekście strony)

Status module cache + katalogi lscache; flush czyści zawartość (z potwierdzeniem).
EOF
      ;;
    ssl|renew-ssl|ssl-renew)
      cat <<'EOF'
Użycie:
  ssl                 Lista certyfikatów (status / dni do wygaśnięcia)
  ssl renew [domena]  Alias: renew-ssl
  renew-ssl [domena]  Odnów Let's Encrypt (potwierdzenie [t/N])

W kontekście strony: ssl = szczegóły certu; renew-ssl = odnowienie.
Wygasły cert → wyraźny komunikat na czerwono + podpowiedź renew-ssl.

Kolejność odnawiania: cyberpanel issueSSL → acme.sh → certbot.
EOF
      ;;
    mysql)
      cat <<'EOF'
Użycie:
  mysql | dbs                 Lista baz (globalnie / w kontekście strony)
  mysql dump <db>             Zrzut → Google Drive
  mysql dump <db> --local [p] Lokalny .sql.gz (domyślnie ~/backups/)
  mysql dump-local [db] [p]   Alias lokalnego dumpa
  mysql import <db> <plik>    Import .sql / .sql.gz (z potwierdzeniem)
  mysql cli [db]              Interaktywna konsola (dbs cli w kontekście)
  mysql top | processlist     Threads / Slow_queries / PROCESSLIST
  mysql optimize [db]         mysqlcheck --optimize + Data_free
  mysql create <db> [user]    Nowa baza + user@localhost + hasło

W kontekście bez [db] — pierwsza wykryta baza strony.
EOF
      ;;
    perms)
      cat <<'EOF'
Użycie (kontekst strony): perms [check|fix]

check  właściciel/grupa docroot, pliki root, 777, wp-config/.env
fix    chown user:user wewnątrz public_html; docroot user:nogroup 750;
       katalogi 755 / pliki 644; wrażliwe 600 (z potwierdzeniem)
EOF
      ;;
    php)
      cat <<'EOF'
Użycie:
  php                      Lista LSPHP + porównanie z php.net
  php update <ver>         Alias: update-php <ver>
  php set <ver>            W kontekście: przełącz LSPHP strony (vhost/CyberPanel)
  php ext [list] [ver]     Moduły php -m + status kluczowych rozszerzeń
  php ext install <n> [ver] Instalacja lsphpXX-<n> (apt/dnf/yum)
  php ini [ver]            Limity php.ini + nadpisania vhost / .user.ini
  php ini set <k> <v> [--vhost|--global]
  php restart [--global]   Kill workerów lsphp (Detached Mode) + ols reload
  php ps                   Procesy lsphp (CPU/RAM)

W kontekście (use <domena>): php set / ext / ini / restart działają na tej stronie.
EOF
      ;;
    update-php|php-update)
      cat <<'EOF'
Użycie:
  update-php <wersja>
  php update <wersja>

Przykłady:
  update-php 8.4
  update-php 84
  php update lsphp83

Działanie:
  1) pokazuje wersję lokalną vs php.net
  2) pyta o potwierdzenie [t/N]
  3) aktualizuje pakiety lsphpXX* (apt/dnf/yum)
  4) przeładowuje OpenLiteSpeed

Uwaga: repozytorium LiteSpeed czasem dogania php.net z opóźnieniem.
EOF
      ;;
    health)
      cat <<'EOF'
Użycie: health

Szybki przegląd: load, RAM, dysk, status OLS i MySQL,
certyfikaty wygasające w ciągu 14 dni.
EOF
      ;;
    applog)
      cat <<'EOF'
Użycie: applog [N]

Ostatnie N linii logu pracy hmtools (domyślnie 50).
Pliki: /hm-tools/logs/hmtools-YYYY-MM-DD.log
EOF
      ;;
    detect)
      cat <<'EOF'
Użycie: detect

Wypisuje wykryty panel (CyberPanel itd.), webserver (OLS),
silnik DB oraz ważne ścieżki konfiguracji.
EOF
      ;;
    cron)
      cat <<'EOF'
Użycie:
  cron | cron list     W kontekście: crony strony; globalnie: system + users
  cron all             Wszystkie crony (system + użytkownicy)
  cron system          /etc/crontab, /etc/cron.d, katalogi okresowe
  cron users           Crontaby wszystkich użytkowników ze spoola
  cron site <domena>   Crony powiązane ze stroną (user + heurystyka w /etc)
  cron user <name>     Crontab wybranego użytkownika
  cron edit [user]     Edycja crontab -e (w kontekście: user strony)

Przykłady:
  hmtools> cron
  hmtools> use example.com
  [example.com]> cron
  [example.com]> cron edit
EOF
      ;;
    pm2)
      cat <<'EOF'
Użycie:
  pm2 | node | apps              Lista + porty + mapa proxy OLS
  pm2 all                        Wszystkie procesy (bez filtra kontekstu)
  pm2 proxy | site | ports | raw Jak wcześniej
  pm2 restart|reload|stop|start <nazwa|id|all>
  pm2 logs [nazwa] [N]           Ostatnie linie (--nostream)
  pm2 save                       Zapisz listę procesów

Akcje uruchamiane jako właściciel PM2_HOME (runuser/sudo -u),
nie jako root z binarką z NVM użytkownika.

W kontekście strony: filtr listy + PM2_HOME użytkownika strony.
EOF
      ;;
    version)
      cat <<'EOF'
Użycie: version

Pokazuje zainstalowaną wersję vs najnowszy tag na GitHubie
oraz punktowy changelog zainstalowanej wersji.
EOF
      ;;
    update-hmtools)
      cat <<'EOF'
Użycie: update-hmtools [--force]

Pobiera instalator z GitHuba i aktualizuje hmtools do najnowszego taga.
Jeśli lokalna wersja = remote — nic nie robi (chyba że --force).

Po udanym update wypisuje changelog nowej wersji.
EOF
      ;;
    uninstall-hmtools)
      cat <<'EOF'
Użycie: uninstall-hmtools [--yes]

Usuwa katalog /hm-tools oraz symlinki /usr/bin/hmtools i /usr/local/bin/hmtools.
Wymaga potwierdzenia (pomiń przez --yes).

Nie usuwa rclone ani backupów na Google Drive.
EOF
      ;;
    help)
      cat <<'EOF'
Użycie:
  help              Lista wszystkich komend
  help <polecenie>  Szczegółowa pomoc dla komendy

Przykłady:
  help use
  help backup
  help ols
EOF
      ;;
    exit|quit)
      cat <<'EOF'
Użycie: exit | quit

W kontekście strony: powrót do hmtools>
Na poziomie głównym: wyjście z hmtools do SSH.
EOF
      ;;
    # --- kontekst strony ---
    info)
      cat <<'EOF'
Użycie: info   (w kontekście strony)

Pełne informacje o środowisku: ścieżki, rozmiar, bazy, SSL, PHP, dysk.
EOF
      ;;
    size)
      cat <<'EOF'
Użycie: size   (w kontekście strony)

Rozmiary katalogów środowiska + top du.
EOF
      ;;
    logs)
      cat <<'EOF'
Użycie: logs [N]   (w kontekście strony)

Ostatnie N linii logów access/error (domyślnie 40).
EOF
      ;;
    clean)
      cat <<'EOF'
Użycie: clean [--lscache]   (w kontekście strony)

1) Pokazuje podgląd: ścieżki, rozmiary, liczbę wpisów, próbkę zawartości
2) Pyta o potwierdzenie [yes/no]
3) Usuwa tylko zawartość typowych cache/tmp (+ LSCache) — foldery zostają

--lscache  tylko katalogi LSCache (jak ols cache flush)

Nie rusza m.in. uploads, mediów ani całego node_modules.
EOF
      ;;
    "")
      hm_help_global
      ;;
    *)
      hm_err "Brak pomocy dla: ${1:-?}"
      echo "Wpisz 'help' aby zobaczyć listę komend."
      return 1
      ;;
  esac
}

hm_cmd_help() {
  if [[ -z "${1:-}" ]]; then
    if [[ -n "${HM_SITE_DOMAIN:-}" ]]; then
      cmd_site_help
    else
      hm_help_global
    fi
    echo
    echo "Szczegóły: help <polecenie>   np. help use"
    return 0
  fi
  hm_help_topic "$1"
}
