# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/pl/1.1.0/) · [Semantic Versioning](https://semver.org/lang/pl/).

Pliki punktowe dla CLI (`version`, `update-hmtools`): katalog [`changelogs/`](changelogs/).

**Instalator** (`install.sh` z brancha `develop`) domyślnie instaluje **najnowszy git tag**.  
Konkretną wersję wymuszasz zmienną `HMTOOLS_VERSION`.

```bash
# zawsze najnowszy tag
curl -fsSL https://raw.githubusercontent.com/hubert-m/vps-ssh-tools/develop/install.sh | bash
```

---

## [Unreleased] / [v0.1.5]

- Fix: `pm2` w kontekście `use` — bin/PM2_HOME ze strony (nie cudzy nvm z `/home/*`)
- Fix: Tab przy wielu dopasowaniach nie wywala hmtools (`set -e` + `bind -x`)
- `php`: porównanie zainstalowanych LSPHP z najnowszymi wersjami z php.net

---

## [v0.1.4] — 2026-10-27

### Instalacja tej wersji

```bash
curl -fsSL https://raw.githubusercontent.com/hubert-m/vps-ssh-tools/develop/install.sh | bash

HMTOOLS_VERSION=v0.1.4 curl -fsSL https://raw.githubusercontent.com/hubert-m/vps-ssh-tools/develop/install.sh | bash
```

### Zmiany

- Fix: prompt `hmtools>` / `[domena]>` nie znika przy pisaniu / Tab
- Prompt w `read -e -p` (readline); Tab bez zbędnego outputu
- Wczesny cache domen; lista kandydatów dopiero przy 2. Tab (gdy brak postępu)
- Ekran powitalny: żółte powiadomienie o nowszej wersji + komenda curl|bash
- `pm2`: czytelniejsza tabela, sortowanie po porcie ↑, skan PM2_HOME użytkowników
- Fix: resolucja `$VH_ROOT` / usera strony (`cron` w `use`, info, ścieżki)
- `cron` w kontekście: skan crontabów użytkowników; kompletna lista komend po `use`

---

## [v0.1.3] — 2026-10-27

### Instalacja tej wersji

```bash
# najnowsza (gdy v0.1.3 jest aktualnym tagiem) — bez HMTOOLS_VERSION
curl -fsSL https://raw.githubusercontent.com/hubert-m/vps-ssh-tools/develop/install.sh | bash

# na sztywno v0.1.3
HMTOOLS_VERSION=v0.1.3 curl -fsSL https://raw.githubusercontent.com/hubert-m/vps-ssh-tools/develop/install.sh | bash
```

### Zmiany

- Fix: `pm2.sh` — błąd składni `[[ =~ ]]` (klasa `[= ]`) blokujący start hmtools

---

## [v0.1.2] — 2026-10-27

### Instalacja tej wersji

```bash
# najnowsza (gdy v0.1.2 jest aktualnym tagiem) — bez HMTOOLS_VERSION
curl -fsSL https://raw.githubusercontent.com/hubert-m/vps-ssh-tools/develop/install.sh | bash

# na sztywno v0.1.2
HMTOOLS_VERSION=v0.1.2 curl -fsSL https://raw.githubusercontent.com/hubert-m/vps-ssh-tools/develop/install.sh | bash
```

### Zmiany

- Tab-complete w REPL: `use <domena>` (oraz komendy / `backup` / `ols`)
- Dopasowanie domen także po zamianie `-`/`_` na kropki
- `help <polecenie>` — szczegółowa pomoc do konkretnej komendy
- `cron` / `crons` — lista i edycja CRON (system, users, kontekst strony)
- `pm2` / `node` / `apps` — procesy PM2/Node (porty, status, proxy OLS, filtr strony)

---

## [v0.1.1] — 2026-10-27

### Instalacja tej wersji

```bash
HMTOOLS_VERSION=v0.1.1 curl -fsSL https://raw.githubusercontent.com/hubert-m/vps-ssh-tools/develop/install.sh | bash
```

### Zmiany

- Stabilniejsza instalacja `curl | bash` (kopiowanie przez `/bin/cp`, bez `rsync`)
- Poprawne rozpakowywanie archiwum z GitHuba (bez `find|head` / `pipefail`)
- Obsługa skryptów bez bitu `+x` w repozytorium (`chmod` po extract)
- Fallback do brancha `develop`, gdy tarball taga się nie uda
- Symlink komendy w `/usr/bin/hmtools` (oraz `/usr/local/bin`) — działa gdy `/usr/local/bin` nie jest w `PATH`
- [`.gitattributes`](.gitattributes) — LF dla skryptów
- Czytelniejsze logi postępu instalacji (stderr)

---

## [v0.1.0] — 2026-10-27

### Instalacja tej wersji

```bash
HMTOOLS_VERSION=v0.1.0 curl -fsSL https://raw.githubusercontent.com/hubert-m/vps-ssh-tools/develop/install.sh | bash
```

### Zmiany

- Interaktywny shell kontekstowy (`webs` → `use` → `exit`)
- Auto-detekcja CyberPanel / OpenLiteSpeed / MariaDB–MySQL
- Lista i szczegóły stron (`info`, `size`, `dbs`, `ssl`, `php`, `logs`)
- Backupy streamingowe na Google Drive (rclone) — strona i cały serwer
- Oszczędność dysku: stream + chunki, próg wolnego miejsca
- Narzędzia: `disk`, `ols`, `ssl`, `mysql`, `health`, `clean`, `detect`
- Instalacja/aktualizacja jednym `curl | bash` (porównanie po git tagach)
- Logi pracy w `/hm-tools/logs` (`applog`)
- Komendy: `update-hmtools`, `version` (+ wypis changelogu)
- Powitanie po pierwszej instalacji
- Odinstalowanie: `uninstall-hmtools [--yes]`

---

[Unreleased]: https://github.com/hubert-m/vps-ssh-tools/compare/v0.1.2...HEAD
[v0.1.2]: https://github.com/hubert-m/vps-ssh-tools/releases/tag/v0.1.2
[v0.1.1]: https://github.com/hubert-m/vps-ssh-tools/releases/tag/v0.1.1
[v0.1.0]: https://github.com/hubert-m/vps-ssh-tools/releases/tag/v0.1.0
