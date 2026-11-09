#!/usr/bin/env bash
# Karty CDP (bez tokenu WS), polityka URL i czyszczenie cache — bez żywego Chrome.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail=0
ok() { echo "OK   $*"; }
bad() { echo "FAIL $*"; fail=1; }

hm_err() { echo "ERR: $*" >&2; }
hm_ok() { :; }
hm_info() { :; }
hm_warn() { echo "WARN: $*" >&2; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }

# shellcheck source=commands/chrome/cdp.sh
source "${ROOT}/commands/chrome/cdp.sh"
# shellcheck source=commands/chrome/clean.sh
source "${ROOT}/commands/chrome/clean.sh"

bash -n "${ROOT}/commands/chrome/main.sh"
bash -n "${ROOT}/commands/chrome/cdp.sh"
bash -n "${ROOT}/commands/chrome/clean.sh"

export HMTOOLS_TEST=1
export HM_CHROME_JSON_BASH=1

check() {
  local name="$1"
  shift
  if "$@"; then
    ok "${name}"
  else
    bad "${name}"
  fi
}

check_not() {
  local name="$1"
  shift
  if "$@"; then
    bad "${name}"
  else
    ok "${name}"
  fi
}

check loopback-v4 hm_chrome_cdp_is_loopback "http://127.0.0.1:9222"
check loopback-local hm_chrome_cdp_is_loopback "http://localhost:9222/json"
check loopback-v6 hm_chrome_cdp_is_loopback "http://[::1]:9222"
check_not spoof hm_chrome_cdp_is_loopback "http://127.0.0.1.evil.com:9222"
check_not lan hm_chrome_cdp_is_loopback "http://10.0.0.5:9222"
check_not evil hm_chrome_cdp_is_loopback "http://evil.com:9222"
check_not empty hm_chrome_cdp_is_loopback ""
check_not userinfo-trick hm_chrome_cdp_is_loopback "http://127.0.0.1:9222@evil.com"

port="$(hm_chrome_cdp_port "http://[::1]:9222")"
[[ "${port}" == "9222" ]] && ok port-v6 || bad "port-v6=${port}"
port="$(hm_chrome_cdp_port "http://127.0.0.1:9222/json/list")"
[[ "${port}" == "9222" ]] && ok port-v4 || bad "port-v4=${port}"

shown="$(hm_chrome_cdp_url_display "http://user:s3cret@127.0.0.1:9222")"
[[ "${shown}" == "http://127.0.0.1:9222" && "${shown}" != *s3cret* ]] && ok redact-cdp || bad "redact=${shown}"

check url-https hm_chrome_url_allowed "https://example.com/a?x=1&y=2"
check url-blank hm_chrome_url_allowed "about:blank"
check_not url-file hm_chrome_url_allowed "file:///etc/passwd"
check_not url-js hm_chrome_url_allowed "javascript:alert(1)"
check_not url-user hm_chrome_url_allowed "http://user:pass@example.com/"
check_not url-data hm_chrome_url_allowed "data:text/html,hi"
check_not url-space hm_chrome_url_allowed "https://example.com/a b"

enc_path="$(hm_chrome_open_path "https://example.com/a?x=1&y=2")"
[[ "${enc_path}" == '/json/new?https%3A%2F%2Fexample.com%2Fa%3Fx%3D1%26y%3D2' ]] \
  && ok urlencode || bad "urlencode=${enc_path}"
check path-new hm_chrome_cdp_path_ok "${enc_path}"
check path-close hm_chrome_cdp_path_ok "/json/close/ABCDEFGH12345678"
check_not path-trav hm_chrome_cdp_path_ok "/json/close/../etc"
check_not path-extra hm_chrome_cdp_path_ok "/json/close/ABCDEFGH12345678/extra"
check_not id-short hm_chrome_target_id_ok "abc"
check_not id-semi hm_chrome_target_id_ok "ABCDEFGH;rm"

