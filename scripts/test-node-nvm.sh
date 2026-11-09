#!/usr/bin/env bash
# Regresja: node — wykrycie .nvm/.npm obok public_html, wersje, update bez sieci
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }
hm_is_valid_domain() { [[ "$1" == *.* ]]; }
hm_file_log() { :; }
hm_help_topic() { :; }
hm_tsv_unfield() { [[ "${1:-}" == "-" ]] && printf '' || printf '%s' "${1:-}"; }
hm_find_site_by_arg_exact() { printf '%s' "$1"; }
hm_with_site_context() { local d="$1"; shift; HM_SITE_DOMAIN="$d"; "$@"; }
C_BOLD=""; C_RESET=""; C_DIM=""; C_CYAN=""; C_RED=""; C_GREEN=""; C_YELLOW=""
_hm_cmd_help() { cat >/dev/null; }
_hm_cmd_register() { :; }
_hm_cmd_register_site() { :; }
hm_confirm_plan() { return 1; }

fail=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

A="${tmpdir}/a"
B="${tmpdir}/b"
C="${tmpdir}/c"
D="${tmpdir}/d"
mkdir -p "${A}/public_html" "${B}/public_html" "${C}/public_html" "${D}/public_html/.nvm" "${D}/public_html/.npm"
mkdir -p "${A}/.nvm/versions/node/v20.10.0/bin" "${A}/.nvm/alias" "${A}/.npm" "${B}/.npm"
printf '%s\n' 'v20.10.0' > "${A}/.nvm/alias/default"
cat > "${A}/.nvm/nvm.sh" <<'EOF'
nvm() { [ "$1" = "--version" ] && echo 0.39.7; }
EOF
cat > "${A}/.nvm/versions/node/v20.10.0/bin/npm" <<'EOF'
#!/bin/sh
echo 10.2.0
EOF
chmod +x "${A}/.nvm/versions/node/v20.10.0/bin/npm"
mkdir -p "${tmpdir}/bin"
cat > "${tmpdir}/bin/npm" <<'EOF'
#!/bin/sh
echo 9.0.0
EOF
chmod +x "${tmpdir}/bin/npm"
export PATH="${tmpdir}/bin:${PATH}"

hm_discover_sites() { HM_SITES_LIST=(a.test b.test c.test d.test); }
hm_resolve_site_paths() {
  local home=""
  case "$1" in
    a.test) home="${A}" ;;
    b.test) home="${B}" ;;
    c.test) home="${C}" ;;
    d.test) home="${D}" ;;
    *) return 1 ;;
  esac
  printf '%s\t%s\t%s\t-\t-\t-\t%s|active\n' "$1" "${home}" "${home}/public_html" "user1"
}

# shellcheck disable=SC1091
source commands/node/main.sh

HM_NODE_LATEST_LOADED=1
HM_NODE_LATEST_NVM=0.40.1
HM_NODE_LATEST_NPM=10.9.0

cmpv="$(hm_node_ver_cmp 0.39.7 0.40.1)"
[[ "${cmpv}" == "-1" ]] && echo "OK   ver-older" || { echo "FAIL ver-older got=${cmpv}"; fail=1; }
cmpv="$(hm_node_ver_cmp 10.9.0 10.9.0)"
[[ "${cmpv}" == "0" ]] && echo "OK   ver-eq" || { echo "FAIL ver-eq got=${cmpv}"; fail=1; }
cmpv="$(hm_node_ver_cmp 10.9.2 10.9.0)"
[[ "${cmpv}" == "1" ]] && echo "OK   ver-newer" || { echo "FAIL ver-newer got=${cmpv}"; fail=1; }

out="$(hm_node_list_sites)"
echo "${out}" | grep -q 'a.test' && echo "OK   list-nvm" || { echo "FAIL list-nvm"; fail=1; }
echo "${out}" | grep -q 'b.test' && echo "OK   list-npm" || { echo "FAIL list-npm"; fail=1; }
if echo "${out}" | grep -q 'c.test'; then
  echo "FAIL list-skip-empty"
  fail=1
else
  echo "OK   list-skip-empty"
fi
if echo "${out}" | grep -q 'd.test'; then
  echo "FAIL list-not-inside-docroot"
  fail=1
else
  echo "OK   list-not-inside-docroot"
fi
echo "${out}" | grep -q '0.39.7' && echo "OK   nvm-ver" || { echo "FAIL nvm-ver"; echo "${out}"; fail=1; }
echo "${out}" | grep 'a.test' | grep -q 'nvm npm' && echo "OK   update-both" || { echo "FAIL update-both"; echo "${out}"; fail=1; }
echo "${out}" | grep 'b.test' | grep -q '9.0.0' && echo "OK   npm-only-ver" || { echo "FAIL npm-only-ver"; echo "${out}"; fail=1; }

applied=0
hm_node_apply_nvm_update() { applied=1; return 0; }
if hm_node_update_nvm a.test 0; then
  echo "FAIL update-cancel-rc"
  fail=1
else
  echo "OK   update-cancel-rc"
fi
[[ "${applied}" -eq 0 ]] && echo "OK   update-cancel-no-apply" || { echo "FAIL update-cancel-no-apply"; fail=1; }

hm_confirm_plan() { return 0; }
if hm_node_update_nvm a.test 1; then
  echo "OK   update-yes-rc"
else
  echo "FAIL update-yes-rc"
  fail=1
fi
[[ "${applied}" -eq 1 ]] && echo "OK   update-yes-apply" || { echo "FAIL update-yes-apply"; fail=1; }

# już aktualne — bez apply
applied=0
cat > "${A}/.nvm/nvm.sh" <<'EOF'
nvm() { [ "$1" = "--version" ] && echo 0.40.1; }
EOF
hm_confirm_plan() { echo CONFIRM-SHOULD-NOT; return 0; }
up="$(hm_node_update_nvm a.test 0 2>&1 || true)"
if [[ "${up}" == *"aktualne"* && "${up}" != *CONFIRM-SHOULD-NOT* && "${applied}" -eq 0 ]]; then
  echo "OK   update-already"
else
  echo "FAIL update-already got=${up} applied=${applied}"
  fail=1
fi

if [[ "${fail}" -eq 0 ]]; then
  echo "ALL PASSED"
  exit 0
fi
echo "FAILED=${fail}"
exit 1
