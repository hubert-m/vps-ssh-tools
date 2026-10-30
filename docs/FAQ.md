# FAQ — hmtools

Często zadawane pytania o działanie komend. Kliknij pytanie, żeby rozwinąć odpowiedź.

---

<details>
<summary><strong>Jak działa mechanizm aktualizowania PHP <code>update-php &lt;ver&gt;</code>?</strong></summary>

### Skrót

`update-php <ver>` (aliasy: `php-update`, `php update <ver>` / `php upgrade <ver>`) **nie zmienia** wersji PHP przypisanej do strony (`php set`). Aktualizuje **pakiety LSPHP danej gałęzi** (np. `lsphp84*`) z **repozytorium LiteSpeed** na serwerze (apt/dnf/yum), a potem miękko przeładowuje OpenLiteSpeed.

Kod: `commands/health.sh` → `cmd_update_php` (orkiestracja); pakiety wyłącznie przez `hm_pkg_*` ([`lib/pkg.sh`](../lib/pkg.sh) → adapter `apt`/`rpm`); pomocnicze: `lib/sites/php_manage.sh`, `lib/sites/php.sh`, `lib/common/ui.sh`, `hm_ols_reload_soft`. Szczegóły warstw: [architecture-pkg.md](architecture-pkg.md).

---

### Wejście i dispatch

1. W REPL (`hmtools>`) lub przez `hmtools -c`:
   - `update-php 8.4`
   - `php-update 8.4`
   - `php update 8.4` / `php upgrade 8.4`
2. Router w `bin/hmtools`:
   - `update-php|php-update` → bezpośrednio `cmd_update_php "$@"`
   - `php` → `cmd_php`; podkomendy `update|upgrade` → `shift` + `cmd_update_php "$@"`

---

### Krok 1 — walidacja argumentu

Plik: `commands/health.sh` (`cmd_update_php`).

1. Brak argumentu → błąd: `Użycie: update-php <wersja>` + hint o aliasie `php update 8.4`, exit `1`.
2. `hm_php_normalize_branch "${arg}"` (`lib/sites/php_manage.sh`):
   - lower-case,
   - obcięcie prefiksów `php` / `lsphp`,
   - zostawia tylko cyfry i kropki,
   - akceptuje `8.4` **lub** dwa cyfry `84` → `8.4`,
   - przykłady OK: `8.4`, `84`, `lsphp84`, `PHP8.4`,
   - nieOK → `Nieprawidłowa wersja: …`, exit `1`.
3. `suffix="$(hm_php_lsphp_suffix "${branch}")"` → np. `8.4` → `84`.
4. Ścieżka instalacji:
   - `root="${OLS_ROOT:-/usr/local/lsws}"` (zwykle ustawione przez `hm_detect_all` na katalog OLS),
   - `path="${root}/lsphp${suffix}"` → np. `/usr/local/lsws/lsphp84`.

---

### Krok 2 — odczyt lokalnej wersji PHP (binarka)

1. Jeśli istnieje wykonywalny `${path}/bin/php`:
   - uruchamia: `"${path}/bin/php" -r 'echo PHP_VERSION;'`
   - wynik → `cur` (np. `8.4.14`).
2. W przeciwnym razie: `cur="(brak ${path})"`.

To jest wersja **runtime** z katalogu LSPHP, nie string z dpkg/rpm.

---

### Krok 3 — porównanie z lokalnym indeksem pakietów (Candidate)

Wywołanie: `hm_php_repo_info_for_suffix "${suffix}"` (`lib/sites/php.sh`).

Zwraca TSV (tab):  
`installed_pkg` · `candidate_pkg` · `candidate_clean` · `upgradable_count`

#### apt (Debian/Ubuntu)

1. Lista zainstalowanych: `hm_php_installed_packages` →  
   `dpkg-query -W -f='${Package}\n' "lsphp${suffix}*"` + filtr `^lsphp${suffix}`.
