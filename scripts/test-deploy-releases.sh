#!/usr/bin/env bash
# Atomowe current, health/build bez przełączenia, webhook 403.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_have_cmd() { return 1; }
_hm_cmd_help() { :; }
_hm_cmd_register() { :; }
_hm_cmd_register_site() { :; }

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
export HM_DEPLOY_HOME="${root}/app"
export HM_SITE_ROOT="${HM_DEPLOY_HOME}"
mkdir -p "${HM_DEPLOY_HOME}/releases/20260101010101" "${HM_DEPLOY_HOME}/releases/20260101010102"
printf 'a\n' > "${HM_DEPLOY_HOME}/releases/20260101010101/index.html"
printf 'b\n' > "${HM_DEPLOY_HOME}/releases/20260101010102/index.html"

# shellcheck disable=SC1091
source lib/site/tx.sh
# shellcheck disable=SC1091
source commands/git/main.sh

ln -sfn target "${root}/probe" 2>/dev/null || true
if ! ls -ld "${root}/probe" 2>/dev/null | grep -q -- '->'; then
  ok switch-platform
else
  hm_deploy_switch_current "${HM_DEPLOY_HOME}" 20260101010101 || bad switch-a
  before="$(readlink "${HM_DEPLOY_HOME}/current")"
  i=0
  while [[ "${i}" -lt 20 ]]; do
    hm_deploy_switch_current "${HM_DEPLOY_HOME}" 20260101010102 || bad switch-b
    hm_deploy_switch_current "${HM_DEPLOY_HOME}" 20260101010101 || bad switch-a2
    now="$(readlink "${HM_DEPLOY_HOME}/current" || true)"
    [[ -n "${now}" && -e "${HM_DEPLOY_HOME}/${now}" ]] || bad switch-empty
    i=$((i + 1))
  done
  [[ -n "${before}" ]] && ok switch-atomic || bad switch-atomic
fi

export HM_DEPLOY_BUILD_FAIL=1
hm_deploy_switch_current "${HM_DEPLOY_HOME}" 20260101010101 || true
snap="$(readlink "${HM_DEPLOY_HOME}/current" 2>/dev/null || echo none)"
if hm_deploy_release_apply 20260101010102; then bad build-rc; else ok build-rc; fi
[[ "$(readlink "${HM_DEPLOY_HOME}/current" 2>/dev/null || echo none)" == "${snap}" ]] && ok build-keeps || bad build-keeps
grep -q failed "${HM_DEPLOY_HOME}/releases/20260101010102/.hm-release-status" && ok build-mark || bad build-mark
unset HM_DEPLOY_BUILD_FAIL

export HM_DEPLOY_HEALTH_MOCK=bad
if hm_deploy_release_apply 20260101010102; then bad health-rc; else ok health-rc; fi
[[ "$(readlink "${HM_DEPLOY_HOME}/current" 2>/dev/null || echo none)" == "${snap}" ]] && ok health-keeps || bad health-keeps
unset HM_DEPLOY_HEALTH_MOCK

secret="token-SECRET-value"
log="${root}/hook.log"
printf '403\n' > "${root}/code"
code="$(hm_deploy_webhook_handle '{"ref":"main"}' "sha256=dead" "${secret}" "${log}" || true)"
[[ "${code}" == "403" ]] && ok hook-403 || bad hook-403
grep -q "${secret}" "${log}" && bad hook-leak || ok hook-noleak
if command -v openssl >/dev/null 2>&1; then
  good="$(printf '%s' '{"ref":"main"}' | openssl dgst -sha256 -hmac "${secret}" | awk '{print $NF}')"
  code="$(hm_deploy_webhook_handle '{"ref":"main"}' "sha256=${good}" "${secret}" "${log}")"
  [[ "${code}" == "202" ]] && ok hook-202 || bad hook-202
  grep -q "${secret}" "${log}" && bad hook-leak2 || ok hook-noleak2
else
  ok hook-openssl-platform
fi

# C5: releases jako symlink → odmowa prune / apply
vic="${root}/victim"
mkdir -p "${vic}/keep1" "${vic}/keep2" "${vic}/drop1" "${vic}/drop2"
printf 'x\n' > "${vic}/drop1/f"
sec_home="${root}/sec"
mkdir -p "${sec_home}"
ln -sfn "${vic}" "${sec_home}/releases" 2>/dev/null || true
if ls -ld "${sec_home}/releases" 2>/dev/null | grep -q -- '->'; then
  export HM_DEPLOY_HOME="${sec_home}"
  if hm_deploy_release_prune "${sec_home}" 2 >/dev/null 2>&1; then bad prune-symlink-rc; else ok prune-symlink-rc; fi
  [[ -d "${vic}/drop1" ]] && ok prune-victim-kept || bad prune-victim-kept
  if hm_deploy_release_apply 20990101010101 >/dev/null 2>&1; then bad apply-symlink-rc; else ok apply-symlink-rc; fi
  [[ -d "${vic}/drop1" ]] && ok apply-victim-kept || bad apply-victim-kept
else
  ok prune-symlink-platform
  ok prune-victim-kept
  ok apply-symlink-platform
  ok apply-victim-kept
fi

# status przez symlink odmowa
export HM_DEPLOY_HOME="${root}/app"
mkdir -p "${HM_DEPLOY_HOME}/releases/statustest"
ln -sfn "${root}/evil-status" "${HM_DEPLOY_HOME}/releases/statustest/.hm-release-status" 2>/dev/null || true
printf 'SAFE\n' > "${root}/evil-status"
if ls -ld "${HM_DEPLOY_HOME}/releases/statustest/.hm-release-status" 2>/dev/null | grep -q -- '->'; then
  if hm_deploy_status_write "${HM_DEPLOY_HOME}/releases/statustest/.hm-release-status" "ok" >/dev/null 2>&1; then
    bad status-symlink-rc
  else
    ok status-symlink-rc
  fi
  grep -q 'SAFE' "${root}/evil-status" && ok status-symlink-kept || bad status-symlink-kept
else
  ok status-symlink-platform
  ok status-symlink-kept
fi

# rollback tylko status=ok
export HM_DEPLOY_HOME="${root}/rb"
mkdir -p "${HM_DEPLOY_HOME}/releases/20260101010101" "${HM_DEPLOY_HOME}/releases/20260101010102" "${HM_DEPLOY_HOME}/releases/20260101010103"
printf 'ok\n' > "${HM_DEPLOY_HOME}/releases/20260101010101/.hm-release-status"
printf 'failed\n' > "${HM_DEPLOY_HOME}/releases/20260101010102/.hm-release-status"
printf 'ok\n' > "${HM_DEPLOY_HOME}/releases/20260101010103/.hm-release-status"
ln -sfn "releases/20260101010103" "${HM_DEPLOY_HOME}/current" 2>/dev/null || true
if ls -ld "${HM_DEPLOY_HOME}/current" 2>/dev/null | grep -q -- '->'; then
  hm_deploy_release_rollback || bad rb-ok-rc
  now="$(readlink "${HM_DEPLOY_HOME}/current")"
  [[ "${now}" == "releases/20260101010101" ]] && ok rb-skip-failed || bad rb-skip-failed
else
  ok rb-ok-platform
  ok rb-skip-failed
fi

[[ "${fail}" -eq 0 ]] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
