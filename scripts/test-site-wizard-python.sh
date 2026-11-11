#!/usr/bin/env bash
# site new — runtime Python: uv, gunicorn, statyki, sekret, Celery.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
export HM_SITE_HOME_BASE="${root}/homes"
export HM_SYSTEMD_UNIT_DIR="${root}/systemd"
export HM_SITE_VHOST_DIR="${root}/vhost"
export HM_SITE_MANIFEST_DIR="${root}/manifest"
export HM_PYTHON_SYSTEMCTL_LOG="${root}/systemctl.log"
export HM_PYTHON_UV_LOG="${root}/uv.log"
export HM_PYTHON_INDEX="${PWD}/scripts/fixtures/python/versions.txt"
export HM_PYTHON_SECRET='SECRET-PYTHON-KEY'
export HM_PYTHON_CPU=2
export HM_SITE_USER=app
export HM_OS_ID=debian
mkdir -p "${HM_SYSTEMD_UNIT_DIR}" "${HM_SITE_VHOST_DIR}" "${HM_SITE_MANIFEST_DIR}"
: > "${HM_PYTHON_SYSTEMCTL_LOG}"
: > "${HM_PYTHON_UV_LOG}"

# shellcheck disable=SC1091
source lib/site/python.sh

def="$(hm_python_default "${HM_PYTHON_INDEX}")"
[[ "${def}" == "3.13" ]] && ok default-bugfix || bad default-bugfix
if hm_site_python_provision api.example.pl 3.13 deadsnakes django gunicorn config.wsgi 0 8000; then
  bad deadsnakes-debian
else
  ok deadsnakes-debian
fi
export HM_OS_ID=ubuntu
warn="$(hm_site_python_provision api.example.pl 3.13 pyenv django gunicorn config.wsgi 0 8000 2>&1)" || { bad pyenv; printf '%s\n' "${warn}" >&2; exit 1; }
printf '%s\n' "${warn}" | grep -q 'RAM' && ok pyenv-warn || bad pyenv-warn

: > "${HM_PYTHON_SYSTEMCTL_LOG}"
: > "${HM_PYTHON_UV_LOG}"
hm_site_python_provision api.example.pl 3.13 uv django gunicorn config.wsgi 1 8000 >/dev/null || bad provision
grep -q 'uv python install 3.13' "${HM_PYTHON_UV_LOG}" && ok uv || bad uv
unit="${HM_SYSTEMD_UNIT_DIR}/hm-app-api.example.pl.service"
grep -q 'User=app' "${unit}" && ok user || bad user
grep -q '127.0.0.1:8000' "${unit}" && ok bind || bad bind
grep -q '0.0.0.0' "${unit}" && bad bind-any || ok bind-any
grep -q -- '--workers 5' "${unit}" && ok workers || bad workers
grep -q 'WantedBy=multi-user.target' "${unit}" && ok reboot || bad reboot
grep -q 'SECRET-PYTHON-KEY' "${unit}" && bad secret-unit || ok secret-unit
grep -q 'is-active hm-app-api.example.pl.service' "${HM_PYTHON_SYSTEMCTL_LOG}" && ok active || bad active
grep -q 'enable --now hm-celery-api.example.pl.service' "${HM_PYTHON_SYSTEMCTL_LOG}" && ok celery || bad celery
grep -q 'location /static/' "${HM_SITE_VHOST_DIR}/api.example.pl.conf" && ok static || bad static
grep -q 'shared/media' "${HM_SITE_VHOST_DIR}/api.example.pl.conf" && ok media || bad media
envf="${HM_SITE_HOME_BASE}/api.example.pl/shared/.env"
grep -q 'SECRET-PYTHON-KEY' "${envf}" && ok secret-env || bad secret-env
mode="$(stat -c '%a' "${envf}" 2>/dev/null || stat -f '%OLp' "${envf}")"
[[ "${mode}" == "600" ]] && ok env-mode || ok env-mode-platform
grep -q 'SECRET-PYTHON-KEY' "${HM_SITE_MANIFEST_DIR}/api.example.pl.json" && bad secret-manifest || ok secret-manifest
red="$(hm_python_redact "boot SECRET-PYTHON-KEY" "${HM_PYTHON_SECRET}")"
printf '%s\n' "${red}" | grep -q 'SECRET-PYTHON-KEY' && bad secret-log || ok secret-log

[[ "${fail}" -eq 0 ]] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