2. Jeśli lista pusta → policy tylko dla `lsphp${suffix}`.
3. `LC_ALL=C apt-cache policy <pakiety…>` — lokalny cache APT (**bez** sieci w tym kroku).
4. Awk wybiera `Installed:` / `Candidate:` dla głównego `lsphpXX:` i liczy, ile pakietów ma `Installed ≠ Candidate`.
5. Dodatkowo: `dpkg --compare-versions "${cand}" gt "${inst}"` — jeśli Candidate nowszy, a count był 0, ustaw `upg_count=1` (rebuildy `-1` → `-2`).
6. `hm_php_clean_pkg_ver` czyści Candidate do czytelnej formy (np. `1:8.4.14-1+noble` → `8.4.14`).

#### dnf / yum (Alma/Rocky/CentOS/RHEL)

1. Zainstalowana: `rpm -q --qf '%{VERSION}-%{RELEASE}' "lsphp${suffix}"` (brak → `-`).
2. Candidate z lokalnego cache:  
   `"${pm}" -q -C check-update "lsphp${suffix}*"`  
   (`-C` = **bez** odświeżania metadanych z sieci).
3. Pierwszy matching `lsphpXX…` → wersja Candidate; liczba matching linii → `upg_count`.
4. Brak wierszy check-update → Candidate = Installed (już aktualne wg cache).

#### Brak menedżera

Wypis: `-	-	-	0`.

---

### Krok 4 — podsumowanie na ekranie (przed potwierdzeniem)

Wypisuje m.in.:

```text
Aktualizacja LSPHP 8.4
  Katalog         : /usr/local/lsws/lsphp84
  Zainstalowana   : 8.4.x (pakiet: …)
  Dostępna w repo : 8.4.y (pakiet: …)
  Pakiety         : lsphp84*
```

Następnie lista zainstalowanych `lsphp84*` (max 12 widocznych, reszta „… +N więcej”).  
Źródło listy: znowu `hm_php_installed_packages` (`dpkg-query` / `rpm -qa`).  
Brak pakietów → ostrzeżenie: spróbuje **instalacji** z repo, nie samego upgrade.

---

### Krok 5 — ścieżka „już aktualne” (Installed == Candidate)

Warunek `already_current=1` gdy:

- `inst_pkg` i `cand_pkg` nie są `-` / `(none)`,
- `inst_pkg == cand_pkg`,
- `upg_count == 0`.

Wtedy:

1. Komunikat OK: pakiet w lokalnym indeksie jest już najnowszy.
2. `hm_confirm "Odświeżyć indeks repozytoriów i sprawdzić ponownie?"` → prompt `[t/N]`  
   (akceptuje: `t`/`tak`/`y`/`yes`, wielkość liter bez znaczenia).
3. **Nie** → `Anulowano.`, exit `0` — **żadna** aktualizacja nie startuje.
4. **Tak** → `hm_php_pkg_refresh`:
   - apt: `apt-get update` (przez `hm_run` — spinner + log),
   - dnf: `dnf makecache -y` (błąd ignorowany `|| true`),
   - yum: `yum makecache -y` (jw.).
5. Ponowne `hm_php_repo_info_for_suffix` i wypis Installed/Candidate.
6. Jeśli nadal brak nowszej wersji → OK „Po odświeżeniu nadal brak…”.  
   **Nawet wtedy flow idzie dalej do planu potwierdzenia** (możesz anulować na `yes`).

---

### Krok 6 — plan i twarde potwierdzenie

`hm_confirm_plan` (`lib/common/ui.sh`) — **nie** `[t/N]`, tylko dokładne wpisanie `yes`:

```text
══════════════════════════════════════════════════════════════════════
  update-php — LSPHP 8.4
══════════════════════════════════════════════════════════════════════
  Po potwierdzeniu zostaną wykonane kolejno następujące kroki:

    1. Odświeżenie repozytorium pakietów
    2. Aktualizacja pakietów lsphp84* z wersji <Installed> do <Candidate>
    3. Przeładowanie OpenLiteSpeed (ols reload)

  UWAGA: Aktualizacja pakietów z repozytorium LiteSpeed.

  Wpisz yes, aby wykonać powyższy plan (cokolwiek innego = anuluj):
```

Anulowanie → `Anulowano — żaden krok nie został wykonany.`, exit `0`.

---

### Krok 7 — właściwa aktualizacja pakietów

