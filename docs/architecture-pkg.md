# Architektura: pakiety i różnice dystrybucji

hmtools rozdziela **dwie osie** różnic między serwerami — nie mieszać ich w kodzie feature’ów (`commands/`, `lib/sites/` poza cienkimi wrapperami).

## Osie

| Oś | Wartości | Pliki | Kiedy |
|----|----------|-------|--------|
| **PKG_MANAGER** | `apt` / `dnf` / `yum` | [`lib/pkg.sh`](../lib/pkg.sh), [`lib/pkg/apt.sh`](../lib/pkg/apt.sh), [`lib/pkg/rpm.sh`](../lib/pkg/rpm.sh) | install, upgrade, candidate, refresh |
| **OS_FAMILY** | `debian` / `rhel` | [`lib/os_family.sh`](../lib/os_family.sh), [`lib/os/debian.sh`](../lib/os/debian.sh), [`lib/os/rhel.sh`](../lib/os/rhel.sh) | grupy WWW, jednostka apache, firewall |
| **OS_ID** (rzadko) | np. `almalinux`, `ubuntu` | `lib/pkg/overrides/<id>.sh`, `lib/os/overrides/<id>.sh` | quirk **jednej** dystrybucji |

## Zasady (SOLID w bashu)

1. Feature woła tylko `hm_pkg_*` / `hm_os_*` — **bez** `apt-get` / `dnf` / `yum` / `case "${OS_ID}"`.
2. Nowy quirk jednej dystrybucji → plik override (redefinicja wybranej `_hm_pkg_do_*` / `_hm_os_do_*`), **nie** `if` w `update-php`.
3. Zmiana w `lib/pkg/apt.sh` lub `rpm.sh` → retest **obu** rodzin OS (`docs/tested/`).
4. Zmiana tylko w `overrides/<OS_ID>.sh` → retest **tej** dystrybucji.

## Ładowanie

`bin/hmtools` → `detect.sh` → `pkg.sh` → `os_family.sh` → … → `hm_load_config` → `hm_detect_all` → `hm_pkg_bind` / `hm_os_bind` (po znanym `OS_ID` + `PKG_MANAGER`).

Nadpisanie testowe: `FORCE_PKG_MANAGER=apt|dnf|yum` w `hmtools.conf`.

## Przykład override (nie commitować na zapas)

```bash
# lib/pkg/overrides/almalinux.sh
# Redefiniuj tylko to, co się różni — po załadowaniu rpm.sh:
_hm_pkg_do_upgrade() {
  hm_run dnf update -y --allowerasing "$@"
}
```

← [Wsparcie OS](os-support.md) · [README](../README.md)
