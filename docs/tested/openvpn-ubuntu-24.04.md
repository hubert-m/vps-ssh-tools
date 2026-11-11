# OpenVPN — Ubuntu 24.04

Ręczna checklista. Pakiety: `apt`.

- [ ] `detect` pokazuje `OS_ID=ubuntu` i w bannerze `openvpn=no`, dopóki nie ma socketa
- [ ] `openvpn install --dry-run` nie zmienia `/etc` i nie woła sieci
- [ ] `openvpn install --yes --endpoint <ip> --port 1194 --proto udp` stawia `openvpn-server@hm`
- [ ] `openvpn` bez argumentów pokazuje endpoint i liczbę klientów
- [ ] `openvpn client add laptop --yes` daje profil 0600, klucz nie ma go w `openvpn log`
- [ ] `openvpn doctor` zgłasza brak, gdy `tls-crypt.key` nie jest 0600
- [ ] `help openvpn` wymienia install, client, crl, backup i doctor
- [ ] Tab: `openvpn client revoke` uzupełnia CN z `index.txt` (tylko wiersze V)
- [ ] Brak urządzenia `tun` przerywa instalację
- [ ] Port 443/tcp przechodzi tam, gdzie UDP 1194 jest ucięte
- [ ] `openvpn audit` na świeżym `hm.conf` nie wypisuje `BŁĄD`
- [ ] `openvpn fail2ban on` ładuje jail `hmtools-openvpn` (`fail2ban-client -t`)
- [ ] Po `openvpn ca rotate` łączy się stary i nowy profil; po `ca rotate finish` tylko nowy