raw='[{"type":"page","id":"ABCDEFGH12345678","title":"a}b \"hi\"","url":"https://ex.com/a}b","webSocketDebuggerUrl":"ws://127.0.0.1/WSSECRETTOKEN"},{"type":"worker","id":"ZZZZZZZZ99999999","title":"w\tork","url":"","webSocketDebuggerUrl":"ws://WSSECRETTOKEN2"}]'
out="$(printf '%s' "${raw}" | hm_chrome_format_targets)"
[[ "${out}" != *WSSECRETTOKEN* && "${out}" != *webSocketDebuggerUrl* ]] && ok no-ws || bad "no-ws=$(printf '%q' "${out}")"
[[ "${out}" == *$'\tABCDEFGH12345678\t'* ]] && ok tab-id || bad "tab-id=$(printf '%q' "${out}")"
[[ "${out}" == *'https://ex.com/a}b'* ]] && ok brace-url || bad "brace-url=$(printf '%q' "${out}")"
[[ "${out}" == *'a}b "hi"'* ]] && ok esc-title || bad "esc-title=$(printf '%q' "${out}")"
[[ "${out}" == *'w ork'* ]] && ok title-tab || bad "title-tab=$(printf '%q' "${out}")"
printf '%s\n' "${out}" | grep -q $'^page\t' && ok page-line || bad page-line

ver='{"Browser" : "Chrome/146", "webSocketDebuggerUrl":"ws://127.0.0.1/WSSECRETTOKEN", "Protocol-Version":"1.3", "V8-Version":"14.6"}'
vout="$(printf '%s' "${ver}" | hm_chrome_print_version_fields)"
[[ "${vout}" != *WSSECRETTOKEN* && "${vout}" != *webSocket* ]] && ok ver-no-ws || bad "ver-no-ws=$(printf '%q' "${vout}")"
[[ "${vout}" == *$'Browser\tChrome/146'* ]] && ok ver-browser || bad "ver-browser=$(printf '%q' "${vout}")"
[[ "${vout}" == *$'Protocol-Version\t1.3'* ]] && ok ver-proto || bad "ver-proto=$(printf '%q' "${vout}")"

check unit-ok hm_chrome_service_allowed "chrome-headless"
check unit-suffix hm_chrome_service_allowed "chrome-headless.service"
check_not unit-nginx hm_chrome_service_allowed "nginx"
check_not unit-inject hm_chrome_service_allowed "chrome-headless;reboot"
CHROME_SERVICE="chromium-headless.service"
[[ "$(hm_chrome_unit)" == "chromium-headless" ]] && ok unit-strip || bad "unit-strip=$(hm_chrome_unit || true)"

ssfile="$(mktemp)"
printf '%s\n' 'tcp LISTEN 0 128 127.0.0.1:9222 0.0.0.0:*' 'tcp LISTEN 0 128 0.0.0.0:9223 0.0.0.0:*' > "${ssfile}"
HM_CHROME_SS_FILE="${ssfile}"
addr="$(hm_chrome_listen_addrs 9222)"
[[ "${addr}" == "127.0.0.1:9222" ]] && ok listen || bad "listen=${addr}"
check addr-lo hm_chrome_addr_is_loopback "127.0.0.1:9222"
check_not addr-any hm_chrome_addr_is_loopback "0.0.0.0:9222"
check addr-6 hm_chrome_addr_is_loopback "[::1]:9222"

aport="$(mktemp -d)"
printf '%s\n' '9333' '/devtools/browser/SECRETUUID' > "${aport}/DevToolsActivePort"
p="$(hm_chrome_active_port_from_file "${aport}/DevToolsActivePort")"
[[ "${p}" == "9333" && "${p}" != *SECRETUUID* ]] && ok active-port || bad "active-port=${p}"
if ln -s "${aport}/DevToolsActivePort" "${aport}/link" 2>/dev/null && [[ -L "${aport}/link" ]]; then
  check_not symlink-port hm_chrome_active_port_from_file "${aport}/link"
