# Kreator `site new`

`site new` składa serwis z kroków: preflight, użytkownik i katalogi, baza, runtime, vhost, manifest. Sekrety zostają w `shared/.env` (0600). Manifest, journal, log i `ps` ich nie dostają.

Alias: `new-site` (to samo co `site new`).

## Przebieg

1. Preflight OS (Debian 11–13, Ubuntu 22.04/24.04, Alma/Rocky 8 i 9), RAM, dysk, porty 80/443, repozytorium, NTP.
2. Domena i aliasy (`www` domyślnie, `--no-www` wyłącza). Kolizja katalogu albo użytkownika kończy się odmową.
3. Użytkownik systemowy i układ `releases/`, `shared/`, `logs/`, `public_html`. `umask` procesu po kroku wraca do poprzedniej wartości.
4. Baza (`mysql`, `postgres`, `sqlite`, `none`) i opcjonalny Redis. Hasło idzie do `.env`.
5. Runtime (PHP: pula FPM per serwis; Node: nvm, PM2 albo systemd na `127.0.0.1`).
6. Vhost z `share/vhost-templates/` (nginx, apache, OLS). Reload dopiero po walidacji.
7. Manifest bez haseł i `COMMIT` w journalu.

Drugie uruchomienie na istniejący manifest nic nie dopisuje. `--resume` pomija kroki oznaczone `DONE`. `--rollback` cofa otwarty journal.

## Flagi

| Flaga | Znaczenie |
|-------|-----------|
| `--runtime php\|node\|python\|dotnet\|static` | Rodzaj aplikacji |
| `--db mysql\|postgres\|sqlite\|none` | Silnik bazy |
| `--redis [cache\|queue]` | Redis (ACL, gdy wersja ≥ 6) |
| `--php`, `--php-preset`, `--php-ext`, `--php-sapi` | Wersja i rozszerzenia PHP |
| `--node`, `--process pm2\|systemd`, `--port` | Node i sposób startu |
| `--webserver nginx\|apache\|ols`, `--proxy-port` | Vhost |
| `--preset` | laravel, wordpress, next, django, aspnet, spa, static |
| `--from plik`, `--save-profile plik` | Profil JSON albo YAML |
| `--user`, `--shell nologin\|bash` | Konto systemowe |
| `--dry-run`, `--json` | Plan bez zmian; `--json` daje jeden obiekt |
| `--yes` | Bez pytania o plan |
| `--resume`, `--rollback` | Journal |

Bez TTY brakująca flaga kończy się błędem. Hasło bez TTY nie jest ustawiane „w ciemno”: albo jest TTY, albo `--secret-file` tam, gdzie komenda je obsługuje.

## Profile

Pliki w `share/site-profiles/`. Opis pól: [README](../share/site-profiles/README.md).

```text
site new sklep.example --from share/site-profiles/laravel.json --yes
```

Profil nie może zawierać hasła. Zapis `--save-profile` trzyma tylko preset, runtime, bazę, webserver i domenę.

## Manifest

Ścieżka robocza kreatora: `…/<domena>/.hmtools/service.json` (katalog 0750, plik 0600). Journal transakcji: `/var/lib/hmtools/journal` (albo `HM_SITE_JOURNAL_DIR`).

Pola: `schema`, `domain`, `aliases`, `user`, `webserver`, `runtime.type` / `version` / `manager`, `databases` (typ, nazwa, user, host, port — bez hasła), `env_file`, `ssl`, `created_by`, `created_at`, `hmtools_version`.

`site show <domena>` wypisuje skrót. `site show <domena> --json` wypisuje manifest po zamaskowaniu pól `password`, `secret` i `token`.

`site new <domena> --dry-run --json` zwraca na przykład:

```json
{"dry_run":true,"domain":"app.example","runtime":"php","db":"mysql","php":"8.4","webserver":"nginx","preset":"laravel","node":"","process":""}
```

## Bezpieczeństwo

- Hasło bazy i sekrety aplikacji są tylko w `shared/.env`.
- Lista `site env list` maskuje wartości. `site env show` bez TTY nic nie wypisuje.
- Vhost proxy i unit Node ustawiają nasłuch na `127.0.0.1`, nie na `0.0.0.0`.
- `umask` jest zmieniany wyłącznie w podpowłoce kroku katalogów i przy zapisie pliku.

## Testy

Mock (bez VPS):

```bash
for t in scripts/test-site-wizard-*.sh; do bash "$t"; done
```

Fixture katalogów i snapshoty vhosta oraz unitu: `scripts/fixtures/site-wizard/`. Checklisty ręczne trzech dystrybucji: [docs/tested/site-wizard.md](tested/site-wizard.md).

## Cykl życia

`site show` (albo `info --manifest` w kontekście strony) pokazuje runtime, wersję i zasoby z listy obok manifestu. `site runtime php|node|python|dotnet <wersja>` przełącza serwis i przy błędzie zostawia poprzednią wersję. Pakiety używane przez inne serwisy nie są odinstalowywane. `site doctor` porównuje listę zasobów ze stanem dysku. `webs delete` po znalezieniu tej listy usuwa zasoby kreatora (workery, unit, vhost, pulę, bazy, firewall, porty, logrotate, cron) i nie rusza pozycji oznaczonych jako współdzielone. `--keep-db` zostawia bazy, `--keep-files` zostawia katalog, `--archive` woła `webs archive`.

## Operacje

`site new` z `--cron` (laravel, wp, django albo własna komenda `--cron-cmd`), `--worker` (queue, celery, node, dotnet) i `--workers N` zapisuje timer `hm-cron-<domena>-schedule` oraz szablon `hm-worker-<domena>@.service` (`Restart=always`, `MemoryMax`, stop przez SIGTERM). Logi aplikacji idą do `logs/` i `/etc/logrotate.d/hm-<domena>` (daily, 14, compress, copytruncate). Ścieżki trafiają na listę zasobów, więc `webs delete` i rollback je wyłączają i kasują. Publiczne zostają 80/443. Dodatkowy port tylko przez `--open-port` (komentarz `hm:<domena>`). Docker dostaje ostrzeżenie, bo omija UFW. `--health-path` zapisuje URL, a `health --check` zgłasza worker, którego `systemctl is-active` nie jest `active`, i przy `--notify` woła `notify`. `--logrotate` bez crona i workera i tak zakłada rotację. `HM_SITE_BACKUP=1` dopisuje domenę do listy backupu.

## FAQ

**Dlaczego port aplikacji jest tylko na 127.0.0.1?**  
Aplikacja (Node, PHP-FPM, Gunicorn) nie powinna być dostępna z internetu. Publiczny jest wyłącznie vhost (80/443). Ruch do procesu idzie przez proxy na loopback. Otwarcie `0.0.0.0` obchodzi vhost, TLS i nagłówki.

**Skąd Tab bierze wersje?**  
Z pliku cache (`HM_SITE_VERSION_CACHE`, domyślnie `/var/lib/hmtools/site-versions.cache`), wiersze `php 8.4`, `node 22`, `dotnet 8`, `python 3.12`. Bez pliku Tab podaje krótki zestaw wbudowany.
