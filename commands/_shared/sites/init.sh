#!/usr/bin/env bash
# Wspólne helpery discovery/vhost/ssl/print stron
declare -ga HM_SITES_LIST=()
_HM_SHARED_SITES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vhost.sh
source "${_HM_SHARED_SITES}/vhost.sh"
# shellcheck source=ssl.sh
source "${_HM_SHARED_SITES}/ssl.sh"
# shellcheck source=discover.sh
source "${_HM_SHARED_SITES}/discover.sh"
# shellcheck source=print.sh
source "${_HM_SHARED_SITES}/print.sh"
