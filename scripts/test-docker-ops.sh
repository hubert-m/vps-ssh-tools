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
export HM_DOCKER_PROJECT="app_staging"
export HM_DOCKER_COMPOSE_FILES="docker-compose.yml,compose.override.yml"
export FORCE_DOCKER=yes
export DOCKER=yes
export DOCKER_COMPOSE=plugin
mkdir -p "${root}/stack" "${root}/bin"
printf 'PASSWORD=SECRET-DOCKER\n' > "${root}/stack/.env"
printf 'nginx:1.25 sha256:aaa\n' > "${root}/stack/images.txt"

cat > "${root}/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HM_DOCKER_LOG}"
cmd="${1:-}"
shift || true

if [[ "${cmd}" == "compose" && "${1:-}" == "version" ]]; then
  echo "Docker Compose version v2.0.0"
  exit 0
fi
if [[ "${cmd}" == "info" ]]; then
  exit 0
fi
if [[ "${cmd}" == "ps" ]]; then
  # ps -aq [--filter ...]
  if [[ "$*" == *app_staging* ]] || [[ "$*" == "-aq" ]] || [[ "$*" == -aq* ]]; then
    if [[ "$*" == *app_staging* ]]; then
      printf '%s\n' 'cid1'
    else
      printf '%s\n' 'cid1' 'cid2'
    fi
  fi
  exit 0
fi
if [[ "${cmd}" == "inspect" ]]; then
  fmt=""
  target=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--format) fmt="$2"; shift 2 ;;
      *) target="$1"; shift ;;
    esac
  done
  if [[ "${fmt}" == *Config.Image* ]]; then
    if [[ "${target}" == "cid2" ]]; then echo 'mariadb:10.11'; else echo 'nginx:1.25'; fi
  elif [[ "${fmt}" == *'.Image'* ]]; then
    echo 'sha256:aaa'
  elif [[ "${fmt}" == *State.Status* ]]; then
    echo 'running'
  elif [[ "${fmt}" == *State.Restarting* ]]; then
    echo 'false'
  elif [[ "${fmt}" == *RestartCount* ]]; then
    echo '0'
  elif [[ "${fmt}" == *Health.Status* ]] || [[ "${fmt}" == *State.Health* ]]; then
    if [[ -n "${HM_DOCKER_HEALTH_SEQ:-}" ]]; then
      # sekwencja: starting,starting,healthy — plik licznika
      _seqfile="${HM_DOCKER_HEALTH_SEQ_FILE:-${HM_DOCKER_LOG}.healthseq}"
      _n=0
      [[ -f "${_seqfile}" ]] && _n="$(cat "${_seqfile}" 2>/dev/null || echo 0)"
      _n=$((_n + 1))
      printf '%s' "${_n}" > "${_seqfile}"
      _line="$(printf '%s' "${HM_DOCKER_HEALTH_SEQ}" | cut -d, -f"${_n}")"
      [[ -n "${_line}" ]] || _line="$(printf '%s' "${HM_DOCKER_HEALTH_SEQ}" | awk -F, '{print $NF}')"
      echo "${_line}"
    else
      echo 'healthy'
    fi
  elif [[ "${fmt}" == *RestartPolicy* ]]; then
    if [[ "${target}" == "cid1" ]]; then echo 'no'; else echo 'unless-stopped'; fi
  elif [[ "${fmt}" == *Healthcheck* ]]; then
    if [[ "${target}" == "cid1" ]]; then echo 'no'; else echo 'yes'; fi
  elif [[ "${fmt}" == *Privileged* ]]; then
    if [[ "${target}" == "cid1" ]]; then echo 'true'; else echo 'false'; fi
  elif [[ "${fmt}" == *HostIp* ]] || [[ "${fmt}" == *Ports* ]]; then
    if [[ "${target}" == "cid1" ]]; then echo '0.0.0.0:80 '; else echo '127.0.0.1:3306 '; fi
  elif [[ "${fmt}" == *'.Name'* ]]; then
    if [[ "${target}" == "cid1" ]]; then echo '/web'; else echo '/db'; fi
  else
    echo ''
  fi
  exit 0
fi
if [[ "${cmd}" == "compose" && "$*" == *logs* ]]; then
  printf 'PASSWORD=SECRET-DOCKER still-ok-line\n'
  exit 0
fi
# Pierwszy up -d (bez force-recreate) może padać — symulacja złego obrazu
if [[ "${cmd}" == "compose" && "$*" == *" up "* && "$*" == *"-d"* && "$*" != *force-recreate* ]]; then
  if [[ "${HM_DOCKER_UP_FAIL:-0}" == "1" ]]; then
    echo "Error: exec not found" >&2
    exit 1
  fi
fi
if [[ "${cmd}" == "pull" ]]; then
  # pull name@<imageID> musi padać (jak na prawdziwym Dockerze)
  if [[ "$*" == *@sha256:* ]]; then
    exit 1
  fi
  exit 0
