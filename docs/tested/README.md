# Checklisty testów ręcznych (per OS)

Dla każdej wspieranej dystrybucji osobny plik z **niezaznaczonymi** checkboxami. Zaznaczaj po ręcznym teście na czystym / docelowym VPS.

| Dystrybucja | Plik | Rodzina | Pakiety |
|-------------|------|---------|---------|
| Ubuntu | [ubuntu.md](ubuntu.md) | debian | apt |
| Debian | [debian.md](debian.md) | debian | apt |
| AlmaLinux | [almalinux.md](almalinux.md) | rhel | dnf |
| Rocky Linux | [rocky.md](rocky.md) | rhel | dnf |
| CentOS | [centos.md](centos.md) | rhel | dnf / yum |
| RHEL | [rhel.md](rhel.md) | rhel | dnf |

Zakres funkcji: [commands.md](../commands.md) · detekcja: [detection.md](../detection.md) · OS: [os-support.md](../os-support.md)

Wspólna treść checklisty: [`_checklist-body.md`](_checklist-body.md). Po zmianie listy akcji: `python docs/tested/_gen_checklists.py` (nadpisze pliki per-OS, **zachowując tylko wspólny szablon** — zaznaczenia w plikach OS znikną).

← [README główny](../../README.md)
