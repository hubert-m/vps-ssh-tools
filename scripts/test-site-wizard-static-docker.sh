#!/usr/bin/env bash
# W09: static/SPA vhost + docker compose (127.0.0.1) + rollback compose-down.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1 HMTOOLS_TEST_NO_TTY=1
export HM_SITE_WEB_VALIDATE=ok
export FORCE_DOCKER=yes DOCKER=yes DOCKER_COMPOSE=plugin

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_have_cmd() {
  case "$1" in
    nginx|apache2|apachectl|docker) return 0 ;;
    *) command -v "$1" >/dev/null 2>&1 ;;
  esac
}
hm_is_valid_domain() { [[ "$1" == *.* ]]; }
hm_confirm_plan() { return 0; }
hm_print_secret() { :; }
hm_gen_password() { printf 'x'; }
hm_pkg_install() { :; }

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
export HM_SITE_HOME_BASE="${root}/homes"
export HM_SITE_PORT_FILE="${root}/ports.json"
export HM_SITE_SS_FILE="${root}/ss.txt"
export HM_SITE_WEB_LOG="${root}/web.log"
export HM_SITE_WEB_JOURNAL="${root}/journal.txt"
export HM_SITE_WEB_CONF_DIR="${root}/nginx/sites-available"
export HM_SITE_JOURNAL_DIR="${root}/tx-journal"
export HM_SITE_STATE_DIR="${root}/site-state"
export HM_SITE_LOCK_DIR="${root}/locks"
export HM_SITE_MANIFEST_DIR="${root}/manifest"
export HM_APP_PORT_RANGE=3001-3010
export HM_SITE_USER=app
export HM_SITE_DOCKER_LOG="${root}/docker.log"
export PATH="${root}/bin:${PATH}"
export DOCKER_BIN="${root}/bin/docker"
mkdir -p "${HM_SITE_HOME_BASE}" "${HM_SITE_WEB_CONF_DIR}" "${root}/bin" "${root}/nginx/sites-enabled" \
  "${HM_SITE_JOURNAL_DIR}" "${HM_SITE_STATE_DIR}" "${HM_SITE_LOCK_DIR}" "${HM_SITE_MANIFEST_DIR}"
: > "${HM_SITE_WEB_LOG}"
: > "${HM_SITE_DOCKER_LOG}"
printf 'LISTEN 0.0.0.0:2999\n' > "${HM_SITE_SS_FILE}"
printf 'ID=ubuntu\nVERSION_ID="24.04"\n' > "${root}/os-release"
export HM_SITE_OS_FILE="${root}/os-release"
export ALLOW_UNSUPPORTED_OS=1

cat > "${root}/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HM_SITE_DOCKER_LOG}"
case "${1:-}" in
  info) exit 0 ;;
  compose)
    shift || true
    if [[ "${1:-}" == "version" ]]; then
      echo "Docker Compose version v2.0.0"
      exit 0
    fi
    exit 0
    ;;
esac
exit 0
EOF
chmod +x "${root}/bin/docker"

# shellcheck disable=SC1091
source lib/site/env.sh
# shellcheck disable=SC1091
source lib/site/base.sh
# shellcheck disable=SC1091
source lib/site/tx.sh
# shellcheck disable=SC1091
source lib/site/web.sh
# shellcheck disable=SC1091
source lib/site/db.sh
# shellcheck disable=SC1091
source lib/site/docker.sh
# shellcheck disable=SC1091
source lib/site/lifecycle.sh
# shellcheck disable=SC1091
source commands/site-create/wizard-db.sh

hm_os_nginx_sites_enabled() { printf '%s/nginx/sites-enabled' "${root}"; }
hm_site_manifest_dir() { printf '%s' "${HM_SITE_MANIFEST_DIR}"; }
hm_site_manifest_path() { printf '%s/%s.json' "$(hm_site_manifest_dir)" "$1"; }
hm_site_manifest_write() { :; }
hm_tx_lock() { return 0; }
hm_tx_unlock() { return 0; }
hm_is_valid_unix_user() { [[ "$1" =~ ^[a-z_][a-z0-9_-]*$ ]]; }
hm_site_base_user_exists() { return 1; }
hm_site_base_create_user() { return 0; }
hm_site_base_own() { :; }
useradd() { :; }
groupadd() { :; }
id() { return 1; }
getent() { return 1; }

# --- SPA: fallback index.html w vhostu ---
out="${root}/spa.out"
cmd_site_new spa.example.pl --runtime static --spa --db none --webserver nginx --user spaapp --yes >"${out}" 2>&1 || {
  bad "site-new-spa"
  cat "${out}" >&2
}
sconf="${HM_SITE_WEB_CONF_DIR}/spa.example.pl.conf"
if [[ -f "${sconf}" ]] && grep -q 'try_files \$uri \$uri/ /index.html' "${sconf}" \
  && [[ -f "${HM_SITE_HOME_BASE}/spa.example.pl/public_html/index.html" ]]; then
  ok "spa-fallback"
else
  bad "spa-fallback"
  cat "${out}" >&2 || true
  cat "${sconf}" 2>/dev/null || true
fi