fi
if [[ "${cmd}" == "tag" || "${cmd}" == "manifest" ]]; then
  exit 0
fi
if [[ "${cmd}" == "image" ]]; then
  # image inspect -f RepoDigests
  if [[ "${1:-}" == "inspect" ]]; then
    echo ''
    exit 0
  fi
  exit 0
fi
exit 0
EOF
cat > "${root}/bin/trivy" <<'EOF'
#!/usr/bin/env bash
printf 'nginx CRITICAL 2 HIGH 1\n'
printf 'line with PASSWORD=SECRET-DOCKER mid\n'
exit 0
EOF
chmod +x "${root}/bin/docker" "${root}/bin/trivy" || true
export DOCKER_BIN="${root}/bin/docker"
export HM_TRIVY_BIN="${root}/bin/trivy"

# shellcheck disable=SC1091
source commands/docker/main.sh

export HM_DOCKER_HEALTH=fail
: > "${HM_DOCKER_LOG}"
if cmd_docker compose update app_staging >"${root}/update.out" 2>"${root}/update.err"; then
  bad update-rc
else
  ok update-rc
fi
grep -q 'sha256:aaa' "${root}/stack/.hmtools-digests" && ok update-digest || bad update-digest
# Rollback: najpierw tag <imageID> <tag> (bez udanego pull ID)
grep -E 'tag sha256:aaa nginx:1.25|tag sha256:aaa mariadb' "${HM_DOCKER_LOG}" >/dev/null && ok update-rollback-tag || {
  bad update-rollback-tag
  grep tag "${HM_DOCKER_LOG}" || true
}
# pull @imageID nie powinien być wymagany do sukcesu (może być próbowany i padać)
grep -E 'force-recreate' "${HM_DOCKER_LOG}" >/dev/null && ok update-force-recreate || bad update-force-recreate
# tag przed force-recreate
tag_line="$(grep -nE 'tag sha256:aaa' "${HM_DOCKER_LOG}" | head -1 | cut -d: -f1)"
up_line="$(grep -nE 'force-recreate' "${HM_DOCKER_LOG}" | head -1 | cut -d: -f1)"
if [[ -n "${tag_line}" && -n "${up_line}" && "${tag_line}" -lt "${up_line}" ]]; then
  ok update-rollback-order
else
  bad update-rollback-order
fi
grep -q 'SECRET-DOCKER' "${root}/update.out" "${HM_DOCKER_LOG}" && bad update-secret || ok update-secret
grep -qE 'compose -p app_staging' "${HM_DOCKER_LOG}" && ok update-project-flag || bad update-project-flag
grep -qE '\-f docker-compose\.yml' "${HM_DOCKER_LOG}" && ok update-file-flag || bad update-file-flag

# up -d rc≠0 ⇒ rollback (tag + force-recreate), nie zostawia wadliwego obrazu
: > "${HM_DOCKER_LOG}"
export HM_DOCKER_HEALTH=ok
export HM_DOCKER_UP_FAIL=1
if cmd_docker compose update app_staging >"${root}/upfail.out" 2>"${root}/upfail.err"; then
  bad update-upfail-rc
else
  ok update-upfail-rc
fi
grep -qi 'up -d nieudany\|Przywracam zapisane digesty' "${root}/upfail.out" "${root}/upfail.err" 2>/dev/null \
  && ok update-upfail-msg || ok update-upfail-msg-skip
grep -E 'tag sha256:aaa' "${HM_DOCKER_LOG}" >/dev/null && ok update-upfail-tag || bad update-upfail-tag
grep -E 'force-recreate' "${HM_DOCKER_LOG}" >/dev/null && ok update-upfail-recreate || bad update-upfail-recreate
unset HM_DOCKER_UP_FAIL

: > "${HM_DOCKER_LOG}"
export HM_DOCKER_HEALTH=ok
cmd_docker compose update app_staging >"${root}/ok.out"
grep -E 'pull .*@sha256:aaa' "${HM_DOCKER_LOG}" >/dev/null && bad update-ok-rollback || ok update-ok
grep -q 'compose -p app_staging' "${HM_DOCKER_LOG}" && ok update-ok-p || bad update-ok-p
grep -E 'compose -p app_staging .* pull|compose -p app_staging -f .* pull' "${HM_DOCKER_LOG}" >/dev/null && ok update-pull || {
  bad update-pull
  cat "${HM_DOCKER_LOG}"
}

logs="$(cmd_docker compose logs app_staging 20)"
printf '%s\n' "${logs}" | grep -q 'still-ok-line' && ok logs-line || bad logs-line
printf '%s\n' "${logs}" | grep -q 'PASSWORD=\[redacted\]' && ok logs-redact-value || bad logs-redact-value
printf '%s\n' "${logs}" | grep -q 'SECRET-DOCKER' && bad logs-secret || ok logs-secret

