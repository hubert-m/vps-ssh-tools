# Szybki start

```text
# hmtools
hmtools> detect
hmtools> webs
 #  DOMAIN              PHP    SSL   SIZE    STATUS
 1  example.com         8.2    yes   12.4G   active
 2  blog.example.com    8.1    yes    2.1G   active

hmtools> use 1
[example.com]> info
[example.com]> dbs
[example.com]> backup
[example.com]> exit
hmtools> backup full
hmtools> exit
```

- `webs` — lista usług (dodaj `--quick`, żeby pominąć wolne `du`)
- `use <numer|domena>` — wejście w kontekst strony (**Tab** uzupełnia domenę)
- `exit` w kontekście — powrót do `hmtools>`
- `exit` na poziomie głównym — wyjście do SSH

Pełna mapa komend: [commands.md](commands.md).

← [README](../README.md)