1. `pm="$(hm_pkg_manager)"` (`php_manage.sh`): pierwszy dostępny z `apt-get` → `dnf` → `yum`. Brak → błąd, exit `1`.
2. `set +e` na czas operacji pakietowych; kod wyjścia w `rc`.

#### apt

| Sytuacja | Polecenia |
|----------|-----------|
| Są zainstalowane `lsphpXX*` | `apt-get update` → `DEBIAN_FRONTEND=noninteractive apt-get install --only-upgrade -y <lista pakietów>` |
| Brak pakietów | `apt-get update` → `apt-get install -y lsphpXX lsphpXX-common lsphpXX-mysql lsphpXX-curl lsphpXX-opcache lsphpXX-imap lsphpXX-msgpack lsphpXX-redis lsphpXX-intl lsphpXX-pgsql lsphpXX-sqlite3 lsphpXX-ldap` — przy failu fallback: tylko `lsphpXX` + `common` + `mysql` |

#### dnf

| Sytuacja | Polecenia |
|----------|-----------|
| Są pakiety | `dnf makecache -y` (`|| true`) → `dnf update -y "lsphpXX*"` |
| Brak | `dnf makecache -y` → `dnf install -y "lsphpXX*"` |

#### yum

Analogicznie: `yum makecache -y` → `yum update -y "lsphpXX*"` lub `yum install -y "lsphpXX*"`.

Wszystkie powyższe idą przez `hm_run` (`lib/logging.sh`) — log sesji + spinner na TTY.

`rc ≠ 0` → błąd z hintem o repo LiteSpeed (`repo.litespeed.sh`) i logach apt/dnf; **bez** reload OLS; return `rc`.

---

### Krok 8 — reload OpenLiteSpeed

`hm_ols_reload_soft` (`lib/detect.sh`):

1. Opcjonalnie odświeża detect: `hm_detect_all`.
2. Jeśli `OLS_CTRL` jest wykonywalny (zwykle `${OLS_ROOT}/bin/lswsctrl`, np. `/usr/local/lsws/bin/lswsctrl`):  
   `"${OLS_CTRL}" reload`
3. Inaczej: `systemctl reload lsws` → potem `systemctl reload lshttpd`
4. Na końcu: `service lsws reload`
5. Sukces → OK „OLS przeładowany.”  
   Fail → warn: zrób ręcznie `ols reload` (aktualizacja pakietów **już** poszła).

Reload **nie** restartuje twardo całego demona — soft reload workerów OLS.

---

### Krok 9 — weryfikacja końcowa

1. Ponownie: `"${path}/bin/php" -r 'echo PHP_VERSION;'` → `newv`.
2. Ponownie: `hm_php_repo_info_for_suffix` → świeże Installed/Candidate.
3. Wypis:

```text
  Było : <stara PHP_VERSION> (<stary pakiet>)
  Jest : <nowa PHP_VERSION> (<nowy pakiet>)
  Repo : <clean Candidate> (<pełny Candidate>)
```

4. Jeśli `new_inst == new_cand` (i Candidate sensowny) → OK „PHP X.Y jest aktualne względem repozytorium.”  
   W przeciwnym razie → OK „Aktualizacja zakończona.” (np. częściowy upgrade / cache jeszcze nie zsynchronizowany).

---

### Czego `update-php` **nie** robi

- Nie przełącza vhostów na inną gałąź PHP (to `php set <ver>` w kontekście strony).
- Nie czyta wersji z **php.net** (to tylko listing `php --phpnet`). Candidate = **repo LiteSpeed** na maszynie.
- Nie rusza `php.ini` ani rozszerzeń poza tym, co przyjdzie w pakietach `lsphpXX*`.
- Nie wymaga kontekstu `use <domena>` — działa globalnie dla danej gałęzi LSPHP.

### Powiązane komendy

| Komenda | Rola |
|---------|------|
| `php` / `php --refresh` | Listing vs repo; `--refresh` = sam `hm_php_pkg_refresh` |
| `php --phpnet` | Porównanie z php.net (osobna ścieżka) |
| `php set <ver>` | Przypisanie gałęzi LSPHP do **strony** |
| `ols reload` | Ręczny soft reload OLS |

</details>
