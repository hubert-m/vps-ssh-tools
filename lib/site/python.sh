#!/usr/bin/env bash
# Runtime Python dla site new: uv/venv, gunicorn/uvicorn, statyki Django, Celery.

if [[ -n "${HMTOOLS_SITE_PYTHON_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_SITE_PYTHON_LOADED=1

hm_python_index_rows() {
  local file="$1" ver status
  [[ -f "${file}" ]] || return 1
  while read -r ver status _; do
    [[ -n "${ver}" && "${ver}" != \#* ]] || continue
    printf '%s\t%s\n' "${ver}" "${status}"
  done < "${file}"
}

hm_python_default() {
  local file="$1" ver status best=""
  while IFS=$'\t' read -r ver status; do
    [[ "${status}" == "bugfix" ]] || continue
    if [[ -z "${best}" ]] || printf '%s\n%s\n' "${best}" "${ver}" | sort -V | tail -1 | grep -qx "${ver}"; then
      best="${ver}"
    fi
  done < <(hm_python_index_rows "${file}")
  [[ -n "${best}" ]] || return 1
  printf '%s\n' "${best}"
}

hm_python_os_id() {
  if [[ -n "${HM_OS_ID:-}" ]]; then
    printf '%s' "${HM_OS_ID}"
    return 0
  fi
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    printf '%s' "${ID:-}"
  fi
}

hm_site_python_home() {
  if declare -F hm_site_home >/dev/null 2>&1; then
    hm_site_home "$1"
    return
  fi
  printf '%s/%s' "${HM_SITE_HOME_BASE:-/home}" "$1"
}

hm_python_systemctl() {
  if [[ -n "${HM_PYTHON_SYSTEMCTL_LOG:-}" ]]; then
    printf '%s\n' "$*" >> "${HM_PYTHON_SYSTEMCTL_LOG}"
    if [[ "${1:-}" == "is-active" ]]; then
      printf 'active\n'
    fi
    return 0
  fi
  [[ "${HMTOOLS_TEST:-}" == "1" ]] && return 0
  systemctl "$@"
}

hm_python_redact() {
  local line="$1" secret="$2"
  [[ -n "${secret}" ]] && line="${line//${secret}/***}"
  printf '%s\n' "${line}"
}

hm_python_write_unit() {
  local path="$1" user="$2" home="$3" exec="$4" fw="$5"
  mkdir -p "$(dirname "${path}")"
  {
    printf '%s\n' '[Unit]' 'After=network.target' '' '[Service]' 'Type=simple'
    printf 'User=%s\n' "${user}"
    printf 'WorkingDirectory=%s/current\n' "${home}"
    printf 'ExecStart=%s\n' "${exec}"
    if [[ "${fw}" == "django" ]]; then
      printf '%s\n' 'Environment=DJANGO_SETTINGS_MODULE=config.settings'
    fi
    printf 'EnvironmentFile=-%s/shared/.env\n' "${home}"
    printf '%s\n' 'Restart=always' 'NoNewPrivileges=true' 'ProtectSystem=strict' 'PrivateTmp=true'
    printf 'ReadWritePaths=%s/shared\n' "${home}"
    printf '%s\n' '' '[Install]' 'WantedBy=multi-user.target'
  } > "${path}"
}

hm_python_write_vhost() {
  local domain="$1" home="$2" path block
  # Snipet dla W04 ({{EXTRA}}) — nie zapisujemy sites-available.
  if declare -F hm_site_state_dir >/dev/null 2>&1; then
    path="$(hm_site_state_dir "${domain}")/vhost.extra"
  elif [[ -n "${HM_SITE_STATE_DIR:-}" ]]; then
    path="${HM_SITE_STATE_DIR}/${domain}/vhost.extra"
  else
    path="${home}/.config/hmtools/vhost.extra"
  fi
  block="$(cat <<EOF
    location /static/ {
        alias ${home}/shared/static/;
    }
    location /media/ {
        alias ${home}/shared/media/;
    }
EOF
)"
  mkdir -p "$(dirname "${path}")"
  if declare -F hm_site_write_nofollow >/dev/null 2>&1; then
    printf '%s\n' "${block}" | hm_site_write_nofollow "${path}" || printf '%s\n' "${block}" > "${path}"
  else
    printf '%s\n' "${block}" > "${path}"
  fi
}

hm_python_note_unit() {
  local path="$1" domain="$2"
  if declare -F hm_site_resource_add >/dev/null 2>&1; then
    hm_site_resource_add "${domain}" unit "${path}" 0 || true
  fi
  if declare -F hm_tx_note_undo >/dev/null 2>&1; then
    hm_tx_note_undo "$(printf 'systemd-unit\t%s' "${path}")"
  fi
}

hm_python_create_venv() {
  local venv="$1" ver="$2" source="$3" user="$4" py=""
  mkdir -p "$(dirname "${venv}")"
  if [[ -n "${HM_PYTHON_UV_LOG:-}" || "${HM_PYTHON_MOCK:-}" == "1" ]]; then
    mkdir -p "${venv}/bin"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "${venv}/bin/python"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "${venv}/bin/gunicorn"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "${venv}/bin/uvicorn"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "${venv}/bin/celery"
    chmod 0755 "${venv}/bin/"*
    return 0
  fi
  case "${source}" in
    uv)
      if command -v uv >/dev/null 2>&1; then
        su -s /bin/bash "${user}" -c "uv python install ${ver} && uv venv ${venv}" || return 1
        su -s /bin/bash "${user}" -c "${venv}/bin/python -m pip install gunicorn uvicorn" || \
          su -s /bin/bash "${user}" -c "uv pip install --python ${venv}/bin/python gunicorn uvicorn" || return 1
      else
        py="$(command -v "python${ver}" 2>/dev/null || command -v python3)"
        [[ -n "${py}" ]] || { hm_err "Brak uv i python${ver}."; return 1; }
        su -s /bin/bash "${user}" -c "${py} -m venv ${venv}" || return 1
        su -s /bin/bash "${user}" -c "${venv}/bin/pip install --upgrade pip gunicorn uvicorn" || return 1
      fi
      ;;
    system|deadsnakes)
      py="$(command -v "python${ver}" 2>/dev/null || command -v python3)"
      [[ -n "${py}" ]] || { hm_err "Brak interpretera python${ver}/python3."; return 1; }
      su -s /bin/bash "${user}" -c "${py} -m venv ${venv}" || return 1
      su -s /bin/bash "${user}" -c "${venv}/bin/pip install --upgrade pip gunicorn uvicorn" || return 1
      ;;
    pyenv)
      hm_warn "pyenv: oczekuję istniejącego python${ver}; tworzę venv."
      py="$(command -v "python${ver}" 2>/dev/null || command -v python3)"
      su -s /bin/bash "${user}" -c "${py} -m venv ${venv}" || return 1
      su -s /bin/bash "${user}" -c "${venv}/bin/pip install gunicorn uvicorn" || return 1
      ;;
  esac
  [[ -x "${venv}/bin/python" ]] || { hm_err "venv bez ${venv}/bin/python."; return 1; }
}

