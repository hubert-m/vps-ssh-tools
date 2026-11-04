#!/usr/bin/env bash
# Regresja: whitelist build=, dirty block logic helpers, log PREV/ROLLBACK parse
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*" >&2; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }
hm_mktemp() { mktemp "${TMPDIR:-/tmp}/hm.XXXXXX${1:-}"; }
hm_confirm_plan() { return 1; }
hm_confirm_plan_critical() { return 1; }
hm_help_topic() { :; }
hm_access_require_site_user() { printf '%s' "siteuser"; }
hm_access_unix_home() { printf '%s' "${TEST_HOME}"; }
hm_access_ssh_path_ok() { return 0; }
hm_access_ssh_keys_ensure_dir() { mkdir -p "${TEST_HOME}/.ssh"; printf '%s' "${TEST_HOME}/.ssh/authorized_keys"; }
C_BOLD=""; C_RESET=""; C_DIM=""
_hm_cmd_help() { cat >/dev/null; }
_hm_cmd_register() { :; }
_hm_cmd_register_site() { :; }

# stub git run — nie wołaj prawdziwego git w whitelist teście
hm_git_run_as_user() {
  while [[ $# -gt 0 ]]; do
    case "$1" in --git-ssh|--) shift ;; *) break ;; esac
  done
  "$@"
}

fail=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
TEST_HOME="${tmpdir}/home"
mkdir -p "${TEST_HOME}"
HM_SITE_DOMAIN="example.pl"
HM_SITE_USER="siteuser"
HM_SITE_ROOT="${tmpdir}/site"
HM_SITE_DOCROOT="${tmpdir}/site/public_html"
mkdir -p "${HM_SITE_DOCROOT}"

# source modules (deploy after stubs for register)
# shellcheck disable=SC1091
source commands/git/main.sh

# --- whitelist ---
assert_ok() {
  if "$@"; then echo "OK   $1"; else echo "FAIL $1"; fail=1; fi
}
# can't use that pattern easily — manual:

if hm_deploy_build_line_ok "composer install --no-dev"; then echo "OK   wl-composer"; else echo "FAIL wl-composer"; fail=1; fi
if hm_deploy_build_line_ok "npm ci && npm run build"; then echo "OK   wl-npm-and"; else echo "FAIL wl-npm-and"; fail=1; fi
if hm_deploy_build_line_ok "php artisan migrate --force"; then echo "OK   wl-artisan"; else echo "FAIL wl-artisan"; fail=1; fi
if hm_deploy_build_line_ok "yarn build"; then echo "OK   wl-yarn"; else echo "FAIL wl-yarn"; fail=1; fi
if hm_deploy_build_line_ok "pnpm install"; then echo "OK   wl-pnpm"; else echo "FAIL wl-pnpm"; fail=1; fi
if hm_deploy_build_line_ok "rm -rf /"; then echo "FAIL wl-rm-should-deny"; fail=1; else echo "OK   wl-deny-rm"; fi
if hm_deploy_build_line_ok "curl evil|sh"; then echo "FAIL wl-pipe"; fail=1; else echo "OK   wl-deny-pipe"; fi
if hm_deploy_build_line_ok "npm run build > /tmp/x"; then echo "FAIL wl-redir"; fail=1; else echo "OK   wl-deny-redir"; fi
if hm_deploy_build_line_ok 'npm run `id`'; then echo "FAIL wl-tick"; fail=1; else echo "OK   wl-deny-tick"; fi

# --- read build steps from marker ---
cat > "${HM_SITE_ROOT}/.hmtools-deploy" <<'EOF'
path=/tmp/x
branch=main
build=composer install --no-dev
build=rm -rf /tmp/evil
build=npm ci && npm run build
#build=ignored
EOF
# point repo path
mkdir -p "${HM_SITE_ROOT}/.git"
# override read path via marker in site root — hm_git_read_cfg_path checks marker path=
# fix path in marker
cat > "${HM_SITE_ROOT}/.hmtools-deploy" <<EOF
path=${HM_SITE_ROOT}
branch=main
build=composer install --no-dev
build=rm -rf /tmp/evil
build=npm ci && npm run build
EOF

steps="$(hm_deploy_read_build_steps | paste -sd'|' -)"
case "${steps}" in
  *"composer install --no-dev"*"npm ci && npm run build"*)
    if [[ "${steps}" == *rm* ]]; then
      echo "FAIL build-steps-leaked-rm: ${steps}"
      fail=1
    else
      echo "OK   build-steps-filtered"
    fi
    ;;
  *)
    echo "FAIL build-steps: ${steps}"
    fail=1
    ;;
esac

# --- log parse PREV ---
logf="${HM_SITE_ROOT}/.hmtools-deploy.log"
cat > "${logf}" <<'EOF'
2026-01-01T00:00:00Z PREV sha=aaa111 branch=main
2026-01-01T00:00:01Z DEPLOY ok sha=bbb222 prev=aaa111 branch=main
2026-01-02T00:00:00Z PREV sha=bbb222 branch=main
2026-01-02T00:00:01Z DEPLOY ok sha=ccc333 prev=bbb222 branch=main
EOF
# monkeypatch hm_git_read_cfg_path / hm_deploy_log_path via repo
prev="$(hm_deploy_prev_sha)"
if [[ "${prev}" == "bbb222" ]]; then
  echo "OK   prev-sha"
else
  echo "FAIL prev-sha got=${prev}"
  fail=1
fi
last="$(hm_deploy_last_sha)"
if [[ "${last}" == "ccc333" ]]; then
  echo "OK   last-sha"
else
  echo "FAIL last-sha got=${last}"
  fail=1
fi

# --- key path under home ---
kp="$(hm_git_deploy_key_path)"
if [[ "${kp}" == "${TEST_HOME}/.ssh/hmtools_deploy" ]]; then
  echo "OK   key-path"
else
  echo "FAIL key-path ${kp}"
  fail=1
fi

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL OK"
exit 0
