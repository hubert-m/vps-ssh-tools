# Wsparcie dystrybucji i usług

hmtools wykrywa OS z `/etc/os-release` (`lib/detect.sh`) i dobiera menedżer pakietów oraz sposób restartu usług.

## Wspierane dystrybucje

| Rodzina | ID (przykłady) | Pakiety |
|---------|----------------|---------|
| **debian** | `ubuntu`, `debian`, (ID_LIKE=debian) | `apt` / `apt-get` |
| **rhel** | `almalinux`, `rocky`, `centos`, `rhel`, `fedora` | `dnf` lub `yum` |

Obsługa **OpenLiteSpeed** (CyberPanel) pozostaje pełna i bez regresji — to nadal główny scenariusz (`ols`, `webs`, `php`, …).

Na Nginx/Apache dostępne są głównie narzędzia niezależne od OLS (`mysql`, `backup`, `health`, `disk`); komendy `ols`/`php` LSPHP wymagają instalacji LiteSpeed.

## Różnice ścieżek / usług

| Obszar | OLS | Nginx | Apache (Debian) | Apache (RHEL) |
|--------|-----|-------|-----------------|---------------|
| Conf | `/usr/local/lsws/conf/` | `/etc/nginx/` | `/etc/apache2/` | `/etc/httpd/` |
| Error log | `…/logs/error.log` | `/var/log/nginx/error.log` | `/var/log/apache2/error.log` | `/var/log/httpd/error_log` |
| Reload | `lswsctrl` → `systemctl` | `systemctl reload nginx` | `apache2` | `httpd` |
| SSL LE | `/etc/letsencrypt/` (wspólne) | j.w. | j.w. | j.w. |

Helpery: `hm_service_reload`, `hm_web_error_log_guess`, `hm_pkg_install`, `PKG_MANAGER` / `OS_FAMILY`.

## Niewspierany / nierozpoznany OS

Jeśli `OS_SUPPORTED=0` (brak `/etc/os-release` albo nieznana dystrybucja):

1. Banner ostrzega przy starcie.
2. Prompt: `hmtools[unsupported]>`.
3. Dozwolone tylko: `uninstall-hmtools`, `help`, `version`, `detect`, `exit`.

Bypass (świadomie): `ALLOW_UNSUPPORTED_OS=1` w `hmtools.conf`.

## Testy

Weryfikacja ręczna na czystych VPS: Ubuntu LTS, Debian, AlmaLinux, Rocky, CentOS Stream — `detect`, `health`, instalacja pakietu przez właściwy PM, reload WWW.

← [README](../README.md) · [Detekcja stosu](detection.md)