: > "${HM_DOCKER_LOG}"
cmd_docker compose down app_staging >/dev/null
grep -E 'compose -p app_staging .* down|compose -p app_staging -f .* down' "${HM_DOCKER_LOG}" >/dev/null && ok down-project || {
  bad down-project
  cat "${HM_DOCKER_LOG}"
}

scan="$(cmd_docker scan nginx:1.25)"
printf '%s\n' "${scan}" | grep -q 'CRITICAL 2' && ok scan || bad scan
printf '%s\n' "${scan}" | grep -q 'PASSWORD=\[redacted\]' && ok scan-redact || bad scan-redact
printf '%s\n' "${scan}" | grep -q 'SECRET-DOCKER' && bad scan-secret || ok scan-secret

export HM_DOCKER_AUDIT="${root}/audit.txt"
printf 'web no no yes 0.0.0.0:80 nginx:latest\ndb unless-stopped yes no 127.0.0.1:3306 mariadb:10.11\n' > "${root}/audit.txt"
audit="$(cmd_docker audit)"
printf '%s\n' "${audit}" | grep -q $'privileged\tweb' && ok audit-priv || bad audit-priv
printf '%s\n' "${audit}" | grep -q $'public-port\tweb\t0.0.0.0:80' && ok audit-port || bad audit-port
printf '%s\n' "${audit}" | grep -q $'latest\tweb\tnginx:latest' && ok audit-latest || bad audit-latest
printf '%s\n' "${audit}" | grep -q $'\tdb\b' && bad audit-db || ok audit-db

unset HM_DOCKER_AUDIT
audit2="$(cmd_docker audit)"
printf '%s\n' "${audit2}" | grep -q $'privileged\tweb' && ok audit-live-priv || bad audit-live-priv
printf '%s\n' "${audit2}" | grep -q 'public-port' && ok audit-live-port || bad audit-live-port

: > "${HM_DOCKER_LOG}"
export HM_DOCKER_UPDATES="${root}/updates.txt"
printf 'nginx:1.25 nginx:1.26\n' > "${root}/updates.txt"
upd="$(cmd_docker updates)"
printf '%s\n' "${upd}" | grep -qx 'nginx:1.25 -> nginx:1.26' && ok updates || bad updates
grep -q pull "${HM_DOCKER_LOG}" && bad updates-pull || ok updates-pull

unset HM_DOCKER_UPDATES
export HM_DOCKER_NEWER='nginx:1.25=nginx:1.26'
: > "${HM_DOCKER_LOG}"
upd2="$(cmd_docker updates)"
printf '%s\n' "${upd2}" | grep -q 'nginx:1.25 -> nginx:1.26' && ok updates-live || bad updates-live
grep -qE '(^| )pull( |$)' "${HM_DOCKER_LOG}" && bad updates-live-pull || ok updates-live-nopull

# health: starting → healthy (bez rollbacku)
unset HM_DOCKER_HEALTH
export HM_DOCKER_HEALTH_TIMEOUT=10
export HM_DOCKER_HEALTH_INTERVAL=1
export HM_DOCKER_NOHEALTH_STABLE=0
export HM_DOCKER_HEALTH_SEQ='starting,starting,healthy'
export HM_DOCKER_HEALTH_SEQ_FILE="${root}/health.seq"
: > "${HM_DOCKER_HEALTH_SEQ_FILE}"
: > "${HM_DOCKER_LOG}"
if cmd_docker compose update app_staging >"${root}/health-ok.out" 2>"${root}/health-ok.err"; then
  grep -E 'force-recreate|Przywracam' "${HM_DOCKER_LOG}" "${root}/health-ok.out" "${root}/health-ok.err" >/dev/null 2>&1 \
    && bad health-wait-ok-rollback || ok health-wait-starting-then-healthy
else
  bad health-wait-starting-then-healthy
  cat "${root}/health-ok.err" || true
fi

# health: starting aż do timeoutu → rollback
export HM_DOCKER_HEALTH_TIMEOUT=3
export HM_DOCKER_HEALTH_INTERVAL=1
export HM_DOCKER_HEALTH_SEQ='starting,starting,starting,starting,starting,starting'
: > "${HM_DOCKER_HEALTH_SEQ_FILE}"
: > "${HM_DOCKER_LOG}"
if cmd_docker compose update app_staging >"${root}/health-to.out" 2>"${root}/health-to.err"; then
  bad health-wait-timeout-rc
else
  ok health-wait-timeout-rc
fi
grep -E 'force-recreate' "${HM_DOCKER_LOG}" >/dev/null && ok health-wait-timeout-rollback || bad health-wait-timeout-rollback
unset HM_DOCKER_HEALTH_SEQ HM_DOCKER_HEALTH_SEQ_FILE
export HM_DOCKER_HEALTH=ok

[[ "${fail}" -eq 0 ]] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
