#!/usr/bin/env bash
# Mock SSH dla testów fleet — bez sieci, odpowiedzi wg zdalnej komendy hmtools -c.
# Po -- przychodzi JEDEN argv (jak u sshd): „hmtools -c <printf %q cmd>”.
set -euo pipefail

REMOTE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --)
      shift
      REMOTE="${1:-}"
      break
      ;;
    -p|-o) shift 2 ;;
    -*) shift ;;
    *@*)
      shift
      ;;
    *)
      shift
      ;;
  esac
done

# Rozwiń printf %q z remote_one → argv: bin -c <cmd>
CMD=""
if [[ -n "${REMOTE}" ]]; then
  # shellcheck disable=SC2086
  eval "set -- ${REMOTE}"
  if [[ "${2:-}" == "-c" ]]; then
    CMD="${3:-}"
  else
    CMD="${REMOTE}"
  fi
fi

# Test połączenia / prosty echo
if [[ "${CMD}" == *"doctor --json"* || "${REMOTE}" == *"doctor --json"* ]]; then
  printf '{"version":"v0.1.13","tools":{"ssh":"ok"}}\n'
  exit 0
fi

case "${CMD}" in
  *"health --check --json"*)
    if [[ "${HM_FLEET_MOCK_FAIL_HEALTH:-}" == "1" ]]; then
      echo "ssh fail" >&2
      exit 1
    fi
    echo '{"ok":false,"alerts":["disk:used=95%>=90%"],"disk_used":95}'
    exit 0
    ;;
  *"update check --json"*)
    echo '{"upgradable":4,"security":1,"reboot":"yes","cyberpanel":"2.3.9"}'
    exit 0
    ;;
  *"backup list --json"*)
    echo '{"snapshots":[{"scope":"shop.example","stamp":"20260115-120000","age_seconds":7200,"ok":true}]}'
    exit 0
    ;;
  *"ssl --json"*)
    echo '{"certs":[{"domain":"a.example","status":"OK","days":90,"expiry":"2026-06-01"},{"domain":"b.example","status":"WKRÓTCE","days":5,"expiry":"2026-01-20"}]}'
    exit 0
    ;;
  *"report weekly --json"*)
    # Klucz „issues” jak report --json; mock z „issue” też obsługiwany w fleet report.
    echo '{"report":"weekly","sections":[{"title":"Usługi","issues":1},{"title":"Kopie","issues":0}]}'
    exit 0
    ;;
  "echo fleet-ok"|"version"|*"echo fleet-ok"*|*"version"*)
    echo fleet-ok
    exit 0
    ;;
  *uninstall*|*purge*|*delete*)
    echo "destructive-ok"
    exit 0
    ;;
esac

echo "mock-ssh: nieobsługiwane: REMOTE=${REMOTE} CMD=${CMD}" >&2
exit 127
