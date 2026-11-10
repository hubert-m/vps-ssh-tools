# Profile `site new`

JSON (albo YAML) bez haseł. `site new <domena> --from plik` bierze stąd preset, runtime, bazę, webserver i wersję PHP. Domena w pliku jest pusta — podajesz ją w komendzie.

| Plik | preset | runtime | db | webserver | php |
|------|--------|---------|----|-----------|-----|
| `laravel.json` | laravel | php | mysql | nginx | 8.4 |
| `wordpress.json` | wordpress | php | mysql | nginx | 8.3 |
| `nextjs.json` | next | node | none | nginx | — |
| `django.json` | django | python | postgres | nginx | — |
| `aspnet.json` | aspnet | dotnet | none | nginx | — |
| `spa.json` | spa | static | none | nginx | — |

Pole `domain` zostaw puste w szablonie. `--save-profile` zapisuje ten sam zestaw pól dla już utworzonego serwisu.
