# Architektura: komendy jako moduły

Każde narzędzie REPL to katalog `commands/<nazwa>/` z obowiązkowym `main.sh`.

## Ładowanie

`bin/hmtools` → `commands/_load.sh`:

1. Inicjuje mapy: `HM_CMD_ALIAS_MAP`, `HM_CMD_ENTRY`, `HM_CMD_RESTRICTED`, `HM_CMD_SITE_ENTRY`, `HM_CMD_HELP`.
2. Source `commands/_shared/sites/init.sh` (discovery/vhost wspólne dla wielu narzędzi).
3. Dla każdego `commands/<tool>/` (pomija `_shared`): opcjonalnie `meta.sh`, potem `main.sh`.
4. Source `commands/_dispatch.sh`.

Rejestracja w `main.sh`:

```bash
_hm_cmd_help webs <<'EOF'
Użycie: webs …
EOF

_hm_cmd_register webs cmd_webs 0 sites list
#                 ^name ^fn     ^restricted_ok  ^aliases…

_hm_cmd_register_site info cmd_site_info   # tylko w kontekście [domena]>
```

`help <polecenie>` → alias map → `HM_CMD_HELP`; brak wpisu → „Brak podpowiedzi dla tego polecenia” ([`lib/help.sh`](../lib/help.sh)).

Hyphen w nazwie katalogu (`update-hmtools`) → funkcja zwykle `cmd_update_hmtools`.

## Dispatch

`hm_dispatch` w `bin/hmtools`:

1. Pusta linia / `exit|quit|q` — rdzeń (nie są modułami).
2. Restricted OS → tylko moduły z `HM_CMD_RESTRICTED[name]=1`.
3. Kontekst site → `hm_site_try_dispatch` (lokalne nazwy + wyjątki ssl/backup/…).
4. `hm_cmd_invoke` → alias → `HM_CMD_ENTRY` → wywołanie `cmd_*`.

## Gdzie leży logika

| Obszar | Lokalizacja |
|--------|-------------|
| Backup | `commands/backup/{main,core,list,…}.sh` |
| PHP repo/manage/update | `commands/php/` |
| Delete site | `commands/delete-site/` |
| Lista/discovery stron | `commands/webs/` + `commands/_shared/sites/` |
| Kontekst strony | `commands/site/` |
| Infra (pkg, OS, OLS API, DB) | `lib/` |

## Kreator (`lib/wizard.sh`)

`hm_wiz_step <id> <tytuł> <pytanie> [walidacja] [warunek]` rejestruje krok. Pytanie woła `hm_wiz_input_text|choice|multi|yesno|secret|port`. `<` / `wstecz` cofa, `?` pokazuje `hm_wiz_help`, `!` stan, `q` anuluje. Ctrl+C sprząta `HM_WIZ_TMP_DIR` (domyślnie `/var/lib/hmtools/tmp`).

`hm_wiz_flag <id> --flaga` wiąże odpowiedź z trybem bez TTY. Brak wartości daje `Brak --flaga (wymagane w trybie nieinteraktywnym)` i kod ≠ 0, bez `read`. `HM_WIZ_DRY=1` albo `site new --dry-run` wypisuje plan i nic nie zmienia. Sekrety nie wchodzą do podsumowania, serializacji (`hm_wiz_serialize`) ani logu. Testy podają stdin przy `HM_WIZ_FORCE_PROMPT=1`.

← [structure.md](structure.md)
