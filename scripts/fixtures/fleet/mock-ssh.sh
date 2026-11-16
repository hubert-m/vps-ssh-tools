#!/usr/bin/env bash
# Mock SSH dla testów fleet — bez sieci, odpowiedzi wg zdalnej komendy hmtools -c.
set -euo pipefail

REMOTE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --)
      shift
      REMOTE="$*"
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

# Test połączenia / prosty echo
if [[ "${REMOTE}" == *"doctor --json"* ]]; then
  printf '{"version":"v0.1.13","tools":{"ssh":"ok"}}\n'
  exit 0
fi

case "${REMOTE}" in
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
    echo '{"report":"weekly","sections":[{"title":"Usługi","issues":1},{"title":"Kopie","issues":0}]}'
    exit 0
    ;;
  *"echo fleet-ok"*|*"version"*)
    echo fleet-ok
    exit 0
    ;;
  *uninstall*|*purge*|*delete*)
    echo "destructive-ok"
    exit 0
    ;;
esac

echo "mock-ssh: nieobsługiwane: ${REMOTE}" >&2
exit 127