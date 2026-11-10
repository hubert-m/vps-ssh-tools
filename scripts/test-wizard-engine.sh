#!/usr/bin/env bash
# Silnik kreatora: wstecz, zła wartość, multi, anulowanie, sekret, dry-run, brak TTY.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1
unset HMTOOLS_TEST_NO_TTY || true

# shellcheck disable=SC1091
source lib/common/ui.sh
hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_have_cmd() { return 1; }
hm_confirm_plan() { return 0; }
hm_is_valid_domain() { return 0; }

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
export HM_WIZ_TMP_DIR="${root}/var/lib/hmtools/tmp"
export HM_WIZ_STATE_FILE="${root}/answers.json"
export HM_WIZ_SS_FILE="${root}/ss.txt"
printf 'LISTEN 0 128 0.0.0.0:80 \n' > "${HM_WIZ_SS_FILE}"
mkdir -p "${HM_WIZ_TMP_DIR}"

# shellcheck disable=SC1091
source lib/wizard.sh
# shellcheck disable=SC1091
source commands/site-create/wizard-db.sh

ask_domain() { hm_wiz_input_text "$1" "Domena" ""; }
valid_domain() { [[ "${HM_WIZ[$1]}" == *.* ]]; }
ask_runtime() { hm_wiz_input_choice "$1"; }
ask_php() { hm_wiz_input_choice "$1"; }
ask_ext() { hm_wiz_input_multi "$1"; }
ask_port() { hm_wiz_input_port "$1"; }
ask_secret() { hm_wiz_input_secret "$1"; }
when_php() { [[ "${HM_WIZ[runtime]:-}" == "PHP" ]]; }
wiz_apply() {
  printf '%s %s %s %s\n' "${HM_WIZ[domain]}" "${HM_WIZ[runtime]}" "${HM_WIZ[ext]}" "${HM_WIZ[port]}" > "${root}/marker"
}

setup_steps() {
  hm_wiz_reset
  hm_wiz_step domain "Domena" ask_domain valid_domain
  hm_wiz_help domain "Podaj FQDN."
  hm_wiz_step runtime "Runtime" ask_runtime
  hm_wiz_options runtime $'PHP\nNode.js'
  hm_wiz_step php "Wersja PHP" ask_php "" when_php
  hm_wiz_options php $'*8.4\n8.3'
  hm_wiz_step ext "Rozszerzenia" ask_ext
  hm_wiz_options ext $'gd\nmbstring\ncurl\nzip'
  hm_wiz_step port "Port" ask_port
  hm_wiz_step secret "Hasło" ask_secret
  hm_wiz_mark_secret secret
  HM_WIZ_PLAN=("katalog serwisu" "pula php")
  HM_WIZ_APPLY=wiz_apply
}

export HM_WIZ_FORCE_PROMPT=1
export HM_WIZ_DRY=0
setup_steps
out="${root}/run.out"
err="${root}/run.err"
hm_wiz_run >"${out}" 2>"${err}" <<'EOF'
?
bad-domain
sklep.example.pl
!
<
shop.example.pl
1
1
1,3
80
8080
WIZSECRET9
yes
EOF
grep -q 'Podaj FQDN' "${out}" && ok help || bad help
grep -q 'Nieprawidłowa wartość' "${err}" && ok invalid || bad invalid
grep -q 'shop.example.pl' "${root}/marker" && ok back-domain || bad back-domain
grep -q 'PHP gd,curl 8080' "${root}/marker" && ok multi || bad multi
grep -q 'WIZSECRET9' "${out}" "${err}" "${root}/answers.json" "${root}/marker" && bad secret-leaked || ok secret-hidden
ps -ef >"${root}/ps.txt" 2>/dev/null || ps aux >"${root}/ps.txt" 2>/dev/null || : >"${root}/ps.txt"
if grep -q 'WIZSECRET9' "${root}/ps.txt"; then bad secret-ps; else ok secret-ps; fi
[[ -d "${HM_WIZ_TMP_DIR}/wiz-$$" ]] && bad tmp-left || ok tmp-clean

# anulowanie nie zostawia tmp ani markera
rm -f "${root}/marker"
setup_steps
if hm_wiz_run >"${root}/cancel.out" 2>"${root}/cancel.err" <<'EOF'
q
EOF
then
  bad cancel-rc
else
  ok cancel-rc
fi
[[ -e "${root}/marker" ]] && bad cancel-marker || ok cancel-marker
find "${HM_WIZ_TMP_DIR}" -mindepth 1 | grep -q . && bad cancel-tmp || ok cancel-tmp

# dry-run: plan bez apply
rm -f "${root}/marker"
export HM_WIZ_DRY=1
setup_steps
hm_wiz_run >"${root}/dry.out" 2>"${root}/dry.err" <<'EOF'
dry.example.pl
1
1
1,3
8080
WIZSECRET9
EOF
grep -q 'dry-run: brak zmian' "${root}/dry.out" && ok dry-msg || bad dry-msg
[[ -e "${root}/marker" ]] && bad dry-apply || ok dry-apply
export HM_WIZ_DRY=0

# zakres 1-3
hm_wiz_reset
hm_wiz_step only "Pakiety" ask_ext
hm_wiz_options only $'a\nb\nc\nd'
HM_WIZ_APPLY=""
HM_WIZ_PLAN=()
hm_wiz_run >"${root}/range.out" <<'EOF'
1-3
yes
EOF
[[ "${HM_WIZ[only]:-}" == "a,b,c" ]] && ok multi-range || bad multi-range

# brak flagi bez TTY
export HM_WIZ_FORCE_PROMPT=0
export HM_WIZ_NONINTERACTIVE=1
hm_wiz_reset
hm_wiz_step php "Wersja PHP" ask_php
hm_wiz_flag php --php 1
set +e
hm_wiz_run >"${root}/batch.out" 2>"${root}/batch.err"
rc=$?
set -e
[[ "${rc}" -ne 0 ]] && ok batch-rc || bad batch-rc
grep -q 'Brak --php (wymagane w trybie nieinteraktywnym)' "${root}/batch.err" && ok batch-msg || bad batch-msg

# site new bez argumentów nie wisi
set +e
cmd_site_new >"${root}/empty.out" 2>"${root}/empty.err"
rc=$?
set -e
[[ "${rc}" -ne 0 ]] && ok empty-rc || bad empty-rc
grep -q 'Brak --domain (wymagane w trybie nieinteraktywnym)' "${root}/empty.err" && ok empty-msg || bad empty-msg

# --dry-run na ścieżce flag nie tworzy katalogu
export HM_WIZ_NONINTERACTIVE=0
mkdir -p "${root}/homes"
export HM_SITE_HOME_BASE="${root}/homes"
cmd_site_new flag.example --dry-run --db none --yes >"${root}/flagdry.out"
grep -q 'dry-run: brak zmian' "${root}/flagdry.out" && ok flag-dry || bad flag-dry
[[ -d "${root}/homes/flag.example" ]] && bad flag-dry-dir || ok flag-dry-dir

[[ "${fail}" -eq 0 ]] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
