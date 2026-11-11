#!/usr/bin/env bash
# docker compose update/down/logs, scan, audit, updates — mock CLI.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_have_cmd() { return 1; }
hm_run() { "$@"; }
hm_confirm_plan() { return 0; }
hm_confirm_plan_critical() { return 0; }
hm_help_topic() { :; }
hm_detect_docker() { :; }
_hm_cmd_help() { cat >/dev/null; }
_hm_cmd_register() { :; }
_hm_cmd_register_site() { :; }

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
export HM_DOCKER_LOG="${root}/docker.log"
export HM_DOCKER_STACK_DIR="${root}/stack"
export HM_DOCKER_AUDIT="${root}/audit.txt"
export HM_DOCKER_UPDATES="${root}/updates.txt"
export FORCE_DOCKER=yes
export DOCKER=yes
export DOCKER_COMPOSE=plugin
mkdir -p "${root}/stack" "${root}/bin"
printf 'PASSWORD=SECRET-DOCKER\n' > "${root}/stack/.env"
printf 'nginx sha256:aaa\n' > "${root}/stack/images.txt"
printf 'web no no yes 0.0.0.0:80 nginx:latest\ndb unless-stopped yes no 127.0.0.1:3306 mariadb:10.11\n' > "${root}/audit.txt"
printf 'nginx:1.25 nginx:1.26\n' > "${root}/updates.txt"

cat > "${root}/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HM_DOCKER_LOG}"
if [[ "$*" == *logs* ]]; then
  printf 'PASSWORD=SECRET-DOCKER\nok line\n'
fi
exit 0
EOF
cat > "${root}/bin/trivy" <<'EOF'
#!/usr/bin/env bash
printf 'nginx CRITICAL 2 HIGH 1\n'
printf 'PASSWORD=SECRET-DOCKER\n'
exit 0
EOF
chmod +x "${root}/bin/docker" "${root}/bin/trivy" || true
export DOCKER_BIN="${root}/bin/docker"
export HM_TRIVY_BIN="${root}/bin/trivy"

# shellcheck disable=SC1091
source commands/docker/main.sh

export HM_DOCKER_HEALTH=fail
if cmd_docker compose update app >"${root}/update.out" 2>"${root}/update.err"; then
  bad update-rc
else
  ok update-rc
fi
grep -q 'sha256:aaa' "${root}/stack/.hmtools-digests" && ok update-digest || bad update-digest
grep -q 'pull nginx@sha256:aaa' "${HM_DOCKER_LOG}" && ok update-rollback || bad update-rollback
grep -q 'SECRET-DOCKER' "${root}/update.out" "${HM_DOCKER_LOG}" && bad update-secret || ok update-secret

: > "${HM_DOCKER_LOG}"
export HM_DOCKER_HEALTH=ok
cmd_docker compose update app >"${root}/ok.out"
grep -q 'pull nginx@sha256:aaa' "${HM_DOCKER_LOG}" && bad update-ok-rollback || ok update-ok
grep -q 'compose pull' "${HM_DOCKER_LOG}" && ok update-pull || bad update-pull

logs="$(cmd_docker compose logs app 20)"
printf '%s\n' "${logs}" | grep -qx 'ok line' && ok logs-line || bad logs-line
printf '%s\n' "${logs}" | grep -q 'SECRET-DOCKER' && bad logs-secret || ok logs-secret

cmd_docker compose down app >/dev/null
grep -q 'compose down' "${HM_DOCKER_LOG}" && ok down || bad down

scan="$(cmd_docker scan nginx:1.25)"
printf '%s\n' "${scan}" | grep -q 'CRITICAL 2' && ok scan || bad scan
printf '%s\n' "${scan}" | grep -q 'SECRET-DOCKER' && bad scan-secret || ok scan-secret

audit="$(cmd_docker audit)"
printf '%s\n' "${audit}" | grep -q $'privileged\tweb' && ok audit-priv || bad audit-priv
printf '%s\n' "${audit}" | grep -q $'public-port\tweb\t0.0.0.0:80' && ok audit-port || bad audit-port
printf '%s\n' "${audit}" | grep -q $'latest\tweb\tnginx:latest' && ok audit-latest || bad audit-latest
printf '%s\n' "${audit}" | grep -q $'\tdb\b' && bad audit-db || ok audit-db

: > "${HM_DOCKER_LOG}"
upd="$(cmd_docker updates)"
printf '%s\n' "${upd}" | grep -qx 'nginx:1.25 -> nginx:1.26' && ok updates || bad updates
grep -q pull "${HM_DOCKER_LOG}" && bad updates-pull || ok updates-pull

[[ "${fail}" -eq 0 ]] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
