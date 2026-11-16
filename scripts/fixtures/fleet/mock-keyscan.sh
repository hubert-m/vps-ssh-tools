#!/usr/bin/env bash
# Mock ssh-keyscan dla testów fleet.
set -euo pipefail
host="mock"
port="22"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) port="${2:-22}"; shift 2 ;;
    -H) shift ;;
    -T) shift 2 || shift ;;
    *) host="${1}"; shift ;;
  esac
done
printf '%s ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMockFleetTestKeyForHost%sPort%s\n' \
  "${host}" "${host}" "${port}"
exit 0