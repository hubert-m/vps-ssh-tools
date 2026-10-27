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
  backup setup          Konfiguracja rclone / Google Drive
  backup full           Pełna kopia serwera → Drive
  backup site <domena>  Kopia jednej strony (lub w kontekście: backup)
  backup test           Test połączenia rclone

W kontekście strony samo 'backup' = pełna kopia tego środowiska
(pliki + bazy) streamem na Google Drive (bez dużego archiwum lokalnego).

Zobacz też: help mysql
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
Użycie: ols [status|reload|restart|log]

Zarządzanie OpenLiteSpeed:
  status    Stan / wersja / proces (domyślne)
  reload    Przeładowanie konfiguracji
  restart   Restart (z potwierdzeniem)
  log [N]   Ostatnie N linii error.log (domyślnie 50)
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
  mysql | dbs           Lista baz (globalnie lub w kontekście — powiązane ze stroną)
  mysql dump <nazwa_db> Zrzut jednej bazy streamem na Google Drive

Status powiązania DB: confirmed (panel) / detected (wp-config, .env) / prefix-match.
EOF
      ;;
    php)
      cat <<'EOF'
Użycie:
  php                 Lista LSPHP + porównanie z php.net
  php update <ver>    Alias: update-php <ver>

Globalnie / w kontekście: lista zainstalowanych lsphp* vs najnowsze z php.net.
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
  pm2 | node | apps         Lista procesów PM2 + porty + mapa proxy OLS
  pm2 all                   Wszystkie procesy PM2 (bez filtra kontekstu)
  pm2 proxy                 Same mapowania extprocessor proxy → port
  pm2 site <domena>         Procesy powiązane ze stroną
  pm2 ports                 Nasłuchujące porty (node/pm2/next)
  pm2 raw                   Surowy output: pm2 list

W kontekście strony filtruje po:
  - cwd procesu pod site root
  - nazwie PM2 zawierającej domenę
  - porcie zgodnym z proxy w vhost OLS

Wykrywa też stack z package.json (next, react, nuxt, vite, …).
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
Użycie: clean   (w kontekście strony)

Bezpieczne czyszczenie typowych katalogów cache/tmp (z potwierdzeniem).
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