else
  rm -f "${aport}/link"
  ok "symlink-port (ten system nie tworzy symlinku, pominięte)"
fi

base="$(mktemp -d)"
root="${base}/puppeteer/chrome"
keep="${root}/linux-146.0.7680.76/chrome-linux64"
old="${root}/linux-120.0.0.0/chrome-linux64"
mkdir -p "${keep}" "${old}"
printf '#!/bin/sh\n' > "${keep}/chrome"
chmod +x "${keep}/chrome"
printf 'old\n' > "${old}/chrome"
have_link=0
if ln -s /tmp "${root}/linux-evil" 2>/dev/null && [[ -L "${root}/linux-evil" ]]; then
  have_link=1
else
  rm -rf "${root}/linux-evil"
fi
tmpd="${base}/tmp"
mkdir -p "${tmpd}/.org.chromium.Chromium.abc"
printf 'x\n' > "${tmpd}/.org.chromium.Chromium.abc/f"
have_tmp_link=0
if ln -s /tmp "${tmpd}/.org.chromium.Chromium.link" 2>/dev/null && [[ -L "${tmpd}/.org.chromium.Chromium.link" ]]; then
  have_tmp_link=1
else
  rm -rf "${tmpd}/.org.chromium.Chromium.link"
fi
mkdir -p "${tmpd}/not-chrome"
data="${base}/profile"
mkdir -p "${data}/Default/Cache" "${data}/Default/Code Cache" "${data}/Default"
printf 'c\n' > "${data}/Default/Cache/x"
printf 'cookie\n' > "${data}/Default/Cookies"
printf 'cc\n' > "${data}/Default/Code Cache/x"

