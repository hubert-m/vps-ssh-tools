#!/usr/bin/env bash
# Moduł: delete-site

_HM_DEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=delete.sh
source "${_HM_DEL_DIR}/delete.sh"

_hm_cmd_register delete-site cmd_delete_site 0 deletesite destroy-site
