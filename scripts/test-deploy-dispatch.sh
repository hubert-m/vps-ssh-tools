#!/usr/bin/env bash
# deploy: podkomendy log/config/release/rollback nie idą w clone-deploy.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1 HMTOOLS_TEST_NO_TTY=1

# shellcheck disable=SC1091
source lib/common/ui.sh
hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_have_cmd() { return 1; }
hm_help_topic() { printf 'help %s\n' "$1"; }
hm_git_require_site() { return 0; }
hm_is_valid_domain() { [[ "${1:-}" =~ ^[a-zA-Z0-9._-]{1,253}$ ]]; }
_hm_cmd_help() { :; }
_hm_cmd_register() { :; }
_hm_cmd_register_site() { :; }

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
export HM_SITE_DOMAIN=my.test
export HM_SITE_HOME="${root}/home"
mkdir -p "${HM_SITE_HOME}/repo"
printf 'DEPLOY ok sha=abc\n' > "${HM_SITE_HOME}/repo/.hmtools-deploy.log"

hm_git_read_cfg_path() { printf '%s/repo' "${HM_SITE_HOME}"; }
# shellcheck disable=SC1091
source commands/git/deploy.sh

hit=""
hm_clone_deploy() { hit="clone:$*"; return 0; }
hm_deploy_config() { hit="config"; return 0; }
hm_deploy_release_apply() { hit="release"; return 0; }
hm_deploy_rollback() { hit="rollback-git"; return 0; }
hm_deploy_release_rollback() { hit="rollback-rel"; return 0; }
hm_deploy_run() { hit="run"; return 0; }
hm_deploy_home() { printf '%s' "${HM_SITE_HOME}"; }
hm_deploy_log_path() { printf '%s/repo/.hmtools-deploy.log' "${HM_SITE_HOME}"; }

hit=""
cmd_deploy log >/dev/null
[[ "${hit}" != clone:* ]] && ok log-not-clone || bad log-not-clone
out="$(cmd_deploy log)"
printf '%s\n' "${out}" | grep -q 'DEPLOY ok' && ok log-tail || bad log-tail

hit=""
cmd_deploy config >/dev/null
[[ "${hit}" == "config" ]] && ok config || bad config

hit=""
cmd_deploy release my.test >/dev/null
[[ "${hit}" == "release" ]] && ok release || bad release

hit=""
cmd_deploy rollback >/dev/null
[[ "${hit}" == "rollback-git" || "${hit}" == "rollback-rel" ]] && ok rollback || bad rollback

hit=""
cmd_deploy prod.example.pl --yes >/dev/null
[[ "${hit}" == "clone:prod.example.pl --yes" ]] && ok clone-domain || bad clone-domain

hit=""
cmd_deploy clone staging.example --yes >/dev/null
[[ "${hit}" == "clone:staging.example --yes" ]] && ok clone-explicit || bad clone-explicit

[[ "${fail}" -eq 0 ]] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
