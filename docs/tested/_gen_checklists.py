#!/usr/bin/env python3
"""Generate per-OS checklist markdown from _checklist-body.md."""
from pathlib import Path

ROOT = Path(__file__).resolve().parent
body = ROOT.joinpath("_checklist-body.md").read_text(encoding="utf-8")
if body.startswith("<!--"):
    body = body.split("-->", 1)[1].lstrip("\n")

OSES = [
    {
        "file": "ubuntu.md",
        "title": "Ubuntu — checklista testów hmtools",
        "fam": "debian",
        "pkg": "apt / apt-get",
        "oid": "ubuntu",
        "notes": """## Specyfika Ubuntu

- [ ] `detect` pokazuje `OS_ID=ubuntu`, `OS_FAMILY=debian`, `PKG_MANAGER=apt`
- [ ] `php --refresh` używa `apt-get update`
- [ ] Apache (jeśli obecny): unit `apache2`, log `/var/log/apache2/error.log`
- [ ] Nginx (jeśli obecny): unit `nginx`, log `/var/log/nginx/error.log`
""",
    },
    {
        "file": "debian.md",
        "title": "Debian — checklista testów hmtools",
        "fam": "debian",
        "pkg": "apt / apt-get",
        "oid": "debian",
        "notes": """## Specyfika Debian

- [ ] `detect` pokazuje `OS_ID=debian`, `OS_FAMILY=debian`, `PKG_MANAGER=apt`
- [ ] `php --refresh` używa `apt-get update`
- [ ] Apache (jeśli obecny): unit `apache2`, log `/var/log/apache2/error.log`
- [ ] Nginx (jeśli obecny): unit `nginx`, log `/var/log/nginx/error.log`
""",
    },
    {
        "file": "almalinux.md",
        "title": "AlmaLinux — checklista testów hmtools",
        "fam": "rhel",
        "pkg": "dnf (fallback yum)",
        "oid": "almalinux",
        "notes": """## Specyfika AlmaLinux

- [ ] `detect` pokazuje `OS_ID=almalinux`, `OS_FAMILY=rhel`, `PKG_MANAGER=dnf` (lub yum)
- [ ] `php --refresh` używa `dnf makecache` / `yum makecache`
- [ ] Apache (jeśli obecny): unit `httpd`, log `/var/log/httpd/error_log`
- [ ] Nginx (jeśli obecny): unit `nginx`, log `/var/log/nginx/error.log`
""",
    },
    {
        "file": "rocky.md",
        "title": "Rocky Linux — checklista testów hmtools",
        "fam": "rhel",
        "pkg": "dnf (fallback yum)",
        "oid": "rocky",
        "notes": """## Specyfika Rocky Linux

- [ ] `detect` pokazuje `OS_ID=rocky`, `OS_FAMILY=rhel`, `PKG_MANAGER=dnf` (lub yum)
- [ ] `php --refresh` używa `dnf makecache` / `yum makecache`
- [ ] Apache (jeśli obecny): unit `httpd`, log `/var/log/httpd/error_log`
- [ ] Nginx (jeśli obecny): unit `nginx`, log `/var/log/nginx/error.log`
""",
    },
    {
        "file": "centos.md",
        "title": "CentOS — checklista testów hmtools",
        "fam": "rhel",
        "pkg": "dnf / yum",
        "oid": "centos",
        "notes": """## Specyfika CentOS

- [ ] `detect` pokazuje `OS_ID=centos` (lub pochodna Stream), `OS_FAMILY=rhel`
- [ ] `PKG_MANAGER` = `dnf` (CentOS Stream / 8+) lub `yum` (starsze)
- [ ] `php --refresh` używa właściwego PM (`dnf`/`yum makecache`)
- [ ] Apache (jeśli obecny): unit `httpd`, log `/var/log/httpd/error_log`
- [ ] Nginx (jeśli obecny): unit `nginx`, log `/var/log/nginx/error.log`
""",
    },
    {
        "file": "rhel.md",
        "title": "RHEL — checklista testów hmtools",
        "fam": "rhel",
        "pkg": "dnf (fallback yum)",
        "oid": "rhel",
        "notes": """## Specyfika RHEL

- [ ] `detect` pokazuje `OS_ID=rhel`, `OS_FAMILY=rhel`, `PKG_MANAGER=dnf` (lub yum)
- [ ] `php --refresh` używa `dnf makecache` / `yum makecache`
- [ ] Apache (jeśli obecny): unit `httpd`, log `/var/log/httpd/error_log`
- [ ] Nginx (jeśli obecny): unit `nginx`, log `/var/log/nginx/error.log`
""",
    },
]

for o in OSES:
    header = f"""# {o['title']}

Checklist ręcznych testów hmtools na **{o['oid']}**. Zaznaczaj `- [x]` po weryfikacji.

| | |
|--|--|
| **OS_ID** | `{o['oid']}` |
| **Rodzina** | {o['fam']} |
| **Pakiety** | {o['pkg']} |
| **Mapa komend** | [commands.md](../commands.md) |
| **Indeks testów** | [README.md](README.md) |

{o['notes']}
---

"""
    ROOT.joinpath(o["file"]).write_text(header + body, encoding="utf-8", newline="\n")
    print("Wrote", o["file"])
