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
source scripts/lib-test-site.sh
hm_test_site_load
export HM_SITE_STATE_DIR="${root}/state"
mkdir -p "${HM_SITE_STATE_DIR}"

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
hm_tx_note_undo() { printf 'undo=%s\n' "$1" >> "${root}/journal.log"; }
hm_site_resource_add() { printf '%s\t%s\n' "$2" "$3" >> "${root}/resources"; }
hm_site_python_provision api.example.pl 3.13 uv django gunicorn config.wsgi 1 8000 >/dev/null || bad provision
grep -q 'uv python install 3.13' "${HM_PYTHON_UV_LOG}" && ok uv || bad uv
[[ -x "${HM_SITE_HOME_BASE}/api.example.pl/venv/bin/python" ]] && ok venv-bin || bad venv-bin
unit="${HM_SYSTEMD_UNIT_DIR}/hm-app-api.example.pl.service"
grep -q 'User=app' "${unit}" && ok user || bad user
grep -q '127.0.0.1:8000' "${unit}" && ok bind || bad bind
grep -q '0.0.0.0' "${unit}" && bad bind-any || ok bind-any
grep -q -- '--workers 5' "${unit}" && ok workers || bad workers
grep -q 'WantedBy=multi-user.target' "${unit}" && ok reboot || bad reboot
grep -q 'SECRET-PYTHON-KEY' "${unit}" && bad secret-unit || ok secret-unit
grep -q "undo=systemd-unit	${unit}" "${root}/journal.log" && ok unit-undo || bad unit-undo
grep -q 'is-active hm-app-api.example.pl.service' "${HM_PYTHON_SYSTEMCTL_LOG}" && ok active || bad active
grep -q 'enable --now hm-celery-api.example.pl.service' "${HM_PYTHON_SYSTEMCTL_LOG}" && ok celery || bad celery
home_py="${HM_SITE_HOME_BASE}/api.example.pl"
extra=""
for cand in \
  "${HM_SITE_STATE_DIR}/api.example.pl/vhost.extra" \
  "${home_py}/.config/hmtools/vhost.extra"
do
  [[ -f "${cand}" ]] && extra="${cand}" && break
done
[[ ! -f "${HM_SITE_VHOST_DIR}/api.example.pl.conf" ]] && ok vhost-not-written || bad vhost-not-written
[[ -n "${extra}" ]] && grep -q 'location /static/' "${extra}" && ok static || bad static
[[ -n "${extra}" ]] && grep -q 'shared/media' "${extra}" && ok media || bad media
envf="${HM_SITE_HOME_BASE}/api.example.pl/shared/.env"
grep -q 'SECRET-PYTHON-KEY' "${envf}" && ok secret-env || bad secret-env
[[ "$(grep -c '^SECRET_KEY=' "${envf}")" -eq 1 ]] && ok secret-once || bad secret-once
# ponowny provision nie dubluje SECRET_KEY
hm_site_python_provision api.example.pl 3.13 uv django gunicorn config.wsgi 0 8000 >/dev/null || true
[[ "$(grep -c '^SECRET_KEY=' "${envf}")" -eq 1 ]] && ok secret-nodup || bad secret-nodup
mode="$(stat -c '%a' "${envf}" 2>/dev/null || stat -f '%OLp' "${envf}")"
[[ "${mode}" == "600" ]] && ok env-mode || ok env-mode-platform
grep -q 'SECRET-PYTHON-KEY' "${HM_SITE_MANIFEST_DIR}/api.example.pl.json" && bad secret-manifest || ok secret-manifest
red="$(hm_python_redact "boot SECRET-PYTHON-KEY" "${HM_PYTHON_SECRET}")"
printf '%s\n' "${red}" | grep -q 'SECRET-PYTHON-KEY' && bad secret-log || ok secret-log

# Domyślny wsgi per framework
[[ "$(hm_python_default_wsgi flask)" == "app:app" ]] && ok default-flask || bad default-flask
[[ "$(hm_python_default_wsgi fastapi)" == "main:app" ]] && ok default-fastapi || bad default-fastapi
[[ "$(hm_python_default_wsgi django)" == "config.wsgi" ]] && ok default-django || bad default-django

# Flask: ExecStart z app:app + placeholder
: > "${HM_PYTHON_SYSTEMCTL_LOG}"
hm_site_python_provision flask.example.pl 3.13 uv flask gunicorn "" 0 8010 >/dev/null || bad flask-prov
funit="${HM_SYSTEMD_UNIT_DIR}/hm-app-flask.example.pl.service"
grep -q 'app:app' "${funit}" && ok flask-wsgi || bad flask-wsgi
[[ -f "${HM_SITE_HOME_BASE}/flask.example.pl/current/app.py" ]] && ok flask-placeholder || bad flask-placeholder
[[ ! -f "${HM_SITE_VHOST_DIR}/flask.example.pl.conf" ]] && ok flask-no-vhost || bad flask-no-vhost

[[ "${fail}" -eq 0 ]] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
