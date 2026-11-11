# OpenVPN — AlmaLinux 9

Ręczna checklista. Pakiety: `dnf`, najpierw EPEL (`epel-release`, `openvpn`, `easy-rsa`).

- [ ] `detect` pokazuje rodzinę `rhel` i `PKG_MANAGER=dnf`
- [ ] `openvpn install --dry-run` nie woła `dnf` bez zgody
- [ ] Instalacja z `--yes` włącza `openvpn-server@hm` i firewalld (port i masquerade)
- [ ] `services` pokazuje `openvpn`, gdy unit jest zainstalowany
- [ ] `openvpn doctor` zgłasza tryb klucza inny niż 0600
- [ ] `openvpn config set` przyjmuje tylko ENDPOINT, PORT, PROTO, DNS, SUBNET
- [ ] Brak `tun` przerywa instalację
- [ ] SELinux nie blokuje socketa `/run/openvpn-server/hm.sock` (banner `openvpn=yes` dopiero przy sockecie)
- [ ] NAT zostaje po restarcie (usługa `hmtools-openvpn-nat` albo firewalld)
- [ ] `openvpn audit` na świeżym `hm.conf` nie wypisuje `BŁĄD`
- [ ] `openvpn fail2ban on` ładuje jail `hmtools-openvpn` (`fail2ban-client -t`)
- [ ] Po `openvpn ca rotate` łączy się stary i nowy profil; po `ca rotate finish` tylko nowy