hm_python_env_upsert() {
  local envf="$1" key="$2" val="$3" tmp
  mkdir -p "$(dirname "${envf}")"
  (
    umask 077
    if [[ -f "${envf}" ]] && grep -q "^${key}=" "${envf}"; then
      tmp="$(mktemp "${TMP_DIR:-${TMPDIR:-/tmp}}/hm-env.XXXXXX")"
      awk -F= -v k="${key}" -v v="${val}" 'BEGIN{OFS="="} $1==k {$0=k"="v; done=1} {print} END{if(!done) print k"="v}' "${envf}" > "${tmp}"
      cat "${tmp}" > "${envf}"
      rm -f "${tmp}"
    else
      printf '%s=%s\n' "${key}" "${val}" >> "${envf}"
    fi
    chmod 0600 "${envf}" 2>/dev/null || true
  )
}

hm_python_default_wsgi() {
  case "${1:-}" in
    flask) printf 'app:app' ;;
    fastapi) printf 'main:app' ;;
    django|*) printf 'config.wsgi' ;;
  esac
}

hm_python_write_placeholder() {
  local home="$1" fw="$2" user="$3" cur="${1}/current"
  mkdir -p "${cur}"
  case "${fw}" in
    flask)
      [[ -f "${cur}/app.py" ]] && return 0
      cat > "${cur}/app.py" <<'EOF'
