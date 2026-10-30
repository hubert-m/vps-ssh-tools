#!/usr/bin/env bash
# Moduł: detect


_hm_cmd_help detect <<'EOF'
Użycie: detect | env

Karta „Wykryty stos”:
  OS (/etc/os-release) + rodzina (debian/rhel) + pkg (apt/dnf/yum),
  PANEL, WEBSERVER, DB oraz ścieżki OLS/CyberPanel.
  Wspierane OS: Ubuntu, Debian, AlmaLinux, Rocky Linux, CentOS, RHEL.
  Panele: cyberpanel, cpanel (UAPI), plesk (CLI), webmin, directadmin, aapanel.
  WWW: openlitespeed, nginx, apache (+ dodatkowe, jeśli współistnieją).

Sugeruje komendy hmtools dopasowane do stosu.
Niewspierany OS → tylko uninstall-hmtools / help / version / detect / exit
  (bypass: ALLOW_UNSUPPORTED_OS=1).
Nadpisanie: FORCE_PANEL, FORCE_WEBSERVER, FORCE_DB_ENGINE.
EOF

cmd_detect() {
  hm_detect_print
}

_hm_cmd_register detect cmd_detect 1 env
