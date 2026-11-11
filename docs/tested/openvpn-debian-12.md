# OpenVPN — Debian 12

Ręczna checklista. Pakiety: `apt`.

- [ ] `detect` pokazuje `OS_ID=debian`, rodzina `debian`
- [ ] `openvpn install --dry-run` nie zmienia `/etc`
- [ ] Instalacja z `--yes` zapisuje `hm.conf` i unit `openvpn-server@hm`
- [ ] `openvpn status` i puste `openvpn` dają ten sam skrót
- [ ] CRL: `openvpn crl update`, potem `openvpn crl status` nie pokazuje wygasłej listy
- [ ] `openvpn doctor` widzi pakiet `openvpn` i `easyrsa`
- [ ] Kopia `openvpn backup` nie wypisuje `ca.key` na stdout
- [ ] NAT nie dotyka reguł SSH
- [ ] Forwarding działa po restarcie (sysctl `99-hmtools-openvpn.conf`)
- [ ] `openvpn audit` na świeżym `hm.conf` nie wypisuje `BŁĄD`
- [ ] `openvpn fail2ban on` ładuje jail `hmtools-openvpn` (`fail2ban-client -t`)
- [ ] Po `openvpn ca rotate` łączy się stary i nowy profil; po `ca rotate finish` tylko nowy