def app(environ, start_response):
    start_response("200 OK", [("Content-Type", "text/plain")])
    return [b"hmtools flask placeholder — deploy your app\n"]
EOF
      ;;
    fastapi)
      [[ -f "${cur}/main.py" ]] && return 0
      cat > "${cur}/main.py" <<'EOF'
from fastapi import FastAPI
app = FastAPI()
@app.get("/")
def root():
    return {"ok": True, "msg": "hmtools fastapi placeholder"}
EOF
      ;;
    django)
      [[ -f "${cur}/config/wsgi.py" || -f "${cur}/manage.py" ]] && return 0
      mkdir -p "${cur}/config"
      cat > "${cur}/config/wsgi.py" <<'EOF'
def application(environ, start_response):
    start_response("200 OK", [("Content-Type", "text/plain")])
    return [b"hmtools django placeholder — deploy your project\n"]
EOF
      printf '' > "${cur}/config/__init__.py"
      ;;
    *) return 0 ;;
  esac
  chown -R "${user}:${user}" "${cur}" 2>/dev/null || true
  hm_info "Utworzono placeholder aplikacji w current/ (framework=${fw})."
}

hm_site_python_provision() {
  local domain="$1" ver="$2" source="$3" fw="$4" server="$5" wsgi="$6" celery="${7:-0}" port="${8:-}"
  local home user bind exec unit venv workers cpu state os key idx
  [[ "${domain}" =~ ^[A-Za-z0-9.-]+$ ]] || { hm_err "Zła domena."; return 1; }
  case "${source}" in
    uv|system|deadsnakes|pyenv) ;;
    *) hm_err "Źródło Pythona: uv, system, deadsnakes albo pyenv."; return 1 ;;
  esac
  case "${fw}" in
    django|flask|fastapi) ;;
    *) hm_err "Framework: django, flask albo fastapi."; return 1 ;;
  esac
  [[ -n "${wsgi}" ]] || wsgi="$(hm_python_default_wsgi "${fw}")"
  os="$(hm_python_os_id)"
  if [[ "${source}" == "deadsnakes" && "${os}" != "ubuntu" ]]; then
    hm_err "deadsnakes jest tylko dla Ubuntu."
    return 1
  fi
  if [[ "${source}" == "pyenv" ]]; then
    hm_warn "pyenv kompiluje CPython. To trwa i potrzebuje RAM oraz pakietów build."
  fi
  if [[ -z "${port}" ]]; then
    if declare -F hm_site_web_port_get >/dev/null 2>&1; then
      port="$(hm_site_web_port_get "${domain}" 2>/dev/null || true)"
    fi
    port="${port:-8000}"
  fi
  [[ "${port}" =~ ^[0-9]+$ ]] || { hm_err "Zły port aplikacji."; return 1; }
  if [[ -z "${ver}" ]]; then
    if command -v python3 >/dev/null 2>&1; then
      ver="$(python3 --version 2>&1 | awk '{print $2}' | cut -d. -f1,2)"
    fi
    if [[ -z "${ver}" ]]; then
      idx="${HM_PYTHON_INDEX:-}"
      if [[ -z "${idx}" && -n "${HMTOOLS_ROOT:-}" && -f "${HMTOOLS_ROOT}/share/python/versions.txt" ]]; then
        idx="${HMTOOLS_ROOT}/share/python/versions.txt"
      elif [[ -z "${idx}" && -n "${HMTOOLS_ROOT:-}" ]]; then
        idx="${HMTOOLS_ROOT}/scripts/fixtures/python/versions.txt"
      fi
      ver="$(hm_python_default "${idx}")" || { hm_err "Brak domyślnej wersji Pythona."; return 1; }
    fi
  fi
  user="${HM_SITE_USER:-www-data}"
  home="$(hm_site_python_home "${domain}")"
  venv="${home}/venv"
  mkdir -p "${home}/shared/static" "${home}/shared/media" "${home}/current"
  if [[ -n "${HM_PYTHON_UV_LOG:-}" ]]; then
    case "${source}" in
      uv) printf 'uv python install %s\nuv sync\n' "${ver}" >> "${HM_PYTHON_UV_LOG}" ;;
      system) printf 'python3-venv %s\n' "${ver}" >> "${HM_PYTHON_UV_LOG}" ;;
      *) printf '%s %s\n' "${source}" "${ver}" >> "${HM_PYTHON_UV_LOG}" ;;
    esac
  fi
  hm_python_create_venv "${venv}" "${ver}" "${source}" "${user}" || return 1
  hm_python_write_placeholder "${home}" "${fw}" "${user}"
  chown -R "${user}:${user}" "${home}/shared" "${home}/current" "${venv}" 2>/dev/null || true
  key="${HM_PYTHON_SECRET:-}"
  if [[ -z "${key}" ]]; then
    if declare -F hm_gen_password >/dev/null 2>&1; then
      key="$(hm_gen_password)"
    else
      key="generated-secret-key"
    fi
  fi
  hm_python_env_upsert "${home}/shared/.env" "SECRET_KEY" "${key}"
  hm_python_env_upsert "${home}/shared/.env" "ALLOWED_HOSTS" "${domain}"
  cpu="${HM_PYTHON_CPU:-1}"
  workers=$((cpu * 2 + 1))
  if [[ "${HM_PYTHON_BIND:-port}" == "sock" ]]; then
    bind="unix:/run/hm-app/${domain}.sock"
  else
    bind="127.0.0.1:${port}"
  fi
  case "${fw}:${server}" in
    fastapi:uvicorn)
      exec="${venv}/bin/uvicorn --workers ${workers} --host 127.0.0.1 --port ${port} ${wsgi:-app:app}"
      ;;
    fastapi:*)
      exec="${venv}/bin/gunicorn -k uvicorn.workers.UvicornWorker --workers ${workers} --bind ${bind} ${wsgi:-app:app}"
      ;;
    *)
      exec="${venv}/bin/gunicorn --workers ${workers} --bind ${bind} ${wsgi}"
      ;;
  esac
  unit="${HM_SYSTEMD_UNIT_DIR:-/etc/systemd/system}/$(hm_site_app_unit_name "${domain}")"
  hm_python_write_unit "${unit}" "${user}" "${home}" "${exec}" "${fw}"
  hm_python_note_unit "${unit}" "${domain}"
  if [[ "${fw}" == "django" ]]; then
    hm_python_write_vhost "${domain}" "${home}"
  fi
  if [[ -n "${HM_SITE_MANIFEST_DIR:-}" ]]; then
    mkdir -p "${HM_SITE_MANIFEST_DIR}"
    printf '{"runtime":{"type":"python","version":"%s"},"framework":"%s"}\n' "${ver}" "${fw}" > "${HM_SITE_MANIFEST_DIR}/${domain}.json"
  fi
  hm_python_systemctl enable --now "$(hm_site_app_unit_name "${domain}")"
  state="$(hm_python_systemctl is-active "$(hm_site_app_unit_name "${domain}")")"
  [[ "${state}" == "active" || "${HMTOOLS_TEST:-}" != "1" ]] || {
    hm_err "$(hm_site_app_unit_name "${domain}") nie jest active."
    return 1
  }
  if [[ "${celery}" == "1" ]]; then
    local cu bu
    cu="${HM_SYSTEMD_UNIT_DIR:-/etc/systemd/system}/hm-celery-${domain}.service"
    bu="${HM_SYSTEMD_UNIT_DIR:-/etc/systemd/system}/hm-celery-${domain}-beat.service"
    hm_python_write_unit "${cu}" "${user}" "${home}" "${venv}/bin/celery -A ${wsgi%%.*} worker --loglevel=INFO" "${fw}"
    hm_python_write_unit "${bu}" "${user}" "${home}" "${venv}/bin/celery -A ${wsgi%%.*} beat --loglevel=INFO" "${fw}"
    hm_python_note_unit "${cu}" "${domain}"
    hm_python_note_unit "${bu}" "${domain}"
    hm_python_systemctl enable --now "hm-celery-${domain}.service"
    hm_python_systemctl enable --now "hm-celery-${domain}-beat.service"
  fi
  HM_PYTHON_LAST_SECRET="${key}"
  HM_SITE_RUNTIME_VERSION="${ver}"
}
