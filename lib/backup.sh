#!/usr/bin/env bash
# Backup → rclone (loader). Implementacja: lib/backup/*.sh

if [[ -n "${HMTOOLS_BACKUP_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_BACKUP_LOADED=1

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_LIB_DIR}/common.sh"
# shellcheck source=detect.sh
source "${_LIB_DIR}/detect.sh"
# shellcheck source=sites.sh
source "${_LIB_DIR}/sites.sh"
# shellcheck source=rclone_drive.sh
source "${_LIB_DIR}/rclone_drive.sh"
# shellcheck source=db.sh
source "${_LIB_DIR}/db.sh"
# shellcheck source=size.sh
source "${_LIB_DIR}/size.sh"

_BACKUP_DIR="${_LIB_DIR}/backup"
# shellcheck source=backup/core.sh
source "${_BACKUP_DIR}/core.sh"
# shellcheck source=backup/list.sh
source "${_BACKUP_DIR}/list.sh"
# shellcheck source=backup/restore.sh
source "${_BACKUP_DIR}/restore.sh"
# shellcheck source=backup/prune.sh
source "${_BACKUP_DIR}/prune.sh"
# shellcheck source=backup/schedule.sh
source "${_BACKUP_DIR}/schedule.sh"