case "${old}" in
  "${base}"/*) ;;
  *) echo "FAIL ścieżka testu poza base"; exit 1 ;;
esac

export HM_CHROME_PUPPETEER_ROOT="${root}"
export HM_CHROME_TMP_ROOT="${tmpd}"
export HM_CHROME_USER_DATA_DIR="${data}"
export CHROME_BIN="${keep}/chrome"
export CHROME_SERVICE="chrome-headless"

cands="$(hm_chrome_clean_candidates)"
[[ "${cands}" == *"linux-120.0.0.0"* ]] && ok cand-old || bad "cand-old=$(printf '%q' "${cands}")"
[[ "${cands}" != *"linux-146.0.7680.76"* ]] && ok cand-keep || bad cand-keep
if [[ "${have_link}" -eq 1 ]]; then
  [[ "${cands}" != *"linux-evil"* ]] && ok cand-link || bad cand-link
else
  ok "cand-link (ten system nie tworzy symlinku, pominięte)"
fi
[[ "${cands}" == *".org.chromium.Chromium.abc"* ]] && ok cand-tmp || bad cand-tmp
if [[ "${have_tmp_link}" -eq 1 ]]; then
  [[ "${cands}" != *"Chromium.link"* ]] && ok cand-tmp-link || bad cand-tmp-link
else
  ok "cand-tmp-link (ten system nie tworzy symlinku, pominięte)"
fi
[[ "${cands}" != *"not-chrome"* ]] && ok cand-other || bad cand-other
[[ "${cands}" == *"Default/Cache"* ]] && ok cand-cache || bad cand-cache
[[ "${cands}" == *"Code Cache"* ]] && ok cand-code || bad cand-code
[[ "${cands}" != *"Cookies"* ]] && ok cand-cookies || bad cand-cookies

check_not del-keep hm_chrome_deletable puppeteer "${keep}"
check_not del-cookies hm_chrome_deletable cache "${data}/Default/Cookies"
check_not del-tmp-root hm_chrome_deletable tmp /tmp
check_not del-inner hm_chrome_deletable puppeteer "${old}"
check del-old hm_chrome_deletable puppeteer "${root}/linux-120.0.0.0"
check_not rm-cookies hm_chrome_rm_tree cache "${data}/Default/Cookies"
[[ -f "${data}/Default/Cookies" ]] && ok cookies-still || bad cookies-still

confirm_called=0
hm_confirm_plan() { confirm_called=1; return 0; }
cmd_chrome_clean --dry-run >/dev/null
[[ "${confirm_called}" -eq 0 && -d "${old}" && -f "${data}/Default/Cookies" && -x "${keep}/chrome" ]] \
  && ok dry-run || bad dry-run
cmd_chrome_clean --yes >/dev/null
[[ "${confirm_called}" -eq 0 && -d "${old}" ]] && ok yes-alone || bad yes-alone

cmd_chrome_clean --execute --yes >/dev/null
[[ ! -d "${old}" ]] && ok exec-old || bad exec-old
[[ -d "${keep}" && -x "${keep}/chrome" ]] && ok exec-keep || bad exec-keep
[[ ! -d "${tmpd}/.org.chromium.Chromium.abc" ]] && ok exec-tmp || bad exec-tmp
if [[ "${have_tmp_link}" -eq 1 ]]; then
  [[ -L "${tmpd}/.org.chromium.Chromium.link" ]] && ok exec-tmplink || bad exec-tmplink
else
  ok "exec-tmplink (ten system nie tworzy symlinku, pominięte)"
fi
[[ ! -d "${data}/Default/Cache" ]] && ok exec-cache || bad exec-cache
[[ ! -e "${data}/Default/Code Cache" ]] && ok exec-cc || bad exec-cc
[[ -f "${data}/Default/Cookies" && -d "${data}/Default" ]] && ok exec-cookies || bad exec-cookies
if [[ "${have_link}" -eq 1 ]]; then
  [[ -L "${root}/linux-evil" ]] && ok exec-evil-link || bad exec-evil-link
else
  ok "exec-evil-link (ten system nie tworzy symlinku, pominięte)"
fi
[[ "${confirm_called}" -eq 1 ]] && ok exec-confirm || bad exec-confirm

mkdir -p "${root}/linux-130.0.0.0"
unset CHROME_BIN
cands2="$(hm_chrome_clean_candidates)"
[[ "${cands2}" != *"linux-130"* ]] && ok no-bin-keeps-linux || bad "no-bin=$(printf '%q' "${cands2}")"
check_not no-bin-del hm_chrome_deletable puppeteer "${root}/linux-130.0.0.0"

CHROME_SERVICE="nginx"
check_not log-nginx cmd_chrome_log 10
check_not log-0 cmd_chrome_log 0
check_not log-201 cmd_chrome_log 201
check_not log-abc cmd_chrome_log abc
check_not restart-nginx cmd_chrome_restart --yes

grep -q 'chrome tabs' "${ROOT}/commands/chrome/main.sh" && ok help-tabs || bad help-tabs
grep -q 'webSocketDebuggerUrl' "${ROOT}/commands/chrome/main.sh" && ok help-ws || bad help-ws
grep -q 'source "${_HM_CHROME_DIR}/cdp.sh"' "${ROOT}/commands/chrome/main.sh" && ok wired-cdp || bad wired-cdp
grep -q -- '--execute' "${ROOT}/lib/complete/tab.sh" && ok tab-complete || bad tab-complete

if command -v python3 >/dev/null 2>&1; then
  pout="$(printf '%s' "${raw}" | hm_chrome_format_targets_py)"
  [[ "${pout}" != *WSSECRETTOKEN* && "${pout}" == *ABCDEFGH12345678* && "${pout}" == *'a}b "hi"'* ]] \
    && ok py-targets || bad "py-targets=$(printf '%q' "${pout}")"
else
  ok "py-targets (brak python3, pominięte)"
fi

rm -rf "${base}" "${aport}" "${ssfile}"

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
