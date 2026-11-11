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
  local domain="$1" home="$2" path
  path="${HM_SITE_VHOST_DIR:-/etc/nginx/sites-available}/${domain}.conf"
  mkdir -p "$(dirname "${path}")"
  cat > "${path}" <<EOF
location /static/ {
    alias ${home}/shared/static/;
}
location /media/ {
    alias ${home}/shared/media/;
}
EOF
}

hm_site_python_provision() {
  local domain="$1" ver="$2" source="$3" fw="$4" server="$5" wsgi="$6" celery="${7:-0}" port="${8:-8000}"
  local home user bind exec unit venv workers cpu state os key
  [[ "${domain}" =~ ^[A-Za-z0-9.-]+$ ]] || { hm_err "Zła domena."; return 1; }
  case "${source}" in
    uv|system|deadsnakes|pyenv) ;;
    *) hm_err "Źródło Pythona: uv, system, deadsnakes albo pyenv."; return 1 ;;
  esac
  case "${fw}" in
    django|flask|fastapi) ;;
    *) hm_err "Framework: django, flask albo fastapi."; return 1 ;;
  esac
  os="$(hm_python_os_id)"
  if [[ "${source}" == "deadsnakes" && "${os}" != "ubuntu" ]]; then
    hm_err "deadsnakes jest tylko dla Ubuntu."
    return 1
  fi
  if [[ "${source}" == "pyenv" ]]; then
    hm_warn "pyenv kompiluje CPython. To trwa i potrzebuje RAM oraz pakietów build."
  fi
  [[ "${port}" =~ ^[0-9]+$ ]] || { hm_err "Zły port aplikacji."; return 1; }
  if [[ -z "${ver}" ]]; then
    ver="$(hm_python_default "${HM_PYTHON_INDEX:-scripts/fixtures/python/versions.txt}")" || return 1
  fi
  user="${HM_SITE_USER:-www-data}"
  home="$(hm_site_python_home "${domain}")"
  venv="${home}/venv"
  mkdir -p "${home}/shared/static" "${home}/shared/media" "${home}/current" "${venv}/bin"
  if [[ -n "${HM_PYTHON_UV_LOG:-}" ]]; then
    case "${source}" in
      uv) printf 'uv python install %s\nuv sync\n' "${ver}" >> "${HM_PYTHON_UV_LOG}" ;;
      system) printf 'python3-venv %s\n' "${ver}" >> "${HM_PYTHON_UV_LOG}" ;;
      *) printf '%s %s\n' "${source}" "${ver}" >> "${HM_PYTHON_UV_LOG}" ;;
    esac
  fi
  key="${HM_PYTHON_SECRET:-}"
  if [[ -z "${key}" ]]; then
    if declare -F hm_gen_password >/dev/null 2>&1; then
      key="$(hm_gen_password)"
    else
      key="generated-secret-key"
    fi
  fi
  mkdir -p "${home}/shared"
  umask 077
  printf 'SECRET_KEY=%s\nALLOWED_HOSTS=%s\n' "${key}" "${domain}" >> "${home}/shared/.env"
  chmod 0600 "${home}/shared/.env" 2>/dev/null || true
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
  unit="${HM_SYSTEMD_UNIT_DIR:-/etc/systemd/system}/hm-app-${domain}.service"
  hm_python_write_unit "${unit}" "${user}" "${home}" "${exec}" "${fw}"
  if [[ "${fw}" == "django" ]]; then
    hm_python_write_vhost "${domain}" "${home}"
  fi
  if [[ -n "${HM_SITE_MANIFEST_DIR:-}" ]]; then
    mkdir -p "${HM_SITE_MANIFEST_DIR}"
    printf '{"runtime":{"type":"python","version":"%s"},"framework":"%s"}\n' "${ver}" "${fw}" > "${HM_SITE_MANIFEST_DIR}/${domain}.json"
  fi
  hm_python_systemctl enable --now "hm-app-${domain}.service"
  state="$(hm_python_systemctl is-active "hm-app-${domain}.service")"
  [[ "${state}" == "active" || "${HMTOOLS_TEST:-}" != "1" ]] || {
    hm_err "hm-app-${domain} nie jest active."
    return 1
  }
  if [[ "${celery}" == "1" ]]; then
    hm_python_write_unit "${HM_SYSTEMD_UNIT_DIR:-/etc/systemd/system}/hm-celery-${domain}.service" "${user}" "${home}" "${venv}/bin/celery -A ${wsgi%%.*} worker --loglevel=INFO" "${fw}"
    hm_python_write_unit "${HM_SYSTEMD_UNIT_DIR:-/etc/systemd/system}/hm-celery-${domain}-beat.service" "${user}" "${home}" "${venv}/bin/celery -A ${wsgi%%.*} beat --loglevel=INFO" "${fw}"
    hm_python_systemctl enable --now "hm-celery-${domain}.service"
    hm_python_systemctl enable --now "hm-celery-${domain}-beat.service"
  fi
  HM_PYTHON_LAST_SECRET="${key}"
}