# --- Docker: tylko 127.0.0.1 + compose up ---
: > "${HM_SITE_DOCKER_LOG}"
out="${root}/docker.out"
cmd_site_new grafana.example.pl --runtime docker --image grafana/grafana:11 \
  --container-port 3000 --db none --webserver nginx --user grafapp --yes >"${out}" 2>&1 || {
  bad "site-new-docker"
  cat "${out}" >&2
}
compose="${HM_SITE_HOME_BASE}/grafana.example.pl/compose.yaml"
dconf="${HM_SITE_WEB_CONF_DIR}/grafana.example.pl.conf"
jdir="${HM_SITE_JOURNAL_DIR}/grafana.example.pl"
jfile="$(ls -1 "${jdir}"/*.log 2>/dev/null | tail -1 || true)"
if [[ -f "${compose}" ]] && grep -q '127.0.0.1:' "${compose}" && ! grep -qi '0.0.0.0' "${compose}" \
  && grep -q 'grafana/grafana:11' "${compose}" \
  && grep -q 'compose -p hm-grafana-example-pl' "${HM_SITE_DOCKER_LOG}" \
  && [[ -f "${dconf}" ]] && grep -q '127.0.0.1:' "${dconf}" \
  && [[ -n "${jfile}" ]] && grep -F -q $'undo=compose-down\thm-grafana-example-pl\t' "${jfile}"; then
  ok "docker-loopback"
else
  bad "docker-loopback"
  cat "${out}" >&2 || true
  cat "${compose}" 2>/dev/null || true
  cat "${HM_SITE_DOCKER_LOG}" >&2 || true
  cat "${jfile:-/dev/null}" >&2 || true
fi

# Walidacja odmawia 0.0.0.0
badc="${root}/bad-compose.yaml"
printf '%s\n' 'services:' '  app:' '    image: x' '    ports:' '      - "0.0.0.0:80:80"' > "${badc}"
if hm_site_docker_validate_compose "${badc}" >/dev/null 2>&1; then
  bad "refuse-public-port"
else
  ok "refuse-public-port"
fi

# image YAML injection / port / out
hm_site_docker_image_ok 'nginx:1' && ok "image-ok" || bad "image-ok"
if hm_site_docker_image_ok $'nginx:1\n    privileged: true'; then
  bad "image-inject"
else
  ok "image-inject"
fi
hm_site_docker_port_ok 3000 && ok "port-ok" || bad "port-ok"
hm_site_docker_port_ok 99999 && bad "port-hi" || ok "port-hi"
hm_site_build_out_ok dist && ok "out-ok" || bad "out-ok"
hm_site_build_out_ok '../../etc' && bad "out-traversal" || ok "out-traversal"

injc="${root}/inj-compose.yaml"
printf '%s\n' 'services:' '  app:' '    image: x' '    privileged: true' '    ports:' '      - "127.0.0.1:80:80"' > "${injc}"
if hm_site_docker_validate_compose "${injc}" >/dev/null 2>&1; then
  bad "refuse-privileged"
else
  ok "refuse-privileged"
fi

if hm_site_docker_provision evil.test $'nginx:1\n    network_mode: host\n    privileged: true\n    ports: ["8080:80"]' 3000 auto 1 >/dev/null 2>&1; then
  bad "provision-inject"
else
  ok "provision-inject"
fi
if hm_site_docker_provision evil2.test nginx:alpine 99999 auto 1 >/dev/null 2>&1; then
  bad "provision-bad-port"
else
  ok "provision-bad-port"
fi

# static build: --out bad + runuser log
export HM_SITE_BUILD_LOG="${root}/build.log"
: > "${HM_SITE_BUILD_LOG}"
if cmd_site_new badout.example.pl --runtime static --build 'npm run build' --out '../../etc' --db none --webserver nginx --user spaapp --yes >/dev/null 2>&1; then
  bad "out-site-new"
else
  ok "out-site-new"
fi
cmd_site_new build.example.pl --runtime static --build 'npm run build' --out dist --db none --webserver nginx --user spaapp --yes >/dev/null 2>&1 \
  && grep -q 'runuser -u spaapp' "${HM_SITE_BUILD_LOG}" && ok "build-runuser" || bad "build-runuser"

# --- Rollback: compose-down (undo dispatch) ---
: > "${HM_SITE_DOCKER_LOG}"
mkdir -p "${root}/homes/rb.example.pl"
printf 'services: {}\n' > "${root}/homes/rb.example.pl/compose.yaml"
hm_tx_undo_dispatch "$(printf 'compose-down\thm-rb-example-pl\t%s\t%s' \
  "${root}/homes/rb.example.pl" "${root}/homes/rb.example.pl/compose.yaml")" || true
if grep -q 'compose -p hm-rb-example-pl down' "${HM_SITE_DOCKER_LOG}"; then
  ok "rollback-compose-down"
else
  bad "rollback-compose-down"
  cat "${HM_SITE_DOCKER_LOG}" >&2 || true
fi

if [[ "${fail}" -eq 0 ]]; then
  echo "ALL PASSED"
else
  echo "FAILED" >&2
  exit 1
fi
