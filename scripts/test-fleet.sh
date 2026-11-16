#!/usr/bin/env bash
# fleet — inwentarz, run równoległy, agregaty, mock SSH.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"
export HMTOOLS_ROOT="${ROOT}"
export HMTOOLS_TEST=1

# shellcheck disable=SC1091
source scripts/_stubs.sh
# shellcheck source=../lib/common/json.sh
source lib/common/json.sh
# shellcheck disable=SC1091
source commands/fleet/main.sh

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

hm_help_topic() { :; }
FLEET_CONFIRM=0
hm_confirm_plan() {
  [[ "${FLEET_CONFIRM}" -eq 1 ]] && return 0
  return 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
export HM_FLEET_DIR="${tmp}/fleet"
export HM_FLEET_SSH="${ROOT}/scripts/fixtures/fleet/mock-ssh.sh"
export HM_FLEET_KEYSCAN="${ROOT}/scripts/fixtures/fleet/mock-keyscan.sh"
export HM_FLEET_PARALLEL=2
export HM_FLEET_TIMEOUT=5

chmod +x "${HM_FLEET_SSH}" "${HM_FLEET_KEYSCAN}"

hm_fleet_add web1 'root@10.0.0.1' --tags prod,wp >/dev/null || bad add-web1
hm_fleet_add web2 'deploy@10.0.0.2:2222' --tags staging >/dev/null || bad add-web2

mode="$(stat -c '%a' "${HM_FLEET_INVENTORY}" 2>/dev/null || stat -f '%OLp' "${HM_FLEET_INVENTORY}" 2>/dev/null || echo '?')"
mode="${mode##0}"
if [[ "${mode}" == "600" ]]; then
  ok inventory-0600
elif [[ "${mode}" == "644" && "${OSTYPE:-}" == msys* ]]; then
  ok inventory-0600-msys
else
  bad "inventory-0600 (got ${mode})"
fi

grep -qxF 'root@10.0.0.1' <(hm_fleet_list 2>/dev/null | true) || true
out_list="$(hm_fleet_list 2>/dev/null || true)"
printf '%s\n' "${out_list}" | grep -q 'web1' && printf '%s\n' "${out_list}" | grep -q 'prod,wp' && ok list || bad list

grep -q 'ssh-ed25519' "${HM_FLEET_KNOWN_HOSTS}" && ok known-hosts || bad known-hosts

hm_fleet_test >/dev/null 2>&1 && ok test-all || bad test

tags_out="$(hm_fleet_select_hosts "" "prod")"
printf '%s\n' "${tags_out}" | grep -qxF 'web1' && ok tags-prod || bad tags-prod
printf '%s\n' "${tags_out}" | grep -qxF 'web2' && bad tags-staging-only || ok tags-staging-only

run_out="$(hm_fleet_run "echo fleet-ok" --tags prod 2>/dev/null || true)"
printf '%s\n' "${run_out}" | grep -q '\[web1\]' && printf '%s\n' "${run_out}" | grep -q 'fleet-ok' && ok run-one || bad run-one

rc_all=0
run_par="$(hm_fleet_run "version" 2>/dev/null)" || rc_all=$?
printf '%s\n' "${run_par}" | grep -q '\[web1\]' && printf '%s\n' "${run_par}" | grep -q '\[web2\]' && ok run-parallel || bad run-parallel

FLEET_CONFIRM=0
if hm_fleet_run "uninstall-hmtools" 2>/dev/null; then
  bad destructive-no-confirm
else
  ok destructive-no-confirm
fi

FLEET_CONFIRM=1
hm_fleet_run "uninstall-hmtools" --yes >/dev/null 2>&1 && ok destructive-with-yes || bad destructive-with-yes

health="$(hm_fleet_health 2>/dev/null || true)"
printf '%s\n' "${health}" | grep -q 'web1' && printf '%s\n' "${health}" | grep -q 'false' && ok agg-health || bad agg-health

upd="$(hm_fleet_update_check 2>/dev/null || true)"
printf '%s\n' "${upd}" | grep -q 'web2' && printf '%s\n' "${upd}" | grep -q '4' && ok agg-update || bad agg-update

bak="$(hm_fleet_backup_status 2>/dev/null || true)"
printf '%s\n' "${bak}" | grep -q '20260115' && ok agg-backup || bad agg-backup

ssl="$(hm_fleet_ssl 2>/dev/null || true)"
printf '%s\n' "${ssl}" | grep -q 'WKRÓTCE\|1' && ok agg-ssl || bad agg-ssl

report="$(hm_fleet_report 2>/dev/null || true)"
printf '%s\n' "${report}" | grep -q 'Usługi' && ok agg-report || bad agg-report

hm_fleet_remove web2 >/dev/null || bad remove
! hm_fleet_host_line web2 >/dev/null 2>&1 && ok remove-gone || bad remove-gone

# timeout / rc — mock zwraca 127 dla nieznanej komendy
rc_bad=0
hm_fleet_run "unknown-cmd-xyz" 2>/dev/null || rc_bad=$?
[[ "${rc_bad}" -ne 0 ]] && ok run-collective-rc || bad run-collective-rc

# cleanup trap (bez osieroconych — katalog tymczasowy znika)
[[ -z "${HM_FLEET_RUN_TMP:-}" ]] && ok no-run-tmp-left || bad no-run-tmp-left

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"