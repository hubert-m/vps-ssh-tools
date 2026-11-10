#!/usr/bin/env bash
# site new --dry-run --json, site show --json, help i Tab.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1
export HMTOOLS_TEST_NO_TTY=1

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

# shellcheck disable=SC1091
source lib/common/ui.sh
hm_confirm_plan() { return 0; }
hm_info() { printf 'INFO %s\n' "$*"; }
hm_warn() { printf 'WARN %s\n' "$*"; }
hm_ok() { printf 'OK %s\n' "$*"; }

declare -gA HM_CMD_HELP=()
declare -gA HM_CMD_ENTRY=()
declare -gA HM_CMD_ALIAS_MAP=()
declare -gA HM_CMD_RESTRICTED=()
declare -gA HM_CMD_SITE_ENTRY=()
_hm_cmd_help() { local topic="$1"; HM_CMD_HELP["${topic}"]="$(cat)"; }
_hm_cmd_register() { :; }
_hm_cmd_register_site() { :; }

# shellcheck disable=SC1091
source lib/site/tx.sh
# shellcheck disable=SC1091
source commands/site-create/main.sh

js="$(cmd_site_new app.example --runtime php --db mysql --php 8.4 --webserver nginx --preset laravel --dry-run --json)"
printf '%s\n' "${js}" | grep -q '"dry_run":true' && ok "dry-json-flag" || bad "dry-json-flag"
printf '%s\n' "${js}" | grep -q '"domain":"app.example"' && ok "dry-json-domain" || bad "dry-json-domain"
printf '%s\n' "${js}" | grep -q '"runtime":"php"' && ok "dry-json-runtime" || bad "dry-json-runtime"
printf '%s\n' "${js}" | grep -q '"db":"mysql"' && ok "dry-json-db" || bad "dry-json-db"
printf '%s\n' "${js}" | grep -q '"php":"8.4"' && ok "dry-json-php" || bad "dry-json-php"
printf '%s\n' "${js}" | grep -q '"webserver":"nginx"' && ok "dry-json-web" || bad "dry-json-web"
printf '%s\n' "${js}" | grep -q 'password\|secret\|GenPass' && bad "dry-json-secret" || ok "dry-json-secret"
printf '%s\n' "${js}" | head -1 | grep -q '^{' && ok "dry-json-only" || { bad "dry-json-only"; printf '%s\n' "${js}" >&2; }

root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
export HM_SITE_MANIFEST_DIR="${root}/manifest"
mkdir -p "${HM_SITE_MANIFEST_DIR}"
# tx.sh jest załadowany przed db.sh — ścieżka to katalog manifestu.
man="$(hm_site_manifest_path app.example)"
mkdir -p "$(dirname "${man}")"
cat > "${man}" <<'EOF'
{"schema":1,"domain":"app.example","webserver":"nginx","runtime":{"type":"php","version":"8.4","manager":"fpm"},"env_file":"/home/app.example/shared/.env","password":"SuperSecret99"}
EOF
show="$(cmd_site_show app.example)"
printf '%s\n' "${show}" | grep -q $'runtime\tphp' && ok "show-runtime" || bad "show-runtime"
printf '%s\n' "${show}" | grep -q 'SuperSecret99' && bad "show-secret" || ok "show-secret"
sjs="$(cmd_site_show app.example --json)"
printf '%s\n' "${sjs}" | grep -q '"domain":"app.example"' && ok "show-json" || bad "show-json"
printf '%s\n' "${sjs}" | grep -q 'SuperSecret99' && bad "show-json-secret" || ok "show-json-secret"
printf '%s\n' "${sjs}" | grep -F -q '"password":"****"' && ok "show-json-mask" || bad "show-json-mask"

printf '%s\n' "${HM_CMD_HELP[site]:-}" | grep -q 'site new' && ok "help-site-new" || bad "help-site-new"
printf '%s\n' "${HM_CMD_HELP[site]:-}" | grep -q -- '--json' && ok "help-json" || bad "help-json"
printf '%s\n' "${HM_CMD_HELP[new-site]:-}" | grep -q 'site new' && ok "help-alias" || bad "help-alias"

# shellcheck disable=SC1091
source lib/complete/helpers.sh
# shellcheck disable=SC1091
source lib/complete/tab.sh
export HM_SITE_VERSION_CACHE="${root}/versions.cache"
printf '%s\n' 'php 8.5' 'php 7.4' 'node 22' 'node 20' > "${HM_SITE_VERSION_CACHE}"

READLINE_LINE='site new --runtime '
READLINE_POINT=${#READLINE_LINE}
rt="$(hm_tab_complete)"
printf '%s\n' "${rt}" | grep -q 'php' && printf '%s\n' "${rt}" | grep -q 'node' && ok "tab-runtime" || bad "tab-runtime"

READLINE_LINE='site new --php '
READLINE_POINT=${#READLINE_LINE}
pv="$(hm_tab_complete)"
printf '%s\n' "${pv}" | grep -q '8.5' && printf '%s\n' "${pv}" | grep -q '7.4' && ok "tab-php-cache" || bad "tab-php-cache"

READLINE_LINE='new-site --j'
READLINE_POINT=${#READLINE_LINE}
hm_tab_complete
[[ "${READLINE_LINE}" == *'--json'* ]] && ok "tab-json" || bad "tab-json line=${READLINE_LINE}"

if [[ "${fail}" -ne 0 ]]; then
  echo FAILED
  exit 1
fi
echo "ALL OK"
