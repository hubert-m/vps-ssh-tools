# OpenVPN

`openvpn` stawia serwer z własnym PKI i profilami klientów. Komenda jest niedostępna na niewspieranym OS (tryb restricted). Alias: `ovpn`, `vpn`.

## Układ

Stan w `hmtools.state` jest źródłem prawdy. `hm.conf` powstaje z niego ponownie, nie przez ręczną edycję. Instancja to `openvpn-server@hm`.

| Plik | Rola |
| --- | --- |
| `commands/openvpn/main.sh` | rejestracja, klienci, CRL, pomoc |
| `commands/openvpn/install.sh` | pakiety, PKI, NAT, uninstall |
| `commands/openvpn/config.sh` | port, DNS, trasy, ccd, rollback |
| `commands/openvpn/status.sh` | status, who, kick, log, health |
| `commands/openvpn/backup.sh` | archiwum, manifest, restore |
| `commands/openvpn/audit.sh` | audyt, Fail2Ban, rotacja CA |

Kolejność: install, klienci, revoke, REPL, status, uninstall, config, backup, audit. MVP to install, klienci, revoke i REPL. WireGuard, QR całego profilu i login z hasłem są poza tym modułem. Przejście na żywym VPS (install, client add, who, revoke, backup, restore, uninstall, SSH bez zmian) jest na checkliście w `docs/tested/`.

### Gwarancje architektury

- **Jedno źródło prawdy:** `/etc/openvpn/server/hmtools.state` (nadpisywalne `HM_OVPN_*`). `hm.conf` jest renderowany ze stanu, nie edytowany ręcznie jako źródło.
- **Brak reinstall/init-pki:** gdy instalacja hmtools już istnieje (`hm.conf` + stan albo PKI), `openvpn install` odmawia — zmiany idą przez `config set` / klientów. Ponowne `init-pki` nie kasuje CA.
- **CRL tylko w `hm/`:** `crl-verify` wskazuje `…/hm/crl.pem`. `install --force` przy obcej konfiguracji **nie** nadpisuje cudzego `crl.pem` w katalogu serwera.
- **Obca konfiguracja:** obce `*.conf` blokują install bez `--force`; `--force` wymaga krytycznego potwierdzenia i nie rusza plików spoza markera hmtools przy uninstall bez manifestu.
- **NAT / firewall:** bloki oznaczone `hmtools-openvpn`; SSH i reguły spoza markera zostają. `PREV_FORWARD` w stanie służy uninstallowi.
- **Testy:** `scripts/test-openvpn-*.sh` (mock CLI, bez żywego demona).

## Instalacja

```bash
openvpn install --dry-run
openvpn install --yes --port 1194 --proto udp --endpoint vpn.example --subnet 10.8.0.0/24
```

Powstają `hm.conf` (tls-crypt, AES-256-GCM), stan w `hmtools.state` i unit `openvpn-server@hm`. NAT dopisuje się w oznaczonym bloku i nie rusza reguł SSH.

`openvpn` bez argumentów pokazuje skrót (endpoint, port, liczba ważnych klientów, CRL). Gdy nie ma konfiguracji, podpowiada `openvpn install --dry-run`.

## Klienci

```bash
openvpn client add laptop --yes
openvpn client export laptop
openvpn client revoke laptop --yes
openvpn client renew laptop --yes
openvpn crl update
```

Profil `.ovpn` ma klucz w pliku 0600. Treść klucza nie trafia do applog. `openvpn who` czyta lokalny plik statusu, `openvpn kick <nazwa>` wysyła `kill` na socket management.

`openvpn backup [katalog]` kopiuje sam katalog PKI. `openvpn backup --local` składa `tar.gz` z konfiguracją, PKI, profilami i manifestem SHA-256 (plik 0600). Wysyłka `--target` bez `BACKUP_ENCRYPT_PASSPHRASE` jest blokowana. `openvpn restore <plik> --yes` sprawdza sumy, a przy nieudanym starcie wraca do poprzedniego stanu.

`openvpn uninstall` domyślnie robi **kopię katalogu PKI** (nie pełne `tar.gz` z `--local`), potem zdejmuje bloki `hmtools-openvpn`, unit, sysctl, cron i jail. `ip_forward` wraca do `PREV_FORWARD` z manifestu. Reguły spoza markera, w tym SSH, zostają. Bez manifestu komenda odmawia; `--force` pozwala zdjąć markery / sysctl bez manifestu i **nie kasuje** obcych plików spoza allowlisty hmtools. `--no-backup` pomija kopię PKI. `--dry-run` nic nie zmienia.

`openvpn doctor` wykrywa `easyrsa` jak install (PATH albo `/usr/share/easy-rsa/…`), unit oraz tryb `tls-crypt.key` i `ca.key` ze ścieżki PKI z `hmtools.state` (domyślnie `…/hm/pki`). `openvpn config set` składa `hm.conf` ze stanu. Przed zapisem powstaje kopia, a nieudany restart przywraca poprzedni plik. `--dry-run` nic nie zmienia. `openvpn client ip` zapisuje `ccd` i nie restartuje usługi.

`openvpn audit` tylko czyta konfigurację i wypisuje `OK`, `UWAGA` albo `BŁĄD` z podpowiedzią. `openvpn audit --fix` poprawia uprawnienia, usuwa `compress` i dopisuje `tls-version-min 1.2`. Szyfr zostaje, bo zmiana wymaga nowych profili. `openvpn fail2ban on` stawia jail `hmtools-openvpn` na błędy TLS i `AUTH_FAILED`, z adresem bieżącej sesji SSH w `ignoreip`. `openvpn ca rotate` trzyma starą i nową CA w jednym bundlu, a `openvpn ca rotate finish` zostawia tylko nową. Port `1194/udp` jest znanym portem w `security ports`.

## Typowe problemy

- **Brak tun.** Instalacja zatrzymuje się, gdy w systemie nie ma urządzenia `tun`. Trzeba je włączyć u dostawcy albo w kontenerze (`--device /dev/net/tun`).
- **CRL wygasła.** Klienci dostają błąd weryfikacji. `openvpn crl update` wystawia nową listę, a `openvpn schedule install` wpina cotygodniowy cron.
- **Docker i FORWARD.** Kontener z OpenVPN potrzebuje przekazywania pakietów (`ip_forward`) i łańcucha FORWARD. Sam NAT na hoście nie wystarczy, gdy Docker nadpisuje reguły.
- **NAT u providera.** Ruch z `10.8.0.0/24` musi wychodzić przez maskaradę na interfejsie VPS. Część sieci blokuje forwarding; wtedy klienci łączą się, ale nie mają internetu.
- **Port 443/tcp.** W sieciach, które puszczają tylko HTTPS, ustaw `--port 443 --proto tcp`. UDP 1194 bywa ucinane.

## Detekcja

Banner i `health` wspominają OpenVPN tylko wtedy, gdy istnieje lokalny socket zarządzania albo `FORCE_OPENVPN=yes`. Start nie odpala `systemctl` ani sieci. `services` pokazuje unit `openvpn-server@hm`, gdy jest zainstalowany.
